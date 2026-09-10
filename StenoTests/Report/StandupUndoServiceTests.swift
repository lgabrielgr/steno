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
