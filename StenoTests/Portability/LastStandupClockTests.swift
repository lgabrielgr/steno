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

// MARK: - After a merge, where single-machine undo semantics stop applying

/// Two report ids, fixed so the two stores below hold the *same* pair.
private func tiedReportIDs() -> [UUID] {
    ["00000000-0000-0000-0000-0000000000aa", "00000000-0000-0000-0000-0000000000bb"]
        .map { UUID(uuidString: $0) ?? UUID() }
}

@MainActor
private func storeWithTiedReports(
    insertedIn order: [UUID], distinctRawInstantFor: UUID? = nil
) throws -> (ExportFixture, Project) {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments", modifiedAt: ExportFixture.at(0))
    let instant = ExportFixture.at(100)
    for id in order {
        // One report may be given a *raw* instant that differs from the other
        // while rounding to the same wire millisecond — the shape a locally
        // created report has on the Mac that made it, beside the imported copy
        // on the other Mac, since `apply` leaves unchanged rows at full
        // precision.
        let stamp = id == distinctRawInstantFor ? ExportFixture.at(100.000_2) : instant
        fixture.context.insert(
            StandupReport(
                id: id, projectID: project.id, generatedAt: stamp,
                windowStart: ExportFixture.at(0), windowEnd: instant,
                markdownBody: "*Yesterday*\n- shipped it", wasAIGenerated: false))
    }
    try fixture.context.save()
    return (fixture, project)
}

@MainActor
@Test("which report Undo offers does not depend on the order the store holds them")
func undoSelectionIsOrderIndependent() throws {
    // M2.5-02 makes the tie reachable. On one machine `StandupService` stamps
    // `generatedAt` from a single `now()` per Copy, so two reports cannot share
    // it — but this PR unions two machines' reports, and two Macs can produce one
    // in the same millisecond. `undoableReport` sorted on `generatedAt` alone, so
    // the order among equals was unspecified: two machines could converge on an
    // identical record set and still disagree about what Undo would take back.
    //
    // **Asserted as order-independence, not as "it picks the lowest uuid".** The
    // first version of this test asserted the implementation's choice and passed
    // against a deliberately wrong tie-break roughly half the time, because the
    // fixture's ids were random — a coin flip dressed as a test.
    let ids = tiedReportIDs()
    let (forward, forwardProject) = try storeWithTiedReports(insertedIn: ids)
    let (backward, backwardProject) = try storeWithTiedReports(insertedIn: ids.reversed())

    let chosenForward = try StandupUndoService(context: forward.context)
        .undoableReport(for: forwardProject)
    let chosenBackward = try StandupUndoService(context: backward.context)
        .undoableReport(for: backwardProject)

    #expect(chosenForward != nil)
    #expect(chosenForward?.id == chosenBackward?.id)
}

@MainActor
@Test("a live report from one machine outranks an undo from the other")
func aLiveReportOutranksTheOtherMachinesUndo() throws {
    // **The derivation is not "what undo would have written on one machine", and
    // after a merge it must not be.** Machine A reported through 100 and never
    // took it back. Machine B reported a shorter window and undid it. Merged,
    // the clock is 100 — because the work up to 100 *was* reported aloud, which
    // is the thing §10.1 says must never be re-reported.
    //
    // D-099's claim that the derivation reproduces what `commit` and `undo`
    // write is a single-machine claim; the other tests in this file are what
    // pin it. This is the cross-machine rule, stated so it is chosen rather than
    // accidental.
    let live = MergeFixture.report(
        1, project: 1, generatedAt: MergeFixture.at(100), windowStart: MergeFixture.at(0),
        windowEnd: MergeFixture.at(100))
    let undone = MergeFixture.report(
        2, project: 1, generatedAt: MergeFixture.at(110), windowStart: MergeFixture.at(0),
        windowEnd: MergeFixture.at(90), undone: true)

    let clock = LastStandupClock.value(forProjectID: MergeFixture.id(1), in: [live, undone])

    #expect(clock == MergeFixture.at(100))
    // And the undo still governs where nothing else covers the window: drop the
    // live report and the clock falls back to what undo restored.
    #expect(
        LastStandupClock.value(forProjectID: MergeFixture.id(1), in: [undone])
            == MergeFixture.at(0))
}

@MainActor
@Test("the undo tie is decided at wire precision, not by raw Date equality")
func theUndoTieIsDecidedAtWirePrecision() throws {
    // **This is the case that broke the previous version of the tie-break.**
    // `apply` leaves unchanged local rows at full precision, so the Mac that
    // created a report holds `…40.4817263` while the Mac that imported it holds
    // `…40.482`. Raw `Date` equality groups those differently on the two
    // machines: one sees a tie and applies the uuid rule, the other sees two
    // distinct instants and takes the later. Same converged record set,
    // different answer to "what would Undo take back".
    //
    // **The distinct raw instant goes to the *higher* uuid deliberately.** Give
    // it to the lower one and both rules happen to choose the same report, and
    // the test passes against the broken code — which is what the first version
    // of this test did.
    let ids = tiedReportIDs()
    let higher = try #require(ids.max { $0.uuidString < $1.uuidString })

    let (rounded, roundedProject) = try storeWithTiedReports(insertedIn: ids)
    let (rawPrecision, rawProject) = try storeWithTiedReports(
        insertedIn: ids, distinctRawInstantFor: higher)

    // Both instants are the same millisecond on the wire, so both stores hold
    // what is, to the format, the same pair — and must answer identically.
    #expect(
        ExportDocument.wireString(ExportFixture.at(100.000_2))
            == ExportDocument.wireString(ExportFixture.at(100)))

    let fromRounded = try StandupUndoService(context: rounded.context)
        .undoableReport(for: roundedProject)
    let fromRaw = try StandupUndoService(context: rawPrecision.context)
        .undoableReport(for: rawProject)

    #expect(fromRounded != nil)
    #expect(fromRounded?.id == fromRaw?.id)
}
