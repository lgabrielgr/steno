import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// D-099's derivation, pinned against the two services it models.
///
/// **This is the point of `LastStandupClock` being its own type.** It recomputes
/// a value that `StandupService.commit` and `StandupUndoService.undo` each write
/// directly, and a derivation that models two services will drift from them. A
/// comment claiming the two agree would be the defect; driving the real services
/// and comparing is the guard.
///
/// Every test ends in the same assertion — derived equals live — because that is
/// the invariant. What differs is the history leading up to it.

@MainActor
private struct ClockFixture {
    let fixture: ExportFixture
    let project: Project

    init() throws {
        fixture = try ExportFixture()
        project = try fixture.project("Payments", modifiedAt: ExportFixture.at(0))
        let task = try fixture.task(
            "Fix the retry handler", in: project, createdAt: ExportFixture.at(10))
        try fixture.event("repro'd the race", on: task, at: ExportFixture.at(20))
    }

    /// What the store actually holds.
    var live: Date? { project.lastStandupAt }

    /// What D-099 recomputes from the reports alone.
    ///
    /// The snapshot is deliberately **not** wire-normalized: these dates came
    /// from the services and never went through a file, so comparing them to
    /// `live` at full precision is the strict form of the assertion.
    func derived() throws -> Date? {
        let snapshot = try fixture.encoder(includingCachedData: true).snapshot()
        return LastStandupClock.value(forProjectID: project.id, in: snapshot.reports)
    }

    @discardableResult
    func commit(at offset: TimeInterval) throws -> StandupReport {
        let window = try ReportGatherer(
            context: fixture.context, now: { ExportFixture.at(offset) }
        ).gather(for: project)
        return try StandupService(
            context: fixture.context, now: { ExportFixture.at(offset) }, copy: { _ in true }
        ).commit("*Yesterday*\n- shipped it", of: window, for: project).report
    }

    func undo(_ report: StandupReport) throws {
        _ = try StandupUndoService(context: fixture.context).undo(report, for: project)
    }
}

@MainActor
@Test("a project with no reports has no clock, derived or stored")
func noReportsMeansNoClock() throws {
    let clock = try ClockFixture()

    #expect(clock.live == nil)
    #expect(try clock.derived() == nil)
}

@MainActor
@Test("after one Copy, the derivation equals the stored clock")
func afterOneCopy() throws {
    let clock = try ClockFixture()
    try clock.commit(at: 100)

    #expect(clock.live != nil)
    #expect(try clock.derived() == clock.live)
}

@MainActor
@Test("after two Copies, the derivation equals the stored clock")
func afterTwoCopies() throws {
    let clock = try ClockFixture()
    try clock.commit(at: 100)
    try clock.commit(at: 200)

    #expect(try clock.derived() == clock.live)
}

@MainActor
@Test("after undoing the only report, the derivation equals the restored clock")
func afterUndoingTheOnlyReport() throws {
    let clock = try ClockFixture()
    let report = try clock.commit(at: 100)
    try clock.undo(report)

    // This is the row that decides the shape of the rule. A "newest report that
    // is not undone" derivation yields nil here, and nil makes the next Prepare
    // compute a *sliding* window — the loss D-067 and M2-04's step 5 avoid.
    // Reading `windowStart` for an undone report reproduces what undo restores.
    #expect(clock.live != nil)
    #expect(try clock.derived() == clock.live)
}

@MainActor
@Test("after undoing the newer of two reports, the derivation equals the clock")
func afterUndoingTheNewerOfTwo() throws {
    let clock = try ClockFixture()
    try clock.commit(at: 100)
    let second = try clock.commit(at: 200)
    try clock.undo(second)

    #expect(try clock.derived() == clock.live)
}

@MainActor
@Test("after a Copy, an undo, and another Copy, the derivation equals the clock")
func afterCopyUndoCopy() throws {
    let clock = try ClockFixture()
    let first = try clock.commit(at: 100)
    try clock.undo(first)
    try clock.commit(at: 300)

    #expect(try clock.derived() == clock.live)
}
