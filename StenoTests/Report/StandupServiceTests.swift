import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 step 7: Copy's four effects, all of them or none of them.

/// A string the renderer would never produce, so an assertion that
/// `markdownBody` equals it cannot pass against an implementation that
/// re-renders the window instead of storing the user's text.
private let editedDraft = "the user rewrote every word of this by hand"

@MainActor
private func windowWithOneTask(_ fixture: ReportFixture) throws -> GatheredWindow {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    return try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
}

@MainActor
@Test("Copy persists the report carrying the edited text, not the generated text")
func copyPersistsTheEditedText() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    let reports = try fixture.reportsInStore()
    #expect(reports.count == 1)
    #expect(reports.first?.markdownBody == editedDraft)
    #expect(reports.first?.wasAIGenerated == false)
    #expect(reports.first?.isUndone == false)
    #expect(reports.first?.projectID == fixture.alpha.id)
}

@MainActor
@Test("Copy appends one standupReported event per task in the window")
func copyAppendsAnEventPerTask() throws {
    let fixture = try ReportFixture()
    let first = try fixture.task("one", in: fixture.alpha, status: .inProgress)
    let second = try fixture.task("two", in: fixture.alpha, status: .blocked)
    try fixture.event("a note", on: first, at: 60)
    try fixture.event("another", on: second, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
    #expect(window.tasks.count == 2, "precondition: both tasks are in the window")

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    let reported = try fixture.eventsInStore(kind: .standupReported)
    #expect(Set(reported.map(\.taskID)) == Set([first.id, second.id]))
    #expect(reported.allSatisfy { $0.body == "Reported to standup" })
}

@MainActor
@Test("the clock advances to the window's end, not to the moment of the Copy")
func copyAdvancesTheClockToTheWindowEnd() throws {
    let fixture = try ReportFixture()
    // Gathered at origin+300; copied ten minutes later, at origin+900.
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // D-076. `lastStandupAt` must be the generate instant, so anything captured
    // between generating and copying falls into the next window rather than
    // into a gap no report will ever cover.
    let stored = try fixture.reloadThroughASecondContext(fixture.alpha)
    #expect(stored?.lastStandupAt == ReportFixture.origin.addingTimeInterval(300))
    #expect(stored?.lastStandupAt == window.end)
}

@MainActor
@Test("the report's window bounds match the window that was copied")
func reportRecordsTheWindowItCopied() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // M2-04 recovers the previous `lastStandupAt` from `windowStart`, so these
    // two are the undo mechanism, not decoration.
    let report = try #require(try fixture.reportsInStore().first)
    #expect(report.windowStart == window.start)
    #expect(report.windowEnd == window.end)
    #expect(report.generatedAt == ReportFixture.origin.addingTimeInterval(900))
}

@MainActor
@Test("a failed save leaves the store exactly as it was")
func failedSaveWritesNothing() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    let counter = WriteCounter()

    #expect(throws: Boom.self) {
        _ = try fixture.standupService(nowOffset: 900, save: { _ in throw Boom() })
            .commit(editedDraft, of: window, for: fixture.alpha)
    }

    // Read through independent contexts: the context that attempted the write
    // still holds the inserted objects, so asserting against it would pass even
    // if the rollback had done nothing.
    #expect(try fixture.reportsInStore().isEmpty)
    #expect(try fixture.eventsInStore(kind: .standupReported).isEmpty)
    #expect(
        try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt
            == ReportFixture.origin)
    #expect(counter.posts == 0, "a write that did not happen must not be announced")
}

@MainActor
@Test("a failed Copy does not ride along on the next successful save")
func failedCopyDoesNotLeakIntoALaterSave() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    #expect(throws: Boom.self) {
        _ = try fixture.standupService(nowOffset: 900, save: { _ in throw Boom() })
            .commit(editedDraft, of: window, for: fixture.alpha)
    }

    // This is what `context.rollback()` is actually for, and the only assertion
    // that can tell whether it ran. With an injected throwing `save` nothing
    // reaches the store either way, so asserting on the store immediately after
    // the failure passes whether or not the abandoned rows were discarded.
    // They are still sitting in the context; the *next* commit is what would
    // flush them to disk.
    try fixture.context.save()

    #expect(try fixture.reportsInStore().isEmpty)
    #expect(try fixture.eventsInStore(kind: .standupReported).isEmpty)
    #expect(
        try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt
            == ReportFixture.origin)
}

@MainActor
@Test("a refused clipboard leaves the store committed and says so")
func refusedClipboardStillCommits() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    let result = try fixture.standupService(nowOffset: 900, copy: { _ in false })
        .commit(editedDraft, of: window, for: fixture.alpha)

    // Not reversible: the compensation for an appended Event is a delete, which
    // §3.3 forbids. So it is reported, and M2-04's undo is the recovery.
    #expect(result.didReachClipboard == false)
    #expect(try fixture.reportsInStore().count == 1)
    #expect(try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt == window.end)
}

@MainActor
@Test("the copied text is what reaches the clipboard")
func theEditedTextReachesTheClipboard() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    nonisolated(unsafe) var copied: String?

    let result = try fixture.standupService(
        nowOffset: 900,
        copy: {
            copied = $0
            return true
        }
    )
    .commit(editedDraft, of: window, for: fixture.alpha)

    #expect(copied == editedDraft)
    #expect(result.didReachClipboard)
}

@MainActor
@Test("D16 — copying for one project does not touch another")
func copyingOneProjectLeavesTheOtherAlone() throws {
    let fixture = try ReportFixture()
    let outsider = try fixture.task("beta's work", in: fixture.beta, status: .inProgress)
    try fixture.event("beta note", on: outsider, at: 60)
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    #expect(try fixture.reloadThroughASecondContext(fixture.beta)?.lastStandupAt == nil)
    let reported = try fixture.eventsInStore(kind: .standupReported)
    #expect(!reported.contains { $0.taskID == outsider.id })
}

@MainActor
@Test("a window belonging to another project is refused before anything is written")
func mismatchedWindowIsRefused() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    let counter = WriteCounter()

    #expect(throws: StandupError.windowBelongsToAnotherProject) {
        // Alpha's window, Beta's project: without the guard this advances one
        // project's clock against the other's window.
        _ = try fixture.standupService(nowOffset: 900)
            .commit(editedDraft, of: window, for: fixture.beta)
    }

    #expect(try fixture.reportsInStore().isEmpty)
    #expect(try fixture.reloadThroughASecondContext(fixture.beta)?.lastStandupAt == nil)
    #expect(counter.posts == 0)
}

@MainActor
@Test("each standupReported event names the report that appended it")
func eventsCarryTheirReportID() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    let result = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // M2-04 redacts exactly the events belonging to the report being undone.
    let reported = try fixture.eventsInStore(kind: .standupReported)
    #expect(reported.count == 1)
    let payload = StandupReportedPayload.decoded(from: reported.first?.payload)
    #expect(payload?.reportID == result.report.id)
}

@MainActor
@Test("a successful Copy announces itself once")
func successfulCopyPostsOnce() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    let counter = WriteCounter()

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    #expect(counter.posts == 1)
}

@MainActor
@Test("an empty window still copies, advancing the clock with no events")
func emptyWindowCopiesCleanly() throws {
    let fixture = try ReportFixture()
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
    #expect(window.tasks.isEmpty, "precondition: nothing happened in this window")

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // "Nothing to report since yesterday" is a thing people say at stand-ups,
    // and D-074 renders it as three `_None_` sections rather than a blank
    // string. Copying it is legitimate and must still advance the clock.
    #expect(try fixture.reportsInStore().count == 1)
    #expect(try fixture.eventsInStore(kind: .standupReported).isEmpty)
    #expect(try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt == window.end)
}
