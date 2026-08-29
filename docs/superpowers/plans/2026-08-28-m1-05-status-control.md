# M1-05 Status Control & Transitions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One code path for changing a task's status, appending a `statusChanged` event on every
transition, reachable from a keyboard shortcut and from a control in every surface that shows a task.

**Architecture:** A `StatusService` in StenoKit, shaped exactly like the existing `CaptureService`
(injected `context`/`now`/`save`), is the only route to a status change — enforced by construction,
because this task also reduces the domain models' mutators from `public` to `internal`. The four
statuses and the cycle order live as pure values next to it. The main window's view model calls the
service; the views call the view model; the app target can no longer reach a mutator at all.

**Tech Stack:** Swift 6 language mode, macOS 14.0 floor, SwiftData, SwiftUI, Swift Testing,
XcodeGen, SwiftLint `--strict`.

**Spec:** [`docs/superpowers/specs/2026-08-28-m1-05-status-control-design.md`](../specs/2026-08-28-m1-05-status-control-design.md)

## Global Constraints

- **Never commit to `main`.** Work on `feat/status-control`, open one PR, do not merge (CLAUDE.md, §9.5).
- **`make build && make test && make lint` must all pass before the PR.** "This should compile" is
  not acceptable (§9.5 step 4, §13).
- **The event log is append-only.** Never mutate or delete an `Event` row; the only permitted write
  to an existing event is flipping `isRedacted` (§3.3, §13).
- **Every transition appends exactly one `statusChanged` event. No transition is silent.** M2.5-02's
  merge derives `TaskItem.status` from the newest `statusChanged` event, so a transition without its
  event silently reverts after an import (M1-05 task file).
- **Any status may move to any other. No enforced workflow, no fifth status** (§3.2, D11).
- **Never break capture latency.** Nothing in this task touches the quick-add path; if a change
  appears to, stop and report it (§1.1, §13).
- **Views get no store access** — no `@Query`, no `@Environment(\.modelContext)`. View models
  mediate (ARCHITECTURE §2 rule 2, D-019).
- **SwiftLint `--strict`:** `identifier_name` rejects any identifier under 3 characters except `id`.
  This is why the transition's second property is `into`, not `to` — verified, not assumed.
  `empty_count` rejects `x.count == 0`; use `isEmpty`. `force_unwrapping` is on.
- **`OSLogMessage` has no `+` operator.** Build log lines as a single interpolated literal.
- **Swift 6:** `deinit` on a `@MainActor` class is nonisolated and cannot touch isolated members.
- **Never commit `Steno.xcodeproj` or `Local.xcconfig`.** Both are generated/gitignored.
- **Every commit** uses a Conventional Commits prefix and ends with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Notes on the toolchain, so you do not misread a green run

- `make test` regenerates `Steno.xcodeproj` on every run, by design. That is not a problem to fix.
- **`xcbeautify` does not print parameterized test cases.** Task 3's 12-case table will never appear
  in the output. Absence is not failure.
- New directories need no `project.yml` edit — XcodeGen globs whole target directories.

## Verification already performed on this plan's code

Every Swift block below was type-checked against the **real module**, not in isolation: the whole of
`StenoKit` plus the new files under `-swift-version 6 -target arm64-apple-macos14.0`, then the whole
of the `Steno` app target against the resulting `.swiftmodule`. Test blocks were type-checked with
the Testing macro plugin loaded, so `#expect`/`#require` are expanded, not skipped. Every assertion
in Tasks 2, 3 and 5 was then **executed** against real SwiftData and passed.

**That still does not make them correct.** Type-checking proves syntax; running these particular
assertions proves these particular claims. Four defects shipped in the previous milestone's
"verified" plan blocks. **Read critically, and if you find a defect, report it — that is the correct
behaviour, not a deviation. Earlier tasks in this repo have found several.**

### One finding this verification produced, which the code below depends on

`ModelContext.rollback()` **does not restore a mutated property on an already-persisted object.**
Measured: after `rollback()`, `hasChanges` is `false` and nothing is written to the store — a
sibling context still reads the old value, and a later `save()` does not persist the rejected one —
but the *held reference* still reports the mutated value. A **fetch** in the same context refreshes
that same instance (`===` identical) so it then reads the stored value.

Consequences, all of which are already reflected below:

- `MainWindowModel` is safe, because every failure path calls `reload()`, which fetches.
- A test asserting `task.status == .todo` on the held reference after a failed save **fails**. The
  test in Task 3 refetches instead, and a second test pins the stale-reference behaviour so a future
  SwiftData change is a failing test rather than a surprise.
- `StatusService` gets no restore logic. Its doc comment states the contract instead.

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `StenoKit/Support/WriteNotifications.swift` | 1 | `.stenoDidWrite` and `WriteObservation` — moved from `Capture/` |
| `StenoTests/Support/WriteCounter.swift` | 1 | Counts posts; shared by two test files |
| `StenoKit/Status/StatusTransition.swift` | 2 | The transition as a value; the cycle order |
| `StenoKit/Status/StatusService.swift` | 3 | The one write path for status |
| `StenoKit/Models/{TaskItem,Project,Event}.swift` | 4 | Mutators reduced to `internal` |
| `StenoKit/Features/MainWindow/MainWindowActions.swift` | 5 | `ActiveSheet.blockedReason`, three protocol members |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | 1, 5 | Observes the renamed notification; drives the service |
| `Steno/Features/MainWindow/StatusControl.swift` | 6 | One status control, three call sites |
| `Steno/App/MainWindowCommands.swift` | 6 | ⌘⇧S and ⌘⇧B |
| `docs/*` | 7 | ARCHITECTURE, DECISIONS, task files, README |

---

## Task 1: Rename `.stenoDidCapture` to `.stenoDidWrite`

A mechanical rename, done first so Tasks 3 and 5 have the name they post. No behaviour changes.

**Files:**
- Move: `StenoKit/Capture/CaptureNotifications.swift` → `StenoKit/Support/WriteNotifications.swift`
- Modify: `StenoKit/Capture/CaptureService.swift` (one post site and its comment)
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift` (doc line, property, registration)
- Modify: `StenoKit/Features/Capture/QuickCaptureModel.swift` (one doc line)
- Modify: `StenoTests/Capture/CaptureNotificationTests.swift`
- Create: `StenoTests/Support/WriteCounter.swift`

**Interfaces:**
- Produces: `public extension Notification.Name { static let stenoDidWrite: Notification.Name }`
  with raw value `"com.lgabrielgr.steno.didWrite"`; `final class WriteObservation` (internal,
  `init(_ token: any NSObjectProtocol)`); `@MainActor final class WriteCounter` (internal test
  helper, `private(set) var posts: Int`).
- Consumes: nothing.

- [ ] **Step 1: Move the file**

```bash
git mv StenoKit/Capture/CaptureNotifications.swift StenoKit/Support/WriteNotifications.swift
```

`Support/` because the notification is no longer capture-specific: `StatusService` posts it in
Task 3 and M1-06's notes will.

- [ ] **Step 2: Rewrite the moved file**

Replace the entire contents of `StenoKit/Support/WriteNotifications.swift` with:

```swift
import Foundation

extension Notification.Name {
    /// Posted after a domain write is on disk.
    ///
    /// **Posted at the write, not by each surface** (D-031). View models fetch
    /// manually and do not refresh, so without this the floating panel and
    /// M1-04's popover would insert tasks — and change statuses — that an open
    /// main window never notices. One post site per writing service covers all
    /// three of D15's surfaces.
    ///
    /// Named for writes rather than captures because `StatusService` posts it
    /// too (D-035), and M1-06's notes will. The alternative — one notification
    /// per write kind — grows a registration per observer per feature, and the
    /// first one forgotten is a staleness bug that looks like SwiftData being
    /// flaky.
    public static let stenoDidWrite = Notification.Name("com.lgabrielgr.steno.didWrite")
}

/// Holds a `NotificationCenter` token and removes it when its owner is
/// deallocated.
///
/// **Why this is a separate object rather than a stored token plus a
/// `deinit`.** In Swift 6 the `deinit` of a `@MainActor` class is nonisolated
/// and may not reference isolated stored properties, so the obvious
/// `deinit { NotificationCenter.default.removeObserver(token) }` inside
/// `MainWindowModel` does not compile. Holding the token in a non-isolated
/// object means ARC releases it along with the model and *this* `deinit`,
/// which touches nothing isolated, does the removal.
final class WriteObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
```

- [ ] **Step 3: Update the three production call sites**

In `StenoKit/Capture/CaptureService.swift`, the post site near the end of `capture`:

```swift
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
```

In `StenoKit/Features/MainWindow/MainWindowModel.swift` there are four occurrences — the type's doc
comment, the stored property and its comment, and the registration. Rename the property
`captureObservation` → `writeObservation` as well:

```swift
/// surface writes, so this model observes `.stenoDidWrite` and reloads.
```

```swift
    /// Kept alive so the observation lives exactly as long as this model. See
    /// `WriteObservation` for why the token is not a plain stored property.
    private var writeObservation: WriteObservation?
```

```swift
        writeObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
```

In `StenoKit/Features/Capture/QuickCaptureModel.swift`, the doc line:

```swift
/// it: `CaptureService` posts `.stenoDidWrite`, and any open main window
```

- [ ] **Step 4: Extract the post counter into a shared test helper**

`CaptureNotificationTests` declares a `private final class PostCounter`. Task 3 needs the same
thing, and two copies are two chances for one to stop counting. Create
`StenoTests/Support/WriteCounter.swift`:

```swift
import Foundation

@testable import StenoKit

/// Counts `.stenoDidWrite` posts synchronously.
///
/// Posts are made on the main actor with no delivery queue, so by the time the
/// service call returns the count is final — which is what makes these
/// assertions deterministic rather than timed.
///
/// Shared by `CaptureNotificationTests` and `StatusServiceTests` rather than
/// duplicated: both services post the same notification, and two copies of the
/// counter would be two chances for one of them to stop counting correctly.
@MainActor
final class WriteCounter {
    /// Named `posts`, not `count`: SwiftLint's `empty_count` rejects
    /// `something.count == 0`, and `--strict` makes that a build failure.
    private(set) var posts = 0
    private var observation: WriteObservation?

    init() {
        observation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.posts += 1 }
            })
    }
}
```

- [ ] **Step 5: Update the existing test file**

In `StenoTests/Capture/CaptureNotificationTests.swift`, delete the whole `private final class
PostCounter { … }` declaration (including its doc comment, which now lives on `WriteCounter`) and
replace the three uses of `PostCounter()` with `WriteCounter()`.

- [ ] **Step 6: Verify no stale references remain**

```bash
grep -rn "stenoDidCapture\|CaptureObservation\|PostCounter" --include='*.swift' Steno StenoKit StenoTests
```

Expected: no output. (`docs/superpowers/` still mentions the old names; those are historical records
of M1-03 and are deliberately left alone — CLAUDE.md says `DECISIONS.md` supersedes them. Task 7
updates `ARCHITECTURE.md` and `DECISIONS.md`, which are current documents.)

- [ ] **Step 7: Build, test, lint**

```bash
make build && make test && make lint
```

Expected: all green. The four notification tests still pass — the rename changes no behaviour.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: .stenoDidCapture becomes .stenoDidWrite

A second writing service arrives in this branch, so a notification named for
captures would assert something false about every status change that posts it.
The observation token and its counter move with the name; the file moves to
Support/ because it is no longer capture-specific.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: `StatusTransition` and the cycle

Pure values, no container, no clock.

**Files:**
- Create: `StenoKit/Status/StatusTransition.swift`
- Test: `StenoTests/Status/StatusTransitionTests.swift`

**Interfaces:**
- Consumes: `Status` and `Status.displayName` (both exist).
- Produces: `public struct StatusTransition: Equatable, Sendable` with
  `public let from: Status`, `public let into: Status`,
  `public init(from: Status, into: Status)`, `public var eventBody: String`;
  and on `Status`: `public static let cycle: [Status]`, `public var next: Status`.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Status/StatusTransitionTests.swift`:

```swift
import Testing

@testable import StenoKit

@Test("the event body is FR-3's spelling with §3.3's arrow")
func eventBodyUsesDisplayNamesAndTheSpecArrow() {
    let transition = StatusTransition(from: .inProgress, into: .blocked)
    #expect(transition.eventBody == "IN-PROGRESS → BLOCKED")
}

@Test("the arrow is U+2192, not an ASCII hyphen-arrow")
func eventBodyArrowIsTheSpecCharacter() {
    let body = StatusTransition(from: .todo, into: .done).eventBody
    #expect(body.contains("\u{2192}"))
    #expect(!body.contains("->"))
}

@Test("the cycle is TODO, IN-PROGRESS, DONE — BLOCKED is not in it (D-034)")
func cycleExcludesBlocked() {
    #expect(Status.cycle == [.todo, .inProgress, .done])
    #expect(!Status.cycle.contains(.blocked))
}

@Test("next walks the cycle and wraps at the end")
func nextWalksAndWraps() {
    #expect(Status.todo.next == .inProgress)
    #expect(Status.inProgress.next == .done)
    #expect(Status.done.next == .todo)
}

@Test("cycling out of BLOCKED goes to IN-PROGRESS")
func nextFromBlockedIsInProgress() {
    #expect(Status.blocked.next == .inProgress)
}

@Test("three presses from TODO returns to TODO without ever passing through BLOCKED")
func cyclingNeverProducesBlocked() {
    var status = Status.todo
    var visited: [Status] = []
    for _ in 0..<3 {
        status = status.next
        visited.append(status)
    }
    #expect(status == .todo)
    #expect(!visited.contains(.blocked))
}
```

Note: D11's "the four statuses are the only four" needs no test here — `EnumTests` and
`StatusDisplayTests` each already assert `Status.allCases.count == 4`.

- [ ] **Step 2: Run to verify they fail**

```bash
make test
```

Expected: FAIL — `cannot find 'StatusTransition' in scope`, and `type 'Status' has no member 'cycle'`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Status/StatusTransition.swift`:

```swift
/// A status change, as a value.
///
/// Free-standing rather than a method on `Status` or on `StatusService`,
/// because `eventBody` is the one string in this feature that lands in an
/// append-only log — it is worth asserting against literals with no container
/// and no clock, which is the argument `TaskGrouping` makes for being a free
/// function.
public struct StatusTransition: Equatable, Sendable {
    public let from: Status

    /// Named `into` rather than `to` because SwiftLint's `identifier_name`
    /// rejects a two-character name and `--strict` makes that a build failure.
    public let into: Status

    public init(from: Status, into: Status) {
        self.from = from
        self.into = into
    }

    /// §3.3's spelling: `"IN-PROGRESS → BLOCKED"`.
    ///
    /// The arrow is U+2192 — the character §3.3's example table uses, checked
    /// at the byte level. An ASCII `->` would diverge silently from the spec
    /// in every event ever written, and events are never edited (§3.3).
    public var eventBody: String {
        "\(from.displayName) → \(into.displayName)"
    }
}

extension Status {
    /// What the Cycle Status shortcut walks through (D-034).
    ///
    /// **`blocked` is deliberately absent.** Cycling all four would make
    /// TODO → DONE a three-press walk appending two `statusChanged` events for
    /// states the user never meant to be in, and M2-02 renders that log into a
    /// stand-up. `blocked` is the one status §3.3 pairs with a reason; it stays
    /// a deliberate act, reachable from the status control and from ⌘⇧B.
    public static let cycle: [Status] = [.todo, .inProgress, .done]

    /// The next status in `cycle`, wrapping at the end.
    ///
    /// `blocked` is not in `cycle` and so has no successor there; cycling out
    /// of it goes to `inProgress`, because the thing you do once you are
    /// unblocked is the work.
    public var next: Status {
        guard let index = Self.cycle.firstIndex(of: self) else { return .inProgress }
        return Self.cycle[(index + 1) % Self.cycle.count]
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
make build && make test && make lint
```

Expected: PASS, 0 lint violations.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: the status transition and the cycle, as pure values

The event body is the one string in this feature that lands in an append-only
log, so it is worth asserting against literals rather than through a container.
BLOCKED is left out of the cycle deliberately: including it would make TODO to
DONE a three-press walk that appends two statusChanged events for states the
user never meant to be in, and M2-02 renders that log into a stand-up.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: `StatusService`

**Files:**
- Create: `StenoKit/Status/StatusService.swift`
- Test: `StenoTests/Status/StatusServiceTests.swift`

**Interfaces:**
- Consumes: `StatusTransition(from:into:)` and `.eventBody` from Task 2; `.stenoDidWrite` and
  `WriteCounter` from Task 1; `TaskItem.setStatus(_:at:)`, `Event(taskID:timestamp:kind:body:)`,
  `StenoStore.inMemory()` (all exist).
- Produces: `@MainActor public struct StatusService` with
  `public init(context:now:save:)` (same defaults as `CaptureService`),
  `@discardableResult public func setStatus(_ new: Status, on task: TaskItem) throws -> Bool`,
  `@discardableResult public func addBlockedReason(_ text: String, to task: TaskItem) throws -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Status/StatusServiceTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)
private let later = epoch.addingTimeInterval(3600)

private struct SaveFailure: Error {}

@MainActor
private func makeTask(_ status: Status = .todo) throws -> (TaskItem, ModelContext) {
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: epoch)
    context.insert(task)
    task.setStatus(status, at: epoch)
    try context.save()
    return (task, context)
}

@MainActor
private func events(_ context: ModelContext, _ kind: EventKind) throws -> [Event] {
    // Filtered in memory rather than in a `#Predicate`: D18 caps the dataset,
    // and a predicate over an enum-typed property is the kind of thing that
    // compiles and then fails at fetch time.
    try context.fetch(FetchDescriptor<Event>()).filter { $0.kind == kind }
}

/// Every ordered pair of distinct statuses — §3.2's "any status may move to
/// any other", enumerated rather than sampled.
private let orderedPairs: [(Status, Status)] = Status.allCases.flatMap { from in
    Status.allCases.filter { $0 != from }.map { (from, $0) }
}

@MainActor
@Test("any status moves to any other, appending one event that names it", arguments: orderedPairs)
private func anyStatusMovesToAnyOther(from: Status, into: Status) throws {
    let (task, context) = try makeTask(from)
    let service = StatusService(context: context, now: { later })

    let changed = try service.setStatus(into, on: task)

    #expect(changed)
    #expect(task.status == into)
    let appended = try events(context, .statusChanged)
    #expect(appended.count == 1)
    #expect(appended.first?.body == "\(from.displayName) → \(into.displayName)")
    #expect(appended.first?.taskID == task.id)
}

@MainActor
@Test("setting the status a task already has writes nothing at all")
func nonTransitionWritesNothing() throws {
    let (task, context) = try makeTask(.inProgress)
    let counter = WriteCounter()
    let service = StatusService(context: context, now: { later })

    let changed = try service.setStatus(.inProgress, on: task)

    #expect(!changed)
    #expect(try events(context, .statusChanged).isEmpty)
    // Unmoved: re-stamping would reset the clock M6-01's stale rule reads.
    #expect(task.statusChangedAt == epoch)
    #expect(counter.posts == 0)
}

@MainActor
@Test("entering done sets completedAt and leaving it clears it")
func completedAtFollowsDone() throws {
    let (task, context) = try makeTask(.inProgress)
    let service = StatusService(context: context, now: { later })

    try service.setStatus(.done, on: task)
    #expect(task.completedAt == later)

    try service.setStatus(.todo, on: task)
    #expect(task.completedAt == nil)
}

@MainActor
@Test("every transition stamps statusChangedAt — M6-01's stale rule depends on it")
func transitionStampsStatusChangedAt() throws {
    let (task, context) = try makeTask(.todo)
    let service = StatusService(context: context, now: { later })

    try service.setStatus(.inProgress, on: task)

    #expect(task.statusChangedAt == later)
}

@MainActor
@Test("a blocked task takes a reason as its own event")
func blockedReasonIsAppended() throws {
    let (task, context) = try makeTask(.blocked)
    let service = StatusService(context: context, now: { later })

    let added = try service.addBlockedReason("Waiting on infra", to: task)

    #expect(added)
    let appended = try events(context, .blockedReason)
    #expect(appended.map(\.body) == ["Waiting on infra"])
}

@MainActor
@Test("a reason on a task that is not blocked writes nothing")
func blockedReasonRequiresBlocked() throws {
    let (task, context) = try makeTask(.inProgress)
    let service = StatusService(context: context, now: { later })

    let added = try service.addBlockedReason("Waiting on infra", to: task)

    #expect(!added)
    #expect(try events(context, .blockedReason).isEmpty)
}

@MainActor
@Test("whitespace-only text appends no reason — the sheet's Esc path")
func blankBlockedReasonWritesNothing() throws {
    let (task, context) = try makeTask(.blocked)
    let service = StatusService(context: context, now: { later })

    let added = try service.addBlockedReason("   \n ", to: task)

    #expect(!added)
    #expect(try events(context, .blockedReason).isEmpty)
}

@MainActor
@Test("a successful transition posts .stenoDidWrite exactly once")
func transitionPostsOnce() throws {
    let (task, context) = try makeTask(.todo)
    let counter = WriteCounter()

    try StatusService(context: context, now: { later }).setStatus(.done, on: task)

    #expect(counter.posts == 1)
}

@MainActor
@Test("a failed save leaves no event, no stored transition, and no post")
func failedSaveRollsBack() throws {
    let (task, context) = try makeTask(.todo)
    let counter = WriteCounter()
    let service = StatusService(
        context: context, now: { later }, save: { _ in throw SaveFailure() })

    #expect(throws: SaveFailure.self) {
        try service.setStatus(.done, on: task)
    }

    // Refetched from the service's OWN context, not read off `task`. After
    // `rollback()` the held reference still reports the rejected value; it is
    // the fetch that refreshes it. Reading `task.status` here would assert
    // SwiftData's staleness and call it a passing rollback.
    let refetched = try #require(context.fetch(FetchDescriptor<TaskItem>()).first)
    #expect(refetched.status == .todo)
    #expect(refetched.completedAt == nil)
    #expect(try events(context, .statusChanged).isEmpty)
    #expect(counter.posts == 0)
}

@MainActor
@Test("after a failed save the held reference is stale until the context refetches")
func failedSaveLeavesHeldReferenceStaleUntilRefetch() throws {
    let (task, context) = try makeTask(.todo)
    let service = StatusService(
        context: context, now: { later }, save: { _ in throw SaveFailure() })

    #expect(throws: SaveFailure.self) {
        try service.setStatus(.done, on: task)
    }

    // This pins observed SwiftData behaviour the design depends on rather than
    // behaviour anyone wants: `rollback()` protects the store and clears
    // `hasChanges`, but does not restore the in-memory object. `MainWindowModel`
    // is safe because it calls `reload()` on the failure path — and the test
    // exists so that a future caller which does not is a failing test rather
    // than a window showing a status the store rejected (D-018).
    #expect(task.status == .done)

    let refetched = try #require(context.fetch(FetchDescriptor<TaskItem>()).first)
    #expect(refetched === task)
    #expect(refetched.status == .todo)
}
```

**Note on the parameterized test:** it is `private` because it takes `private` values through
`arguments:`. `make test` will not print its 12 cases — `xcbeautify` hides parameterized cases.

- [ ] **Step 2: Run to verify they fail**

```bash
make test
```

Expected: FAIL — `cannot find 'StatusService' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Status/StatusService.swift`:

```swift
import Foundation
import SwiftData

/// The one path for changing a task's status (§3.2, §3.3, D-033).
///
/// Every transition appends exactly one `statusChanged` event. A transition
/// that skips its event is not cosmetic: §3.3 makes the log the source of
/// truth, and M2.5-02's merge *derives* `TaskItem.status` from the newest
/// `statusChanged` event — so a silent transition reverts after an import,
/// months later, for no visible reason.
///
/// Shaped like `CaptureService`, for its reasons: `@MainActor` because
/// `ModelContext` is not `Sendable`; `now` injected so timestamps are
/// assertable; `save` injected because a real `ModelContext` cannot be made to
/// fail on demand, and the rollback is the path that most needs a test.
///
/// **On a failed save the store is untouched, but a caller's held reference is
/// not restored.** Measured, not assumed: `context.rollback()` discards the
/// inserted event and prevents the mutation from ever being persisted, yet the
/// in-memory object keeps the rejected value until the context is fetched
/// again — a fetch refreshes that same instance. Callers that hold a task must
/// refetch after a failure; `MainWindowModel` does, by calling `reload()`.
@MainActor
public struct StatusService {
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

    /// Move `task` to `new`, appending the `statusChanged` event §3.3 requires.
    ///
    /// Returns whether a transition actually happened. Setting the status a
    /// task already has writes **nothing** — no event, no save, no post — and
    /// returns `false`: `TaskItem.setStatus` no-ops on it, and an event for it
    /// would describe a transition that never occurred, which M2-02 would then
    /// render into a stand-up as work that did not happen.
    ///
    /// Rethrows a save failure after rolling the context back. Without that
    /// the mutation would be committed by the next unrelated save (D-018).
    @discardableResult
    public func setStatus(_ new: Status, on task: TaskItem) throws -> Bool {
        // Read before the mutation. Reading `task.status` afterwards compiles
        // and yields `"BLOCKED → BLOCKED"` in a log that has no correction path.
        let transition = StatusTransition(from: task.status, into: new)
        guard transition.from != transition.into else { return false }

        let stamp = now()
        task.setStatus(new, at: stamp)
        context.insert(
            Event(
                taskID: task.id, timestamp: stamp, kind: .statusChanged,
                body: transition.eventBody))

        try commit()
        return true
    }

    /// §3.3's optional `blockedReason`, appended after the transition rather
    /// than as part of it (D-036).
    ///
    /// Writes nothing and returns `false` when the task is not currently
    /// blocked, or when `text` is empty after trimming — which is what makes
    /// the reason sheet's Esc path free rather than a source of empty events.
    @discardableResult
    public func addBlockedReason(_ text: String, to task: TaskItem) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.status == .blocked, !trimmed.isEmpty else { return false }

        context.insert(
            Event(taskID: task.id, timestamp: now(), kind: .blockedReason, body: trimmed))
        try commit()
        return true
    }

    /// Save, roll back on failure, and tell the other surfaces.
    private func commit() throws {
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        // After the save, never before: an observer that reloads must not be
        // able to read a context whose write has not landed. Synchronous
        // delivery on this actor is what lets tests assert a count rather than
        // wait for one.
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
make build && make test && make lint
```

Expected: PASS, 0 lint violations. Remember the 12 parameterized cases will not be printed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: StatusService — every transition appends its event

§3.3 makes the log the source of truth and M2.5-02's merge derives status from
the newest statusChanged event, so a transition without one silently reverts
after an import. The service is the only place that pairing is guaranteed.

Setting a status a task already has writes nothing: an event for it would
describe a transition that never occurred, which M2-02 would render into a
stand-up as work that did not happen. The blocked reason is a second method
rather than a parameter, because the transition commits before it is asked for.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: Close the mutation hole — mutators become `internal`

**Files:**
- Modify: `StenoKit/Models/TaskItem.swift` (`rename`, `move`, `setArchived`, `setStatus`)
- Modify: `StenoKit/Models/Project.swift` (`rename`, `setJiraProjectKeys`, `setArchived`)
- Modify: `StenoKit/Models/Event.swift` (`redact`)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new. This task removes API rather than adding it.

**Why this is safe, verified rather than assumed:** no file in the `Steno` app target calls a domain
mutator or constructs a model — the app reaches the store only through `MainWindowModel` and the two
services, all inside `StenoKit`. All 32 files in `StenoTests` use `@testable import StenoKit`, none
a plain `import`. Both were checked by grep before this plan was written; re-check in Step 1 rather
than trusting this paragraph.

- [ ] **Step 1: Confirm the preconditions still hold**

```bash
grep -rn "setStatus\|\.rename(\|\.move(\|setArchived\|setJiraProjectKeys\|\.redact()" --include='*.swift' Steno
grep -rL "@testable import StenoKit" $(find StenoTests -name '*.swift')
```

Expected: no output from either. If the first prints anything, stop and report — an app-target caller
means this task's premise is wrong and the fix is not simply dropping `public`.

- [ ] **Step 2: Drop `public` from the eight mutators**

In each of the three model files, change `public func <name>(` to `func <name>(` for exactly these:
`TaskItem.rename`, `TaskItem.move`, `TaskItem.setArchived`, `TaskItem.setStatus`, `Project.rename`,
`Project.setJiraProjectKeys`, `Project.setArchived`, `Event.redact`.

**Do not touch initialisers or stored properties** — they stay `public`; views read them and
`StenoStore` constructs models.

- [ ] **Step 3: Add the reason to `TaskItem.setStatus`'s doc comment**

Its existing comment says "call the service, not this, once M1-05 exists". That sentence is now
enforced rather than requested. Replace that paragraph with:

```swift
    /// **This does not append the `statusChanged` event**, which needs a
    /// `ModelContext`. `StatusService` is the only sanctioned caller and
    /// appends it there. As of M1-05 this method is `internal`, so the app
    /// target cannot reach it at all — the rule is enforced by the compiler
    /// rather than by this comment (D-033).
```

- [ ] **Step 4: Build, test, lint**

```bash
make build && make test && make lint
```

Expected: all green. Nothing should need changing — that is the point of Step 1.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: domain mutators become internal, closing D-019's hole

MainWindowModel publishes live @Model objects, so view code held a real
TaskItem with a public setStatus — it could skip the event entirely and have
the next unrelated save commit it. Nothing did, but this is the branch adding
status controls to views, which is when it stops being theoretical.

Dropping public makes StatusService the only route by construction. The
alternative was a comment asking future view code not to call setStatus, and
this repo's review history is largely a record of comments that promised
things the code did not enforce.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: The view model and the actions protocol

**Files:**
- Modify: `StenoKit/Features/MainWindow/MainWindowActions.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Test: `StenoTests/Features/MainWindow/MainWindowModelStatusTests.swift`

**Interfaces:**
- Consumes: `StatusService.setStatus(_:on:)` and `.addBlockedReason(_:to:)` from Task 3;
  `Status.next` from Task 2.
- Produces: `ActiveSheet.blockedReason(UUID)`; on `MainWindowActions`,
  `var canChangeStatus: Bool { get }`, `func cycleStatusOnSelection()`, `func markSelectionBlocked()`;
  on `MainWindowModel`, additionally `public func setStatus(_ new: Status, on taskID: UUID)` and
  `public func addBlockedReason(_ text: String, to taskID: UUID)`.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Features/MainWindow/MainWindowModelStatusTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeModelWithTask() throws -> (MainWindowModel, TaskItem) {
    let context = ModelContext(try StenoStore.inMemory())
    let model = MainWindowModel(context: context, now: { origin })
    model.createProject(named: "Payments")
    let task = try #require(
        try model.captureService().capture(
            text: "Fix the retry handler", preferred: model.preferredProjectIDForCapture))
    model.reload()
    model.selectedTaskID = task.id
    return (model, task)
}

@MainActor
@Test("status actions are disabled until a task is selected")
func canChangeStatusTracksTheSelection() throws {
    let (model, _) = try makeModelWithTask()
    #expect(model.canChangeStatus)

    model.selectedTaskID = nil
    #expect(!model.canChangeStatus)
}

@MainActor
@Test("cycling walks TODO, IN-PROGRESS, DONE and never lands on BLOCKED")
func cyclingWalksTheCycle() throws {
    let (model, task) = try makeModelWithTask()

    model.cycleStatusOnSelection()
    #expect(task.status == .inProgress)

    model.cycleStatusOnSelection()
    #expect(task.status == .done)

    model.cycleStatusOnSelection()
    #expect(task.status == .todo)
}

@MainActor
@Test("cycling with nothing selected does nothing")
func cyclingWithoutSelectionIsANoOp() throws {
    let (model, task) = try makeModelWithTask()
    model.selectedTaskID = nil

    model.cycleStatusOnSelection()

    #expect(task.status == .todo)
    #expect(model.lastError == nil)
}

@MainActor
@Test("marking blocked transitions and then offers the reason sheet")
func markingBlockedOffersTheReasonSheet() throws {
    let (model, task) = try makeModelWithTask()

    model.markSelectionBlocked()

    #expect(task.status == .blocked)
    #expect(model.activeSheet == .blockedReason(task.id))
}

@MainActor
@Test("marking a task blocked when it already is offers no sheet")
func blockingAnAlreadyBlockedTaskOffersNoSheet() throws {
    let (model, task) = try makeModelWithTask()
    model.markSelectionBlocked()
    model.activeSheet = nil

    model.markSelectionBlocked()

    #expect(task.status == .blocked)
    // No transition happened, so there is no event for a reason to annotate.
    #expect(model.activeSheet == nil)
}

@MainActor
@Test("the reason lands on the timeline of the selected task")
func blockedReasonReachesTheTimeline() throws {
    let (model, task) = try makeModelWithTask()
    model.markSelectionBlocked()

    model.addBlockedReason("Waiting on infra", to: task.id)

    #expect(
        model.selectedTaskEvents.contains { event in
            event.kind == .blockedReason && event.body == "Waiting on infra"
        })
}

@MainActor
@Test("a failed save surfaces an error and leaves the group alone")
func failedStatusSaveSurfacesAnError() throws {
    struct SaveFailure: Error {}
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)

    // Built with a working save so the fixture exists, then re-made with a
    // failing one — a real ModelContext cannot be made to fail on demand.
    let seed = MainWindowModel(context: context, now: { origin })
    seed.createProject(named: "Payments")
    try seed.captureService().capture(
        text: "Fix the retry handler", preferred: seed.preferredProjectIDForCapture)

    let model = MainWindowModel(
        context: context, now: { origin }, save: { _ in throw SaveFailure() })
    let taskID = try #require(model.groups.first?.tasks.first?.id)
    model.selectedTaskID = taskID

    model.cycleStatusOnSelection()

    #expect(model.lastError != nil)
    #expect(model.groups.map(\.status) == [.todo])
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
make test
```

Expected: FAIL — `value of type 'MainWindowModel' has no member 'canChangeStatus'`, and
`type 'ActiveSheet' has no member 'blockedReason'`.

- [ ] **Step 3: Extend `ActiveSheet` and `MainWindowActions`**

In `StenoKit/Features/MainWindow/MainWindowActions.swift`, add the case after `editProject`:

```swift
    /// §3.3's optional blocked reason, for the named task (M1-05).
    ///
    /// The transition has already committed when this appears, so dismissing
    /// the sheet is not a cancellation — it is declining to annotate.
    case blockedReason(UUID)
```

and add to the protocol, after `canCreateTask`:

```swift
    /// FR-3's status shortcuts act on the selected task, so the menu gates on
    /// this rather than offering an action with no subject.
    var canChangeStatus: Bool { get }
```

and after `selectPreviousProject()`:

```swift
    func cycleStatusOnSelection()
    func markSelectionBlocked()
```

- [ ] **Step 4: Implement them on `MainWindowModel`**

Add next to `canCreateTask`:

```swift
    /// FR-3's status actions need a subject.
    public var canChangeStatus: Bool { selectedTaskID != nil }
```

Add in the `MainWindowActions` section, immediately before `public func newTask()`:

```swift
    /// D15's one path for status, over this window's context. The view never
    /// sees the context itself — it calls the model, which holds the service,
    /// exactly as `captureService()` arranges for capture.
    private func statusService() -> StatusService {
        StatusService(context: context, now: now, save: save)
    }

    /// Move a task, then offer a reason if it just became blocked.
    public func setStatus(_ new: Status, on taskID: UUID) {
        guard let task = task(withID: taskID) else { return }
        do {
            let changed = try statusService().setStatus(new, on: task)
            lastError = nil
            reload()
            // Only on a real transition. Re-selecting BLOCKED on a task that is
            // already blocked wrote nothing, so prompting for a reason would
            // offer to annotate an event that does not exist.
            if changed, new == .blocked { activeSheet = .blockedReason(taskID) }
        } catch {
            Log.app.error(
                "could not change the status: \(String(describing: error), privacy: .public)")
            lastError = "Could not change the status. Your change was not saved."
            // Not cosmetic: `rollback()` leaves the held task reporting the
            // rejected status, and it is this fetch that refreshes it. Without
            // it the window would show a status the store refused (D-018).
            reload()
        }
    }

    /// §3.3's optional reason, committed after the transition.
    public func addBlockedReason(_ text: String, to taskID: UUID) {
        guard let task = task(withID: taskID) else { return }
        do {
            try statusService().addBlockedReason(text, to: task)
            lastError = nil
            reload()
        } catch {
            Log.app.error(
                "could not save the blocked reason: \(String(describing: error), privacy: .public)")
            lastError = "Could not save the reason. Your change was not saved."
            reload()
        }
    }

    public func cycleStatusOnSelection() {
        guard let id = selectedTaskID, let task = task(withID: id) else { return }
        setStatus(task.status.next, on: id)
    }

    public func markSelectionBlocked() {
        guard let id = selectedTaskID else { return }
        setStatus(.blocked, on: id)
    }
```

- [ ] **Step 5: Run the tests**

```bash
make build && make test && make lint
```

Expected: PASS, 0 lint violations.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: status actions on the main window model

The model holds the service and the views call the model, so no view ever sees
a ModelContext — ARCHITECTURE §2 rule 2, and the same arrangement captureService()
already makes for capture.

The reason sheet is offered only when a transition actually happened: marking a
task blocked when it already is writes nothing, so prompting would offer to
annotate an event that does not exist.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: The views and the menu

No tests: these need a window server, which D-010 puts out of reach of the headless bundle. They are
covered by Task 5's tests below them and by §10's manual checks. **The compiler is the gate here** —
`make build` catches the exhaustive-switch failure in `MainWindowView` if the sheet case is missed.

**Files:**
- Create: `Steno/Features/MainWindow/StatusControl.swift`
- Modify: `Steno/Features/MainWindow/TaskDetailView.swift`
- Modify: `Steno/Features/MainWindow/TaskListView.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift`
- Modify: `Steno/App/MainWindowCommands.swift`

**Interfaces:**
- Consumes: `MainWindowModel.setStatus(_:on:)`, `.addBlockedReason(_:to:)`,
  `.cycleStatusOnSelection()`, `.markSelectionBlocked()`, `.canChangeStatus`,
  `ActiveSheet.blockedReason(UUID)` — all from Task 5; `Status.allCases`, `Status.displayName`.
- Produces: `struct StatusMenuItems` and `struct StatusControl` (both internal to the app target).
  **M1-04's popover consumes `StatusMenuItems` — do not make it `private`.**

- [ ] **Step 1: Create the control**

Create `Steno/Features/MainWindow/StatusControl.swift`:

```swift
import StenoKit
import SwiftUI

/// The four statuses as menu items, with a checkmark on the current one.
///
/// **One list, every surface.** The detail pane's menu and the task rows'
/// context menu both render this, and M1-04's popover will too, so the four
/// statuses cannot acquire a per-surface spelling — the same argument that put
/// `Status.displayName` in StenoKit rather than in a view.
struct StatusMenuItems: View {
    let current: Status
    let onSelect: (Status) -> Void

    var body: some View {
        // `id: \.self` because `Status` is not `Identifiable`; it is a raw
        // `String` enum, so it is `Hashable` for free.
        ForEach(Status.allCases, id: \.self) { status in
            Button {
                onSelect(status)
            } label: {
                // Two branches rather than one `Label` with a conditional
                // image name: an empty `systemImage` string renders as a
                // missing-image placeholder, not as nothing.
                if status == current {
                    Label(status.displayName, systemImage: "checkmark")
                } else {
                    Text(status.displayName)
                }
            }
        }
    }
}

/// The detail pane's status control: the current status, clickable.
struct StatusControl: View {
    let current: Status
    let onSelect: (Status) -> Void

    var body: some View {
        Menu {
            StatusMenuItems(current: current, onSelect: onSelect)
        } label: {
            Text(current.displayName)
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
```

- [ ] **Step 2: Put the control in the detail pane**

In `Steno/Features/MainWindow/TaskDetailView.swift`, replace the static capsule:

```swift
                    Text(task.status.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
```

with:

```swift
                    StatusControl(current: task.status) { new in
                        model.setStatus(new, on: task.id)
                    }
```

and replace this now-false paragraph in the type's doc comment:

```swift
/// **The status is a label, not a control.** Status changes are M1-05; this
/// task displays status and never mutates it.
```

with:

```swift
/// **The status control writes through `MainWindowModel`, never directly.**
/// The model publishes live `@Model` objects, so a view holds a real
/// `TaskItem` — but `TaskItem`'s mutators are `internal` as of M1-05, so this
/// file cannot skip `StatusService` and the event it appends even by mistake
/// (D-033).
```

- [ ] **Step 3: Put the control on the task rows**

In `Steno/Features/MainWindow/TaskListView.swift`, in `rows(_:)`, replace:

```swift
            .tag(task.id)
        }
```

with:

```swift
            .tag(task.id)
            // A context menu rather than an always-visible per-row picker: the
            // list is already grouped *by* status, so an inline control would
            // restate its own section header on every row. M1-04's popover is
            // where an always-visible toggle earns the space, because that
            // list has no section headers.
            .contextMenu {
                StatusMenuItems(current: task.status) { new in
                    model.setStatus(new, on: task.id)
                }
            }
        }
```

- [ ] **Step 4: Host the reason sheet**

In `Steno/Features/MainWindow/MainWindowView.swift`, add a case to the `switch sheet` immediately
before `case .editProject(let id):`:

```swift
            case .blockedReason(let id):
                // §3.3's reason is optional, and the transition to BLOCKED has
                // already committed by the time this appears — Esc declines to
                // annotate, it does not undo. `TextEntrySheet` disables its
                // confirm on empty input, so "no reason" costs one keystroke.
                TextEntrySheet(
                    title: "Why is this blocked?",
                    placeholder: "Optional — waiting on what?",
                    confirm: "Add Reason"
                ) { model.addBlockedReason($0, to: id) }
```

- [ ] **Step 5: Add the two menu items**

In `Steno/App/MainWindowCommands.swift`, insert before the
`// FR-3 lists "switch project" …` comment:

```swift
        // FR-3's "cycle status" and the deliberate way into BLOCKED (D-034).
        // Its own menu rather than an addition to File: M1-06's "Add Note"
        // belongs beside these, and neither is a File operation.
        //
        // ⌘⇧S and ⌘⇧B rather than the otherwise natural arrow chords: a menu
        // item bound to ⌘⇧→ would shadow "extend selection to end of line"
        // inside the capture field, and §1.1 makes that field the one thing
        // that must not degrade. Steno has no Save item, so ⌘⇧S is free here.
        CommandMenu("Task") {
            Button("Cycle Status") { actions?.cycleStatusOnSelection() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions?.canChangeStatus != true)

            Button("Mark Blocked") { actions?.markSelectionBlocked() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.canChangeStatus != true)
        }

```

Also update that file's doc comment, which names this task:

```swift
/// **Extending this is the whole point.** M1-05 added "Cycle Status" and
/// "Mark Blocked"; M1-06 adds "Add Note": one method on `MainWindowActions`,
/// one `Button` here.
```

- [ ] **Step 6: Build, test, lint**

```bash
make build && make test && make lint
```

Expected: all green. If `make build` reports `switch must be exhaustive` in `MainWindowView.swift`,
Step 4 was missed.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: status controls in the detail pane and on task rows

One StatusMenuItems view behind both surfaces, so the four statuses cannot
acquire a per-surface spelling — and so M1-04's popover inherits a control
rather than building a third.

Rows get a context menu rather than an inline picker: the list is already
grouped by status, so a per-row control would restate its own section header
on every row.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/DECISIONS.md`
- Modify: `docs/tasks/M1-05-status-control.md`
- Modify: `docs/tasks/M1-04-menu-bar.md`
- Modify: `docs/tasks/README.md`

`docs/REQUIREMENTS.md` is **not** amended — nothing in this branch contradicts it. FR-3 asks for a
cycle shortcut without specifying its order, §3.3 marks `blockedReason` optional, and §3.2's
transition rules are implemented as written.

- [ ] **Step 1: `ARCHITECTURE.md`**

In §3's invariant table, replace the `.stenoDidCapture` row and add one:

```
| Surfaces see each other's writes | Every successful write posts `.stenoDidWrite` | `CaptureService` and `StatusService` post, `MainWindowModel` observes (M1-03, M1-05) | D-019, D-035 |
| A status change never happens without its event | `StatusService` is the only route; the model mutators are `internal` | `StatusService.setStatus` (M1-05) | §3.3, D-033 |
```

In §5's tree, add under `StenoKit/` after the `Capture/` entry:

```
  Status/         status service, transition and cycle           (exists, M1-05)
```

and move the notification into the `Support/` line:

```
  Support/        Logging.swift, ProjectPalette.swift, WriteNotifications.swift  (exists, M0-02/M1-02/M1-05)
```

- [ ] **Step 2: `DECISIONS.md` — four new entries**

Append after D-032, following the file's stated format:

```markdown
### D-033 — `StatusService` is the only route to a status change
**2026-08-28** · M1-05 · **Status:** accepted, closes D-019's mutation hole

Status transitions go through `StatusService`, which appends the `statusChanged`
event §3.3 requires in the same call. To make that structural rather than
advisory, the domain mutators — `TaskItem.rename`/`.move`/`.setArchived`/`.setStatus`,
`Project.rename`/`.setJiraProjectKeys`/`.setArchived`, and `Event.redact()` — drop
from `public` to `internal`.

**Why:** `MainWindowModel` publishes live `@Model` objects, so view code holds a
real `TaskItem`. With a `public setStatus` it could skip the event and have the
next unrelated `save(context)` commit the change — the hole M0-05 left and D-019
named. M2.5-02's merge *derives* `TaskItem.status` from the newest `statusChanged`
event, so such a transition silently reverts after an import, months later,
looking like data corruption. The reduction compiles because no file in the
`Steno` target calls a mutator or constructs a model, and every test file uses
`@testable import`.
**Alternatives:** a doc comment asking view code not to call `setStatus` — a
promise, where this branch's predecessor spent four review rounds on comments
that promised things the code did not enforce.

### D-034 — The cycle shortcut skips BLOCKED
**2026-08-28** · M1-05 · **Status:** accepted

`Status.cycle` is `[.todo, .inProgress, .done]`, and ⌘⇧S walks it. `blocked` is
reachable from the status control and from ⌘⇧B, never from the cycle. Cycling
out of `blocked` goes to `inProgress`.

**Why:** every transition appends an event, and M2-02 renders that log into a
stand-up. Cycling all four would make TODO → DONE a three-press walk appending
two events for states the user never meant to be in — individually truthful,
collectively a description of work that did not happen. `blocked` is also the one
status §3.3 pairs with a reason, which makes it a deliberate act rather than a
waypoint. FR-3 requires a cycle shortcut and does not say what it cycles through,
so this is a choice inside a silent spec, not a deviation from it.
**Alternatives:** all four in declaration order (the event noise above); four
direct shortcuts (⌃⌘1–4), rejected because FR-3 asks for a cycle specifically.

### D-035 — `.stenoDidCapture` is renamed `.stenoDidWrite`
**2026-08-28** · M1-05 · **Status:** accepted, renames D-031's notification

One notification, posted by every writing service after a successful save.
`CaptureService` and `StatusService` post it today; M1-06's notes will. D-031's
reasoning is unchanged and still applies in full — only the name moved, along
with `CaptureObservation` → `WriteObservation` and the file to `StenoKit/Support/`.

**Why:** D-031's own doc comment said the notification was meant to cover "M1-05's
and M1-06's future writes", but the name said capture, and a status change is not
a capture.
**Alternatives:** a second name alongside the first, which grows a registration
per observer per feature and makes the first forgotten one a staleness bug that
looks like SwiftData being flaky; or posting `.stenoDidCapture` from
`StatusService`, which is free and makes the name assert something false.

### D-036 — The blocked reason is offered after the transition, never before
**2026-08-28** · M1-05 · **Status:** accepted

Moving a task to BLOCKED commits the `statusChanged` event immediately; only then
does a sheet offer an optional reason. Esc or empty input appends no
`blockedReason` event, and the status has already changed either way.
`StatusService.addBlockedReason(_:to:)` is a separate method rather than a
parameter on `setStatus`.

**Why:** §3.3 marks the reason optional, and M1-05's task file warns that making
it mandatory adds friction at the moment the user is most frustrated. Committing
first means the friction is zero even if they ignore the sheet. The parameter
form was drafted and rejected: because the transition commits first, nothing
would ever pass it, and it would ship as an unused argument.
**Alternatives:** the service taking the reason inline (dead parameter); no UI at
all until M1-06 (ships a capability nothing exercises).
```

Also add a pointer line to D-031, under its existing text:

```markdown
**Renamed by D-035 (M1-05):** the notification is now `.stenoDidWrite` and the
token holder `WriteObservation`. Everything above still applies.
```

- [ ] **Step 3: Tick the task file**

In `docs/tasks/M1-05-status-control.md`, change every `- [ ]` in **Acceptance criteria** to `- [x]`,
and append under the notes:

```markdown
**Settled during implementation.** The cycle shortcut walks TODO → IN-PROGRESS →
DONE and skips BLOCKED (D-034). The domain mutators dropped from `public` to
`internal`, which this file asked to be decided deliberately (D-033). The blocked
reason is offered after the transition, never as a precondition (D-036).
```

- [ ] **Step 4: Note the reordering in M1-04's task file**

In `docs/tasks/M1-04-menu-bar.md`, under **Notes for the spec/plan phase**, replace the first bullet
(the one beginning "If M1-05 has not merged yet") with:

```markdown
- **M1-05 merged first, so its status path exists.** The popover's inline toggles call
  `StatusService.setStatus(_:on:)` through a view model; they do not mutate `TaskItem` and
  cannot — its mutators are `internal` as of M1-05 (D-033). The popover also inherits
  `StatusMenuItems` from `Steno/Features/MainWindow/StatusControl.swift`, and
  `CaptureFieldView`'s `.bar` style from M1-03. Build none of those a second time.
```

- [ ] **Step 5: Tick the README row**

In `docs/tasks/README.md`, change the M1-05 row to `- [x]`. Check the other M1 rows for anything
that merged without being ticked (CLAUDE.md step 4) and tick those too.

- [ ] **Step 6: Verify and commit**

```bash
make build && make test && make lint
git add -A
git commit -m "docs: record M1-05's four decisions and tick its criteria

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Manual verification (for the user, after `make run`)

Agents cannot see or click this app — views need a window server and the test bundle is headless
(D-010). These eight checks cover what no test in this branch can:

1. Select a task, press ⌘⇧S repeatedly — status walks TODO → IN-PROGRESS → DONE → TODO, and the row
   moves between sections each time.
2. ⌘⇧S never produces BLOCKED.
3. Press ⌘⇧B — the task moves to BLOCKED and a "Why is this blocked?" sheet appears.
4. Press Esc on that sheet — the task is still BLOCKED, and the timeline shows one `statusChanged`
   event and no reason event.
5. Repeat and type a reason — the timeline shows both events, reason second.
6. Right-click a task row — the four statuses appear with a checkmark on the current one; picking one
   moves the row.
7. Change the status from the detail pane — the list row moves to match.
8. With no task selected, Cycle Status and Mark Blocked are greyed out in the Task menu.

## PR body must state

- The build order swapped: M1-05 landed before M1-04, and why (M1-04's toggles need this path).
- The cycle skips BLOCKED — a choice inside FR-3's silence, not a deviation from it.
- The mutator visibility reduction, which M1-05's task file asked to be decided deliberately.
- **The `rollback()` finding:** `ModelContext.rollback()` protects the store but does not restore a
  held reference. `MainWindowModel` was already safe because it reloads on failure; the behaviour is
  now pinned by a test and stated in `StatusService`'s doc comment.
