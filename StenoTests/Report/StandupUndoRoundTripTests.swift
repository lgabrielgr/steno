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
