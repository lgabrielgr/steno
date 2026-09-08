# M2-01 Report Window Computation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Given a project, compute D8's report window and gather every event inside it — pure, headless, and side-effect free.

**Architecture:** Two units in a new `StenoKit/Report/` directory. `ReportWindow` is a caseless enum holding the window rule — FR-4 step 2's 24h first-run lookback and §10.1's clock-skew clamp — with no store and no clock, so its branches are testable against literals. `ReportGatherer` is a `@MainActor` struct that reads through a `ModelContext` and returns `GatheredWindow`: a `Sendable` value snapshot rather than live SwiftData rows, because M3-03 hands it across an async boundary to an `AIProvider` and `@Model` classes cannot go there. It has no `save` parameter and posts no notification — that absence is FR-4's side-effect guarantee expressed as a type.

**Tech Stack:** Swift 6, SwiftData, swift-testing (`@Test` / `#expect`), SwiftLint `--strict`, macOS 14.0 floor.

**Spec:** [`docs/superpowers/specs/2026-09-07-m2-01-report-window-design.md`](../specs/2026-09-07-m2-01-report-window-design.md) — read it alongside this plan. Every "why" below is argued there.

## Global Constraints

- **Work on branch `feat/report-window`. Never commit to `main`.** Open a PR and **do not merge it** — the user reviews and merges (CLAUDE.md, §9.5). `main` is protected, so a direct push fails anyway.
- `make build && make test && make lint` must all pass before the PR (§9.5 step 4). SwiftLint runs `--strict`, so a warning is a failure.
- **The event log is append-only.** Nothing in this task creates, mutates, or deletes an `Event`.
- **This task writes nothing at all.** No `context.save()`, no `.stenoDidWrite` post, no `lastStandupAt` advance. FR-4: "Generating a preview must be free of side effects, so the user can peek without corrupting their window."
- **Out of scope — do not build:** markdown rendering (M2-02), advancing `lastStandupAt` or the Copy flow (M2-03), undo (M2-04), `SourceRef` refreshing (M4-01), anything in the AI layer (M3).
- Commit subjects take a Conventional Commits prefix (`feat:`, `docs:`, `test:`). Every commit ends with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Every code block in this plan was compiled and run before the plan was written.** The full suite passed and SwiftLint reported 0 violations across 135 files. Type them as given — variants have not been verified.

### Toolchain gotchas that apply here

- **An enum inside a SwiftData `#Predicate` does not compile**, in either spelling. Every `EventKind` and `Status` filter in this task happens in memory after the fetch. `EventQueries` already records this.
- A `@Test` function that takes a **private** type must itself be `private`, or it will not compile.
- `xcbeautify` does not print parameterized test cases. Absence from the output is not failure.
- SwiftLint `--strict` rejects identifiers shorter than three characters and the literal word `TODO` in a comment.
- Use `ModelContext(container)`, never `container.mainContext` — `mainContext` does not retain its container, and the store dangles mid-test.
- A same-context refetch returns the object you already hold. Asserting "the store was not written" requires a **second** `ModelContext` over the same container.
- `make test` regenerates `Steno.xcodeproj` on every run, by design. It can disturb an open Xcode session.

---

## Task overview

| # | Deliverable | Files |
|---|---|---|
| 1 | `ReportWindow` — the window rule | `Report/ReportWindow.swift` |
| 2 | `EventQueries.inWindow` and a `report` log category | `Models/EventQueries.swift`, `Support/Logging.swift` |
| 3 | The snapshot types and the gathering core | `Report/GatheredWindow.swift`, `Report/ReportGatherer.swift` |
| 4 | Inclusion, ordering, ticket keys, cadence | `Report/ReportGatherer.swift` |
| 5 | The four purity gates | `Report/ReportGathererPurityTests.swift` |
| 6 | Mutation sweep — prove every gate can fail | none (verification) |
| 7 | `DECISIONS.md`, `ARCHITECTURE.md`, the PR | docs |

---

### Task 1: `ReportWindow` — the window rule

FR-4 step 2's 24h first-run lookback and §10.1's clock-skew clamp, as a rule with no store and no clock. Split out from the gatherer for the reason `NoteCorrection` is split out from `NoteService`: two of this task's acceptance criteria are statements about window arithmetic and nothing else, and a rule taking plain values is testable against literals rather than a store fixture.

**Files:**
- Create: `StenoKit/Report/ReportWindow.swift`
- Create: `StenoTests/Report/ReportWindowTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ReportWindow.bounds(lastStandupAt: Date?, now: Date) -> (start: Date, end: Date)` and `ReportWindow.firstRunLookback: TimeInterval`. Task 3 calls `bounds`.

- [ ] **Step 1: Create the two new directories**

```bash
mkdir -p StenoKit/Report StenoTests/Report
```

- [ ] **Step 2: Write the failing tests**

Create `StenoTests/Report/ReportWindowTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let noon = Date(timeIntervalSince1970: 1_700_000_000)

@Test("FR-4 step 2: a project's first report looks back 24 hours")
func firstRunProducesATwentyFourHourWindow() {
    let (start, end) = ReportWindow.bounds(lastStandupAt: nil, now: noon)

    #expect(end == noon)
    #expect(start == noon.addingTimeInterval(-86_400))
    #expect(end.timeIntervalSince(start) == 86_400)
}

@Test("D8: a subsequent report starts from that project's own lastStandupAt")
func aSubsequentRunStartsFromLastStandupAt() {
    let last = noon.addingTimeInterval(-3_600)

    let (start, end) = ReportWindow.bounds(lastStandupAt: last, now: noon)

    #expect(start == last)
    #expect(end == noon)
}

/// One row of the gap table. Private, so the `@Test` function taking it must be
/// private too — a non-private function with a private parameter type does not
/// compile.
private struct GapCase: Sendable {
    let label: String
    let days: Double
}

/// D8's whole claim, as one parameterized test rather than two hand-written
/// ones.
///
/// The point is that a weekend and a vacation traverse **the same code with no
/// branch between them**. Two separate tests would pass just as well against an
/// implementation that special-cased one of them, which is exactly what D8 says
/// must not exist — so the shared body is the assertion, not a convenience.
@Test(
    "D8: weekend and vacation gaps need no special-casing",
    arguments: [
        GapCase(label: "three-day weekend", days: 3),
        GapCase(label: "two-week vacation", days: 14),
        GapCase(label: "sick day", days: 1),
        GapCase(label: "same morning", days: 0.25),
    ])
private func gapsOfAnyLengthProduceTheirOwnWindow(gap: GapCase) {
    let seconds = gap.days * 86_400
    let last = noon.addingTimeInterval(-seconds)

    let (start, end) = ReportWindow.bounds(lastStandupAt: last, now: noon)

    #expect(start == last, "\(gap.label): window must start at the last stand-up")
    #expect(end.timeIntervalSince(start) == seconds, "\(gap.label): no clamping, no rounding")
}

@Test("§10.1 clock skew: a future lastStandupAt clamps to an empty window")
func aFutureLastStandupClampsToEmpty() {
    let ahead = noon.addingTimeInterval(90)

    let (start, end) = ReportWindow.bounds(lastStandupAt: ahead, now: noon)

    #expect(start == noon)
    #expect(end == noon)
    #expect(start <= end, "M2-03 persists this pair; M2-04 restores lastStandupAt from it")
}

@Test("the 24h fallback is not used to paper over a future lastStandupAt")
func clampingDoesNotFallBackToTwentyFourHours() {
    let ahead = noon.addingTimeInterval(90)

    let (start, _) = ReportWindow.bounds(lastStandupAt: ahead, now: noon)

    // Falling back to 24h here would silently re-report a day of work the user
    // already said out loud on the other Mac.
    #expect(start != noon.addingTimeInterval(-86_400))
}
```

- [ ] **Step 3: Run them and confirm they fail**

Run: `make test 2>&1 | grep -E "error:|Test Execute"`
Expected: FAIL — `cannot find 'ReportWindow' in scope`.

- [ ] **Step 4: Write the implementation**

Create `StenoKit/Report/ReportWindow.swift`:

```swift
import Foundation

/// FR-4 step 2's window, as a rule with no store and no clock.
///
/// Extracted from `ReportGatherer` for the reason `NoteCorrection` is extracted
/// from `NoteService`: two of M2-01's acceptance criteria are statements about
/// window arithmetic and nothing else, and a rule that takes plain values is
/// testable against literals rather than against a store fixture.
public enum ReportWindow {
    /// FR-4 step 2, and §3.5 as corrected in v1.7: a project's first report
    /// looks back 24 hours.
    ///
    /// `TimeInterval` arithmetic, deliberately, not `Calendar` arithmetic. FR-4
    /// says "24h before now" — not "yesterday", and not "since the start of the
    /// previous day". `Calendar.date(byAdding: .day, value: -1)` expresses a
    /// different sentence, one that shifts by an hour across a DST boundary and
    /// hands the user a 23- or 25-hour window twice a year.
    public static let firstRunLookback: TimeInterval = 24 * 60 * 60

    /// D8's window for one project: since that project's last stand-up.
    ///
    /// Takes the two facts it needs rather than a `Project`, so every branch is
    /// reachable from literals and neither a store nor a clock is required to
    /// test it.
    ///
    /// **`start` is clamped to `end`.** A `lastStandupAt` in the future is
    /// reachable through a supported path, not a hypothetical: §10.1 merges the
    /// field by "take the later timestamp", so reporting on a Mac whose clock
    /// runs fast and importing onto one whose clock does not leaves the second
    /// machine holding a timestamp ahead of its own `now`. Clamping yields an
    /// empty window — a thin report — where the alternatives are worse: falling
    /// back to 24h silently re-reports work already said aloud, and throwing
    /// takes out the app's core feature over a ninety-second clock disagreement
    /// (§7.4). It also keeps `windowStart <= windowEnd` true for every
    /// `StandupReport` M2-03 persists, which M2-04's undo reads back.
    ///
    /// The clamp is not logged here — `ReportGatherer` does that, so this stays
    /// a pure function of its arguments.
    public static func bounds(lastStandupAt: Date?, now: Date) -> (start: Date, end: Date) {
        let requested = lastStandupAt ?? now.addingTimeInterval(-firstRunLookback)
        return (min(requested, now), now)
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test 2>&1 | grep -E "Test Execute|error:"`
Expected: `Test Execute Succeeded`.

The gap table is parameterized over four cases. `xcbeautify` will not print them — that is expected.

- [ ] **Step 6: Mutation-check both rules**

Apply each mutation, run `make test`, confirm the named test goes **red**, then revert it. A mutation that survives means the test is decorative — fix the test before moving on.

| Mutation in `ReportWindow.swift` | Must be caught by |
|---|---|
| `firstRunLookback` `24 * 60 * 60` → `48 * 60 * 60` | "FR-4 step 2: a project's first report looks back 24 hours" |
| `return (min(requested, now), now)` → `return (requested, now)` | "§10.1 clock skew: a future lastStandupAt clamps to an empty window" |

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add StenoKit/Report/ReportWindow.swift StenoTests/Report/ReportWindowTests.swift
git commit -m "feat: report window rule — FR-4 step 2 and the clock-skew clamp

D8's window as a rule with no store and no clock, so the 24h first-run lookback
and the clamp are testable against literals rather than a fixture — the split
NoteCorrection already has from NoteService.

The clamp covers a lastStandupAt ahead of now, which §10.1's 'take the later
timestamp' merge produces whenever a report is made on a Mac with a fast clock
and imported onto one without. An empty window is a thin report; falling back
to 24h would silently re-report a day already said aloud, and throwing would
take out the app's core feature over a clock disagreement (§7.4).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `EventQueries.inWindow` and a `report` log category

The store vocabulary the gatherer reads through. The window predicate joins `EventQueries` rather than living in the gatherer because that file's own doc comment already names this caller: "M2-01's gathering and M3-03's prompt both have to honour that — so the predicate lives in one place rather than being rewritten, and eventually mis-written, per call site."

**Files:**
- Modify: `StenoKit/Models/EventQueries.swift` — append a second static after `timeline(forTaskID:)`
- Modify: `StenoKit/Support/Logging.swift` — add one `Logger` after `app`
- Modify: `StenoTests/Notes/EventQueriesTests.swift` — append two tests

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `EventQueries.inWindow(start: Date, end: Date) -> FetchDescriptor<Event>` and `Log.report: Logger`. Task 3 uses both.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Notes/EventQueriesTests.swift` (the file already declares `origin` and imports what these need):

```swift
@MainActor
@Test("the window query is closed at both ends and excludes redacted rows")
func theWindowQueryIsClosedAtBothEnds() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    let events = [
        Event(taskID: taskID, timestamp: origin.addingTimeInterval(-1), kind: .note, body: "before"),
        Event(taskID: taskID, timestamp: origin, kind: .note, body: "start"),
        Event(taskID: taskID, timestamp: origin.addingTimeInterval(30), kind: .note, body: "middle"),
        Event(taskID: taskID, timestamp: origin.addingTimeInterval(60), kind: .note, body: "end"),
        Event(taskID: taskID, timestamp: origin.addingTimeInterval(61), kind: .note, body: "after"),
    ]
    let hidden = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(30), kind: .note, body: "hidden")
    for event in events + [hidden] { context.insert(event) }
    hidden.redact()
    try context.save()

    let found = try context.fetch(
        EventQueries.inWindow(start: origin, end: origin.addingTimeInterval(60)))

    // Both boundaries inclusive. FR-4 step 3 specifies a closed interval, and
    // M2-03's Copy stamps lastStandupAt and its standupReported events with the
    // same instant — so this is the behaviour ReportGatherer's kind filter
    // exists to absorb.
    #expect(found.map(\.body) == ["start", "middle", "end"])
}

@MainActor
@Test("the window query returns events oldest first")
func theWindowQueryIsAscending() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    // Inserted newest-first, so insertion order disagrees with the sort.
    for offset in [50, 10, 30] {
        context.insert(
            Event(
                taskID: taskID, timestamp: origin.addingTimeInterval(Double(offset)),
                kind: .note, body: "at \(offset)"))
    }
    try context.save()

    let found = try context.fetch(
        EventQueries.inWindow(start: origin, end: origin.addingTimeInterval(60)))

    // Ascending, unlike timeline(forTaskID:): a report narrates a window
    // forwards, while a timeline shows the newest note first.
    #expect(found.map(\.body) == ["at 10", "at 30", "at 50"])
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `make test 2>&1 | grep -E "error:|Test Execute"`
Expected: FAIL — `type 'EventQueries' has no member 'inWindow'`.

- [ ] **Step 3: Add the query**

In `StenoKit/Models/EventQueries.swift`, insert this **after** the closing brace of `timeline(forTaskID:)` and before the enum's closing brace:

```swift
    /// Every non-redacted event in `[start, end]`, oldest first (FR-4 step 3).
    ///
    /// **Closed at both ends, as FR-4 specifies**, and that is load-bearing
    /// rather than incidental: M2-03's Copy stamps `project.lastStandupAt` and
    /// the `standupReported` events it appends with the same instant, so the
    /// next report's `start` equals those events' timestamps exactly. The
    /// interval therefore returns them every time — which is why
    /// `ReportGatherer` drops the kind, rather than this descriptor narrowing
    /// to a half-open range that would also drop a legitimate note stamped on
    /// the boundary.
    ///
    /// Not scoped to a task or a project. `Event` carries no `projectID` and
    /// this predicate stays `Date && Date && !Bool` — a `taskIDs.contains(...)`
    /// clause is the kind of construct that compiles and then throws at fetch
    /// time. The caller intersects with its own task set in memory; D18 caps
    /// the dataset, so the fetch is the cost and the filter is free.
    ///
    /// Ascending, unlike `timeline(forTaskID:)`: a report narrates a window
    /// forwards, while a timeline shows the newest note first.
    public static func inWindow(start: Date, end: Date) -> FetchDescriptor<Event> {
        FetchDescriptor<Event>(
            predicate: #Predicate {
                $0.timestamp >= start && $0.timestamp <= end && !$0.isRedacted
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
    }
```

- [ ] **Step 4: Add the log category**

In `StenoKit/Support/Logging.swift`, insert this immediately after the `app` logger and before the `captureSignposter` doc comment:

```swift
    /// The report path (FR-4).
    ///
    /// Its own category so a clamped or empty window can be found without
    /// reading every `app` line:
    ///
    ///     /usr/bin/log show --last 1h --info --predicate \
    ///       'subsystem == "com.lgabrielgr.steno" AND category == "report"'
    ///
    /// Spell out `/usr/bin/log` — zsh has a `log` builtin that shadows it.
    public static let report = Logger(subsystem: subsystem, category: "report")
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test 2>&1 | grep -E "window query|Test Execute|error:"`
Expected: both new tests pass, `Test Execute Succeeded`.

- [ ] **Step 6: Mutation-check the interval**

| Mutation in `EventQueries.swift` | Must be caught by |
|---|---|
| `$0.timestamp >= start` → `$0.timestamp > start` | "the window query is closed at both ends and excludes redacted rows" |
| `order: .forward` → `order: .reverse` | "the window query returns events oldest first" |

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add StenoKit/Models/EventQueries.swift StenoKit/Support/Logging.swift StenoTests/Notes/EventQueriesTests.swift
git commit -m "feat: a closed-interval event query for the report window

EventQueries gains inWindow(start:end:). It goes here rather than in the
gatherer because this file's doc comment already names M2-01's gathering as a
caller it centralises the redaction rule for.

Closed at both ends, as FR-4 step 3 specifies, and the tests assert both
boundaries rather than assuming them — M2-03's Copy will stamp lastStandupAt
and its standupReported events with one instant, so the boundary is load
bearing and the gatherer's kind filter is what absorbs it.

Ascending, unlike timeline(forTaskID:): a report narrates a window forwards
where a timeline shows the newest note first.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---
### Task 3: the snapshot types and the gathering core

`GatheredWindow` and a `ReportGatherer` that computes the window and gathers its events. Inclusion and ordering arrive in Task 4, so at the end of this task the gatherer returns **every** non-archived task in the project, unsorted.

**Files:**
- Create: `StenoKit/Report/GatheredWindow.swift`
- Create: `StenoKit/Report/ReportGatherer.swift`
- Create: `StenoTests/Report/ReportFixture.swift`
- Create: `StenoTests/Report/ReportGathererTests.swift`

**Interfaces:**
- Consumes: `ReportWindow.bounds(lastStandupAt:now:)` (Task 1); `EventQueries.inWindow(start:end:)` and `Log.report` (Task 2).
- Produces: `GatheredWindow(projectID:cadence:start:end:tasks:)`, `GatheredTask(id:title:status:ticketKeys:events:)`, `GatheredEvent(timestamp:kind:body:)`, all `Sendable` and `Equatable`; and `ReportGatherer(context:now:)` with `func gather(for project: Project) throws -> GatheredWindow`. Task 4 extends the gatherer; Task 5 tests it.

- [ ] **Step 1: Write the test fixture**

Create `StenoTests/Report/ReportFixture.swift`. Note `setLastStandup` — it commits, which matters: `lastStandupAt` is a plain `var` (§10.1 gives it its own merge rule, so it must not stamp `modifiedAt`), and a bare uncommitted assignment leaves `context.hasChanges` true and silently defeats Task 5's second purity gate.

```swift
import Foundation
import SwiftData

@testable import StenoKit

/// A store with two projects, for the gatherer's tests.
///
/// Holds the `ModelContainer` as well as the context, because the purity gates
/// need a **second** `ModelContext` over the same container: a refetch on the
/// context that did the reading returns the object already held, so it would
/// pass even against a mutation. The independent context is what makes those
/// assertions real reads of the store.
@MainActor
struct ReportFixture {
    let container: ModelContainer
    let context: ModelContext
    let alpha: Project
    let beta: Project

    /// 2023-11-14 22:13:20 UTC. A fixed instant, so every window is arithmetic
    /// the reader can check by hand.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        container = try StenoStore.inMemory()
        context = ModelContext(container)
        alpha = Project(name: "Alpha", colorHex: "#112233", modifiedAt: Self.origin)
        beta = Project(name: "Beta", colorHex: "#445566", modifiedAt: Self.origin)
        context.insert(alpha)
        context.insert(beta)
        try context.save()
    }

    @discardableResult
    func task(
        _ title: String, in project: Project, status: Status = .todo,
        createdAt: Date = ReportFixture.origin, archived: Bool = false
    ) throws -> TaskItem {
        let item = TaskItem(title: title, projectID: project.id, createdAt: createdAt)
        context.insert(item)
        if status != .todo { item.setStatus(status, at: createdAt) }
        if archived { item.setArchived(true, at: createdAt) }
        try context.save()
        return item
    }

    @discardableResult
    func event(
        _ body: String, on task: TaskItem, at offset: TimeInterval,
        kind: EventKind = .note, redacted: Bool = false
    ) throws -> Event {
        let event = Event(
            taskID: task.id, timestamp: Self.origin.addingTimeInterval(offset),
            kind: kind, body: body)
        context.insert(event)
        if redacted { event.redact() }
        try context.save()
        return event
    }

    @discardableResult
    func jiraRef(_ key: String, on task: TaskItem) throws -> SourceRef {
        let ref = SourceRef(taskID: task.id, kind: .jiraIssue, identifier: key)
        context.insert(ref)
        ref.task = task
        try context.save()
        return ref
    }

    /// Set a project's last stand-up **and commit it**.
    ///
    /// A method rather than a bare assignment at each call site because
    /// `lastStandupAt` is a plain `var` (§10.1 gives it its own merge rule, so
    /// it must not stamp `modifiedAt`), which makes an uncommitted assignment
    /// easy to write and invisible afterwards. It leaves `context.hasChanges`
    /// true, which silently defeats the purity gate that asserts the gatherer
    /// left nothing pending.
    func setLastStandup(_ date: Date?, on project: Project) throws {
        project.lastStandupAt = date
        try context.save()
    }

    /// The gatherer under test, with its clock pinned to `origin + offset`.
    func gatherer(nowOffset: TimeInterval) -> ReportGatherer {
        ReportGatherer(context: context, now: { Self.origin.addingTimeInterval(nowOffset) })
    }

    /// Read `project` back through a context that has never seen it, so the
    /// value comes from the store rather than from an object already in memory.
    func reloadThroughASecondContext(_ project: Project) throws -> Project? {
        let fresh = ModelContext(container)
        let id = project.id
        return try fresh.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id }))
            .first
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `StenoTests/Report/ReportGathererTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

@MainActor
@Test("FR-4 step 3: the window's events are gathered, oldest first")
func theWindowsEventsAreGatheredOldestFirst() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("second", on: task, at: 120)
    try fixture.event("first", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.count == 1)
    #expect(window.tasks[0].events.map(\.body) == ["first", "second"])
    #expect(window.projectID == fixture.alpha.id)
    #expect(window.cadence == .daily)
}

@MainActor
@Test("events outside the window are not gathered")
func eventsOutsideTheWindowAreExcluded() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("before the window", on: task, at: -60)
    try fixture.event("inside", on: task, at: 60)
    try fixture.event("after the window", on: task, at: 600)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].events.map(\.body) == ["inside"])
}

@MainActor
@Test("§3.3: redacted events are excluded")
func redactedEventsAreExcluded() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("kept", on: task, at: 60)
    try fixture.event("withdrawn", on: task, at: 90, redacted: true)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].events.map(\.body) == ["kept"])
}

@MainActor
@Test("a standupReported event stamped exactly at windowStart does not appear")
func theLastReportsOwnEventIsNotGathered() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    // Exactly what M2-03's Copy leaves behind: the event and the new
    // lastStandupAt share one instant, and FR-4's interval is closed.
    try fixture.event("reported", on: task, at: 0, kind: .standupReported)
    try fixture.event("real work", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].events.map(\.body) == ["real work"])
}

@MainActor
@Test("the interval stays closed: an ordinary event at windowStart is kept")
func anOrdinaryEventOnTheBoundaryIsKept() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("on the start boundary", on: task, at: 0)
    try fixture.event("on the end boundary", on: task, at: 300)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    // This is the test that keeps the standupReported exclusion falsifiable. A
    // half-open interval would pass the test above and fail this one.
    #expect(
        window.tasks[0].events.map(\.body) == ["on the start boundary", "on the end boundary"])
}

@MainActor
@Test("an archived task is dropped even with events in the window")
func anArchivedTaskIsDropped() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task(
        "abandoned", in: fixture.alpha, status: .inProgress, archived: true)
    try fixture.event("still noisy", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.isEmpty)
}

@MainActor
@Test("ticket keys carry every jiraIssue ref, sorted, and no other kind")
func ticketKeysCarryEveryJiraRefSorted() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("two tickets", in: fixture.alpha, status: .inProgress)
    try fixture.jiraRef("PAY-14", on: task)
    try fixture.jiraRef("ACC-2", on: task)
    let link = SourceRef(
        taskID: task.id, kind: .githubPR, identifier: "steno#21",
        url: "https://github.com/x/y/pull/21")
    fixture.context.insert(link)
    link.task = task
    try fixture.context.save()
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].ticketKeys == ["ACC-2", "PAY-14"])
}

@MainActor
@Test("FR-4 step 2: a project that has never reported gets a 24h window")
func aFirstReportGetsATwentyFourHourWindow() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("yesterday evening", on: task, at: -3_600)
    try fixture.event("two days ago", on: task, at: -172_800)

    #expect(fixture.alpha.lastStandupAt == nil)
    let window = try fixture.gatherer(nowOffset: 0).gather(for: fixture.alpha)

    #expect(window.start == ReportFixture.origin.addingTimeInterval(-86_400))
    #expect(window.tasks[0].events.map(\.body) == ["yesterday evening"])
}

@MainActor
@Test("§10.1 clock skew: a future lastStandupAt yields an empty, non-inverted window")
func aFutureLastStandupYieldsAnEmptyWindow() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("carried over", in: fixture.alpha, status: .inProgress)
    try fixture.event("real work", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin.addingTimeInterval(600), on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.start == window.end)
    #expect(window.tasks[0].events.isEmpty, "no events, but the open task still reports")
    #expect(window.tasks.count == 1)
}

@MainActor
@Test("D17: cadence travels with the window")
func cadenceTravelsWithTheWindow() throws {
    let fixture = try ReportFixture()
    let biweekly = Project(
        name: "EM sync", colorHex: "#778899", reportCadence: .periodic,
        modifiedAt: ReportFixture.origin)
    fixture.context.insert(biweekly)
    try fixture.context.save()

    let window = try fixture.gatherer(nowOffset: 0).gather(for: biweekly)

    #expect(window.cadence == .periodic)
}
```

- [ ] **Step 3: Run them and confirm they fail**

Run: `make test 2>&1 | grep -E "error:|Test Execute"`
Expected: FAIL — `cannot find 'ReportGatherer' in scope`.

- [ ] **Step 4: Write the snapshot types**

Create `StenoKit/Report/GatheredWindow.swift`:

```swift
import Foundation

/// One project's report window and everything inside it (FR-4 steps 2–3, D8).
///
/// **Value types, not the SwiftData rows they were read from.** M3-03 hands
/// this to an `AIProvider` across an async boundary, and `TaskItem` and `Event`
/// are `@Model` classes: not `Sendable`, not safe in another isolation domain.
/// Returning live rows would mean these types get written anyway — later, in a
/// task whose review gate is about prompt construction rather than about the
/// shape of the report payload.
///
/// It is also half of FR-4's side-effect guarantee expressed as a type rather
/// than as a convention: a caller holding a `GatheredWindow` has nothing it
/// *could* mutate.
public struct GatheredWindow: Sendable, Equatable {
    /// M2-03 writes this to `StandupReport.projectID`.
    public let projectID: UUID

    /// D17 selects the section set (M2-02) and the output schema (M3-03).
    public let cadence: ReportCadence

    /// `StandupReport.windowStart` / `windowEnd`. Never inverted — see
    /// `ReportWindow.bounds`.
    public let start: Date
    public let end: Date

    public let tasks: [GatheredTask]

    public init(
        projectID: UUID,
        cadence: ReportCadence,
        start: Date,
        end: Date,
        tasks: [GatheredTask]
    ) {
        self.projectID = projectID
        self.cadence = cadence
        self.start = start
        self.end = end
        self.tasks = tasks
    }
}

/// One task as the report sees it.
public struct GatheredTask: Sendable, Equatable {
    /// M2-03 appends `standupReported` here; §7.3 sends it as `task_id`.
    public let id: UUID
    public let title: String
    public let status: Status

    /// Every `jiraIssue` ref on the task, sorted.
    ///
    /// **Plural, where §7.3 says "ticket key" singular.** FR-1.5's extractor
    /// creates one ref per key it finds, so a task whose notes mention two
    /// tickets carries two. Keeping only one would silently drop a key the user
    /// has to say out loud — the exact failure §7.3's "preserve verbatim"
    /// constraint exists to prevent. Sorted so the output is deterministic.
    public let ticketKeys: [String]

    /// This task's non-redacted events inside the window, oldest first.
    ///
    /// **May be empty**, and a renderer must handle that honestly rather than
    /// emit a blank bullet: a task included because it is currently
    /// `inProgress` or `blocked` has said nothing during the window, and that
    /// is precisely the task Monday's stand-up is about.
    public let events: [GatheredEvent]

    public init(
        id: UUID,
        title: String,
        status: Status,
        ticketKeys: [String],
        events: [GatheredEvent]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.ticketKeys = ticketKeys
        self.events = events
    }
}

/// One event as the report sees it (§7.3: "all events … with timestamps").
///
/// **Carries no `id`.** An earlier draft had one, justified as what M2-04 would
/// use to find the events it redacts — which was false, because M2-04 redacts
/// `standupReported` events and `ReportGatherer` never returns that kind. With
/// that justification gone nothing reads it, and an unused `public` field on a
/// type M2-02, M2-03 and M3-03 all depend on only gets harder to remove. A task
/// that needs event identity can add it alongside the consumer that wants it.
public struct GatheredEvent: Sendable, Equatable {
    public let timestamp: Date
    public let kind: EventKind
    public let body: String

    public init(timestamp: Date, kind: EventKind, body: String) {
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
    }
}
```

- [ ] **Step 5: Write the gatherer**

Create `StenoKit/Report/ReportGatherer.swift`. This is the Task 3 shape — no inclusion filter and no sort yet:

```swift
import Foundation
import OSLog
import SwiftData

/// Reads one project's report window (FR-4 steps 2–3, D8, D16).
///
/// **Named `Gatherer`, not `Service`, deliberately.** `CaptureService`,
/// `StatusService` and `NoteService` share a shape: each injects `save`,
/// mutates, and posts `.stenoDidWrite`. This type does none of those, and doing
/// any of them would break the guarantee FR-4 states outright — "generating a
/// preview must be free of side effects, so the user can peek without
/// corrupting their window". A name ending in `Service` is an invitation to add
/// the `save` parameter its siblings have, by symmetry, without noticing what
/// that symmetry costs here.
///
/// `@MainActor` because `ModelContext` is not `Sendable`, and `now` injected so
/// the window is assertable — both for the reasons the sibling services record.
/// There is no `save` parameter and no `commit()`; that absence is the design.
@MainActor
public struct ReportGatherer {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// D8's window for `project`, with every event inside it. Writes nothing.
    ///
    /// `throws` covers `context.fetch` failing, and nothing else.
    public func gather(for project: Project) throws -> GatheredWindow {
        let (start, end) = ReportWindow.bounds(lastStandupAt: project.lastStandupAt, now: now())
        warnIfClamped(project: project, end: end)

        // D16 is enforced here. `Event` has no `projectID` — its only link is
        // `taskID`, per §3.3 — so "this project's events" is necessarily "the
        // events of the tasks whose projectID matches", and scoping the task
        // fetch is what makes another project's rows unreachable from this
        // result. Nothing in this type reads another project's lastStandupAt.
        let tasks = try context.fetch(Self.tasks(inProjectID: project.id))
        let buckets = try eventsByTaskID(start: start, end: end, taskIDs: Set(tasks.map(\.id)))

        let gathered =
            tasks
            .map { task in
                GatheredTask(
                    id: task.id,
                    title: task.title,
                    status: task.status,
                    ticketKeys: (task.sourceRefs ?? [])
                        .filter { $0.kind == .jiraIssue }
                        .map(\.identifier)
                        .sorted(),
                    events: buckets[task.id] ?? []
                )
            }

        return GatheredWindow(
            projectID: project.id, cadence: project.reportCadence,
            start: start, end: end, tasks: gathered)
    }

    /// The window's events, bucketed by task, oldest first within each bucket.
    ///
    /// **One fetch, filtered in memory, and both halves of that are deliberate.**
    /// An `EventKind` inside a SwiftData `#Predicate` does not compile in either
    /// spelling — `EventQueries` already records this and already filters kinds
    /// after the fetch for the same reason — and a `taskIDs.contains(...)`
    /// predicate is the other construct not worth betting a fetch on. D18 caps a
    /// project under 20 tasks, so the fetch is the cost and the filtering is
    /// free.
    private func eventsByTaskID(
        start: Date, end: Date, taskIDs: Set<UUID>
    ) throws -> [UUID: [GatheredEvent]] {
        var buckets: [UUID: [GatheredEvent]] = [:]
        for event in try context.fetch(EventQueries.inWindow(start: start, end: end))
        where taskIDs.contains(event.taskID) && event.kind != .standupReported {
            buckets[event.taskID, default: []].append(
                GatheredEvent(timestamp: event.timestamp, kind: event.kind, body: event.body))
        }
        return buckets
    }

    /// The project's live tasks. Archived tasks are not reported on.
    ///
    /// The predicate stays `UUID == UUID && !Bool` for `EventQueries`' reason:
    /// a `Status` inside a `#Predicate` does not compile, so the status half of
    /// `isReportable` happens in memory.
    private static func tasks(inProjectID id: UUID) -> FetchDescriptor<TaskItem> {
        FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.projectID == id && !$0.isArchived }
        )
    }

    /// Record a clamped window (§5.2 of the design; §8 permits log metadata).
    ///
    /// Dates, never task content. The condition re-derives the clamp rather
    /// than having `ReportWindow.bounds` report it, so that stays a pure
    /// function of its arguments.
    private func warnIfClamped(project: Project, end: Date) {
        guard let last = project.lastStandupAt, last > end else { return }
        Log.report.notice(
            """
            lastStandupAt is ahead of now; clamping the report window to empty. \
            project=\(project.id.uuidString, privacy: .public) \
            lastStandupAt=\(last.timeIntervalSince1970, privacy: .public) \
            now=\(end.timeIntervalSince1970, privacy: .public)
            """)
    }
}
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `make test 2>&1 | grep -E "Test Execute|error:"`
Expected: `Test Execute Succeeded`.

One oddity to expect: `tasks(inProjectID:)`'s doc comment mentions `isReportable`, which does not exist until Task 4. It is a comment, so it compiles; leave it as written rather than editing it out and back in.

- [ ] **Step 7: Mutation-check the rules this task owns**

| Mutation in `ReportGatherer.swift` | Must be caught by |
|---|---|
| drop `&& event.kind != .standupReported` from the `where` clause | "a standupReported event stamped exactly at windowStart does not appear" |
| `#Predicate { $0.projectID == id && !$0.isArchived }` → `#Predicate { $0.projectID == id }` | "an archived task is dropped even with events in the window" |

Also confirm that dropping the kind filter does **not** break "the interval stays closed: an ordinary event at windowStart is kept", and that Task 2's half-open mutation does not break the `standupReported` test. The two rules are independently tested on purpose — that is why the spec rejected doing both.

- [ ] **Step 8: Lint and commit**

```bash
make lint
git add StenoKit/Report/GatheredWindow.swift StenoKit/Report/ReportGatherer.swift StenoTests/Report/ReportFixture.swift StenoTests/Report/ReportGathererTests.swift
git commit -m "feat: gather a project's report window — FR-4 steps 2-3, D8, D16

ReportGatherer reads one project's window and returns it as a Sendable value
snapshot. Not live SwiftData rows: M3-03 hands this across an async boundary to
an AIProvider, and @Model classes are neither Sendable nor safe there. Inert
values also make FR-4's side-effect guarantee a property of the type rather
than a convention.

Named Gatherer, not Service, deliberately. The three *Service types each inject
save, mutate, and post .stenoDidWrite; this one does none of those, and a name
ending in Service invites a future agent to add the save parameter its siblings
have without noticing what that symmetry costs here.

D16 is enforced by scoping the task fetch to the project. Event carries no
projectID — its only link is taskID, per §3.3 — so a project's events are
necessarily its tasks' events, and no path here reads another project's
lastStandupAt.

standupReported events are excluded from gathering. FR-4 does not say so; this
is a declared interpretation, argued in the design doc and repeated in the PR
body. A report is not work, and M2-03's Copy will stamp lastStandupAt and its
events with one instant, so a closed interval returns them every time.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: inclusion, ordering, and the tie-break

Two rules the gathering core deliberately left out, because each is a decision rather than a mechanism.

**Inclusion is active *or* open.** The obvious reading of FR-4 step 3 — gather the events in the window — is not sufficient: FR-4's own report structure two paragraphs later has a **Today** section ("current IN-PROGRESS tasks") and a **Blockers** section ("BLOCKED tasks with reasons"), both defined by *current status* rather than by window activity. A task set in progress on Friday and left quiet over the weekend is exactly what Monday's stand-up is for.

**Ordering is explicit** because SwiftData does not specify fetch order without a `SortDescriptor`, and M2-02 must render the same markdown from the same window every time.

**Files:**
- Modify: `StenoKit/Report/ReportGatherer.swift`
- Modify: `StenoTests/Report/ReportGathererTests.swift` — append

**Interfaces:**
- Consumes: everything from Task 3.
- Produces: `ReportGatherer.precedes(_:_:) -> Bool` (internal, so tests reach it via `@testable`). `gather` now filters and sorts.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Report/ReportGathererTests.swift`:

```swift
@MainActor
@Test("a quiet in-progress task is still reported, with no events")
func aQuietOpenTaskSurvives() throws {
    let fixture = try ReportFixture()
    // Set in progress on Friday; nothing said over the weekend. FR-4's "Today"
    // section is about exactly this task.
    try fixture.task("carried over", in: fixture.alpha, status: .inProgress)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.count == 1)
    #expect(window.tasks[0].title == "carried over")
    #expect(window.tasks[0].events.isEmpty)
}

@MainActor
@Test("a quiet blocked task is still reported")
func aQuietBlockedTaskSurvives() throws {
    let fixture = try ReportFixture()
    try fixture.task("waiting on infra", in: fixture.alpha, status: .blocked)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.map(\.title) == ["waiting on infra"])
}

@MainActor
@Test("a quiet finished task is dropped")
func aQuietFinishedTaskIsDropped() throws {
    let fixture = try ReportFixture()
    try fixture.task("shipped last month", in: fixture.alpha, status: .done)
    try fixture.task("not started", in: fixture.alpha, status: .todo)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.isEmpty)
}

@MainActor
@Test("a finished task that moved during the window is reported")
func aTaskCompletedInsideTheWindowIsReported() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("shipped this morning", in: fixture.alpha, status: .done)
    try fixture.event("TODO → DONE", on: task, at: 60, kind: .statusChanged)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.map(\.title) == ["shipped this morning"])
}

@MainActor
@Test("tasks are ordered by createdAt, not by whatever the fetch returns")
func tasksAreOrderedByCreatedAt() throws {
    let fixture = try ReportFixture()
    // Inserted newest-first, deliberately. A test that inserted them in the
    // expected order would pass against no sort at all: SwiftData returns
    // insertion order here, so the two would agree and the assertion would be
    // measuring nothing. Making insertion order disagree with the sort key is
    // what gives this test the power to fail.
    for index in (0..<6).reversed() {
        try fixture.task(
            "task \(index)", in: fixture.alpha, status: .inProgress,
            createdAt: ReportFixture.origin.addingTimeInterval(Double(index)))
    }
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.map(\.title) == (0..<6).map { "task \($0)" })
}

@MainActor
@Test("tasks created in the same instant are ordered by id, in both directions")
func tasksCreatedTogetherAreTieBrokenById() throws {
    let fixture = try ReportFixture()
    let earlier = try fixture.task(
        "a", in: fixture.alpha, createdAt: ReportFixture.origin)
    let later = try fixture.task(
        "b", in: fixture.alpha, createdAt: ReportFixture.origin)

    // Asserted on the comparator, not on a gathered order: at the sizes D18
    // permits, `sorted(by:)` is stable in practice, so an output-order test
    // would pass just as well with no tie-break at all.
    let (low, high) =
        earlier.id.uuidString < later.id.uuidString ? (earlier, later) : (later, earlier)

    #expect(ReportGatherer.precedes(low, high))
    #expect(ReportGatherer.precedes(high, low) == false)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `make test 2>&1 | tail -20`
Expected: **TEST BUILD FAILED**, with `type 'ReportGatherer' has no member 'precedes'` on both `#expect` lines of the tie-break test.

The compile error masks the rest: "a quiet finished task is dropped" and "tasks are ordered by createdAt" cannot run until it clears, and they fail on their own once it does. Do not take the build failure as a sign the other tests are fine.

Note that "a quiet in-progress task is still reported" and "a quiet blocked task is still reported" **already pass** at this point — with no filter, everything is included. They are still worth having: they are what stops a later change from narrowing the rule to activity-only.

- [ ] **Step 3: Add the two helpers**

In `StenoKit/Report/ReportGatherer.swift`, insert both immediately **before** the `warnIfClamped` doc comment:

```swift
    /// Report order: oldest task first, ties broken by id.
    ///
    /// Explicit, because SwiftData does not specify fetch order without a
    /// `SortDescriptor`, and M2-02 must render the same markdown from the same
    /// window every time.
    ///
    /// **The tie-break is not decoration.** `sorted(by:)` is not documented as
    /// stable, so two tasks created in the same instant would otherwise have an
    /// unspecified relative order — the exact nondeterminism this sort exists to
    /// remove. It is a named function rather than a closure because that
    /// instability does not reproduce at the sizes D18 permits: a test on a
    /// handful of tasks cannot distinguish a missing tie-break from a stable
    /// sort, so the rule is asserted here directly instead of inferred from an
    /// output order that would agree either way.
    ///
    /// `UUID` is not `Comparable`, so the tie-break goes through `uuidString`.
    static func precedes(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }

    /// Whether `task` belongs in the report: active **or** open.
    ///
    /// The obvious reading of FR-4 step 3 — gather the events in the window — is
    /// not sufficient, because FR-4's own report structure two paragraphs later
    /// needs more than activity. **Today** is "current IN-PROGRESS tasks" and
    /// **Blockers** is "BLOCKED tasks with reasons": both are defined by current
    /// status, not by window activity. A task set in progress on Friday and left
    /// quiet over the weekend is exactly what Monday's stand-up is for, and an
    /// activity-only rule drops it.
    ///
    /// Exhaustive with no `default`, so a status added later is a compile error
    /// here rather than a silent omission from every report.
    private static func isReportable(_ task: TaskItem, hasEvents: Bool) -> Bool {
        switch task.status {
        case .inProgress, .blocked:
            true
        case .todo, .done:
            hasEvents
        }
    }
```

- [ ] **Step 4: Wire them into `gather`**

In `gather(for:)`, the pipeline currently reads:

```swift
        let gathered =
            tasks
            .map { task in
```

Change it to:

```swift
        let gathered =
            tasks
            .filter { Self.isReportable($0, hasEvents: !(buckets[$0.id] ?? []).isEmpty) }
            .sorted(by: Self.precedes)
            .map { task in
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test 2>&1 | grep -E "Test Execute|error:"`
Expected: `Test Execute Succeeded`.

- [ ] **Step 6: Mutation-check both rules**

| Mutation in `ReportGatherer.swift` | Must be caught by |
|---|---|
| `isReportable`'s body → `case .inProgress, .blocked, .todo, .done: hasEvents` | "a quiet in-progress task is still reported, with no events" |
| delete the `.sorted(by: Self.precedes)` line | "tasks are ordered by createdAt, not by whatever the fetch returns" |
| `precedes` → `lhs.createdAt < rhs.createdAt` | "tasks created in the same instant are ordered by id, in both directions" |

The third one is why `precedes` is a named function rather than a closure. `sorted(by:)` is not documented as stable, but at the sizes D18 permits it *is* stable in practice — so an output-order test cannot distinguish a missing tie-break from a stable sort, and the rule has to be asserted directly. **If you inline this comparator into the sort call, that test loses all of its power.**

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add StenoKit/Report/ReportGatherer.swift StenoTests/Report/ReportGathererTests.swift
git commit -m "feat: report inclusion is active-or-open, and ordering is explicit

A task is reported when it is not archived and either has events in the window
or is currently inProgress or blocked. Activity-only gathering is the obvious
reading of FR-4 step 3 and it is wrong: FR-4's own Today and Blockers sections
are defined by current status, so a task set in progress on Friday and left
quiet over the weekend would vanish from Monday's stand-up.

Consequence for M2-02: GatheredTask.events may be empty, and the renderer has
to say something honest for that task rather than emit a blank bullet.

Ordering is explicit because SwiftData does not specify fetch order without a
SortDescriptor and M2-02 must be deterministic. The tie-break is a named
function so it can be tested directly — sorted(by:) is stable in practice at
these sizes, so an output-order test cannot tell a missing tie-break from a
stable sort.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: the four purity gates

FR-4's central guarantee: "generating a preview must be free of side effects, so the user can peek without corrupting their window." Four gates, because no one of them subsumes the others — a write that never posts `.stenoDidWrite` passes gate 1, a write that posts *and* saves passes gate 2, and a mutation held only in memory passes gate 3 unless the read goes through an independent context.

**Files:**
- Create: `StenoTests/Report/ReportGathererPurityTests.swift`

**Interfaces:**
- Consumes: `ReportGatherer`, `ReportFixture`, and `WriteCounter` (already in `StenoTests/Support/`, shared with the capture and status tests).
- Produces: nothing. This task is entirely tests.

- [ ] **Step 1: Write the tests**

Create `StenoTests/Report/ReportGathererPurityTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4's central guarantee: "generating a preview must be free of side
/// effects, so the user can peek without corrupting their window."
///
/// Four gates, because no one of them subsumes the others. A write that never
/// posts `.stenoDidWrite` passes gate 1; a write that posts *and* saves passes
/// gate 2; a mutation held only in memory passes gate 3 unless the read goes
/// through an independent context.

@MainActor
@Test("gate 1 — gathering posts no .stenoDidWrite")
func gatheringPostsNoWriteNotification() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("a note", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let counter = WriteCounter()

    _ = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(counter.posts == 0)
}

@MainActor
@Test("gate 2 — gathering leaves the context with nothing to save")
func gatheringLeavesNoPendingChanges() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("a note", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    #expect(fixture.context.hasChanges == false, "precondition: the fixture is committed")

    _ = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(fixture.context.hasChanges == false)
}

@MainActor
@Test("gate 3 — FR-4: the clock does not advance on generate")
func gatheringDoesNotAdvanceTheClock() throws {
    let fixture = try ReportFixture()
    try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    let before = ReportFixture.origin
    try fixture.setLastStandup(before, on: fixture.alpha)

    // Generate repeatedly — the user peeking, being pulled into a meeting, and
    // peeking again — then read the stored value back through a context that
    // has never seen this project.
    let gatherer = fixture.gatherer(nowOffset: 3_600)
    _ = try gatherer.gather(for: fixture.alpha)
    _ = try gatherer.gather(for: fixture.alpha)
    _ = try gatherer.gather(for: fixture.alpha)

    let stored = try fixture.reloadThroughASecondContext(fixture.alpha)
    #expect(stored?.lastStandupAt == before)
}

@MainActor
@Test("gate 4 — D16: reporting on one project does not touch another")
func gatheringOneProjectLeavesTheOtherAlone() throws {
    let fixture = try ReportFixture()
    let mine = try fixture.task("alpha work", in: fixture.alpha, status: .inProgress)
    let theirs = try fixture.task("beta work", in: fixture.beta, status: .inProgress)
    try fixture.event("alpha note", on: mine, at: 60)
    try fixture.event("beta note", on: theirs, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    try fixture.setLastStandup(ReportFixture.origin.addingTimeInterval(-86_400), on: fixture.beta)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    // Beta's window is untouched...
    let storedBeta = try fixture.reloadThroughASecondContext(fixture.beta)
    #expect(storedBeta?.lastStandupAt == ReportFixture.origin.addingTimeInterval(-86_400))
    // ...and none of beta's work leaked into alpha's report.
    #expect(window.tasks.map(\.title) == ["alpha work"])
    #expect(window.tasks.flatMap { $0.events.map(\.body) } == ["alpha note"])
}

@MainActor
@Test("gate 4b — a project with no last stand-up does not borrow another's")
func aFirstReportDoesNotReadAnotherProjectsClock() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("alpha work", in: fixture.alpha, status: .inProgress)
    try fixture.event("eight hours ago", on: task, at: -28_800)
    // Beta reported two minutes ago. If any global "last stand-up" existed,
    // alpha's window would start there and this event would vanish.
    try fixture.setLastStandup(ReportFixture.origin.addingTimeInterval(-120), on: fixture.beta)

    let window = try fixture.gatherer(nowOffset: 0).gather(for: fixture.alpha)

    #expect(window.start == ReportFixture.origin.addingTimeInterval(-86_400))
    #expect(window.tasks[0].events.map(\.body) == ["eight hours ago"])
}
```

- [ ] **Step 2: Run them and confirm they pass**

Run: `make test 2>&1 | grep -E "gate |Test Execute|error:"`
Expected: all five pass. They should pass immediately — the gatherer already writes nothing. **A test that passes the moment you write it has not been shown to work**, which is what Step 3 is for.

- [ ] **Step 3: Mutation-check every gate**

This step is not optional. Apply each mutation, run `make test`, confirm the named gate goes **red**, then revert.

| Mutation in `ReportGatherer.gather` | Must be caught by |
|---|---|
| add `NotificationCenter.default.post(name: .stenoDidWrite, object: nil)` | gate 1 |
| add `project.lastStandupAt = end` | gate 2 |
| add `project.lastStandupAt = end` and `try context.save()` | gate 3 |
| `#Predicate { $0.projectID == id && !$0.isArchived }` → `#Predicate { $0.id == $0.id && !$0.isArchived }` | gate 4 |

If any survives, the gate is decorative. Fix it before continuing.

- [ ] **Step 4: Lint and commit**

```bash
make lint
git add StenoTests/Report/ReportGathererPurityTests.swift
git commit -m "test: four gates on FR-4's side-effect freedom

Generating a report must change nothing, so the user can peek without
corrupting their window. Four gates because none subsumes the others: a write
that never posts .stenoDidWrite passes gate 1, one that posts and saves passes
gate 2, and an in-memory mutation passes gate 3 unless the read goes through an
independent context.

Gates 3 and 4 read the store back through a second ModelContext deliberately. A
same-context refetch returns the object already held, so it would pass against
a mutation and assert nothing.

Every gate was mutation-checked: the behaviour was broken, the gate confirmed
red, and the break reverted.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: mutation sweep

A verification task with no deliverable but a result. The per-task mutation checks above were run as each test was written; this repeats all of them against the finished tree, because a test that could fail in isolation can be made redundant by a later change.

**Files:** none.

- [ ] **Step 1: Confirm the tree is green first**

```bash
make build && make test && make lint
```
Expected: `Build Succeeded`, `Test Execute Succeeded`, `0 violations`.

- [ ] **Step 2: Run every mutation, one at a time**

For each row: apply the mutation, run `make test`, record which tests go red, `git checkout --` the file. All eleven must be caught.

| # | File | Mutation | Expected catcher |
|---|---|---|---|
| 1 | `ReportWindow.swift` | `24 * 60 * 60` → `48 * 60 * 60` | first-run 24h tests |
| 2 | `ReportWindow.swift` | `min(requested, now)` → `requested` | both clock-skew tests |
| 3 | `EventQueries.swift` | `>= start` → `> start` | "the interval stays closed…" |
| 4 | `EventQueries.swift` | `.forward` → `.reverse` | "the window query returns events oldest first" |
| 5 | `ReportGatherer.swift` | drop `&& event.kind != .standupReported` | "a standupReported event stamped exactly at windowStart…" |
| 6 | `ReportGatherer.swift` | drop `&& !$0.isArchived` | "an archived task is dropped…" |
| 7 | `ReportGatherer.swift` | `$0.projectID == id` → `$0.id == $0.id` | gate 4 |
| 8 | `ReportGatherer.swift` | `isReportable` → `hasEvents` for every case | the two quiet-open-task tests |
| 9 | `ReportGatherer.swift` | delete `.sorted(by: Self.precedes)` | "tasks are ordered by createdAt…" |
| 10 | `ReportGatherer.swift` | `precedes` → `lhs.createdAt < rhs.createdAt` | "tasks created in the same instant…" |
| 11 | `ReportGatherer.swift` | add a `.stenoDidWrite` post to `gather` | gate 1 |

- [ ] **Step 3: Record the result**

If all eleven are caught, note it for the PR body: *"Eleven mutations applied to the finished tree; every one was caught by a named test."* If any survives, that test is decorative — strengthen it, then re-run the sweep.

- [ ] **Step 4: Confirm the tree is unmodified**

```bash
git status --porcelain
```
Expected: empty. A mutation left behind here would ship.

---

### Task 7: decisions, architecture, and the PR

**Files:**
- Modify: `docs/DECISIONS.md` — append four entries
- Modify: `docs/ARCHITECTURE.md` — mark `Report/` as existing
- Modify: `docs/tasks/README.md` — only if a merged row is untucked (see Step 3)

- [ ] **Step 1: Append the decisions**

Add to `docs/DECISIONS.md`, following the existing format (`### D-0NN — title`, then a bold date/task/status line, prose, and an **Alternatives:** line). Use the next free numbers — `D-064` is the last one taken as of this plan, so these are **D-065** through **D-068**:

- **D-065 — A gathered window is a `Sendable` value snapshot.** `GatheredWindow` carries values, not `@Model` rows, because M3-03 hands it across an async boundary to an `AIProvider`. Alternatives: returning live `TaskItem`/`Event` (not `Sendable`; the snapshot types get written anyway in M3-03, under a review gate about prompts rather than about payload shape).
- **D-066 — `standupReported` events are never gathered.** A declared interpretation of FR-4 step 3's "all events". A report is not work, and Copy stamps `lastStandupAt` and its events with one instant, so a closed interval returns them every time. Alternatives: a half-open interval (deviates from FR-4, drops legitimate boundary notes, and leaves mid-window report events in); doing both (makes the interval change untestable — nothing could distinguish it once the kind is excluded).
- **D-067 — An inverted window is clamped, not fatal.** `lastStandupAt` ahead of `now` is reachable through §10.1's "take the later timestamp" merge. Clamping keeps `windowStart <= windowEnd` true for every `StandupReport` M2-03 persists and M2-04 reads back. Alternatives: 24h fallback (silently re-reports a day already said aloud); throwing (§7.4 says the user must never arrive empty-handed).
- **D-068 — Report inclusion is active-or-open.** FR-4's **Today** and **Blockers** sections are defined by current status, not window activity. Alternatives: activity-only (drops the task Monday's stand-up is about, and forces M2-02 to open a second read path into the store); every non-archived task (pushes the reportability judgement into M3-03's prompt as noise).

- [ ] **Step 2: Update the architecture map**

In `docs/ARCHITECTURE.md` §5, the `Report/` line currently reads:

```
  Report/         window computation, renderers          (M2-01, M2-02)
```

Change it to:

```
  Report/         window computation (exists, M2-01); renderers (M2-02)
```

- [ ] **Step 3: Check for untucked merged rows**

CLAUDE.md step 4 requires this, because nothing else prompts it and §9.5 forbids a direct commit to `main`.

```bash
grep -n "^- \[ \]" docs/tasks/README.md | head -20
```
Every unticked row should be M2-01 or later. If a row above M2-01 is unticked but its PR merged, tick it in this PR. **Do not tick M2-01's own row** — that happens in a later PR, once this one merges.

- [ ] **Step 4: Full verification**

```bash
make build && make test && make lint
```
All three must be green. Do not open the PR otherwise (§9.5 step 4, §13).

- [ ] **Step 5: Commit the docs**

```bash
git add docs/DECISIONS.md docs/ARCHITECTURE.md docs/tasks/README.md
git commit -m "docs: record M2-01's four decisions and mark Report/ as landed

D-065 the Sendable snapshot, D-066 excluding standupReported, D-067 the
inverted-window clamp, D-068 active-or-open inclusion. Two of them are
interpretations FR-4 does not state; both are declared in the PR body rather
than applied silently.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Push and open the PR — then stop**

```bash
git push -u origin feat/report-window
```

The PR body must state, per §9.5 and CLAUDE.md:

- **Requirement IDs:** D8, D16, D17, FR-4 steps 2–3, §3.3, §3.5.
- **What was done:** `StenoKit/Report/` gains `ReportWindow` and `ReportGatherer`; `EventQueries` gains `inWindow`.
- **How it was verified:** `make build`, `make test`, `make lint` all green; eleven mutations applied to the finished tree and every one caught by a named test.
- **Two declared interpretations of FR-4** — spell both out, with the reasoning from D-066 and D-067, and say plainly that FR-4 does not state either. Note that the `standupReported` collision was *measured* against SwiftData, not inferred: the closed interval really does return an event stamped at exactly `windowStart`.
- **What was deliberately left out:** rendering (M2-02), the clock advance and Copy (M2-03), undo (M2-04), ref refresh (M4-01).
- **One constraint inherited by M2-04:** it cannot get its `standupReported` rows from a `GatheredWindow`, since this path never returns that kind and `StandupReport` stores no event IDs. It must query them itself.

- [ ] **Step 7: Stop. Do not merge.**

The user reviews and merges (CLAUDE.md non-negotiable #1). Once merged, M2-01's row in `docs/tasks/README.md` gets ticked in a later PR.
