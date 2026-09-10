# M2-04 — Undo Last Stand-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An "Undo last stand-up" action that reverses all three of Copy's store effects — the advanced clock, the appended `standupReported` events, and the persisted report — by redaction, never deletion, and only while the report is still the project's most recent.

**Architecture:** One new `StandupUndoService` in StenoKit owns every write, through a single `ModelContext` and a single `save`, so all-or-none is a transaction boundary rather than careful ordering. It cannot reuse `NoteService.redact` (D-044 guards on `isUserAuthored`, false for `standupReported`) and cannot read its events from a `GatheredWindow` (D-066 never returns that kind), so it queries for them itself and matches on the `reportID` payload D-079 added for exactly this. Two surfaces call it: the draft sheet gains a third `.undone` phase, and the `Task` menu gains an item that outlives the sheet.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing. macOS 14.0 floor. Built with `make build && make test && make lint`.

**Spec:** [`docs/superpowers/specs/2026-09-10-m2-04-undo-standup-design.md`](../specs/2026-09-10-m2-04-undo-standup-design.md)

## Global Constraints

- **Never commit to `main`.** Branch `feat/undo-standup`, one PR, do not merge (CLAUDE.md §9.5).
- **The event log is append-only.** Never mutate or delete an `Event`; the only permitted write to an existing row is flipping `isRedacted` (§3.3, §13). This task is the one that looks most like an exception and is not.
- **`make build && make test && make lint` must all pass before the PR.** Verify, do not assert (§9.5 step 4, §13).
- **CI fails when `make format` would change anything** (D-075). Run `make format` before committing; a dirty tree afterwards is your change — commit it.
- **Views get no store access** — no `@Query`, no `@Environment(\.modelContext)`. View models mediate (ARCH §2 rule 2, D-019).
- **SwiftLint runs `--strict`.** Identifiers under 3 characters fail, a literal `TODO` fails, and `file_length` warns at **400 lines** — which `MainWindowModel.swift` is within 3 lines of. Task 5 says what to do about it.
- **SwiftData:** an `EventKind` inside a `#Predicate` does not compile in either spelling, and `Data` has no predicate operation — filter both in memory. In tests use `ModelContext(container)`, never `container.mainContext` (it does not retain its container and dangles). Any refetch meant to prove something about the *store* needs a **second** `ModelContext`.
- **Inside `#expect`, `allSatisfy(\.someProperty)` does not compile.** swift-testing decomposes the expression to `$0.allSatisfy($1)`, and a key path passed to a `rethrows` parameter fails there with "call can throw" on code that cannot. Use the closure form, `allSatisfy { $0.someProperty }`. For the same reason, hoist any `try`-ing collection expression into a `let` before the macro.
- **`Logger` interpolation does not concatenate.** `"a: " + "\(x, privacy: .public)"` fails with *referencing operator function '+' on 'RangeReplaceableCollection' requires that 'OSLogMessage' conform to 'RangeReplaceableCollection'*. Write one string literal.
- Every new decision is recorded in `docs/DECISIONS.md` and cited in the PR body.

> **All code below was compiled at module scope and run.** Where a step says something compiles or a test passes, it was built and executed — not predicted. Every mutation named in a "verify the tests can fail" step was applied to a green tree and observed to fail the named test.

---

## Task 1: The fetch the undo needs

`StandupUndoService` has to find `standupReported` events, and neither half of that test is expressible in a `#Predicate`. This adds the narrowing half to the shared query vocabulary, so the redaction rule stays in one place.

**Files:**
- Modify: `StenoKit/Models/EventQueries.swift`
- Test: `StenoTests/Notes/EventQueriesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `EventQueries.notRedacted(atOrAfter: Date) -> FetchDescriptor<Event>`. Task 2 is its only caller.

- [ ] **Step 1: Write the failing test**

Append to `StenoTests/Notes/EventQueriesTests.swift`:

```swift
@MainActor
@Test("the undo query is inclusive at its bound and excludes redacted rows")
func theUndoQueryBoundsAndExcludesRedacted() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    // Inserted out of order, so a passing result cannot come from insertion
    // order agreeing with the assertion by accident.
    for (offset, body) in [(30, "after"), (-10, "before"), (0, "on the bound")] {
        context.insert(
            Event(
                taskID: taskID, timestamp: origin.addingTimeInterval(Double(offset)),
                kind: .standupReported, body: body))
    }
    let redacted = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(20),
        kind: .standupReported, body: "already redacted")
    context.insert(redacted)
    redacted.redact()
    try context.save()

    let found = try context.fetch(EventQueries.notRedacted(atOrAfter: origin))

    // Inclusive at the bound: `StandupUndoService` calls this with the report's
    // `windowEnd`, and an event stamped exactly there is the boundary case
    // D-066 describes — the user copying the instant they generate.
    #expect(Set(found.map(\.body)) == ["on the bound", "after"])
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL to **build**, with one error: `type 'EventQueries' has no member 'notRedacted'`. A build failure masks every other expected failure in the suite, so read the `❌` lines rather than the summary — and note that `grep`ing for `error:` finds nothing, because xcbeautify prints build errors with a `❌` prefix instead.

- [ ] **Step 3: Add the descriptor**

In `StenoKit/Models/EventQueries.swift`, after `inWindow(start:end:)` and inside the `enum`:

```swift
    /// Every still-live event stamped at or after `date` (FR-4.1's undo).
    ///
    /// **A narrowing, not a match.** `StandupUndoService` is looking for the
    /// `standupReported` events of one particular report, and neither half of
    /// that test is expressible here: an `EventKind` inside a `#Predicate` does
    /// not compile in either spelling, and `payload` is `Data` with no
    /// predicate operation that could read a `reportID` out of it. So this
    /// bounds the fetch and the caller decides — which is safe precisely
    /// because the caller's test is exact (D-079), so an over-broad bound costs
    /// a few rows rather than correctness.
    ///
    /// Redacted rows are excluded for this enum's usual reason and one of its
    /// own: an event already redacted needs no second redaction, so the count
    /// the service logs is the number of rows it actually changed.
    ///
    /// Unsorted. The caller redacts a set, and a set has no order to get wrong.
    public static func notRedacted(atOrAfter date: Date) -> FetchDescriptor<Event> {
        FetchDescriptor<Event>(predicate: #Predicate { $0.timestamp >= date && !$0.isRedacted })
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS — `"the undo query is inclusive at its bound and excludes redacted rows"`.

- [ ] **Step 5: Verify the test can fail**

Two mutations, applied to a green tree, each caught only by this test:

| Mutation | Result |
|---|---|
| `$0.timestamp >= date` → `$0.timestamp > date` | CAUGHT |
| drop `&& !$0.isRedacted` | CAUGHT |

Revert both before continuing, and re-run `make test` to confirm the tree is green again. **`git checkout <file>` will not restore a file git does not track yet** — restore from your own copy of the original text.

- [ ] **Step 6: Commit**

```bash
make format && git add StenoKit/Models/EventQueries.swift StenoTests/Notes/EventQueriesTests.swift
git commit -m "feat: add the event fetch FR-4.1's undo narrows with (M2-04)"
```

---

## Task 2: `StandupUndoService` — the three effects, or none of them

The whole of FR-4.1's behaviour, with no UI. This is the task that carries the review gate: every acceptance criterion in the task file is a statement about this type.

**Files:**
- Create: `StenoKit/Report/StandupUndoService.swift`
- Modify: `StenoTests/Report/ReportFixture.swift`
- Test: `StenoTests/Report/StandupUndoServiceTests.swift`

**Interfaces:**
- Consumes: `EventQueries.notRedacted(atOrAfter:)` (Task 1); `StandupReportedPayload.decoded(from:)`, `StandupReport.markUndone()`, `Event.redact()` (all already in the tree, all `internal`).
- Produces: `StandupUndoService(context:save:)` with `undoableReport(for: Project) throws -> StandupReport?` and `@discardableResult undo(_ : StandupReport, for: Project) throws -> Int`; `StandupUndoError.reportBelongsToAnotherProject` / `.reportIsNoLongerUndoable`; `ReportFixture.standupUndoService(save:)`. Tasks 4 and 5 consume all of it.

- [ ] **Step 1: Add the fixture helper the tests need**

In `StenoTests/Report/ReportFixture.swift`, immediately before `reportsInStore()`:

```swift
    /// FR-4.1's service, over the same context.
    ///
    /// Takes `save` for `standupService`'s reason and no `now` or `copy` at
    /// all: undo reads its timestamps out of the report it is undoing and
    /// touches no clipboard.
    func standupUndoService(
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> StandupUndoService {
        StandupUndoService(context: context, save: save)
    }
```

- [ ] **Step 2: Write the failing tests**

Create `StenoTests/Report/StandupUndoServiceTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4.1: reversing Copy's three store effects, by redaction and never by
/// deletion.

/// Prepare `project`, gather a window, and Copy it — returning the report undo
/// acts on.
///
/// `gatherAt` and `copyAt` are separate offsets because the two instants are
/// genuinely different (D-076) and several assertions below turn on which of
/// them a value came from: `windowEnd` is the gather instant, the appended
/// events carry the Copy instant, and undo restores `windowStart`.
@MainActor
@discardableResult
private func copiedReport(
    _ fixture: ReportFixture,
    in project: Project,
    lastStandupAt: Date?,
    gatherAt: TimeInterval,
    copyAt: TimeInterval,
    save: @escaping (ModelContext) throws -> Void = { try $0.save() }
) throws -> StandupReport {
    try fixture.setLastStandup(lastStandupAt, on: project)
    let window = try fixture.gatherer(nowOffset: gatherAt).gather(for: project)
    return try fixture.standupService(nowOffset: copyAt, save: save)
        .commit("the draft as copied", of: window, for: project).report
}

/// One in-progress task with a note, so every window has something in it.
@MainActor
@discardableResult
private func reportableWork(_ fixture: ReportFixture, in project: Project) throws -> TaskItem {
    let task = try fixture.task("ship the thing", in: project, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    return task
}

/// Every `standupReported` row in the store, **including redacted ones**.
///
/// The distinction is the point: `eventsInStore(kind:)` does not filter
/// redaction, so a count taken through it can tell "redacted" from "deleted".
/// A helper that excluded redacted rows would report a redaction as a missing
/// row and the append-only assertions would pass against a `context.delete`.
@MainActor
private func reportedRows(_ fixture: ReportFixture) throws -> [Event] {
    try fixture.eventsInStore(kind: .standupReported)
}

@MainActor
@Test("FR-4.1: undo restores lastStandupAt from the report's windowStart")
func undoRestoresTheClock() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let previous = ReportFixture.origin.addingTimeInterval(-7200)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: previous, gatherAt: 300, copyAt: 900)

    #expect(
        fixture.alpha.lastStandupAt == ReportFixture.origin.addingTimeInterval(300),
        "precondition: Copy advanced the clock to the window's end")

    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    // The pre-Copy value, and a value distinct from both `windowEnd` and the
    // Copy instant — so this cannot pass by restoring the wrong one of the
    // three dates the report carries.
    #expect(fixture.alpha.lastStandupAt == previous)
    #expect(try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt == previous)
}

@MainActor
@Test("§3.3: undo redacts the standupReported events and deletes nothing")
func undoRedactsRatherThanDeletes() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)

    let before = try reportedRows(fixture)
    #expect(before.count == 1, "precondition: Copy appended one event")
    #expect(before.allSatisfy { !$0.isRedacted }, "precondition: it is live")

    let redacted = try fixture.standupUndoService().undo(report, for: fixture.alpha)

    #expect(redacted == 1)
    let after = try reportedRows(fixture)
    // The row count is the whole assertion. Taken through a fetch that does
    // **not** exclude redacted rows, so a `context.delete` implementation —
    // the obvious one, and the one §3.3 forbids outright — fails here.
    #expect(after.count == before.count)
    // Closure form, not `allSatisfy(\.isRedacted)`: swift-testing decomposes the
    // expression to `$0.allSatisfy($1)`, and a key path passed to a `rethrows`
    // parameter fails to typecheck there — "call can throw" on code that cannot.
    #expect(after.allSatisfy { $0.isRedacted })
    #expect(before.map(\.id) == after.map(\.id), "the same rows, not replacements")
}

@MainActor
@Test("§3.5: the report row survives, marked undone")
func undoRetainsTheReportRow() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)

    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    // Through a context that has never seen the row: a fetch on the context
    // that wrote it returns the object already in hand, so it would report an
    // unsaved flag as persisted.
    let stored = try fixture.reportsInStore()
    #expect(stored.count == 1)
    #expect(stored.first?.isUndone == true)
    #expect(stored.first?.markdownBody == "the draft as copied", "§10 export still reads this")
}

@MainActor
@Test("D-079: undo redacts only the events of the report being undone")
func undoRedactsOnlyItsOwnEvents() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)

    // The first report is copied at +900. The second is *generated* at exactly
    // that instant — the user pressing Prepare the moment they finish copying,
    // which D-066 calls a normal thing to do rather than a contrived one. That
    // makes the first report's event land exactly on the second report's
    // `windowEnd`, so the fetch bound alone cannot separate them and only the
    // payload can.
    let first = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    let second = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: fixture.alpha.lastStandupAt,
        gatherAt: 900, copyAt: 1500)

    #expect(
        first.generatedAt == second.windowEnd,
        "precondition: the earlier report's events sit on the later report's fetch bound")
    #expect(try reportedRows(fixture).count == 2, "precondition: two events, one per report")

    let redacted = try fixture.standupUndoService().undo(second, for: fixture.alpha)

    #expect(redacted == 1, "the bound catches both events; the payload keeps one")
    let rows = try reportedRows(fixture)
    #expect(rows.count == 2, "still two rows — redaction, not deletion")
    #expect(rows.filter(\.isRedacted).map(\.timestamp) == [second.generatedAt])
    #expect(
        rows.filter { !$0.isRedacted }.map(\.timestamp) == [first.generatedAt],
        "the first report's event is untouched — its window was never taken back")
}

@MainActor
@Test("D-079: the payload decides, not the timestamp")
func undoMatchesOnPayloadRatherThanTimestamp() throws {
    let fixture = try ReportFixture()
    let task = try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)

    // An event of this report, stamped somewhere other than `generatedAt`.
    // `StandupService` does not currently produce this — it stamps the report
    // and its events from one `now()` — which is exactly why D-079 refused to
    // depend on that: it is a coincidence the service is free to stop
    // honouring, and undo would then break silently. This row is what makes
    // that rationale falsifiable rather than merely stated.
    let strayStamp = ReportFixture.origin.addingTimeInterval(1200)
    let stray = Event(
        taskID: task.id, timestamp: strayStamp, kind: .standupReported,
        body: "Reported to standup",
        payload: StandupReportedPayload(reportID: report.id).encoded())
    fixture.context.insert(stray)
    try fixture.context.save()

    let redacted = try fixture.standupUndoService().undo(report, for: fixture.alpha)

    #expect(redacted == 2, "both events name this report, whatever their stamps say")
    let rows = try reportedRows(fixture)
    #expect(rows.allSatisfy { $0.isRedacted })
}

@MainActor
@Test("FR-4.1: undo is refused once a newer report exists")
func undoIsRefusedOnceANewerReportExists() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let first = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: fixture.alpha.lastStandupAt,
        gatherAt: 1200, copyAt: 1500)
    let clockAfterTheSecondCopy = fixture.alpha.lastStandupAt

    #expect(throws: StandupUndoError.reportIsNoLongerUndoable) {
        try fixture.standupUndoService().undo(first, for: fixture.alpha)
    }

    // Asserting only the throw would pass against a service that wrote first
    // and refused afterwards. "The older window is history" is a statement
    // about the store, so the store is what gets asserted.
    #expect(fixture.alpha.lastStandupAt == clockAfterTheSecondCopy)
    // Hoisted out of the `#expect`, not for style: swift-testing decomposes the
    // expression into `$0.allSatisfy($1)`, and `allSatisfy` is `rethrows`, so a
    // `try` written inside the macro does not survive expansion.
    let reports = try fixture.reportsInStore()
    let events = try reportedRows(fixture)
    #expect(reports.allSatisfy { !$0.isUndone })
    #expect(events.allSatisfy { !$0.isRedacted })
}

@MainActor
@Test("FR-4.1: undo is not itself undoable")
func undoIsRefusedOnAnAlreadyUndoneReport() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    let service = fixture.standupUndoService()
    try service.undo(report, for: fixture.alpha)

    #expect(try service.undoableReport(for: fixture.alpha) == nil)
    #expect(throws: StandupUndoError.reportIsNoLongerUndoable) {
        try service.undo(report, for: fixture.alpha)
    }
}

@MainActor
@Test("D16: a report cannot be undone against another project")
func undoIsRefusedAcrossProjects() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    try reportableWork(fixture, in: fixture.beta)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.beta)

    #expect(throws: StandupUndoError.reportBelongsToAnotherProject) {
        try fixture.standupUndoService().undo(report, for: fixture.beta)
    }

    #expect(fixture.beta.lastStandupAt == ReportFixture.origin, "Beta's clock is untouched")
}

@MainActor
@Test("a failed save rolls back: the report, the events and the clock are all unchanged")
func aFailedUndoChangesNothing() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    let advancedClock = fixture.alpha.lastStandupAt
    let counter = WriteCounter()

    #expect(throws: Boom.self) {
        try fixture.standupUndoService(save: { _ in throw Boom() })
            .undo(report, for: fixture.alpha)
    }

    // **The load-bearing line.** Without a later successful save the assertions
    // below are unfalsifiable: an implementation that mutated the objects and
    // skipped the rollback would leave those mutations pending in the context,
    // invisible to a second context, and every assertion would pass. This save
    // is what would flush them.
    try fixture.context.save()

    let stored = try fixture.reportsInStore()
    let events = try reportedRows(fixture)
    #expect(stored.first?.isUndone == false)
    #expect(events.allSatisfy { !$0.isRedacted })
    #expect(try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt == advancedClock)
    #expect(counter.posts == 0, "nothing was written, so nothing announced a write")
}

@MainActor
@Test("D-019: a successful undo announces the write, so other surfaces reload")
func undoPostsTheWriteNotification() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    let counter = WriteCounter()

    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    #expect(counter.posts == 1)
}

@MainActor
@Test("undoableReport ignores other projects' reports")
func undoableReportIsScopedToItsProject() throws {
    let fixture = try ReportFixture()
    try reportableWork(fixture, in: fixture.alpha)
    try reportableWork(fixture, in: fixture.beta)
    let alphaReport = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)
    // Beta reports *later*, so a query that ignored `projectID` would return
    // Beta's row for Alpha — the failure an unscoped `fetchLimit = 1` produces.
    let betaReport = try copiedReport(
        fixture, in: fixture.beta, lastStandupAt: ReportFixture.origin,
        gatherAt: 1200, copyAt: 1500)
    let service = fixture.standupUndoService()

    #expect(try service.undoableReport(for: fixture.alpha)?.id == alphaReport.id)
    #expect(try service.undoableReport(for: fixture.beta)?.id == betaReport.id)
}

@MainActor
@Test("a project that has never reported has nothing to undo")
func aProjectWithNoReportsHasNothingToUndo() throws {
    let fixture = try ReportFixture()
    #expect(try fixture.standupUndoService().undoableReport(for: fixture.alpha) == nil)
}

@MainActor
@Test("§3.3: a redacted standupReported event leaves the task's timeline")
func redactedEventsLeaveTheTimeline() throws {
    let fixture = try ReportFixture()
    let task = try reportableWork(fixture, in: fixture.alpha)
    let report = try copiedReport(
        fixture, in: fixture.alpha, lastStandupAt: ReportFixture.origin,
        gatherAt: 300, copyAt: 900)

    let before = try fixture.context.fetch(EventQueries.timeline(forTaskID: task.id))
    #expect(
        before.contains { $0.kind == .standupReported },
        "precondition: the timeline shows it before the undo")

    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    let after = try fixture.context.fetch(EventQueries.timeline(forTaskID: task.id))
    #expect(!after.contains { $0.kind == .standupReported })
    #expect(
        after.contains { $0.kind == .note },
        "the user's own note is untouched — undo is scoped to stand-ups")
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL to build, with exactly two distinct errors — `cannot find 'StandupUndoService' in scope` (the fixture helper's body) and `cannot find type 'StandupUndoService' in scope` (its return type). `StandupUndoError` does **not** appear: the fixture fails first and the rest of the file is never typechecked.

- [ ] **Step 4: Write the service**

Create `StenoKit/Report/StandupUndoService.swift`:

```swift
import Foundation
import OSLog
import SwiftData

/// FR-4.1's undo: the one place a stand-up is taken back.
///
/// A sibling of `StandupService`, not a method on it. That type's `init`
/// carries a clipboard seam undo has no use for, its own doc comment declares
/// it "the one place the stand-up clock advances", and D-044 records that the
/// two guard on different things — `StandupService` on project identity, this
/// on report recency. `NoteService.redact` is not an option either: it guards
/// on `EventKind.isUserAuthored`, which is `false` for `standupReported`, so it
/// refuses exactly the events FR-4.1 must redact and refuses by returning
/// `false` rather than throwing (D-044, D-045).
///
/// **No `now`, and no clipboard.** Undo reads every timestamp it needs out of
/// the report being undone, so it has no clock to inject; and the markdown is
/// already in the user's paste buffer and may already be in Slack, so restoring
/// the previous clipboard contents is neither one of FR-4.1's three effects nor
/// something the store could verify.
@MainActor
public struct StandupUndoService {
    private let context: ModelContext
    /// Injected for `StandupService`'s reason: a real `ModelContext` cannot be
    /// made to fail its save on demand, and the rollback is the path that most
    /// needs a test.
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.save = save
    }

    /// The report `project` could undo right now, or `nil`.
    ///
    /// **One query answers both of FR-4.1's rules.** "Undo applies only to the
    /// most recent report" falls out of the sort and the limit — an older
    /// report is never the row returned. "And only while it is the most recent"
    /// falls out of that being evaluated here, at call time, rather than
    /// cached when the report was written. A report already undone yields
    /// `nil`, so undo is not itself undoable — matching `Event.redact()`, which
    /// is one-way by design and names this requirement as the reason there is
    /// no `unredact()`.
    ///
    /// **A `generatedAt` tie cannot be broken and does not need to be.**
    /// `SortDescriptor` has no secondary key available — `UUID` is not
    /// `Comparable`, the wall `EventQueries.timeline` documents for its own tie
    /// case — but two Copies stamped at the same instant are unreachable:
    /// `StandupDraftModel.canCopy` is `false` once `phase` leaves `.editing`,
    /// and a second report needs a second sheet.
    ///
    /// `throws` rather than returning `nil` on a failed fetch: this is the
    /// gate on whether an action is offered, and D-018's rule is that a failed
    /// read must never be presented as an empty store.
    public func undoableReport(for project: Project) throws -> StandupReport? {
        let projectID = project.id
        var descriptor = FetchDescriptor<StandupReport>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.flatMap { $0.isUndone ? nil : $0 }
    }

    /// Reverse all three of Copy's store effects, atomically. Returns how many
    /// events were redacted.
    ///
    /// Steps 3–5 are field writes into a single `ModelContext` committed by a
    /// single `save`, so "a failure partway must not leave the clock restored
    /// with the events still live" is a property of the transaction boundary
    /// rather than of careful ordering — `StandupService.commit`'s argument.
    /// It binds harder here: the compensating write for a redaction would be an
    /// `unredact()` that §3.3 does not permit to exist.
    ///
    /// **`report` is passed in rather than resolved from `project`.** Resolving
    /// it here would be one fewer parameter and would turn "undo is unavailable
    /// once a newer report exists" from a refusal the caller can see into a
    /// silent substitution of a *different* report — reversing a window the
    /// user never asked about. The explicit pair also mirrors
    /// `commit(_:of:for:)`, so the two halves of FR-4 step 7 read alike.
    @discardableResult
    public func undo(_ report: StandupReport, for project: Project) throws -> Int {
        // 1. The pair must describe the same project. `StandupService.commit`
        //    guards its own pair, and `NoteService.correct` before it: a
        //    mismatch would restore one project's clock out of another
        //    project's window, which is what D16 forbids.
        guard report.projectID == project.id else {
            throw StandupUndoError.reportBelongsToAnotherProject
        }

        // 2. Recency, through the same query the UI gates on, so a menu item
        //    that went stale between a reload and a click cannot undo a report
        //    that has since stopped being the most recent. One comparison
        //    covers both refusals — a newer report exists, or this one is
        //    already undone — because the query folds them together.
        guard try undoableReport(for: project)?.id == report.id else {
            throw StandupUndoError.reportIsNoLongerUndoable
        }

        let events = try standupReportedEvents(of: report)

        // 3. The report is retained and marked, never deleted (§3.5, FR-4.1).
        report.markUndone()

        // 4. Redaction, never deletion (§3.3). There are no exceptions to this
        //    anywhere in the system and this is the feature that looks most
        //    like one.
        for event in events { event.redact() }

        // 5. The clock goes back to where Copy found it. §3.5 defines
        //    `windowStart` as the previous `lastStandupAt`, so no separate
        //    "previous value" field is needed — and D-067's clamp is what makes
        //    this safe, because a report can never carry a `windowStart` later
        //    than its own `windowEnd`.
        //
        //    On a project's *first* report the pre-Copy value was `nil` and
        //    this restores a frozen "24h before Prepare ran" instead. That is
        //    the better of the two: restoring `nil` would make the next Prepare
        //    compute a *sliding* 24h window, silently losing everything between
        //    the original cutoff and the new one. A superset keeps FR-4.1's
        //    promise that undo loses nothing; a sliding window breaks it.
        project.lastStandupAt = report.windowStart

        // 6. One save for all of it. On failure the context returns to where it
        //    started and the caller is told nothing happened.
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }

        // 7. After the save, never before: an observer that reloads must not
        //    read a context whose write has not landed (D-019).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

        // A count, never event bodies — `ReportGatherer` logs dates and never
        // task content, for the same reason.
        Log.app.info("undid a stand-up, redacting \(events.count, privacy: .public) events")
        return events.count
    }

    /// The `standupReported` events this particular report appended.
    ///
    /// **The payload decides; the timestamp only narrows.** D-079 gave the
    /// events a `reportID` precisely so undo would not have to match on
    /// `timestamp == report.generatedAt` — which works today only because
    /// `StandupService` stamps both from one `now()`, a coincidence it is free
    /// to stop honouring, and whose loss would break undo silently. Neither
    /// `kind` nor `payload` is expressible in a `#Predicate`, so the fetch
    /// bounds and this filters.
    ///
    /// `windowEnd` rather than `generatedAt` as the bound, per D-066: the two
    /// are equal only by that same coincidence, and `windowEnd` is the earlier
    /// of them, so it stays correct if they ever diverge.
    private func standupReportedEvents(of report: StandupReport) throws -> [Event] {
        try context.fetch(EventQueries.notRedacted(atOrAfter: report.windowEnd))
            .filter {
                $0.kind == .standupReported
                    && StandupReportedPayload.decoded(from: $0.payload)?.reportID == report.id
            }
    }
}

/// Why an undo was refused before it wrote anything.
public enum StandupUndoError: Error, Equatable {
    /// The report and the project disagree — see `undo`'s first guard.
    case reportBelongsToAnotherProject

    /// A newer report exists for this project, or this one is already undone.
    /// FR-4.1: "once a newer report exists, the older window is history."
    case reportIsNoLongerUndoable
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — 14 tests, from `"FR-4.1: undo restores lastStandupAt from the report's windowStart"` through `"§3.3: a redacted standupReported event leaves the task's timeline"`.

- [ ] **Step 6: Verify the tests can actually fail**

Nine mutations, each applied to a green tree and each caught by the test it was aimed at:

| Mutation | Caught by |
|---|---|
| `event.redact()` → `context.delete(event)` | *undo redacts … and deletes nothing* (row count and row ids) |
| drop the `payload` clause from the filter | *undo redacts only the events of the report being undone* |
| filter on `$0.timestamp == report.generatedAt` instead of the payload | *the payload decides, not the timestamp* |
| `report.windowStart` → `report.windowEnd` | *undo restores lastStandupAt…*, and 5 more |
| delete the recency guard | *undo is refused once a newer report exists*, *undo is not itself undoable* |
| delete `report.markUndone()` | *the report row survives, marked undone*, and 3 more |
| replace the `do/catch` with a bare `try save(context)` | *a failed save rolls back…* |
| `undoableReport` returns `.first` without the `isUndone` check | *undo is not itself undoable* |
| drop the `projectID` predicate | *undoableReport ignores other projects' reports* |
| delete the `.stenoDidWrite` post | *a successful undo announces the write* |
| delete the project-pair guard | *a report cannot be undone against another project* |

Revert each mutation and re-run `make test` before applying the next. A leftover mutation contaminates every later row — an earlier run of this matrix reported eleven false "caught" results because one mutation was never reverted, and two tests then failed on every row for the wrong reason.

- [ ] **Step 7: Commit**

```bash
make format && git add StenoKit/Report/StandupUndoService.swift StenoTests/Report/ StenoTests/Report/ReportFixture.swift
git commit -m "feat: reverse a stand-up by redaction, never deletion — FR-4.1 (M2-04)"
```

---

## Task 3: The round-trip, which is what FR-4.1 actually promises

Task 2 proves each effect is reversed. This proves the thing the user cares about: after an undo, regenerating recovers the window the mistaken Copy took away.

**Files:**
- Test: `StenoTests/Report/StandupUndoRoundTripTests.swift`

**Interfaces:**
- Consumes: `StandupUndoService` (Task 2), `ReportGatherer`, `ReportWindow.firstRunLookback`.
- Produces: nothing. Tests only.

- [ ] **Step 1: Write the tests**

Create `StenoTests/Report/StandupUndoRoundTripTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4.1's real promise: after an undo, regenerating recovers the window the
/// mistaken Copy took away. The task file calls it "the round-trip loses
/// nothing".

@MainActor
@Test("FR-4.1: regenerating after undo reproduces the window exactly")
func regeneratingAfterUndoReproducesTheWindow() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: -1800)
    try fixture.setLastStandup(ReportFixture.origin.addingTimeInterval(-7200), on: fixture.alpha)

    let before = try fixture.gatherer(nowOffset: 0).gather(for: fixture.alpha)
    let report = try fixture.standupService(nowOffset: 300)
        .commit("the draft as copied", of: before, for: fixture.alpha)
        .report

    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    // Gathered at the same instant as the original, so the two windows are
    // comparable in full rather than only in their starts. `GatheredWindow` is
    // `Equatable` all the way down to each task's events, so this asserts the
    // bounds, the task set, the statuses and the event bodies at once — a
    // narrowing anywhere inside it fails here.
    let after = try fixture.gatherer(nowOffset: 0).gather(for: fixture.alpha)
    #expect(after == before)
}

@MainActor
@Test("FR-4.1: undoing a project's first report keeps the frozen 24h cutoff")
func undoingTheFirstReportKeepsTheFrozenCutoff() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    // Twenty hours back: inside the first-run window, and outside the window a
    // *sliding* cutoff would compute an hour later. This event is the whole
    // test — without it the two windows differ only in a `start` nobody reads.
    try fixture.event("started on the retry handler", on: task, at: -20 * 3600)

    #expect(fixture.alpha.lastStandupAt == nil, "precondition: never reported")
    let before = try fixture.gatherer(nowOffset: 0).gather(for: fixture.alpha)
    let report = try fixture.standupService(nowOffset: 300)
        .commit("the draft as copied", of: before, for: fixture.alpha)
        .report

    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    // Undo restored `windowStart` — a frozen "24h before Prepare ran" — rather
    // than the `nil` the field actually held before Copy. That is deliberate
    // and this is where it pays: an hour later, the restored cutoff still
    // reaches back to the same instant.
    #expect(fixture.alpha.lastStandupAt == before.start)

    let anHourLater = try fixture.gatherer(nowOffset: 3600).gather(for: fixture.alpha)
    #expect(anHourLater.start == before.start)

    // What restoring `nil` would have produced instead, stated as a value so
    // the difference is visible rather than argued: an hour of history gone,
    // taking the 20-hour-old note with it.
    let slidingCutoff = ReportFixture.origin.addingTimeInterval(
        3600 - ReportWindow.firstRunLookback)
    #expect(anHourLater.start < slidingCutoff)
    #expect(
        anHourLater.tasks.first?.events.contains { $0.body == "started on the retry handler" }
            == true,
        "the note a sliding cutoff would have dropped is still in the window")
}

@MainActor
@Test("D-066 and §3.3: an undone report's events feed no later summary")
func undoneReportEventsNeverReachALaterSummary() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
    let report = try fixture.standupService(nowOffset: 900)
        .commit("the draft as copied", of: window, for: fixture.alpha)
        .report
    try fixture.standupUndoService().undo(report, for: fixture.alpha)

    // The window now spans the redacted events: undo put the clock back to
    // `windowStart`, and the events were stamped at the Copy instant, so they
    // are squarely inside what the next gather looks at.
    let next = try fixture.gatherer(nowOffset: 1800).gather(for: fixture.alpha)
    #expect(next.start == window.start, "precondition: the clock went back")

    let kinds = next.tasks.flatMap { $0.events.map(\.kind) }
    #expect(!kinds.contains(.standupReported))
    #expect(kinds.contains(.note), "the user's own note survives the round trip")
}
```

- [ ] **Step 2: Run them**

Run: `make test`
Expected: PASS — three tests. They pass immediately against Task 2's service; that is the point of writing them separately, as an independent check on a service whose own tests were written alongside it.

- [ ] **Step 3: Verify they can fail**

Apply `project.lastStandupAt = report.windowEnd` in `StandupUndoService.undo` (Task 2's fourth mutation). Expected: all three of these fail, alongside three of Task 2's. Revert and re-run.

The first-report test is the one worth reading twice: it is the only place the difference between restoring `windowStart` and restoring `nil` is observable, and the 20-hour-old event is what makes it observable. Without that event the two windows differ only in a `start` that nothing reads.

- [ ] **Step 4: Commit**

```bash
make format && git add StenoTests/Report/StandupUndoRoundTripTests.swift
git commit -m "test: prove the undo round-trip loses nothing, first report included (M2-04)"
```

---

## Task 4: `StandupDraftModel` — a third phase

The sheet's state machine learns that a committed report can be taken back.

> **This task also touches one app-target file, and must.** Adding a case to
> `StandupDraftPhase` makes *both* of `StandupDraftSheet`'s switches over it —
> `headline` and `buttons` — non-exhaustive the instant it lands. Leaving them to
> Task 6 makes this commit fail `make build`, which only executing the plan
> revealed. Rendering the new phase belongs here; the button that reaches it
> belongs in Task 6.

**Files:**
- Modify: `StenoKit/Features/MainWindow/StandupDraftModel.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift` (the `init` wiring only)
- Modify: `Steno/Features/MainWindow/StandupDraftSheet.swift` (keep the switches exhaustive)
- Test: `StenoTests/Features/MainWindow/StandupDraftModelTests.swift`

**Interfaces:**
- Consumes: `StandupUndoService` (Task 2).
- Produces: `StandupDraftPhase.undone`; `StandupDraftModel.init(service:undoService:)`, `committedReport`, `canUndo`, `@discardableResult undo(to: Project) -> Bool`. Tasks 5 and 6 consume them.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Features/MainWindow/StandupDraftModelTests.swift`:

```swift
@MainActor
@Test("FR-4.1: undo moves the sheet to its third phase and closes Copy off")
func undoMovesTheSheetToUndone() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    #expect(model.canUndo == false, "nothing has been copied yet")

    #expect(model.commit(to: fixture.alpha))
    #expect(model.canUndo, "the sheet's Undo button is live the moment Copy lands")
    #expect(model.committedReport != nil)

    #expect(model.undo(to: fixture.alpha))

    #expect(model.phase == .undone)
    #expect(model.canUndo == false, "undo is not itself undoable")
    #expect(model.canCopy == false, "this window has already been reported once")
    #expect(model.lastError == nil)
    #expect(try fixture.reportsInStore().first?.isUndone == true)
}

@MainActor
@Test("a refused clipboard's notice does not outlive the report it described")
func undoClearsTheClipboardNotice() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture, copy: { _ in false })

    #expect(model.commit(to: fixture.alpha))
    #expect(model.notice != nil, "precondition: the clipboard refused the write")

    #expect(model.undo(to: fixture.alpha))

    // Left standing, the notice would tell the user to select and copy the text
    // manually — for a stand-up the app has just taken back.
    #expect(model.notice == nil)
    #expect(model.phase == .undone)
}

@MainActor
@Test("undoing before anything was copied does nothing")
func undoBeforeCopyIsANoOp() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)

    #expect(model.undo(to: fixture.alpha) == false)
    #expect(model.phase == .editing)
    #expect(try fixture.reportsInStore().isEmpty)
}

@MainActor
@Test("a failed undo keeps the sheet where it was, so pressing it again is safe")
func aFailedUndoKeepsTheCopiedPhase() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    // Succeeds for the Copy, then refuses the undo — the model holds its
    // services for life, so the only way to fail the second write and not the
    // first is for the injected save to change its mind.
    nonisolated(unsafe) var shouldFail = false
    let (model, _) = try draftReadyToCopy(
        fixture,
        save: { context in
            if shouldFail { throw Boom() }
            try context.save()
        })

    #expect(model.commit(to: fixture.alpha))
    shouldFail = true

    #expect(model.undo(to: fixture.alpha), "a rollback still asks the window to refetch (D-051)")

    #expect(model.phase == .copied, "still undoable — the store rolled back")
    #expect(model.canUndo)
    #expect(model.lastError != nil)
    #expect(try fixture.reportsInStore().first?.isUndone == false)
}

@MainActor
@Test("beginning a new draft forgets the report the last one committed")
func beginClearsTheCommittedReport() throws {
    let fixture = try ReportFixture()
    let (model, window) = try draftReadyToCopy(fixture)
    #expect(model.commit(to: fixture.alpha))
    #expect(model.committedReport != nil, "precondition")

    model.begin(window: window, text: "a fresh draft")

    // Otherwise ⌘R over a committed sheet would leave Undo pointing at the
    // previous report while the text on screen belongs to a new one.
    #expect(model.committedReport == nil)
    #expect(model.canUndo == false)
    #expect(model.phase == .editing)
}

@MainActor
@Test("dismissing forgets the report too")
func dismissClearsTheCommittedReport() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    #expect(model.commit(to: fixture.alpha))

    model.dismiss()

    #expect(model.committedReport == nil)
    #expect(model.canUndo == false)
}
```

- [ ] **Step 2: Update the three existing `StandupDraftModel(...)` call sites in that file**

The `init` gains a parameter in Step 4, so every existing construction breaks. In `draftReadyToCopy`:

```swift
    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900, save: save, copy: copy),
        undoService: fixture.standupUndoService(save: save))
```

In `commitWithoutAWindowIsANoOp`:

```swift
    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900),
        undoService: fixture.standupUndoService())
```

In `successfulRetryClearsTheError`, hoist the flaky save into a `let` so both services share one mind:

```swift
    let flakySave: (ModelContext) throws -> Void = { context in
        if shouldFail { throw Boom() }
        try context.save()
    }
    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900, save: flakySave),
        undoService: fixture.standupUndoService(save: flakySave))
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL to build with six distinct errors:

```
extra argument 'undoService' in call
type 'StandupDraftPhase' has no member 'undone'
value of type 'StandupDraftModel' has no member 'undo'
value of type 'StandupDraftModel' has no member 'canUndo'
value of type 'StandupDraftModel' has no member 'committedReport'
cannot infer contextual base in reference to member 'copied'
```

Note **`extra` argument, not `missing`** — Step 2 added the argument before Step 4 adds the parameter, so the call sites are ahead of the initialiser, not behind it. The last error is collateral: once the initialiser call fails, `model` has no type and every `.copied` in the file loses its context.

- [ ] **Step 4: Add the third phase**

In `StenoKit/Features/MainWindow/StandupDraftModel.swift`, replace the phase enum:

```swift
public enum StandupDraftPhase: Equatable, Sendable {
    /// Step 6: the editable draft, nothing written yet.
    case editing
    /// Step 7 has run. The store is committed; the sheet stays up.
    case copied
    /// FR-4.1 has run against the report step 7 wrote. The store is back where
    /// Copy found it, and there is nothing left to do but close.
    case undone
}
```

Replace the stored-property block and `init` (the `service` property through `canCopy`):

```swift
    /// The row Copy wrote, which FR-4.1's undo acts on.
    ///
    /// M2-03 discarded this value: `commit(to:)` read `didReachClipboard` off
    /// the result and dropped the report. Undo is what needs it — the sheet
    /// undoes *the report it just wrote*, not "whatever is most recent", so
    /// that identity has to survive the commit rather than be re-derived.
    public private(set) var committedReport: StandupReport?

    private let service: StandupService
    private let undoService: StandupUndoService

    public init(service: StandupService, undoService: StandupUndoService) {
        self.service = service
        self.undoService = undoService
    }

    /// Copy is live only with a window to commit, and only once.
    public var canCopy: Bool { window != nil && phase == .editing }

    /// Undo is live only over a report this sheet actually wrote, and only
    /// before it has been undone.
    ///
    /// Reads `committedReport` as well as `phase` rather than `phase` alone:
    /// the two are set together, but a `.copied` phase with no report is a
    /// state `undo(to:)` would have to refuse anyway, and a button that is live
    /// only to refuse is worse than one that is not offered.
    public var canUndo: Bool { committedReport != nil && phase == .copied }
```

Add `committedReport = nil` to **both** `begin(window:text:)` and `dismiss()`, after the `phase = .editing` line in each. Otherwise ⌘R over a committed sheet leaves Undo pointing at the previous report.

In `commit(to:)`'s success branch, capture the report:

```swift
            let result = try service.commit(draft, of: window, for: project)
            phase = .copied
            committedReport = result.report
            lastError = nil
```

Append the undo method as the last member of the type, before its closing brace:

```swift
    /// FR-4.1, from the sheet's Undo button. Never throws, for `commit(to:)`'s
    /// reason — a sheet has nowhere to propagate to.
    ///
    /// Returns whether the window must refetch, on the same contract:
    /// `false` only when nothing was attempted, and **`true` after a failure**,
    /// because what a rolled-back write leaves in the objects this window still
    /// holds is not dependable (D-051).
    ///
    /// **The clipboard is deliberately untouched.** The markdown is already in
    /// the user's paste buffer and may already be in Slack; §7 of this task's
    /// design records why putting it back is neither possible to verify nor one
    /// of the three effects FR-4.1 names.
    @discardableResult
    public func undo(to project: Project) -> Bool {
        guard let committedReport, phase == .copied else { return false }

        do {
            try undoService.undo(committedReport, for: project)
            phase = .undone
            lastError = nil
            // Cleared, not kept: it said the clipboard refused a report that no
            // longer exists, so leaving it up would have the sheet advising the
            // user to copy text for a stand-up it has just taken back.
            notice = nil
        } catch {
            Log.app.error(
                "could not undo the stand-up: \(String(describing: error), privacy: .public)")
            // Stays `.copied` with `committedReport` intact: the store rolled
            // back, so pressing Undo again is safe and is the obvious next move.
            lastError = "Could not undo your stand-up. Nothing was changed — try again."
        }
        return true
    }
```

- [ ] **Step 5: Wire the new dependency in `MainWindowModel.init`**

In `StenoKit/Features/MainWindow/MainWindowModel.swift`:

```swift
        self.standupDraft = StandupDraftModel(
            service: StandupService(context: context, now: now, save: save, copy: copy),
            undoService: StandupUndoService(context: context, save: save))
```

- [ ] **Step 6: Keep the sheet's switches exhaustive**

`make build` fails here with `switch must be exhaustive` — twice — until this is done.

In `Steno/Features/MainWindow/StandupDraftSheet.swift`, replace `headline`:

```swift
    /// The sheet's headline for each reachable state.
    ///
    /// **Four cases, not two.** A refused clipboard still moves `phase` to
    /// `.copied` — the report is committed and the clock has advanced — so
    /// keying the headline on `phase` alone would announce "Copied to
    /// clipboard" directly above the notice saying the clipboard refused it.
    /// The report being *recorded* and the text reaching the *clipboard* are
    /// two different facts, and `.copied` is the one state where they disagree.
    /// `notice` is non-nil exactly then, so it is the discriminator rather than
    /// a second stored flag.
    ///
    /// `.undone` is its own line rather than a return to "Prepare Stand-up".
    /// The store has changed twice and is back where it started, and a headline
    /// that reverted would leave the user unable to tell a successful undo from
    /// a button that did nothing.
    private var headline: String {
        switch draft.phase {
        case .editing:
            "Prepare Stand-up"
        case .copied:
            draft.notice == nil ? "Copied to clipboard" : "Recorded — not copied"
        case .undone:
            "Stand-up undone"
        }
    }
```

And add a `.undone` arm to `buttons`, immediately after the existing `case .copied:`
arm and before the `switch`'s closing brace. Leave `.copied` alone — its Undo button
needs a closure Task 6 supplies:

```swift
            case .undone:
                // One button. Undo is not itself undoable — `Event.redact()` is
                // one-way by design and names this requirement as the reason
                // there is no `unredact()` — and Copy stays dead because the
                // draft's window has already been reported once.
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `make build && make test`
Expected: build succeeds; PASS — six new tests, and the three pre-existing draft tests still green (395 total).

- [ ] **Step 8: Commit**

```bash
make format && git add StenoKit/Features/MainWindow/StandupDraftModel.swift StenoKit/Features/MainWindow/MainWindowModel.swift Steno/Features/MainWindow/StandupDraftSheet.swift StenoTests/Features/MainWindow/StandupDraftModelTests.swift
git commit -m "feat: give the draft sheet an undone phase (M2-04)"
```

---

## Task 5: The menu path, which outlives the sheet

FR-4.1 exists because users misclick, and the realistic misclick is noticed *after* the sheet is closed. This is the surface that covers it.

**Files:**
- Modify: `StenoKit/Features/MainWindow/MainWindowActions.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift`
- Test: `StenoTests/Features/MainWindow/MainWindowModelStandupTests.swift`

**Interfaces:**
- Consumes: `StandupUndoService` (Task 2), `StandupDraftModel.undo(to:)` (Task 4).
- Produces: `MainWindowActions.canUndoStandup` / `.undoLastStandup()`; `MainWindowModel.undoableStandupReport`, `.undoStandupDraft()`. Task 6 consumes all four.

> **`MainWindowModel.swift` is 397 lines after this task and SwiftLint warns at 400 under `--strict`.** The property below is deliberately terse for that reason. Do not expand its doc comment; if you need more room, the file's own comment says the `+Standup` split exists precisely to make room, and stored properties cannot live in an extension — so trim prose here rather than adding lines.

- [ ] **Step 1: Extend the actions protocol**

In `StenoKit/Features/MainWindow/MainWindowActions.swift`, after `canPrepareStandup`:

```swift
    /// FR-4.1 undoes the selected project's most recent report, and only while
    /// it stays the most recent — so the menu gates on this rather than
    /// offering an action that would be refused.
    var canUndoStandup: Bool { get }
```

And after `prepareStandup()`:

```swift
    /// FR-4.1: reverse the selected project's most recent Copy, by redaction.
    /// The sheet has its own button; this is the path that outlives it.
    func undoLastStandup()
```

- [ ] **Step 2: Add the cached report to `MainWindowModel`**

After the `standupDraft` property:

```swift
    /// The report the selected project could undo right now (FR-4.1), or `nil`.
    ///
    /// **Cached rather than fetched on demand**, because `canUndoStandup` is
    /// read from `MainWindowCommands.body`: a fetch behind it would be a store
    /// read on SwiftUI's render path, the hazard `selectedTaskEvents` documents
    /// above, arriving through a menu instead of a pane. `internal(set)` for
    /// `lastError`'s reason — `MainWindowModel+Standup.swift` refreshes it.
    public internal(set) var undoableStandupReport: StandupReport?
```

And at the end of `reload()`, after `reloadSelectedTaskEvents()`:

```swift
        // After `projects`, which `selectedProject` resolves through. FR-4.1's
        // eligibility is "is this *still* the most recent report", which only a
        // fresh read answers — so it refreshes with everything else.
        refreshUndoableStandupReport()
```

- [ ] **Step 3: Write the failing tests**

Append to `StenoTests/Features/MainWindow/MainWindowModelStandupTests.swift`:

```swift
@MainActor
@Test("FR-4.1: the menu offers undo only after a Copy, and only with the sheet closed")
func undoMenuItemGating() throws {
    let (model, _) = try modelWithReportableWork()

    #expect(model.canUndoStandup == false, "nothing has been reported yet")

    model.prepareStandup()
    model.copyStandup()
    #expect(
        model.canUndoStandup == false,
        "while the sheet is up it owns undo — its own button, and its own .undone phase")

    model.dismissStandupDraft()
    #expect(model.canUndoStandup, "and after Close the menu takes over")

    model.selection = .all
    #expect(model.canUndoStandup == false, "D16: the All pseudo-project has no clock to restore")
}

@MainActor
@Test("FR-4.1: the menu path restores the clock and the DONE window with it")
func undoFromTheMenuRestoresTheClock() throws {
    // The same task `copyMovesTheDoneWindow` uses: finished 12 hours ago, so it
    // is inside the first-run 24h window and outside the window Copy leaves.
    let (model, project) = try modelWithReportableWork()
    let finished = TaskItem(
        title: "finished earlier", projectID: project.id,
        createdAt: origin.addingTimeInterval(-13 * 3600))
    model.context.insert(finished)
    finished.setStatus(.done, at: origin.addingTimeInterval(-12 * 3600))
    try model.context.save()
    model.reload()

    model.prepareStandup()
    let restoredCutoff = model.standupDraft.window?.start
    model.copyStandup()
    model.dismissStandupDraft()
    #expect(!model.groups.contains { $0.status == .done }, "precondition: Copy moved the cutoff")

    model.undoLastStandup()

    #expect(project.lastStandupAt == restoredCutoff)
    // The reload is load-bearing beyond the timeline: moving `lastStandupAt`
    // *backwards* moves FR-3's DONE cutoff back too, so the completion the
    // mistaken Copy scrolled out of view has to come back with it.
    #expect(model.groups.contains { $0.status == .done })
    #expect(model.canUndoStandup == false, "and there is nothing left to undo")
    #expect(model.lastError == nil)
}

@MainActor
@Test("FR-4.1: the sheet's Undo button reverses the Copy it just made")
func undoFromTheSheet() throws {
    let (model, project) = try modelWithReportableWork()
    model.prepareStandup()
    let windowStart = model.standupDraft.window?.start
    model.copyStandup()

    model.undoStandupDraft()

    #expect(model.standupDraft.phase == .undone)
    #expect(project.lastStandupAt == windowStart)
    #expect(model.activeSheet == .standupDraft, "the sheet stays up to confirm what happened")
}
```

- [ ] **Step 4: Run them to verify they fail**

Run: `make test`
Expected: FAIL to build with exactly two errors:

```
cannot find 'refreshUndoableStandupReport' in scope
type 'MainWindowModel' does not conform to protocol 'MainWindowActions'
```

Both are in **StenoKit**, which fails before the test bundle is compiled — so the missing-member errors you might expect from the new tests never appear. Do not treat their absence as the tests being wrong.

- [ ] **Step 5: Write the sheet's undo path**

In `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift`, before `dismissStandupDraft()`:

```swift
    /// FR-4.1 from the sheet's Undo button.
    ///
    /// **The project comes from the draft's own window, not from `selection`,**
    /// for `copyStandup()`'s reason: the window was frozen when the user
    /// pressed Prepare while `selection` stays live, and "Next Project" (⌘⌥↓)
    /// is reachable from the menu with this sheet up.
    ///
    /// A sibling of `undoLastStandup()` rather than a call into it. This one
    /// undoes *the report this sheet wrote* and moves the sheet to `.undone`;
    /// that one undoes whatever the selected project's most recent report is,
    /// with no sheet in play. They agree in every reachable state — the sheet's
    /// report is the most recent while the sheet is up — and it is the identity
    /// they are keyed on, not the outcome, that differs.
    public func undoStandupDraft() {
        guard let projectID = standupDraft.window?.projectID,
            let project = project(withID: projectID)
        else { return }
        if standupDraft.undo(to: project) { reload() }
    }
```

- [ ] **Step 6: Write the menu's undo path**

As the last members of the same extension, before its closing brace:

```swift
    // MARK: - FR-4.1, undo

    /// Whether "Undo Last Stand-up" is live.
    ///
    /// **`activeSheet == nil`, so the sheet owns undo while it is up.** The
    /// sheet has its own Undo button and its own `.undone` phase; a menu path
    /// firing behind it would leave that phase reading `.copied` over a report
    /// that has just been taken back, and the sheet would still be offering to
    /// undo it. Gating rather than reconciling two paths is what
    /// `canPrepareStandup` does for the same collision.
    ///
    /// Reads the cached report rather than asking the store, for the reason
    /// `MainWindowModel.undoableStandupReport` gives: the menu evaluates this
    /// during a SwiftUI update pass.
    public var canUndoStandup: Bool { undoableStandupReport != nil && activeSheet == nil }

    /// FR-4.1 from the menu — the path that outlives the sheet.
    ///
    /// The sheet's button covers the misclick noticed immediately; this covers
    /// the one noticed after Close, which is the case FR-4.1's "users will
    /// misclick, and an unrecoverable window advance destroys a day of recall"
    /// is actually about.
    ///
    /// **The project comes from the report, not from `selection`.** Same
    /// hazard `copyStandup()` documents: the cached report was resolved during
    /// a reload, while `selection` stays live and "Next Project" (⌘⌥↓) can move
    /// it between the two. Reading `selection` here would hand one project's
    /// report to another project's row, which the service refuses.
    public func undoLastStandup() {
        guard canUndoStandup, let report = undoableStandupReport,
            let project = project(withID: report.projectID)
        else { return }

        do {
            try undoService().undo(report, for: project)
        } catch {
            Log.app.error(
                "could not undo the stand-up: \(String(describing: error), privacy: .public)")
            lastError = "Could not undo your last stand-up. Nothing was changed."
        }
        // On every outcome, including the failure: a rollback keeps the refused
        // write off disk, but what it leaves in the objects this window still
        // holds is not dependable (D-051). Refetching is the only state worth
        // trusting — and on success the reload is load-bearing beyond the
        // timeline, because moving `lastStandupAt` *backwards* moves FR-3's
        // DONE cutoff for this project just as advancing it did.
        reload()
    }

    /// Re-answer "can the selected project undo something?" from the store.
    ///
    /// Called from `reload()`. A failure is surfaced rather than swallowed —
    /// D-018's rule is that a failed read must not be presented as an empty
    /// store, and here the silent version is a menu item that is simply grey
    /// with no reason given.
    func refreshUndoableStandupReport() {
        guard let project = selectedProject else {
            undoableStandupReport = nil
            return
        }
        do {
            undoableStandupReport = try undoService().undoableReport(for: project)
        } catch {
            Log.app.error(
                "undoable stand-up check failed: \(String(describing: error), privacy: .public)")
            lastError = "Could not check whether your last stand-up can be undone."
            undoableStandupReport = nil
        }
    }

    /// Built per call rather than stored, matching `captureService()` and the
    /// `StatusService` in `MainWindowModel+Status`: it holds no state between
    /// calls, so a stored instance would be a second thing to keep in step with
    /// `context` and `save`.
    private func undoService() -> StandupUndoService {
        StandupUndoService(context: context, save: save)
    }
```

Note the log line is a single string literal. Splitting it across a `+` does not compile — `Logger`'s `OSLogMessage` is not a `RangeReplaceableCollection`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — three new tests, and `make lint` reports 0 violations (check the line count of `MainWindowModel.swift` if it does not).

- [ ] **Step 8: Verify the gating test can fail**

Drop `&& activeSheet == nil` from `canUndoStandup`. Expected: CAUGHT by *"the menu offers undo only after a Copy, and only with the sheet closed"* and nothing else. Revert and re-run.

- [ ] **Step 9: Commit**

```bash
make format && git add StenoKit/Features/MainWindow/ StenoTests/Features/MainWindow/MainWindowModelStandupTests.swift
git commit -m "feat: offer Undo Last Stand-up from the window, not only the sheet (M2-04)"
```

---

## Task 6: The two buttons

App-target layout only. No tests — this is the part an agent cannot verify on this machine (TCC blocks both `osascript` and `screencapture`), so it ends with a checklist for the user rather than a claim.

**Files:**
- Modify: `Steno/Features/MainWindow/StandupDraftSheet.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift`
- Modify: `Steno/App/MainWindowCommands.swift`

**Interfaces:**
- Consumes: everything Tasks 4 and 5 produced.
- Produces: nothing.

- [ ] **Step 1: Give the sheet an `onUndo` closure**

In `StandupDraftSheet`'s stored properties, between `onCopy` and `onClose`:

```swift
    let onUndo: () -> Void
```

- [ ] **Step 2: Add the Undo button**

`headline` and the `.undone` arm already landed in Task 4, because the switches had
to stay exhaustive the moment the enum gained a case. All that is left is the button.

In `buttons`, replace the `case .copied:` arm — leave `.undone` exactly as it is:

```swift
            case .copied:
                // FR-4.1 requires undo to be "easy to find right after a Copy"
                // and not to require hunting through settings. This is that
                // place — D-080 kept the sheet open after Copy precisely so
                // this button would have somewhere to live.
                Button("Undo", action: onUndo)
                    .disabled(!draft.canUndo)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            case .undone:
                // One button. Undo is not itself undoable — `Event.redact()` is
                // one-way by design and names this requirement as the reason
                // there is no `unredact()` — and Copy stays dead because the
                // draft's window has already been reported once.
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
```

- [ ] **Step 3: Pass the closure from the window**

In `Steno/Features/MainWindow/MainWindowView.swift`:

```swift
            case .standupDraft:
                StandupDraftSheet(
                    draft: model.standupDraft,
                    onCopy: { model.copyStandup() },
                    onUndo: { model.undoStandupDraft() },
                    onClose: { model.dismissStandupDraft() })
```

- [ ] **Step 4: Add the menu item**

In `Steno/App/MainWindowCommands.swift`, after the Prepare Stand-up button and inside the same `CommandMenu("Task")`:

```swift
            // FR-4.1's safety net, reachable after the sheet is closed — which
            // is when the misclick it exists for is actually noticed.
            //
            // **No key equivalent, deliberately.** ⌘Z is the system's
            // text-editing undo, and this window puts `TextEditor`s inside the
            // very sheet that produces the report; binding a store transaction
            // to it would make the two indistinguishable at the moment the user
            // most wants them apart. FR-3 asks for shortcuts on the primary
            // actions, and this is a recovery action.
            Button("Undo Last Stand-up") { actions?.undoLastStandup() }
                .disabled(actions?.canUndoStandup != true)
```

- [ ] **Step 5: Verify what can be verified**

Run: `make build && make test && make lint`
Expected: build succeeds, **398** tests pass, 0 lint violations.

**What this cannot verify, and must be said plainly in the PR body:** nobody has clicked either control. The pixels are the gap. Hand the user this checklist rather than a claim:

1. Select a project, ⌘R, Copy → the sheet shows "Copied to clipboard" with **Undo** and **Close**.
2. Press Undo → the headline becomes "Stand-up undone", Undo disappears, only Close remains.
3. Close, then open the `Task` menu → "Undo Last Stand-up" is **greyed** (it was just undone).
4. ⌘R, Copy, Close, then the `Task` menu → "Undo Last Stand-up" is **live**. Choose it; any DONE task that scrolled out of the list on Copy comes back.
5. Select "All" in the sidebar → the item is greyed again.

- [ ] **Step 6: Commit**

```bash
make format && git add Steno/
git commit -m "feat: surface Undo in the draft sheet and the Task menu — FR-4.1 (M2-04)"
```

---

## Task 7: Decisions, tick debt, and the PR

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/tasks/README.md`

- [ ] **Step 1: Add D-084 … D-089 to `docs/DECISIONS.md`**

One entry per decision the design argues, following the house format (`### D-0NN — <claim>`, date · task · status, the reasoning, then **Alternatives:**):

- **D-084 — Undo is its own service, not a method on `StandupService`.** That type's `init` carries a clipboard seam undo never reaches, its doc comment declares it "the one place the stand-up clock advances", and D-044 records that the two guard on different things — project identity versus report recency.
- **D-085 — The `reportID` payload discriminates; the timestamp only narrows the fetch.** Neither `kind` nor `payload` is expressible in a `#Predicate`, so `EventQueries.notRedacted(atOrAfter:)` bounds the fetch at the report's `windowEnd` (D-066) and the payload decides. Cite the test that makes this falsifiable — a `standupReported` row carrying the right `reportID` and a *different* timestamp is still redacted.
- **D-086 — One query answers both of FR-4.1's eligibility rules.** Most recent by `generatedAt`, `fetchLimit = 1`, returned only when `!isUndone` — so "only the most recent", "only while it is the most recent", and "undo is not itself undoable" are one fact, not three guards.
- **D-087 — Undoing a project's first report restores `windowStart`, not `nil`.** `StandupReport` records no "was this the first" flag, and restoring `nil` would make the next Prepare compute a *sliding* 24h window that silently loses history. A frozen cutoff is a superset; a sliding one breaks FR-4.1's promise.
- **D-088 — Undo takes the report explicitly rather than resolving it.** Otherwise "unavailable once a newer report exists" becomes a silent substitution of a different report instead of a refusal the caller can observe.
- **D-089 — Undo has no keyboard shortcut.** ⌘Z is the system's text-editing undo and this window puts `TextEditor`s inside the very sheet that produces the report. FR-3 asks for shortcuts on primary actions; this is a recovery action.

- [ ] **Step 2: Clear the tick debt (CLAUDE.md step 4)**

In `docs/tasks/README.md`:
- Tick **M2-04** and add `— PR #nn`.
- **M2-03's row is unticked** despite merging as PR #26. Tick it and add `— PR #26`.
- M1-08, M2-01 and M2-02 are ticked but missing the `— PR #nn` suffix the M1-04/06/07 rows carry. Add `— PR #20`, `— PR #22`, `— PR #23`.

- [ ] **Step 3: Final verification**

Run: `make format && make build && make test && make lint`
Expected: clean tree after format, build succeeds, **398** tests pass, 0 violations.

- [ ] **Step 4: Open the PR and stop**

The PR body must carry, per §9.5:
- What was verified (`make build && make test && make lint`, the mutation matrix, 398 tests).
- **What was not:** nobody clicked either control. Include Task 6's five-step checklist.
- The known gap this task does **not** close: **O-8** (`M2.5-02`). §10.1 merges `lastStandupAt` by "take the later timestamp", so exporting a project whose report was undone and importing it onto a machine holding the pre-undo value resurrects the advanced clock. The undo is correct locally; the interchange rule that would keep it correct across machines does not exist yet, and inventing half of it here would pre-empt M2.5-02.
- No `REQUIREMENTS.md` amendment. FR-4.1 was implementable exactly as written.

**Do not merge.**
