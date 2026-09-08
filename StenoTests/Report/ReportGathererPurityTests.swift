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
    let task0 = try #require(window.tasks.first)
    #expect(task0.events.map(\.body) == ["eight hours ago"])
}
