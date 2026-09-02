# M1-06 Progress Notes & Timeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Append-only progress notes, a reverse-chronological timeline, and FR-2's five-minute
correction window implemented as redact-and-reappend rather than mutation.

**Architecture:** A `NoteService` sibling of `StatusService` owns the three writes (add, correct,
redact); a pure `NoteCorrection` owns the window rule; `EventQueries` owns the redaction exclusion
so M2-01 and M3-03 inherit it rather than restating it. UI state lives in a `NoteComposerModel` in
`StenoKit` — testable headlessly — with `MainWindowModel+Notes` as the thin layer supplying the
selected task and reloading after writes.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XcodeGen, SwiftLint (`--strict`),
swift-format. macOS 14.0 floor.

**Spec:** [`docs/superpowers/specs/2026-09-02-m1-06-progress-notes-design.md`](../specs/2026-09-02-m1-06-progress-notes-design.md)

## Global Constraints

- **Never commit to `main`.** Branch `feat/progress-notes` is already created. One PR; **do not
  merge it** (CLAUDE.md, §9.5).
- **`make build && make test && make lint` must all pass before the PR.** Verify, don't assert.
- **The event log is append-only.** No code path may write to an existing `Event` row except to
  flip `isRedacted`. Every `Event` field is `private(set)`; **do not add a setter**, including a
  test-only one.
- **SwiftLint runs `--strict`** — every warning is an error. `file_length` caps files at **400
  lines**. `identifier_name` needs 3+ characters. The literal `TODO`/`FIXME` is rejected: write
  "Superseded by M2-01: …" instead. `large_tuple` caps tuples at 2 members.
- **The loop is `make format && make lint`.** swift-format owns layout, SwiftLint owns semantics
  (D-013). When lint fails after formatting, restructure the code — do not add a disable comment,
  and do not edit `.swiftlint.yml` from inside a feature task.
- **Tests use `ModelContext(container)`, never `container.mainContext`** — the latter does not
  retain its container and dangles into an `EXC_BREAKPOINT` on the next write.
- **No enum inside a SwiftData `#Predicate`** — it does not compile in either spelling. Filter
  kinds in memory after the fetch; D18 caps the dataset under 20 live tasks.
- **A `@Test` function taking a `private` type as a parameter must itself be `private`.**
- `make test` hides parameterized-test cases; the absence of per-case rows is not a failure.

All code below was compiled at module scope against `StenoKit`, the `Steno` app target, and the
`StenoTests` bundle with the swift-testing macro plugin, then run through `swift-format` and
`swiftlint --strict` (0 violations across 113 files, format-stable). Where a step says something
compiles, it was built — not predicted.

---

## What changed from the spec, and why

Four design changes, found by building the code rather than describing it.

1. **`MainWindowModel.swift` is at 396 lines against a 400-line hard cap.** Measured: a 406-line
   copy fails `swiftlint --strict` with `file_length`. The spec put composer state on that type;
   there is no room. Task 1 extracts the project actions to `+Projects.swift` (dropping it to 295),
   and composer state moves into its own `NoteComposerModel` — the `CaptureFieldModel` precedent,
   and better than what the spec described.
2. **`NoteComposerModel` holds no back-reference to `MainWindowModel`.** Its inputs arrive as
   parameters, which is what lets it be a `let` initialised in `init` rather than an optional
   assigned after `self` becomes available.
3. **No `Timer` on the model.** `TaskDetailView` drives the recompute with a Combine
   `Timer.publish`, owned by the view that needs it. In Swift 6 a `@MainActor` class cannot
   invalidate a timer from its nonisolated `deinit`, so a model-owned timer needed a wrapper object
   for no benefit.
4. **The invariant guard is split into a pure comparison and a fetching wrapper.** The spec
   proposed proving it by temporarily breaking `correct`. Instead `expectAppendOnly(before:after:)`
   takes two snapshot dictionaries, so three permanent `withKnownIssue` tests prove the guard
   catches mutation and deletion and accepts a redaction — with **no test-only setter on `Event`**,
   which its own doc comment forbids.

Two measured facts to carry into implementation:

- **`context.rollback()` leaves the held object stale.** After a failed correction the in-memory
  `Event` still reports `isRedacted == true` while a fetch of the same row returns `false`, and the
  replacement insert is discarded. Verified by running it. This is why every failure path reloads.
- **`.onKeyPress(KeyEquivalent("n"))` typechecks at the macOS 14.0 floor.**

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `StenoKit/Features/MainWindow/MainWindowModel+Projects.swift` | 1 | **Create.** Project/capture actions, moved verbatim |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | 1, 3, 8 | **Amend.** Loses the project section; gains `noteComposer` |
| `StenoKit/Models/EventKind.swift` | 2 | **Amend.** `isUserAuthored` |
| `StenoKit/Notes/NoteCorrection.swift` | 2 | **Create.** FR-2's window as a pure rule |
| `StenoKit/Models/EventQueries.swift` | 3 | **Create.** The redaction-excluding descriptor |
| `StenoKit/Notes/NoteService.swift` | 4, 5 | **Create.** Add, correct, redact |
| `StenoTests/Notes/EventLogInvariant.swift` | 6 | **Create.** The append-only guard |
| `StenoKit/Features/MainWindow/NoteComposerMode.swift` | 7 | **Create.** Adding vs correcting |
| `StenoKit/Features/MainWindow/NoteComposerModel.swift` | 7 | **Create.** Draft, mode, correctability |
| `StenoKit/Features/MainWindow/MainWindowModel+Notes.swift` | 8 | **Create.** Composer ↔ store |
| `StenoKit/Features/MainWindow/MainWindowActions.swift` | 8 | **Amend.** `canAddNote`, `addNoteToSelection()` |
| `Steno/Features/MainWindow/NoteComposerView.swift` | 9 | **Create.** The multi-line composer |
| `Steno/Features/MainWindow/TimelineRowView.swift` | 9 | **Create.** One event row and its affordances |
| `Steno/Features/MainWindow/TaskDetailView.swift` | 9 | **Amend.** Hosts composer, rows, timer |
| `Steno/Features/MainWindow/TaskListView.swift` | 9 | **Amend.** `.onKeyPress("n")` |
| `Steno/App/MainWindowCommands.swift` | 9 | **Amend.** "Add Note" ⌘⇧A |
| `docs/DECISIONS.md`, `docs/tasks/*` | 10 | **Amend.** Decisions, ticks, deviations |

`StenoKit/Notes/` is a new directory needing no `project.yml` change — XcodeGen globs
`path: StenoKit` wholesale.

---

### Task 1: Make room in `MainWindowModel` — extract the project actions

**Files:**
- Create: `StenoKit/Features/MainWindow/MainWindowModel+Projects.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift` (delete lines 234–333; widen two
  members from `private` to internal)

**Interfaces:**
- Consumes: nothing new.
- Produces: `MainWindowModel.perform(_:_:)` and `MainWindowModel.fetchOrNil(_:_:)` become internal,
  callable from other files in `StenoKit`. No public API change.

Pure code movement, no behaviour change. First, because Task 8 cannot add a stored property
otherwise.

- [ ] **Step 1: Confirm the constraint before acting on it**

```bash
wc -l StenoKit/Features/MainWindow/MainWindowModel.swift
```

Expected: `396`. If it differs, re-measure the budget before continuing — four lines of headroom is
the entire reason for this task.

- [ ] **Step 2: Create the new file with the moved section**

Move lines 236–333 — from the `/// A capture service over this window's context` doc comment
through the closing brace of `archive(projectID:)` — into a new file, wrapped in an extension.
**Do not edit the moved code.** The members are `captureService()`, `preferredProjectIDForCapture`,
`createProject(named:)`, `updateProject(id:name:jiraKeys:)`, `normalisedKeys(_:)`,
`preferredProjectID()`, `archive(projectID:)`.

```swift
import Foundation
import SwiftData

/// The window's project and capture actions, split out of
/// `MainWindowModel.swift` to keep that file under SwiftLint's `file_length`
/// limit — the same move `+Status.swift` already is, and for the same reason.
/// Same type, same rules: the view never sees a `ModelContext`.
extension MainWindowModel {
    // ... lines 236-333 of MainWindowModel.swift, verbatim ...
}
```

- [ ] **Step 3: Delete the moved section and widen its two dependencies**

Delete lines 234–333 from `MainWindowModel.swift`, including the `// MARK: - Writing` header. Then
widen the two members the moved code calls:

```swift
// was: private func perform(_ what: String, _ mutation: () -> Void) -> Bool {
    func perform(_ what: String, _ mutation: () -> Void) -> Bool {

// was: private func fetchOrNil<T: PersistentModel>(
    func fetchOrNil<T: PersistentModel>(
```

Internal, not public — the app target still cannot reach them, so D-019's "views get no store
access" is untouched, exactly as the earlier `context`/`now`/`save` widening for `+Status` was.

- [ ] **Step 4: Verify the split changed nothing**

```bash
make build && make test && make lint
wc -l StenoKit/Features/MainWindow/MainWindowModel.swift
```

Expected: build green, the **existing** suite passes unchanged (no test added or altered), 0 lint
violations, and the file now reads `295`.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Features/MainWindow/MainWindowModel.swift \
        StenoKit/Features/MainWindow/MainWindowModel+Projects.swift
git commit -m "refactor: split project actions out of MainWindowModel

MainWindowModel.swift sat at 396 lines against SwiftLint's 400-line
file_length cap under --strict, so M1-06 could not add the one stored
property it needs. The project and capture actions move out verbatim,
mirroring MainWindowModel+Status.swift, which exists for the same reason.

perform and fetchOrNil widen from private to internal because the moved code
calls them. Still internal, not public: the app target cannot reach them, so
D-019 is untouched.

No behaviour change - no test was added or altered, and the existing suite
passes unchanged."
```

---

### Task 2: FR-2's window as a pure rule

**Files:**
- Modify: `StenoKit/Models/EventKind.swift`
- Create: `StenoKit/Notes/NoteCorrection.swift`
- Test: `StenoTests/Notes/NoteCorrectionTests.swift`

**Interfaces:**
- Consumes: `EventKind` (existing).
- Produces: `EventKind.isUserAuthored: Bool`; `NoteCorrection.window: TimeInterval` (= 300);
  `NoteCorrection.isCorrectable(kind: EventKind, timestamp: Date, isRedacted: Bool, at: Date) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Notes/NoteCorrectionTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@Test("only the kinds the user typed are correctable", arguments: EventKind.allCases)
func onlyUserAuthoredKindsAreCorrectable(kind: EventKind) {
    let correctable = NoteCorrection.isCorrectable(
        kind: kind, timestamp: origin, isRedacted: false, at: origin)
    #expect(correctable == (kind == .note || kind == .blockedReason))
}

@Test("the window is open before five minutes and closed at five minutes")
func theWindowClosesAtFiveMinutes() {
    func correctable(after seconds: TimeInterval) -> Bool {
        NoteCorrection.isCorrectable(
            kind: .note, timestamp: origin, isRedacted: false,
            at: origin.addingTimeInterval(seconds))
    }
    #expect(correctable(after: 0))
    #expect(correctable(after: 299))
    // Half-open: exactly five minutes is already too late.
    #expect(!correctable(after: 300))
    #expect(!correctable(after: 301))
}

@Test("a redacted event is never correctable")
func aRedactedEventIsNeverCorrectable() {
    #expect(
        !NoteCorrection.isCorrectable(
            kind: .note, timestamp: origin, isRedacted: true, at: origin))
}

@Test("an event stamped in the future stays correctable")
func aFutureEventStaysCorrectable() {
    // Clock jitter, or a §10 import from a Mac running fast. Rejecting a
    // negative age would make such a note permanently uncorrectable, which is
    // both likelier and worse than letting it be corrected early.
    #expect(
        NoteCorrection.isCorrectable(
            kind: .note, timestamp: origin.addingTimeInterval(1), isRedacted: false, at: origin))
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
make test 2>&1 | grep -i "NoteCorrection\|isUserAuthored\|error:"
```

Expected: compile failure — `cannot find 'NoteCorrection' in scope` and `value of type 'EventKind'
has no member 'isUserAuthored'`.

- [ ] **Step 3: Add `isUserAuthored`**

Append to `StenoKit/Models/EventKind.swift`:

```swift
extension EventKind {
    /// Whether the user typed this event's body themselves.
    ///
    /// The one place FR-2's correction and redaction scope is decided: the
    /// service, the timeline, and the tests all read this rather than each
    /// spelling out a pair of cases.
    ///
    /// Exhaustive, with no `default`, so a kind added later is a compile error
    /// here rather than a silent `false`.
    public var isUserAuthored: Bool {
        switch self {
        case .note, .blockedReason:
            true
        case .created, .statusChanged, .externalUpdate, .standupReported:
            false
        }
    }
}
```

- [ ] **Step 4: Create `NoteCorrection`**

Create `StenoKit/Notes/NoteCorrection.swift`:

```swift
import Foundation

/// FR-2's five-minute typo window, as a rule with no store and no clock.
public enum NoteCorrection {
    /// FR-2's grace period.
    public static let window: TimeInterval = 5 * 60

    /// Whether an event may still be corrected at `instant`.
    ///
    /// Takes the four facts it needs rather than an `Event`, so every branch is
    /// testable against literals — which matters because two of this task's
    /// acceptance criteria are statements about this function and nothing else.
    ///
    /// **There is deliberately no lower bound on the age.** An event stamped
    /// slightly in the future — clock jitter, or a §10 import from a Mac whose
    /// clock runs fast — yields a negative interval and stays correctable.
    /// Rejecting negative ages would make a note one second in the future
    /// permanently uncorrectable, which is both likelier and worse.
    public static func isCorrectable(
        kind: EventKind, timestamp: Date, isRedacted: Bool, at instant: Date
    ) -> Bool {
        guard kind.isUserAuthored, !isRedacted else { return false }
        return instant.timeIntervalSince(timestamp) < window
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make build && make test && make lint
```

Expected: PASS, 0 violations.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Models/EventKind.swift StenoKit/Notes/NoteCorrection.swift \
        StenoTests/Notes/NoteCorrectionTests.swift
git commit -m "feat: FR-2's correction window as a pure rule

isCorrectable takes the four facts it needs rather than an Event, so every
branch is testable against literals with no container - two of M1-06's
acceptance criteria are statements about this function and nothing else.

EventKind.isUserAuthored is the single place FR-2's correction and redaction
scope is decided: note and blockedReason, nothing else. The switch is
exhaustive with no default, so M4-01 adding a kind is a compile error here
rather than a silent false.

No lower bound on the age, deliberately: an event stamped slightly in the
future - clock jitter, or a §10 import from a Mac running fast - stays
correctable. Rejecting negative ages would make a note one second in the
future permanently uncorrectable, which is likelier and worse."
```

---

### Task 3: The redaction exclusion becomes a property of the query

**Files:**
- Create: `StenoKit/Models/EventQueries.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift` (`fetchEvents(forTaskID:)`)
- Test: `StenoTests/Notes/EventQueriesTests.swift`

**Interfaces:**
- Consumes: `Event` (existing).
- Produces: `EventQueries.timeline(forTaskID: UUID) -> FetchDescriptor<Event>`

The task file is explicit: redaction hides an event from summaries, and M2-01's gathering and
M3-03's prompt both must honour it — "make the exclusion a property of the query, not of each
caller."

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Notes/EventQueriesTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
@Test("the timeline query excludes redacted rows and sorts newest first")
func theTimelineQueryExcludesRedactedRows() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    let older = Event(taskID: taskID, timestamp: origin, kind: .note, body: "older")
    let newer = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(60), kind: .note, body: "newer")
    let hidden = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(30), kind: .note, body: "hidden")
    let other = Event(taskID: UUID(), timestamp: origin, kind: .note, body: "another task")
    for event in [older, newer, hidden, other] { context.insert(event) }
    hidden.redact()
    try context.save()

    let timeline = try context.fetch(EventQueries.timeline(forTaskID: taskID))

    #expect(timeline.map(\.body) == ["newer", "older"])
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
make test 2>&1 | grep -i "EventQueries\|error:"
```

Expected: `cannot find 'EventQueries' in scope`.

- [ ] **Step 3: Create `EventQueries`**

Create `StenoKit/Models/EventQueries.swift`:

```swift
import Foundation
import SwiftData

/// The event log's shared query vocabulary.
///
/// **Redaction is excluded here, not by each caller.** §3.3 hides a redacted
/// event from summaries, and M2-01's gathering and M3-03's prompt both have to
/// honour that — so the predicate lives in one place rather than being
/// rewritten, and eventually mis-written, per call site.
public enum EventQueries {
    /// One task's timeline: newest first, redacted events excluded.
    ///
    /// The predicate stays `UUID == UUID && !Bool` deliberately. An enum inside
    /// a SwiftData `#Predicate` does not compile in either spelling, so any
    /// kind-based filtering happens in memory after the fetch; D18 caps the
    /// dataset, so the fetch is the cost and the filter is free.
    ///
    /// **Ties are possible and benign.** A correction gives its replacement the
    /// original's timestamp, so two rows can share one instant — but the
    /// original is redacted and this descriptor excludes it, so the two never
    /// both appear. `SortDescriptor` could not break the tie by `id` anyway:
    /// `UUID` is not `Comparable`.
    public static func timeline(forTaskID id: UUID) -> FetchDescriptor<Event> {
        FetchDescriptor<Event>(
            predicate: #Predicate { $0.taskID == id && !$0.isRedacted },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
    }
}
```

- [ ] **Step 4: Route `MainWindowModel` through it**

In `StenoKit/Features/MainWindow/MainWindowModel.swift`, replace the whole of
`fetchEvents(forTaskID:)`:

```swift
// Replace this:
    private func fetchEvents(forTaskID id: UUID) -> [Event]? {
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate { $0.taskID == id && !$0.isRedacted },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return fetchOrNil(descriptor, "load the timeline")
    }

// With this:
    /// The redaction exclusion lives in `EventQueries`, not here: §3.3 hides a
    /// redacted event from summaries too, so M2-01's gathering and M3-03's
    /// prompt read the same rule rather than each restating it.
    private func fetchEvents(forTaskID id: UUID) -> [Event]? {
        fetchOrNil(EventQueries.timeline(forTaskID: id), "load the timeline")
    }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make build && make test && make lint
```

Expected: PASS. The existing `MainWindowModel` timeline tests must still pass unchanged — this is a
move, not a change.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Models/EventQueries.swift \
        StenoKit/Features/MainWindow/MainWindowModel.swift \
        StenoTests/Notes/EventQueriesTests.swift
git commit -m "feat: the redaction exclusion becomes a property of the query

MainWindowModel inlined '!isRedacted' in its own descriptor. §3.3 hides a
redacted event from summaries as well as from the timeline, so M2-01's
gathering and M3-03's prompt need the same rule - and three hand-written
copies of a predicate is three chances to get the exclusion wrong.

The predicate stays UUID == UUID && !Bool. An enum inside a SwiftData
#Predicate does not compile in either spelling, so kind-based filtering
happens in memory after the fetch; D18 caps the dataset."
```

---

### Task 4: `NoteService.addNote` — FR-2's append, with FR-1.5 extraction

**Files:**
- Create: `StenoKit/Notes/NoteService.swift`
- Test: `StenoTests/Notes/NoteServiceTests.swift`

**Interfaces:**
- Consumes: `NoteCorrection` (Task 2), `EventQueries` (Task 3), `ReferenceExtractor`,
  `SourceRef.newRefs(from:existing:)`, `Event`, `TaskItem`.
- Produces:
  - `NoteService.init(context: ModelContext, now: @escaping () -> Date = Date.init, save: @escaping (ModelContext) throws -> Void = { try $0.save() })`
  - `@discardableResult NoteService.addNote(_ text: String, to task: TaskItem) throws -> Event?`

`correct` and `redact` arrive in Task 5. This intermediate state was compiled and builds clean.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Notes/NoteServiceTests.swift` with the fixture and the adding tests:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)
private let withinWindow = origin.addingTimeInterval(120)
private let pastWindow = origin.addingTimeInterval(600)

private struct SaveFailure: Error {}

@MainActor
private func makeTask() throws -> (TaskItem, ModelContext) {
    // `ModelContext(container)`, never `container.mainContext` — the latter
    // does not retain its container and dangles the moment this returns.
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    context.insert(task)
    try context.save()
    return (task, context)
}

@MainActor
private func allEvents(_ context: ModelContext) throws -> [Event] {
    try context.fetch(FetchDescriptor<Event>())
}

// MARK: - Adding

@MainActor
@Test("adding a note appends one note event stamped now")
func addingANoteAppendsOneEvent() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { withinWindow })

    let note = try #require(try service.addNote("Repro'd the race condition", to: task))

    #expect(note.kind == .note)
    #expect(note.body == "Repro'd the race condition")
    #expect(note.timestamp == withinWindow)
    #expect(note.taskID == task.id)
    #expect(!note.isRedacted)
    #expect(try allEvents(context).count == 1)
}

@MainActor
@Test("a blank note writes nothing at all")
func aBlankNoteWritesNothing() throws {
    let (task, context) = try makeTask()
    let counter = WriteCounter()
    let service = NoteService(context: context, now: { withinWindow })

    #expect(try service.addNote("   \n  ", to: task) == nil)
    #expect(try allEvents(context).isEmpty)
    #expect(counter.posts == 0)
}

@MainActor
@Test("a note does not stamp modifiedAt")
func aNoteDoesNotStampModifiedAt() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { withinWindow })

    try service.addNote("progress", to: task)

    // §10.1 resolves task conflicts by "later modifiedAt wins". A note is not
    // an edit of the task, and stamping it would let a note outrank a title
    // genuinely edited on another Mac.
    #expect(task.modifiedAt == origin)
}

@MainActor
@Test("FR-1.5 runs over the note body, and re-noting the same key adds no second ref")
func extractionRunsOverNoteBodiesAndDedupes() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { withinWindow })

    try service.addNote("looking at PAY-421 now", to: task)
    #expect(task.sourceRefs?.count == 1)
    #expect(task.sourceRefs?.first?.identifier == "PAY-421")

    try service.addNote("still on PAY-421, nearly done", to: task)
    #expect(task.sourceRefs?.count == 1)
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
make test 2>&1 | grep -i "NoteService\|error:"
```

Expected: `cannot find 'NoteService' in scope`.

- [ ] **Step 3: Create `NoteService` with `addNote`**

Create `StenoKit/Notes/NoteService.swift`:

```swift
import Foundation
import SwiftData

/// The one path for notes and their correction (FR-2, §3.3).
///
/// A sibling of `StatusService`, not an extension of it: `addBlockedReason`
/// guards on `task.status == .blocked`, but correcting a blocked reason three
/// minutes after the task unblocked must still work. Same rows, different rule.
///
/// Shaped like `StatusService` and `CaptureService`, for their reasons:
/// `@MainActor` because `ModelContext` is not `Sendable`; `now` injected so
/// timestamps are assertable; `save` injected because a real `ModelContext`
/// cannot be made to fail on demand, and the rollback is the path that most
/// needs a test.
///
/// **Correction is redact-and-reappend, never mutation.** `Event`'s fields are
/// all `private(set)`, so the shorter path is a compile error rather than a
/// convention — see `correct(_:to:on:)`.
@MainActor
public struct NoteService {
    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.now = now
        self.save = save
    }

    /// FR-2: append a `note` event carrying `text`.
    ///
    /// Returns `nil` for text that is empty after trimming — a no-op rather
    /// than an error, matching `CaptureService.capture`: a surface committing
    /// an untouched field is not a failure worth reporting.
    ///
    /// **Does not stamp `task.modifiedAt`.** `TaskItem.setStatus` already
    /// declines to, on the grounds that status is derived from the event log;
    /// a note is the same kind of fact. Stamping it would let a task that only
    /// gained a note outrank, in §10.1's "later `modifiedAt` wins" merge, a
    /// task whose title was genuinely edited on another Mac.
    @discardableResult
    public func addNote(_ text: String, to task: TaskItem) throws -> Event? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let event = Event(taskID: task.id, timestamp: now(), kind: .note, body: trimmed)
        context.insert(event)
        insertNewRefs(from: trimmed, on: task)
        try commit()
        return event
    }

    /// FR-1.5 over a note body, deduped against what the task already has.
    ///
    /// `SourceRef.newRefs(from:existing:)`'s first real caller — its doc
    /// comment has said so since M0-03. Unlike `CaptureService`, the task here
    /// is not new, so `existing` is genuinely non-empty and the dedup is doing
    /// work rather than being provably a no-op.
    private func insertNewRefs(from text: String, on task: TaskItem) {
        let candidates = ReferenceExtractor.extract(from: text).map {
            $0.sourceRef(taskID: task.id)
        }
        for ref in SourceRef.newRefs(from: candidates, existing: task.sourceRefs ?? []) {
            context.insert(ref)
            // `sourceRef(taskID:)` sets the foreign key only. D-016 keeps both
            // the key and the relationship, and `PersistedInvariantsTests`
            // asserts they never disagree.
            ref.task = task
        }
    }

    /// Save, roll back on failure, and tell the other surfaces.
    ///
    /// **`rollback()` keeps a failed redaction off disk but does not restore
    /// the in-memory object** — the held `Event` still reports
    /// `isRedacted == true` until a fetch refreshes it. Callers must reload on
    /// the error path, or the timeline hides a note the store still has.
    private func commit() throws {
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        // After the save, never before: an observer that reloads must not be
        // able to read a context whose write has not landed.
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make build && make test && make lint
```

Expected: PASS, 0 violations.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Notes/NoteService.swift StenoTests/Notes/NoteServiceTests.swift
git commit -m "feat: append progress notes with reference extraction - FR-2, FR-1.5

A sibling of StatusService rather than an extension of it: addBlockedReason
guards on status == .blocked, but correcting a blocked reason three minutes
after the task unblocked must still work. Same rows, different rule.

addNote runs FR-1.5 extraction over the body and inserts only what
SourceRef.newRefs says is new - its doc comment has named this path as its
first real caller since M0-03, and unlike CaptureService the task already
exists here, so the dedup is doing work rather than being provably a no-op.

It does not stamp task.modifiedAt. TaskItem.setStatus already declines to on
the grounds that status is derived from the event log; a note is the same
kind of fact. Stamping it would let a task that only gained a note outrank,
in §10.1's later-modifiedAt-wins merge, a task whose title was genuinely
edited on another Mac."
```

---

### Task 5: `correct` and `redact` — redact-and-reappend

**Files:**
- Modify: `StenoKit/Notes/NoteService.swift`
- Test: `StenoTests/Notes/NoteServiceTests.swift` (append)

**Interfaces:**
- Consumes: everything from Task 4.
- Produces:
  - `CorrectionOutcome` — `.corrected`, `.unchanged`, `.windowExpired`, `.notCorrectable`
  - `NoteService.correct(_ event: Event, to text: String, on task: TaskItem) throws -> CorrectionOutcome`
  - `@discardableResult NoteService.redact(_ event: Event) throws -> Bool`

**This is the task the whole milestone exists for.** The replacement carries the original's
timestamp **and kind**; the original is never written to except via `redact()`.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Notes/NoteServiceTests.swift`:

```swift
// MARK: - Correcting

@MainActor
@Test("a correction redacts the original and appends a replacement keeping its timestamp")
func aCorrectionRedactsAndReappends() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("fixed PAY-42", to: task))
    let originalID = original.id
    clock = withinWindow

    #expect(try service.correct(original, to: "fixed PAY-421", on: task) == .corrected)

    let events = try allEvents(context)
    #expect(events.count == 2)

    let kept = try #require(events.first { $0.id == originalID })
    #expect(kept.isRedacted)
    // Untouched apart from the flag — the invariant, asserted directly.
    #expect(kept.body == "fixed PAY-42")
    #expect(kept.timestamp == origin)
    #expect(kept.kind == .note)

    let replacement = try #require(events.first { $0.id != originalID })
    #expect(!replacement.isRedacted)
    #expect(replacement.body == "fixed PAY-421")
    // FR-2: the original timestamp, so the timeline does not reorder mid-correction.
    #expect(replacement.timestamp == origin)
    #expect(replacement.kind == .note)
    #expect(replacement.taskID == task.id)
}

@MainActor
@Test("correcting a blocked reason reappends a blocked reason, not a note")
func correctingABlockedReasonKeepsItsKind() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let context2 = context
    let statuses = StatusService(context: context2, now: { clock })
    let notes = NoteService(context: context2, now: { clock })

    try statuses.setStatus(.blocked, on: task)
    try statuses.addBlockedReason("waiting on infra", to: task)
    let reason = try #require(try allEvents(context2).first { $0.kind == .blockedReason })
    clock = withinWindow

    #expect(try notes.correct(reason, to: "waiting on staging infra", on: task) == .corrected)

    let reasons = try allEvents(context2).filter { $0.kind == .blockedReason }
    #expect(reasons.count == 2)
    // FR-2 says "a new note event"; taken literally this would relabel the row.
    #expect(reasons.contains { !$0.isRedacted && $0.body == "waiting on staging infra" })
}

@MainActor
@Test("past the window a correction writes nothing")
func pastTheWindowNothingIsWritten() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("fixed PAY-42", to: task))
    clock = pastWindow
    let counter = WriteCounter()

    #expect(try service.correct(original, to: "fixed PAY-421", on: task) == .windowExpired)

    #expect(try allEvents(context).count == 1)
    #expect(!original.isRedacted)
    #expect(original.body == "fixed PAY-42")
    #expect(counter.posts == 0)
}

@MainActor
@Test("the window does not restart when a correction is itself corrected")
func theWindowDoesNotRestart() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("first", to: task))
    clock = origin.addingTimeInterval(240)
    #expect(try service.correct(original, to: "second", on: task) == .corrected)

    let replacement = try #require(try allEvents(context).first { !$0.isRedacted })
    // The replacement carries the ORIGINAL timestamp, so at T+4m it is still
    // inside the window — and at T+6m it is not, even though it was written
    // only two minutes earlier.
    clock = origin.addingTimeInterval(290)
    #expect(try service.correct(replacement, to: "third", on: task) == .corrected)

    let third = try #require(try allEvents(context).first { !$0.isRedacted })
    clock = origin.addingTimeInterval(360)
    #expect(try service.correct(third, to: "fourth", on: task) == .windowExpired)
}

@MainActor
@Test("a blank or unchanged correction writes nothing")
func aBlankOrUnchangedCorrectionWritesNothing() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("unchanged", to: task))
    clock = withinWindow

    #expect(try service.correct(original, to: "   ", on: task) == .unchanged)
    #expect(try service.correct(original, to: "unchanged", on: task) == .unchanged)
    // Emptying a correction must not be a back door into redaction.
    #expect(!original.isRedacted)
    #expect(try allEvents(context).count == 1)
}

@MainActor
@Test("system-authored events are not correctable")
func systemEventsAreNotCorrectable() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { origin })
    context.insert(Event(taskID: task.id, timestamp: origin, kind: .created, body: "Task created"))
    try context.save()
    let created = try #require(try allEvents(context).first { $0.kind == .created })

    #expect(try service.correct(created, to: "nope", on: task) == .notCorrectable)
    #expect(try service.redact(created) == false)
    #expect(!created.isRedacted)
}

// MARK: - Redacting

@MainActor
@Test("redacting keeps the row and hides it from the timeline query")
func redactingKeepsTheRow() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { origin })
    let note = try #require(try service.addNote("a mistake", to: task))

    #expect(try service.redact(note))

    // Hidden from the shared query...
    #expect(try context.fetch(EventQueries.timeline(forTaskID: task.id)).isEmpty)
    // ...but the row still exists, which is what §3.3 requires.
    #expect(try allEvents(context).count == 1)
    #expect(try #require(try allEvents(context).first).body == "a mistake")
}

@MainActor
@Test("redacting twice writes only once")
func redactingTwiceWritesOnce() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { origin })
    let note = try #require(try service.addNote("a mistake", to: task))
    try service.redact(note)
    let counter = WriteCounter()

    #expect(try service.redact(note) == false)
    #expect(counter.posts == 0)
}

// MARK: - Failure

@MainActor
@Test("a failed correction leaves the original unredacted on disk, but stale in memory")
func aFailedCorrectionRollsBack() throws {
    let (task, context) = try makeTask()
    var clock = origin
    var shouldFail = false
    let service = NoteService(
        context: context, now: { clock },
        save: { context in
            if shouldFail { throw SaveFailure() }
            try context.save()
        })

    let original = try #require(try service.addNote("fixed PAY-42", to: task))
    clock = withinWindow
    shouldFail = true

    #expect(throws: SaveFailure.self) {
        _ = try service.correct(original, to: "fixed PAY-421", on: task)
    }

    // `commit()` has already rolled back. Two different answers follow, and
    // the gap between them is why every caller must reload on the error path.
    //
    // Measured, not assumed: the replacement insert is discarded and the
    // stored row is clean...
    let stored = try allEvents(context)
    #expect(stored.count == 1)
    #expect(try #require(stored.first).isRedacted == false)
    #expect(try #require(stored.first).body == "fixed PAY-42")

    // ...while the reference the caller still holds reports the rejected flag.
    // A timeline rendered from this object would hide a note the store has.
    #expect(original.isRedacted)
}
```

Note what `aFailedCorrectionRollsBack` asserts, because it is counter-intuitive and was **measured,
not assumed**: after the rollback the stored row is clean (`isRedacted == false`, replacement
discarded) while the reference the caller still holds reports `isRedacted == true`. That gap is
exactly why Task 8's failure paths reload.

- [ ] **Step 2: Run to verify they fail**

```bash
make test 2>&1 | grep -i "correct\|redact\|error:"
```

Expected: `value of type 'NoteService' has no member 'correct'` and `... no member 'redact'`, plus
`cannot find 'CorrectionOutcome' in scope`.

- [ ] **Step 3: Add `CorrectionOutcome`**

Insert above the `NoteService` declaration in `StenoKit/Notes/NoteService.swift`:

```swift
/// What an attempted correction did (FR-2).
///
/// Four cases rather than a `Bool` because the UI's response differs in each:
/// expiry keeps the user's draft and offers to append it, `notCorrectable` is a
/// programming error the UI should never have offered, and `unchanged` is a
/// no-op worth no message at all.
public enum CorrectionOutcome: Equatable, Sendable {
    /// The original was redacted and a replacement appended.
    case corrected
    /// Blank, or byte-identical to the original. Nothing was written.
    case unchanged
    /// Past FR-2's window. Nothing was written; the caller still holds the text.
    case windowExpired
    /// Not a user-authored kind, or already redacted. Nothing was written.
    case notCorrectable
}
```

- [ ] **Step 4: Add `correct` and `redact`**

Insert both methods into `NoteService`, after `addNote` and before the private
`insertNewRefs(from:on:)`:

```swift
    /// FR-2's grace-period "edit", which is not an edit.
    ///
    /// Redacts `event` and appends a **new** row carrying the corrected body,
    /// the **original's timestamp**, and the **original's kind**.
    ///
    /// The timestamp is FR-2's own requirement: it keeps the note where the
    /// user expects it in the timeline instead of jumping to the top
    /// mid-correction. It also means the window does not restart — eligibility
    /// measures from `event.timestamp`, so no chain of corrections reaches past
    /// five minutes from the first write.
    ///
    /// **The kind is a deliberate widening of FR-2**, which says "a new `note`
    /// event" because it predates `blockedReason` being correctable. Hard-coding
    /// `.note` would relabel a corrected blocked reason, changing what §3.3 says
    /// the row means and what M2-02 renders it under.
    public func correct(
        _ event: Event, to text: String, on task: TaskItem
    ) throws -> CorrectionOutcome {
        guard event.kind.isUserAuthored, !event.isRedacted else { return .notCorrectable }
        guard
            NoteCorrection.isCorrectable(
                kind: event.kind, timestamp: event.timestamp, isRedacted: event.isRedacted,
                at: now())
        else { return .windowExpired }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied correction is **not** silently converted into a redaction.
        // Making the destructive, one-way operation the outcome of clearing a
        // text field is exactly the surprise `Event` has no `unredact()` to
        // recover from.
        guard !trimmed.isEmpty, trimmed != event.body else { return .unchanged }

        event.redact()
        context.insert(
            Event(
                taskID: event.taskID, timestamp: event.timestamp, kind: event.kind, body: trimmed))
        insertNewRefs(from: trimmed, on: task)
        try commit()
        return .corrected
    }

    /// §3.3's soft delete: hide the event, retain the row.
    ///
    /// Returns whether it wrote. `false` rather than a throw for an ineligible
    /// event matches `StatusService.setStatus`'s no-op contract — nothing
    /// written, nothing for the caller to reload.
    @discardableResult
    public func redact(_ event: Event) throws -> Bool {
        guard event.kind.isUserAuthored, !event.isRedacted else { return false }
        event.redact()
        try commit()
        return true
    }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make build && make test && make lint
```

Expected: PASS, 0 violations.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Notes/NoteService.swift StenoTests/Notes/NoteServiceTests.swift
git commit -m "feat: correction as redact-and-reappend, never mutation - FR-2

The grace-period edit is not an edit. correct() redacts the original and
appends a new row carrying the corrected body, the original's timestamp, and
the original's kind. Event's fields are all private(set), so the shorter
in-place path is a compile error rather than a convention.

The timestamp is FR-2's own requirement - it keeps the note where the user
expects it instead of jumping to the top mid-correction. It also means the
window does not restart: eligibility measures from event.timestamp, so no
chain of corrections reaches past five minutes from the first write. That is
free, and the alternative is unrepresentable - Event has no field separating
'when written' from 'when it happened'.

The kind is a deliberate widening of FR-2, which says 'a new note event'
because it predates blockedReason being correctable. Hard-coding .note would
relabel a corrected blocked reason and change what §3.3 says the row means.
Flagged in the PR body as a spec deviation.

An emptied correction returns .unchanged and writes nothing. Making the
one-way redaction the outcome of clearing a text field is exactly the
surprise Event has no unredact() to recover from."
```

---

### Task 6: The append-only invariant, as a guard that can fail

**Files:**
- Create: `StenoTests/Notes/EventLogInvariant.swift`
- Create: `StenoTests/Notes/EventLogInvariantTests.swift`

**Interfaces:**
- Consumes: `NoteService` (Tasks 4–5), `StatusService` (existing).
- Produces (test-bundle only): `EventSnapshot`, `eventSnapshots(_:)`,
  `expectAppendOnly(before:after:sourceLocation:)`, `expectingAppendOnly(_:_:sourceLocation:)`

**This is acceptance criterion 2** — "no code path mutates an existing `Event` row except to flip
`isRedacted`; assert it in tests, not just in review." Asserting it per-method is too weak, so this
compares the **whole store** before and after every write path in the app.

The trick is `EventSnapshot` deliberately omitting `isRedacted`. Equality therefore permits exactly
one change and rejects every other, and `#require(after[id])` catches deletion.

- [ ] **Step 1: Write the guard**

Create `StenoTests/Notes/EventLogInvariant.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// Every field of an `Event` **except `isRedacted`**.
///
/// The omission is the whole point. Comparing two snapshots for equality
/// therefore permits exactly one change — the redaction flag — and rejects
/// every other write, which is §3.3's invariant stated as a type rather than
/// as a review comment.
struct EventSnapshot: Hashable {
    let id: UUID
    let taskID: UUID
    let timestamp: Date
    let kind: EventKind
    let body: String
    let payload: Data?

    init(
        id: UUID, taskID: UUID, timestamp: Date, kind: EventKind, body: String,
        payload: Data? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.payload = payload
    }

    init(_ event: Event) {
        self.init(
            id: event.id, taskID: event.taskID, timestamp: event.timestamp, kind: event.kind,
            body: event.body, payload: event.payload)
    }
}

@MainActor
func eventSnapshots(_ context: ModelContext) throws -> [UUID: EventSnapshot] {
    var result: [UUID: EventSnapshot] = [:]
    for event in try context.fetch(FetchDescriptor<Event>()) {
        result[event.id] = EventSnapshot(event)
    }
    return result
}

/// The comparison, separated from the fetching.
///
/// Split out so `theInvariantGuardCanActuallyFail` can feed it a doctored pair
/// of snapshots and prove it reports the mutation — without `Event` acquiring
/// a test-only setter it spent its whole doc comment forbidding.
func expectAppendOnly(
    before: [UUID: EventSnapshot],
    after: [UUID: EventSnapshot],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for (id, was) in before {
        let now = try #require(
            after[id], "event \(id) was deleted from the log", sourceLocation: sourceLocation)
        #expect(
            now == was, "event \(id) was mutated in place, not appended to",
            sourceLocation: sourceLocation)
    }
}

/// Run `operation` and assert it mutated no existing event and deleted none.
///
/// Used by every write path in the suite, not just the note ones: the
/// invariant is a property of the whole system (§13), so a status change that
/// started rewriting bodies must fail here too.
@MainActor
func expectingAppendOnly(
    _ context: ModelContext,
    _ operation: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let before = try eventSnapshots(context)
    try operation()
    try expectAppendOnly(
        before: before, after: try eventSnapshots(context), sourceLocation: sourceLocation)
}
```

- [ ] **Step 2: Write the tests, including the guard's own self-checks**

Create `StenoTests/Notes/EventLogInvariantTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)
private let withinWindow = origin.addingTimeInterval(120)

@MainActor
private func makeTask() throws -> (TaskItem, ModelContext) {
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    context.insert(task)
    try context.save()
    return (task, context)
}

@MainActor
private func allEvents(_ context: ModelContext) throws -> [Event] {
    try context.fetch(FetchDescriptor<Event>())
}

/// M1-06's acceptance criterion 2, and §3.3's invariant, as one test over
/// **every** write path in the app rather than one assertion per method.
///
/// `expectingAppendOnly` compares `EventSnapshot`s, which deliberately omit
/// `isRedacted` — so a redaction passes and any other change to any existing
/// row fails, as does a deletion.
@MainActor
@Test("no write path mutates an existing event except to flip isRedacted")
func appendOnlyHoldsAcrossEveryWritePath() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let notes = NoteService(context: context, now: { clock })
    let statuses = StatusService(context: context, now: { clock })

    // A log carrying one of every kind this milestone can produce.
    try statuses.setStatus(.inProgress, on: task)
    let note = try #require(try notes.addNote("first note about PAY-421", to: task))
    try statuses.setStatus(.blocked, on: task)
    try statuses.addBlockedReason("waiting on infra", to: task)
    let reason = try #require(try allEvents(context).first { $0.kind == .blockedReason })

    clock = withinWindow

    try expectingAppendOnly(context) {
        _ = try notes.correct(note, to: "corrected note about PAY-421", on: task)
    }
    try expectingAppendOnly(context) {
        _ = try notes.correct(reason, to: "waiting on staging infra", on: task)
    }
    try expectingAppendOnly(context) {
        try statuses.setStatus(.done, on: task)
    }
    let liveNote = try #require(
        try allEvents(context).first { $0.kind == .note && !$0.isRedacted })
    try expectingAppendOnly(context) {
        _ = try notes.redact(liveNote)
    }
    try expectingAppendOnly(context) {
        _ = try notes.addNote("a later note", to: task)
    }

    // The log only ever grew: 3 statusChanged, 2 note, 1 replacement note,
    // 1 blockedReason, 1 replacement blockedReason.
    #expect(try allEvents(context).count == 8)
}

private let sampleID = UUID()

private func sampleSnapshot(body: String) -> [UUID: EventSnapshot] {
    [
        sampleID: EventSnapshot(
            id: sampleID, taskID: UUID(), timestamp: origin, kind: .note, body: body)
    ]
}

@Test("the invariant guard reports a body rewritten in place")
func theInvariantGuardCanActuallyFail() throws {
    // The guard above is the load-bearing test of this task, so prove it can
    // fail. `withKnownIssue` records the failure rather than propagating it:
    // this test passes only while the guard still notices the mutation, and
    // starts failing the day it stops.
    withKnownIssue("an in-place body rewrite must be caught") {
        try expectAppendOnly(
            before: sampleSnapshot(body: "original"),
            after: sampleSnapshot(body: "rewritten in place"))
    }
}

@Test("the invariant guard reports a deleted row")
func theInvariantGuardCatchesDeletion() throws {
    withKnownIssue("a deleted event must be caught") {
        try expectAppendOnly(before: sampleSnapshot(body: "original"), after: [:])
    }
}

@Test("the invariant guard accepts a redaction")
func theInvariantGuardAcceptsARedaction() throws {
    // `EventSnapshot` omits `isRedacted`, so the one permitted write is
    // invisible to the comparison and passes cleanly.
    try expectAppendOnly(
        before: sampleSnapshot(body: "same"), after: sampleSnapshot(body: "same"))
}
```

The three `withKnownIssue` tests are the point. A test that cannot fail is this repo's recurring
defect, and this is the single test most likely to be one — so the guard's ability to detect an
in-place rewrite and a deletion, and to *accept* a redaction, is itself asserted. Splitting
`expectAppendOnly(before:after:)` out of the fetching wrapper is what makes that possible **without
giving `Event` a test-only setter**, which its own doc comment forbids.

- [ ] **Step 3: Run and verify**

```bash
make build && make test && make lint
```

Expected: PASS. All three self-checks pass while the guard works; the `withKnownIssue` ones start
**failing** the day the guard stops noticing, which is the alarm they exist to be.

- [ ] **Step 4: Sanity-check the count assertion**

`appendOnlyHoldsAcrossEveryWritePath` asserts a final count of 8: three `statusChanged`
(inProgress, blocked, done), two `note` (the original plus "a later note"), one replacement `note`,
one `blockedReason`, one replacement `blockedReason`. If that number moves, something appended
where it should not have — investigate before changing the number.

- [ ] **Step 5: Commit**

```bash
git add StenoTests/Notes/EventLogInvariant.swift StenoTests/Notes/EventLogInvariantTests.swift
git commit -m "test: assert the append-only invariant across every write path

M1-06's acceptance criterion 2 asks for the invariant to be asserted in
tests, not just in review. Per-method assertions are too weak, so this
snapshots every Event row in the store before and after each write - addNote,
correct, redact, setStatus, addBlockedReason - and permits exactly one field
to differ.

EventSnapshot omits isRedacted deliberately. Equality then allows the one
permitted write and rejects every other, and the #require on the id catches
a deletion, which §3.3 forbids as firmly as an edit.

The comparison is split from the fetching so three withKnownIssue tests can
prove the guard actually detects an in-place rewrite and a deleted row, and
accepts a redaction - without Event acquiring the test-only setter its own
doc comment forbids."
```

---

### Task 7: `NoteComposerModel` — the composer's state, testable headlessly

**Files:**
- Create: `StenoKit/Features/MainWindow/NoteComposerMode.swift`
- Create: `StenoKit/Features/MainWindow/NoteComposerModel.swift`
- Test: `StenoTests/Features/MainWindow/NoteComposerModelTests.swift`

**Interfaces:**
- Consumes: `NoteService` (Tasks 4–5), `NoteCorrection` (Task 2), `EventQueries` (Task 3).
- Produces:
  - `NoteComposerMode` — `.adding`, `.correcting(eventID: UUID)`
  - `NoteComposerModel.init(service: NoteService, now: @escaping () -> Date = Date.init)`
  - `var text: String`; `private(set) var mode: NoteComposerMode`, `notice: String?`,
    `lastError: String?`, `correctableEventIDs: Set<UUID>`, `focusRequests: Int`
  - `var canCommit: Bool`; `func requestFocus()`, `refreshCorrectability(in: [Event])`,
    `beginCorrection(of: UUID, in: [Event])`, `cancel()`
  - `@discardableResult func commit(on: TaskItem?, in: [Event]) -> Bool`
  - `@discardableResult func redact(_: UUID, in: [Event]) -> Bool`

**It holds no reference back to `MainWindowModel`.** Its inputs arrive as parameters, which is what
lets Task 8 declare it a `let` in `init` rather than an optional assigned after `self` exists.

Both `commit` and `redact` return **whether the window must refetch** — `true` after a write *and
after a failure*, because `rollback()` leaves the held `Event` stale.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Features/MainWindow/NoteComposerModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

private struct SaveFailure: Error {}

/// A clock the test can advance between calls.
@MainActor
private final class Clock {
    var instant: Date
    init(_ instant: Date) { self.instant = instant }
}

/// A struct, not a tuple: SwiftLint's `large_tuple` caps tuples at two
/// members, and `CaptureFieldModelTests` already established the fixture shape.
@MainActor
private struct ComposerFixture {
    let composer: NoteComposerModel
    let task: TaskItem
    let context: ModelContext
    let clock: Clock
}

@MainActor
private func makeComposer(
    failing shouldFail: @escaping () -> Bool = { false }
) throws -> ComposerFixture {
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    context.insert(task)
    try context.save()
    let clock = Clock(origin)
    let service = NoteService(
        context: context, now: { clock.instant },
        save: { context in
            if shouldFail() { throw SaveFailure() }
            try context.save()
        })
    return ComposerFixture(
        composer: NoteComposerModel(service: service, now: { clock.instant }),
        task: task, context: context, clock: clock)
}

@MainActor
private func timeline(_ context: ModelContext, _ task: TaskItem) throws -> [Event] {
    try context.fetch(EventQueries.timeline(forTaskID: task.id))
}

@MainActor
@Test("a blank draft cannot be committed")
func aBlankDraftCannotBeCommitted() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    #expect(!composer.canCommit)
    composer.text = "   \n "
    #expect(!composer.canCommit)
    composer.text = "real"
    #expect(composer.canCommit)
}

@MainActor
@Test("each focus request is observable, even when already focused")
func focusRequestsAccumulate() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    #expect(composer.focusRequests == 0)
    composer.requestFocus()
    composer.requestFocus()
    // A `Bool` would have collapsed these into one, and the second `N` press
    // would not re-focus a composer the user had clicked away from.
    #expect(composer.focusRequests == 2)
}

@MainActor
@Test("committing a new note appends it and clears the draft")
func committingANewNoteClearsTheDraft() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    composer.text = "Repro'd the race"

    #expect(composer.commit(on: task, in: []))

    #expect(composer.text.isEmpty)
    #expect(composer.mode == .adding)
    #expect(composer.lastError == nil)
    #expect(try timeline(context, task).count == 1)
}

@MainActor
@Test("beginning a correction prefills the draft and refuses an expired row")
func beginningACorrectionPrefills() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    let clock = fixture.clock
    composer.text = "fixed PAY-42"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)

    clock.instant = origin.addingTimeInterval(60)
    composer.beginCorrection(of: note.id, in: [note])
    #expect(composer.text == "fixed PAY-42")
    #expect(composer.mode == .correcting(eventID: note.id))

    composer.cancel()
    clock.instant = origin.addingTimeInterval(600)
    composer.beginCorrection(of: note.id, in: [note])
    // Past the window the composer refuses to open rather than opening a
    // correction whose commit is guaranteed to be refused.
    #expect(composer.mode == .adding)
    #expect(composer.text.isEmpty)
}

@MainActor
@Test("a window that closes mid-correction keeps the draft and says so")
func expiryMidCorrectionKeepsTheDraft() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    let clock = fixture.clock
    composer.text = "fixed PAY-42"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)

    clock.instant = origin.addingTimeInterval(298)
    composer.beginCorrection(of: note.id, in: [note])
    composer.text = "fixed PAY-421"

    // The user typed for a few seconds and the window closed underneath them.
    clock.instant = origin.addingTimeInterval(360)
    #expect(composer.commit(on: task, in: [note]))

    // Nothing lost, nothing written, and the reason is on screen.
    #expect(composer.text == "fixed PAY-421")
    #expect(composer.mode == .adding)
    #expect(composer.notice != nil)
    #expect(composer.lastError == nil)
    #expect(try timeline(context, task).count == 1)
    #expect(!note.isRedacted)
}

@MainActor
@Test("cancelling discards the draft in both modes")
func cancellingDiscardsTheDraft() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    composer.text = "half-typed"
    composer.cancel()
    #expect(composer.text.isEmpty)

    composer.text = "fixed PAY-42"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)
    composer.beginCorrection(of: note.id, in: [note])
    composer.cancel()

    // The abandoned correction must not survive as a new note's draft — the
    // text in the field is a copy of a note that already exists.
    #expect(composer.text.isEmpty)
    #expect(composer.mode == .adding)
}

@MainActor
@Test("correctability follows the clock")
func correctabilityFollowsTheClock() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    let clock = fixture.clock
    composer.text = "a note"
    _ = composer.commit(on: task, in: [])
    let events = try timeline(context, task)
    let note = try #require(events.first)

    composer.refreshCorrectability(in: events)
    #expect(composer.correctableEventIDs.contains(note.id))

    clock.instant = origin.addingTimeInterval(301)
    composer.refreshCorrectability(in: events)
    // This is what makes the "Correct" affordance disappear on its own.
    #expect(composer.correctableEventIDs.isEmpty)
}

@MainActor
@Test("a failed save keeps the text and explains itself")
func aFailedSaveKeepsTheText() throws {
    var shouldFail = false
    let fixture = try makeComposer(failing: { shouldFail })
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    shouldFail = true
    composer.text = "Repro'd the race"

    #expect(composer.commit(on: task, in: []))

    // CaptureFieldModel's contract: retry, don't retype.
    #expect(composer.text == "Repro'd the race")
    #expect(composer.lastError != nil)
    #expect(try timeline(context, task).isEmpty)
}

@MainActor
@Test("redacting hides the row from the timeline and stops a correction of it")
func redactingStopsACorrectionOfTheSameRow() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    composer.text = "a mistake"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)
    composer.beginCorrection(of: note.id, in: [note])

    #expect(composer.redact(note.id, in: [note]))

    #expect(try timeline(context, task).isEmpty)
    #expect(composer.mode == .adding)
    #expect(composer.text.isEmpty)
}
```

`ComposerFixture` is a struct, not a tuple: SwiftLint's `large_tuple` caps tuples at two members,
and a 4-tuple fails `--strict`. `CaptureFieldModelTests` already established the fixture shape.

- [ ] **Step 2: Run to verify they fail**

```bash
make test 2>&1 | grep -i "NoteComposer\|error:"
```

Expected: `cannot find 'NoteComposerModel' in scope`.

- [ ] **Step 3: Create `NoteComposerMode`**

```swift
import Foundation

/// What the detail pane's composer is currently doing.
///
/// One value rather than a `Bool` plus an optional id, for `ActiveSheet`'s
/// reason: "correcting, but no event" and "adding, but an event" are both
/// unrepresentable here.
public enum NoteComposerMode: Equatable, Sendable {
    /// A new note. `⌘↩` appends.
    case adding
    /// FR-2's grace-period correction of an existing event.
    case correcting(eventID: UUID)
}
```

- [ ] **Step 4: Create `NoteComposerModel`**

```swift
import Foundation

/// The detail pane's note composer: the draft, what it is doing with it, and
/// which rows are still correctable.
///
/// **In `StenoKit`, not as `@State` in the view**, for `CaptureFieldModel`'s
/// reason: D-010 puts view state beyond the headless bundle, and FR-2's
/// acceptance criteria are all statements about this logic.
///
/// **It holds no reference back to `MainWindowModel`.** Its inputs — the task,
/// the visible events — arrive as parameters, so there is no closure web to
/// initialise and no retain cycle to weaken. `MainWindowModel+Notes` is the
/// thin wrapper that supplies them and reloads when this type says to.
@Observable
@MainActor
public final class NoteComposerModel {
    /// The draft. Bound directly by the composer's `TextEditor`.
    public var text: String = ""

    public private(set) var mode: NoteComposerMode = .adding

    /// Why a correction stopped being possible, when it did. Distinct from
    /// `lastError`: nothing failed, the window simply closed.
    public private(set) var notice: String?

    /// Set when a write could not be saved. The text is kept while this is
    /// non-nil, so the user retries rather than retypes — `CaptureFieldModel`'s
    /// contract, for the same reason.
    public private(set) var lastError: String?

    /// The events still inside FR-2's window, recomputed as the clock moves.
    public private(set) var correctableEventIDs: Set<UUID> = []

    /// Bumped whenever the composer should take focus. The view watches this
    /// rather than a `Bool`, so a second request re-focuses instead of being
    /// swallowed as "already true".
    public private(set) var focusRequests = 0

    private let service: NoteService
    private let now: () -> Date

    public init(service: NoteService, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    /// `⌘↩` is live only with something to write.
    public var canCommit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// FR-2's one keystroke: `N` from the task list, `⌘⇧A` from the Task menu.
    public func requestFocus() {
        focusRequests += 1
    }

    /// Recompute which rows may still be corrected.
    ///
    /// Driven by the detail pane on a timer as well as on every reload — the
    /// "Correct" affordance has to *disappear* at five minutes, and nothing
    /// else would prompt that.
    public func refreshCorrectability(in events: [Event]) {
        let instant = now()
        correctableEventIDs = Set(
            events
                .filter {
                    NoteCorrection.isCorrectable(
                        kind: $0.kind, timestamp: $0.timestamp, isRedacted: $0.isRedacted,
                        at: instant)
                }
                .map(\.id))
    }

    /// Start correcting `eventID`, prefilled with its current body.
    ///
    /// Refuses a row that is no longer correctable rather than opening a
    /// composer whose commit is guaranteed to be refused.
    public func beginCorrection(of eventID: UUID, in events: [Event]) {
        guard let event = events.first(where: { $0.id == eventID }),
            NoteCorrection.isCorrectable(
                kind: event.kind, timestamp: event.timestamp, isRedacted: event.isRedacted,
                at: now())
        else { return }

        text = event.body
        mode = .correcting(eventID: eventID)
        notice = nil
        lastError = nil
        requestFocus()
    }

    /// `Esc`, or Cancel while correcting.
    ///
    /// **Discards the draft, in both modes.** The rule across this type is that
    /// the user cancelling discards and the system refusing does not — an
    /// abandoned correction must not survive as a new note's draft, because the
    /// text in the field is a copy of a note that already exists.
    public func cancel() {
        text = ""
        mode = .adding
        notice = nil
        lastError = nil
    }

    /// Write the draft. Never throws — a composer has nowhere to propagate to.
    ///
    /// Returns whether the window must refetch. `true` after a write **and
    /// after a failure**: `rollback()` keeps a refused redaction off disk but
    /// leaves the in-memory `Event` reporting `isRedacted == true`, and only a
    /// refetch restores it. Skipping the reload there hides a note the store
    /// still has.
    @discardableResult
    public func commit(on task: TaskItem?, in events: [Event]) -> Bool {
        guard let task, canCommit else { return false }
        let draft = text

        do {
            switch mode {
            case .adding:
                try service.addNote(draft, to: task)
                reset()
            case .correcting(let eventID):
                guard let event = events.first(where: { $0.id == eventID }) else {
                    // Redacted from another surface, or gone in a reload.
                    keepDraft("That note is no longer available — ⌘↩ adds this as a new note.")
                    return true
                }
                switch try service.correct(event, to: draft, on: task) {
                case .corrected, .unchanged:
                    reset()
                case .windowExpired, .notCorrectable:
                    keepDraft(
                        "That note can no longer be corrected — ⌘↩ adds this as a new note instead."
                    )
                }
            }
            lastError = nil
        } catch {
            Log.app.error(
                "could not save the note: \(String(describing: error), privacy: .public)")
            lastError = "Could not save the note. Your text was not saved — try again."
        }
        return true
    }

    /// §3.3's soft delete, behind the view's confirmation.
    ///
    /// Returns whether the window must refetch, on the same rule as `commit`.
    @discardableResult
    public func redact(_ eventID: UUID, in events: [Event]) -> Bool {
        guard let event = events.first(where: { $0.id == eventID }) else { return false }
        do {
            guard try service.redact(event) else { return false }
            lastError = nil
            // The row being corrected just went away underneath the composer.
            if mode == .correcting(eventID: eventID) { reset() }
        } catch {
            Log.app.error(
                "could not remove the note: \(String(describing: error), privacy: .public)")
            lastError = "Could not remove the note. Nothing was changed."
        }
        return true
    }

    /// The system refused: keep the text, drop to adding, say why.
    private func keepDraft(_ why: String) {
        mode = .adding
        notice = why
        lastError = nil
    }

    private func reset() {
        text = ""
        mode = .adding
        notice = nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
make build && make test && make lint
```

Expected: PASS, 0 violations.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Features/MainWindow/NoteComposerMode.swift \
        StenoKit/Features/MainWindow/NoteComposerModel.swift \
        StenoTests/Features/MainWindow/NoteComposerModelTests.swift
git commit -m "feat: the note composer's state, in StenoKit where tests reach it

CaptureFieldModel's precedent: view state held in a view lives in Steno/,
where D-010 puts it beyond the headless bundle - and FR-2's acceptance
criteria are all statements about this logic.

It holds no reference back to MainWindowModel. The selected task and the
visible timeline arrive as parameters, so there is no closure web to
initialise and no retain cycle to weaken, and the next task can declare it a
let in init rather than an optional assigned once self exists.

One rule decides who keeps the draft: the user cancelling discards, the
system refusing does not. Esc clears in both modes, so an abandoned
correction never survives as a new note's draft; a failed save and an expired
window both keep the text, because in neither case did the user say to throw
it away.

commit and redact return whether the window must refetch - true after a write
AND after a failure. rollback() keeps a refused write off disk but leaves the
held Event reporting the rejected isRedacted, and only a refetch restores it."
```

---

### Task 8: Wire the composer into the window

**Files:**
- Create: `StenoKit/Features/MainWindow/MainWindowModel+Notes.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowActions.swift`

**Interfaces:**
- Consumes: `NoteComposerModel` (Task 7), `NoteService` (Tasks 4–5).
- Produces: `MainWindowModel.noteComposer: NoteComposerModel` (a `let`);
  `canAddNote`, `addNoteToSelection()`, `beginNoteCorrection(of:)`, `commitNote()`,
  `redactEvent(_:)`, `refreshNoteCorrectability()`. `MainWindowActions` gains `canAddNote` and
  `addNoteToSelection()`.

- [ ] **Step 1: Add the stored property**

In `MainWindowModel.swift`, immediately after `public var activeSheet: ActiveSheet?`:

```swift
    /// FR-2's note composer. A `let` built in `init`, holding no reference back
    /// to this model — its inputs arrive as parameters from
    /// `MainWindowModel+Notes`, which is what lets it be a `let` at all rather
    /// than an optional assigned after `self` becomes available.
    public let noteComposer: NoteComposerModel
```

- [ ] **Step 2: Initialise it before `reload()`**

```swift
// Replace:
        self.context = context
        self.now = now
        self.save = save
        reload()

// With:
        self.context = context
        self.now = now
        self.save = save
        self.noteComposer = NoteComposerModel(
            service: NoteService(context: context, now: now, save: save), now: now)
        reload()
```

Order matters: `reload()` calls `reloadSelectedTaskEvents()`, which touches `noteComposer` in the
next step. Every stored property must also have a value before `self` is captured by the
`writeObservation` closure at the end of `init` — which is why this goes here and not after.

- [ ] **Step 3: Refresh correctability wherever the timeline changes**

In `reloadSelectedTaskEvents()`, both branches:

```swift
// In the early-return branch, after `selectedTaskTimelineFailed = false`:
            noteComposer.refreshCorrectability(in: [])

// At the end of the method, after `selectedTaskEvents = loaded ?? []`:
        // FR-2's window is a function of the clock, so this is refreshed on a
        // timer as well (see `TaskDetailView`) — but it must also be correct
        // the instant the timeline changes, which is here.
        noteComposer.refreshCorrectability(in: selectedTaskEvents)
```

- [ ] **Step 4: Extend `MainWindowActions`**

Add to the protocol, after `canChangeStatus`:

```swift
    /// FR-2's note entry needs a task to attach to, so the menu gates on this
    /// for the reason above.
    var canAddNote: Bool { get }
```

and after `markSelectionBlocked()`:

```swift
    /// FR-2: focus the note composer for the selected task. Writes nothing.
    func addNoteToSelection()
```

Adding these to the protocol makes forgetting the implementation a compile error rather than a menu
item that silently does nothing — which is the whole reason `MainWindowActions` exists.

- [ ] **Step 5: Create `MainWindowModel+Notes.swift`**

```swift
import Foundation

/// FR-2's note actions: the thin layer between the composer and the store.
///
/// `NoteComposerModel` holds the draft and decides what a write means;
/// this supplies the two things it deliberately does not hold — the selected
/// task and the visible timeline — and reloads when it says to.
///
/// **Every path that can fail reloads.** `NoteService`'s `rollback()` keeps a
/// refused write off disk but leaves the held `Event` reporting the rejected
/// `isRedacted`, and only a refetch restores it. Skipping the reload after a
/// failure hides a note the store still has — worse than the status case
/// `+Status.swift` documents, because a note simply vanishes rather than
/// visibly reverting.
extension MainWindowModel {
    /// FR-3 gates its shortcuts on having a subject.
    public var canAddNote: Bool { selectedTaskID != nil }

    /// FR-2's one keystroke — `N` from the task list, `⌘⇧A` from the Task menu.
    /// Both only move focus; nothing is written until `⌘↩`.
    public func addNoteToSelection() {
        guard canAddNote else { return }
        noteComposer.requestFocus()
    }

    /// Begin FR-2's grace-period correction of one event.
    public func beginNoteCorrection(of eventID: UUID) {
        noteComposer.beginCorrection(of: eventID, in: selectedTaskEvents)
    }

    /// Commit the draft — a new note, or a correction.
    public func commitNote() {
        // Named `subject`, not `task`: `let task = … { task(withID: $0) }`
        // shadows the method with the constant being declared, and Swift 6
        // reports it as "failed to produce diagnostic for expression" rather
        // than as the shadowing it is.
        let subject = selectedTaskID.flatMap { task(withID: $0) }
        if noteComposer.commit(on: subject, in: selectedTaskEvents) { reload() }
    }

    /// §3.3's soft delete, behind the timeline's confirmation.
    public func redactEvent(_ eventID: UUID) {
        if noteComposer.redact(eventID, in: selectedTaskEvents) { reload() }
    }

    /// Re-evaluate FR-2's window against the clock.
    ///
    /// Driven by the detail pane's timer. Its own method rather than a full
    /// `reload()` because it must not fetch: it fires every few seconds, and
    /// the answer depends only on `now()` and events already in hand.
    public func refreshNoteCorrectability() {
        noteComposer.refreshCorrectability(in: selectedTaskEvents)
    }
}
```

Note `commitNote`'s local named `subject`. `let task = selectedTaskID.flatMap { task(withID: $0) }`
shadows the method with the constant being declared, and Swift 6 rejects it with *"failed to
produce diagnostic for expression; please submit a bug report"* rather than naming the shadowing.
This was hit while verifying the plan.

- [ ] **Step 6: Verify**

```bash
make build && make test && make lint
```

Expected: PASS, 0 violations. The existing `MainWindowModel` tests must still pass — nothing in
this task changes reading or status behaviour.

- [ ] **Step 7: Commit**

```bash
git add StenoKit/Features/MainWindow/MainWindowModel.swift \
        StenoKit/Features/MainWindow/MainWindowModel+Notes.swift \
        StenoKit/Features/MainWindow/MainWindowActions.swift
git commit -m "feat: wire the note composer into the main window

MainWindowModel gains one stored let. The composer takes its inputs as
parameters, so it can be built in init before self is capturable - no
optional, no force unwrap, no closure web.

Correctability is refreshed wherever the timeline changes, including the
no-selection branch, so a stale Correct affordance cannot outlive the row it
belongs to.

Every failure path reloads. NoteService's rollback() keeps a refused write off
disk but leaves the held Event reporting the rejected isRedacted - measured,
not assumed - and only a refetch restores it. Skipping the reload there hides
a note the store still has, which is worse than the status case
+Status.swift documents: a status visibly reverts, a note simply vanishes.

canAddNote and addNoteToSelection join MainWindowActions so the next task's
menu item cannot silently do nothing."
```

---

### Task 9: The UI — composer, timeline rows, and the two shortcuts

**Files:**
- Create: `Steno/Features/MainWindow/NoteComposerView.swift`
- Create: `Steno/Features/MainWindow/TimelineRowView.swift`
- Modify: `Steno/Features/MainWindow/TaskDetailView.swift`
- Modify: `Steno/Features/MainWindow/TaskListView.swift`
- Modify: `Steno/App/MainWindowCommands.swift`

**Interfaces:**
- Consumes: everything from Task 8.
- Produces: no testable API. Per D-010 nothing in `Steno/` is covered by the headless bundle; this
  task's correctness is established by the manual pass in Task 10.

- [ ] **Step 1: Create `NoteComposerView`**

```swift
import StenoKit
import SwiftUI

/// FR-2's note entry: a multi-line field above the timeline, never a modal.
///
/// Not a `TextEntrySheet`. That one is a single-line `TextField`, and §3.3's
/// own example of a note — "Repro'd the race condition, it's in the retry
/// handler" — is prose. A modal would also cover the timeline the user is
/// reading while writing about it.
///
/// Everything stateful is in `NoteComposerModel` over in `StenoKit`, where the
/// headless bundle can reach it (D-010); this file is layout.
struct NoteComposerView: View {
    @Bindable var composer: NoteComposerModel
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    private var isCorrecting: Bool {
        if case .correcting = composer.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCorrecting {
                Text("Correcting a note — it keeps its original time in the timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // `TextEditor` has no placeholder of its own, hence the overlay.
            TextEditor(text: $composer.text)
                .font(.body)
                .frame(minHeight: 58, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if composer.text.isEmpty {
                        Text("Add a note…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                }
                .focused($isFocused)

            if let notice = composer.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = composer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("⌘↩ to add")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isCorrecting || !composer.text.isEmpty {
                    Button("Cancel") { composer.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(isCorrecting ? "Save Correction" : "Add Note", action: onCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!composer.canCommit)
            }
        }
        // A counter rather than a `Bool`: a second focus request while the
        // field is already focused must still re-focus, and `isFocused = true`
        // when it is already `true` changes nothing observable.
        .onChange(of: composer.focusRequests) { isFocused = true }
    }
}
```

- [ ] **Step 2: Create `TimelineRowView`**

```swift
import StenoKit
import SwiftUI

/// One event in FR-3's timeline, with FR-2's affordances when they apply.
///
/// **"Correct" is present only while the event is inside FR-2's window and
/// disappears at five minutes.** That is the acceptance criterion "after 5
/// minutes, editing is unavailable" made visible rather than merely true; the
/// service refuses a late correction regardless, but a button that lingers
/// past its own deadline is a lie the user has to discover by clicking.
///
/// "Redact…" is a context menu behind a confirmation. `Event` has no
/// `unredact()` by design, so a one-way action reachable in a single misclick
/// would be a defect.
struct TimelineRowView: View {
    let event: Event
    let isCorrectable: Bool
    let onCorrect: () -> Void
    let onRedact: () -> Void

    @State private var isConfirmingRedaction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.body)
            HStack(spacing: 10) {
                Text(event.timestamp, format: .dateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isCorrectable {
                    Button("Correct", action: onCorrect)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if event.kind.isUserAuthored {
                Button("Redact…", role: .destructive) { isConfirmingRedaction = true }
            }
        }
        .confirmationDialog(
            "Redact this note?", isPresented: $isConfirmingRedaction, titleVisibility: .visible
        ) {
            Button("Redact", role: .destructive, action: onRedact)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "It is hidden from the timeline and from stand-up summaries, and the row is kept. This cannot be undone."
            )
        }
    }
}
```

- [ ] **Step 3: Host both in `TaskDetailView`**

Add `import Combine` at the top, then make three edits.

Insert the composer between the `Divider()` and the `"Timeline"` heading:

```swift
                    Divider()

                    // FR-2's note entry, above the timeline it writes into.
                    NoteComposerView(composer: model.noteComposer) { model.commitNote() }

                    Text("Timeline")
                        .font(.headline)
```

Replace the inline row rendering:

```swift
// Replace:
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.body)
                                Text(event.timestamp, format: .dateTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

// With:
                        ForEach(events) { event in
                            TimelineRowView(
                                event: event,
                                isCorrectable: model.noteComposer.correctableEventIDs.contains(
                                    event.id),
                                onCorrect: { model.beginNoteCorrection(of: event.id) },
                                onRedact: { model.redactEvent(event.id) }
                            )
                        }
```

Attach the tick to the `ScrollView`, immediately after its closing brace:

```swift
            // FR-2's window closes on the clock, not on user action, so
            // something has to tick for the "Correct" affordance to vanish.
            // A Combine publisher rather than a `Timer` on the model: it is
            // owned by the view that needs it and dies with it, so there is no
            // lifetime to manage — and in Swift 6 a `@MainActor` class cannot
            // invalidate a timer from its own nonisolated `deinit` anyway.
            // The recompute it drives is pure and unit-tested; only this
            // scheduling is not.
            .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
                model.refreshNoteCorrectability()
            }
```

Also update the file's header doc comment: it currently ends "M1-06 adds note entry, the correction
window, and redaction." That is now done, so say what is there instead.

- [ ] **Step 4: Add the scoped `N` to `TaskListView`**

Above the `List(selection:)`, add the comment explaining the scoping, and attach the handler to the
outer `Group` — immediately before `.navigationSplitViewColumnWidth`:

```swift
        .onKeyPress(KeyEquivalent("n")) {
            guard model.canAddNote else { return .ignored }
            model.addNoteToSelection()
            return .handled
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
```

with this comment above the `List`:

```swift
                // FR-2's "one keystroke": bare `N`, scoped to this list.
                //
                // **Not a menu key equivalent.** The main menu gets first crack
                // at key-downs and `NSTextView` does not consume plain
                // characters as key equivalents, so `N` in the Task menu would
                // fire while the user typed "n" into the capture field, the New
                // Task sheet, or the note composer — the §1.1 degradation this
                // repo forbids. `.onKeyPress` routes through the responder
                // chain instead, so it fires only when this list holds focus.
                // ⌘⇧A in the Task menu is the discoverable equivalent.
```

`.onKeyPress(_:action:)` is macOS 14.0+; it was typechecked against this repo's floor.

- [ ] **Step 5: Add ⌘⇧A to the Task menu**

In `MainWindowCommands.swift`, append to the `CommandMenu("Task")` block after "Mark Blocked":

```swift
            // FR-2's note entry, reachable from anywhere in the window. The
            // bare `N` the requirement suggests lives on the task list instead
            // — see `TaskListView` for why it cannot be a menu key equivalent.
            Button("Add Note") { actions?.addNoteToSelection() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions?.canAddNote != true)
```

Also update this file's doc comment, which currently says "M1-06 adds 'Add Note': one method on
`MainWindowActions`, one `Button` here" — that prediction has now come true and should read as
history, not as a plan.

- [ ] **Step 6: Verify**

```bash
make format && make build && make test && make lint
```

Expected: build green, suite passes, 0 violations. Run `make format` **before** lint — swift-format
owns layout and can itself introduce a SwiftLint error; when that happens, restructure rather than
reformatting or adding a disable comment.

- [ ] **Step 7: Commit**

```bash
git add Steno/Features/MainWindow/NoteComposerView.swift \
        Steno/Features/MainWindow/TimelineRowView.swift \
        Steno/Features/MainWindow/TaskDetailView.swift \
        Steno/Features/MainWindow/TaskListView.swift \
        Steno/App/MainWindowCommands.swift
git commit -m "feat: note composer, timeline affordances, and FR-2's shortcuts

An inline multi-line composer above the timeline, not a TextEntrySheet: that
one is a single-line TextField and §3.3's own example of a note is prose, and
a modal would cover the timeline the user is reading while writing about it.

Correct appears only while a row is inside the five-minute window and
disappears when it closes, which makes 'after 5 minutes editing is
unavailable' visible rather than merely true. Redact sits in a context menu
behind a confirmation - Event has no unredact() by design, so a one-way
action reachable in one misclick would be a defect.

FR-2 suggests a bare N. It cannot be a menu key equivalent: the main menu
gets first crack at key-downs and NSTextView does not consume plain
characters, so it would fire while typing 'n' into the capture field - the
§1.1 degradation this repo forbids. N is scoped to the task list's focus via
.onKeyPress, with ⌘⇧A in the Task menu for reach and discoverability.
Flagged in the PR body as a spec deviation."
```

---

### Task 10: Decisions, ticks, and the PR

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/tasks/README.md`
- Modify: `docs/tasks/M1-06-progress-notes.md`
- Modify: `docs/REQUIREMENTS.md` (FR-2 amendment)

- [ ] **Step 1: Record the decisions**

Append to `docs/DECISIONS.md`, numbering from **D-044** (D-043 is the current high-water mark).
Each needs the date `2026-09-02`, task `M1-06`, status `accepted`, a **Why**, and **Alternatives**,
matching the existing entries' shape:

- **D-044 — Correction is redact-and-reappend in its own service.** `NoteService` is a sibling of
  `StatusService`, not an extension. *Why:* `addBlockedReason` guards on `status == .blocked`, but
  correcting a reason after the task unblocks must still work. *Alternatives:* extending
  `StatusService` (wrong guard); putting it on `MainWindowModel` (M2-01 needs the rule and has no
  window).
- **D-045 — `EventKind.isUserAuthored` decides correction and redaction scope.** `note` and
  `blockedReason` only. *Why:* the two kinds the user typed; redacting a `statusChanged` corrupts
  what M2.5-02 derives status from, and redacting `created` leaves a task with no origin.
  *Alternatives:* notes only (leaves M1-05's reachable `blockedReason` typo permanent); every kind.
- **D-046 — The replacement carries the original's kind, not `.note`.** *Why:* FR-2 predates
  `blockedReason` being correctable. See Step 4 — this one amends the spec.
- **D-047 — The five-minute window measures from the event's own timestamp and does not restart.**
  *Why:* free, given the replacement carries the original timestamp; restarting is unrepresentable
  without a new `Event` field.
- **D-048 — FR-2's bare `N` is scoped to the task list, with ⌘⇧A in the menu.** *Why:* a
  plain-letter menu key equivalent hijacks typing "n" in every text field, including the one §1.1
  protects.
- **D-049 — Orphan `SourceRef` rows from a redacted note are left in place.** *Why:* reconciling
  would add the app's first delete path for a persisted row, immediately beside the invariant this
  task defends, and would discard `cachedSummary`/`lastFetchedAt` that §10.1 preserves. Deferred to
  M5, where a dead ref is observable. **Record this one as an open decision, not a closed one.**
- **D-050 — `MainWindowModel`'s project actions move to `+Projects.swift`.** *Why:* the file was at
  396 of 400 lines under `--strict`.

- [ ] **Step 2: Tick the README rows**

In `docs/tasks/README.md`:
- Line 61 — tick **M1-04**: `- [x] [M1-04](M1-04-menu-bar.md) — menu bar item and popover (FR-1.2)`.
  It merged as `8edf106` via PR #16 but could not tick its own row before merging; CLAUDE.md step 4
  makes this PR responsible for it.
- Tick **M1-06**'s row and append ` — PR #N` once the PR number exists.

- [ ] **Step 3: Tick M1-06's acceptance criteria that automated tests actually cover**

In `docs/tasks/M1-06-progress-notes.md`, tick criteria 1–5 and cite the test that proves each.
**Leave criterion 6 (`N` opens note entry) unticked** — it is a GUI behaviour, no agent in this
environment can drive the GUI, and `.onKeyPress` scoping is precisely the kind of thing that
typechecks and still misbehaves. Add a "Manual verification" section for it, matching M1-04's.

- [ ] **Step 4: Amend FR-2 in REQUIREMENTS.md**

Change *"append a new `note` event carrying the corrected body"* to *"append a new event **of the
same kind**, carrying the corrected body"*. Bump the version and add a changelog line at the top,
as the existing entries do. This is required rather than optional: CLAUDE.md says a PR that quietly
contradicts REQUIREMENTS.md is worse than one that pauses to ask.

- [ ] **Step 5: Final verification**

```bash
make format && make build && make test && make lint
git status   # Steno.xcodeproj and Local.xcconfig must NOT appear
```

- [ ] **Step 6: Open the PR — and do not merge it**

The body must carry:
1. **Both spec deviations**, with their reasoning: the replacement's kind (§9.1 of the spec, amended
   here in Step 4) and the scoped `N` (§9.2, a mechanism deviation, requirement still met).
2. **The accepted debt**: orphan `SourceRef` rows, deferred to M5 (D-049).
3. **What is not verified**: everything in `Steno/` (D-010), the composer's focus behaviour, the
   `Timer.publish` scheduling, and criterion 6. Say this plainly rather than implying the suite
   covers the UI.
4. **The `MainWindowModel` split** (Task 1) as a no-behaviour-change refactor, so a reviewer knows
   to skim it rather than re-review moved code.
5. **A question for the user**: three of M1-04's five acceptance criteria are still unticked pending
   its manual GUI pass. Ask whether that checklist was run rather than assuming.

```bash
git push -u origin feat/progress-notes
gh pr create --title "feat: progress notes, timeline, and the correction window — FR-2 (M1-06)" --body "..."
```

**Stop here. The user reviews and merges.**

---

## Self-review

**Spec coverage.** Every section of the design maps to a task: §3 → Task 2, §4 → Tasks 4–5, §5 →
Task 3, §6.1 → Tasks 7–8, §6.2–6.3 → Task 9, §6.4 → Task 9, §7 → Tasks 5, 7, 8, §8 → Tasks 2, 4, 5,
6, 7, §9–10 → Task 10. The spec's §6.1 property list is superseded by Task 7's `NoteComposerModel`
API for the file-length reason recorded at the top.

**Type consistency.** `NoteComposerModel`'s methods take `in events: [Event]` throughout;
`MainWindowModel+Notes` passes `selectedTaskEvents` to every one. `commit` and `redact` both return
`Bool` meaning "the window must refetch", and both call sites in `+Notes` treat it that way.
`CorrectionOutcome`'s four cases are all handled in `NoteComposerModel.commit`'s inner `switch`,
which is exhaustive with no `default`.

**Known gaps, stated rather than hidden.** Nothing in `Steno/` is covered by tests (D-010). The
`Timer.publish` scheduling is not tested — only the `refreshCorrectability` recompute it drives.
Acceptance criterion 6 needs a human at a keyboard.
