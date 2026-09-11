import Foundation
import Testing

@testable import StenoKit

/// §10.1's rules one at a time, where `StoreMergePropertyTests` asserts the
/// algebra over a store that diverged in several ways at once.
///
/// **Every test here puts the *same record id* on both sides.** That is the
/// only configuration in which a merge rule runs at all, and it is the one a
/// realistic-looking fixture most easily misses: a record present on one side
/// only is inserted verbatim, so a fixture built that way exercises the union
/// and none of the resolution. Found by mutation — inverting the sticky-flag
/// rule broke nothing until these existed.

private func baseProject() -> ExportedProject {
    MergeFixture.project(1, modifiedAt: MergeFixture.at(10.3))
}

private func baseTask(
    status: Status = .todo, statusChangedAt: TimeInterval = 20.7, modifiedAt: TimeInterval = 20.7,
    completedAt: Date? = nil, title: String = "Fix the retry handler"
) -> ExportedTask {
    MergeFixture.task(
        2, title: title, status: status, createdAt: MergeFixture.at(20.7),
        statusChangedAt: MergeFixture.at(statusChangedAt), completedAt: completedAt,
        modifiedAt: MergeFixture.at(modifiedAt))
}

// MARK: - O-8: the two sticky flags

@Test("O-8: a redaction on either side survives, whichever way the merge runs")
func aRedactionIsSticky() throws {
    // One event id, one body, two different flags — the shape that makes the
    // rule run. Anything else and the union simply carries the row across.
    let body = "a typo I took back"
    let clean = MergeFixture.event(5, at: MergeFixture.at(40.2), body: body, redacted: false)
    let redacted = MergeFixture.event(5, at: MergeFixture.at(40.2), body: body, redacted: true)

    let withClean = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], events: [clean])
    let withRedacted = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], events: [redacted])

    let forward = try StoreMerge.merge(local: withClean, incoming: withRedacted).store
    let backward = try StoreMerge.merge(local: withRedacted, incoming: withClean).store

    #expect(forward == backward)
    #expect(try #require(forward.events.first).isRedacted)
    // Stated separately because this is the consequence that matters: §10.1
    // warns that a lost redaction puts the text back into a stand-up summary.
    #expect(try #require(backward.events.first).isRedacted)
}

@Test("O-8: an undone report stays undone, whichever way the merge runs")
func anUndoneReportIsSticky() throws {
    let live = MergeFixture.report(
        8, generatedAt: MergeFixture.at(60.8), windowStart: MergeFixture.at(0),
        windowEnd: MergeFixture.at(60.8), undone: false)
    let undone = MergeFixture.report(
        8, generatedAt: MergeFixture.at(60.8), windowStart: MergeFixture.at(0),
        windowEnd: MergeFixture.at(60.8), undone: true)

    let withLive = try MergeFixture.store(projects: [baseProject()], reports: [live])
    let withUndone = try MergeFixture.store(projects: [baseProject()], reports: [undone])

    let forward = try StoreMerge.merge(local: withLive, incoming: withUndone).store
    let backward = try StoreMerge.merge(local: withUndone, incoming: withLive).store

    #expect(forward == backward)
    #expect(try #require(forward.reports.first).isUndone)
    // And the clock follows the flag: D-099's derivation reads `windowStart` for
    // an undone report, so the undo is not half-applied after a merge.
    #expect(try #require(forward.projects.first).lastStandupAt == MergeFixture.at(0))
}

// MARK: - §10.1: status derived from the log, not copied

@Test("§10.1: status comes from the newest statusChanged event, not the cache")
func statusIsDerivedNotCopied() throws {
    // The acceptance criterion names this case: a store whose cached `status`
    // disagrees with its own newest `statusChanged` event. The cache says todo;
    // the log says the task reached done.
    let stale = baseTask(status: .todo, statusChangedAt: 20.7)
    let store = try MergeFixture.store(
        projects: [baseProject()],
        tasks: [stale],
        events: [
            MergeFixture.transition(3, from: .todo, into: .inProgress, at: MergeFixture.at(30.9)),
            MergeFixture.transition(4, from: .inProgress, into: .done, at: MergeFixture.at(80.3)),
        ])

    let merged = try StoreMerge.merge(local: store, incoming: store).store
    let task = try #require(merged.tasks.first)

    #expect(task.status == .done)
    #expect(task.statusChangedAt == MergeFixture.at(80.3).wireRounded)
    #expect(task.completedAt == MergeFixture.at(80.3).wireRounded)
}

@Test("§10.1: the deciding event may live only in the incoming file")
func statusIsDerivedAcrossTheUnion() throws {
    let shared = baseTask(status: .inProgress, statusChangedAt: 30.9)
    let local = try MergeFixture.store(
        projects: [baseProject()], tasks: [shared],
        events: [
            MergeFixture.transition(3, from: .todo, into: .inProgress, at: MergeFixture.at(30.9))
        ])
    let incoming = try MergeFixture.store(
        projects: [baseProject()], tasks: [shared],
        events: [
            MergeFixture.transition(3, from: .todo, into: .inProgress, at: MergeFixture.at(30.9)),
            MergeFixture.transition(
                4, from: .inProgress, into: .blocked, at: MergeFixture.at(90.1)),
        ])

    #expect(
        try StoreMerge.merge(local: local, incoming: incoming).store.tasks.first?.status
            == .blocked)
    #expect(
        try StoreMerge.merge(local: incoming, incoming: local).store.tasks.first?.status
            == .blocked)
}

@Test("§3.3: a redacted statusChanged event still decides the status")
func aRedactedTransitionStillCounts() throws {
    // `isRedacted` hides a row from summaries; a status cache is not a summary.
    // If redaction excluded the row, redacting an event would silently revert a
    // task — a mutation of the log by the back door.
    let store = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()],
        events: [
            MergeFixture.transition(3, from: .todo, into: .inProgress, at: MergeFixture.at(30.9)),
            MergeFixture.event(
                4, at: MergeFixture.at(80.3), kind: .statusChanged,
                body: StatusTransition(from: .inProgress, into: .done).eventBody, redacted: true),
        ])

    #expect(try StoreMerge.merge(local: store, incoming: store).store.tasks.first?.status == .done)
}

@Test("a task that went done, back, and done again completes at the latest one")
func completedAtFollowsTheLatestCompletion() throws {
    let store = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()],
        events: [
            MergeFixture.transition(3, from: .todo, into: .done, at: MergeFixture.at(30.9)),
            MergeFixture.transition(4, from: .done, into: .todo, at: MergeFixture.at(50.5)),
            MergeFixture.transition(5, from: .todo, into: .done, at: MergeFixture.at(80.3)),
        ])
    let task = try #require(try StoreMerge.merge(local: store, incoming: store).store.tasks.first)

    // `TaskItem.setStatus` reproduced exactly: the newest transition decides all
    // three fields, so `completedAt` is the latest completion and not the first.
    #expect(task.status == .done)
    #expect(task.completedAt == MergeFixture.at(80.3).wireRounded)
}

@Test("an unreadable body falls back to the cache and is reported, not refused")
func anUnreadableBodyFallsBackAndIsReported() throws {
    let store = try MergeFixture.store(
        projects: [baseProject()],
        tasks: [baseTask(status: .blocked, statusChangedAt: 30.9)],
        events: [
            MergeFixture.event(
                3, at: MergeFixture.at(80.3), kind: .statusChanged, body: "TODO -> DONE")
        ])

    let result = try StoreMerge.merge(local: store, incoming: store)

    // §10.2 chose JSON partly so a file could be hand-edited. A mistyped arrow
    // must not cost the whole import, and must not be silently swallowed either.
    #expect(result.store.tasks.first?.status == .blocked)
    #expect(result.unparsedStatusBodies == [MergeFixture.id(3)])
}

@Test("with no transition in the log, the later statusChangedAt wins")
func withNoTransitionTheCacheClockDecides() throws {
    let older = baseTask(status: .todo, statusChangedAt: 20.7)
    let newer = baseTask(status: .blocked, statusChangedAt: 90.1)
    let local = try MergeFixture.store(projects: [baseProject()], tasks: [older])
    let incoming = try MergeFixture.store(projects: [baseProject()], tasks: [newer])

    #expect(
        try StoreMerge.merge(local: local, incoming: incoming).store.tasks.first?.status
            == .blocked)
    #expect(
        try StoreMerge.merge(local: incoming, incoming: local).store.tasks.first?.status
            == .blocked)
}

extension Date {
    /// This instant as the file carries it, for assertions against a merge
    /// output — which has been through `wireNormalized` and is therefore rounded.
    ///
    /// **Non-throwing deliberately.** It is read inside `#expect`, whose
    /// autoclosure is not throwing, and a `get throws` here fails to compile
    /// with "property access can throw, but it is not marked with 'try' and it
    /// is executed in a non-throwing autoclosure" — pointing at the macro
    /// expansion rather than at this line. Falling back to `self` on a decode
    /// failure is safe: `self` is full precision, so an assertion comparing it
    /// against a merged value goes red rather than vacuously green.
    var wireRounded: Date {
        let json = Data("[\"\(ExportDocument.wireString(self))\"]".utf8)
        let decoded = try? ExportDocument.decoder().decode([Date].self, from: json)
        return decoded?.first ?? self
    }
}

// MARK: - §10.1: the cached pair, and where commutativity legitimately stops

@Test("§10.1: later lastFetchedAt wins and the summary travels with it")
func theLaterFetchWinsAndCarriesItsSummary() throws {
    let older = MergeFixture.ref(
        7, lastFetchedAt: MergeFixture.at(50.1), cachedSummary: "In review")
    let newer = MergeFixture.ref(
        7, lastFetchedAt: MergeFixture.at(90.4), cachedSummary: "Merged, 4 comments")

    let mine = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [older])
    let theirs = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [newer])

    for merged in [
        try StoreMerge.merge(local: mine, incoming: theirs).store,
        try StoreMerge.merge(local: theirs, incoming: mine).store,
    ] {
        let ref = try #require(merged.sourceRefs.first)
        // The pair moves together, exactly as `SourceRef.recordFetch` moves it.
        // Resolving the summary independently of its timestamp would let a store
        // claim a summary was fetched at a moment it was not.
        #expect(ref.lastFetchedAt == MergeFixture.at(90.4).wireRounded)
        #expect(ref.cachedSummary == "Merged, 4 comments")
    }
}

@Test("§10.1: nil loses to any value, so a cache-free file never clears a cache")
func nilLosesToAnyValue() throws {
    // This is the shape of an ordinary export: §10.2 excludes cached external
    // data by default, so the incoming ref carries neither field.
    let cached = MergeFixture.ref(
        7, lastFetchedAt: MergeFixture.at(50.1), cachedSummary: "In review")
    let bare = MergeFixture.ref(7)

    let mine = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [cached])
    let theirs = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [bare])

    let merged = try StoreMerge.merge(local: mine, incoming: theirs).store
    #expect(try #require(merged.sourceRefs.first).cachedSummary == "In review")
}

@Test("a cache-free export is not a complete description, and does not converge")
func aCacheFreeExportDoesNotConverge() throws {
    // **Asserted deliberately, so nobody later reads this as a merge bug.**
    // §10.6's commutativity property holds for exports taken with the same
    // `includesCachedExternalData` setting. With the default `false` the file
    // carries neither cached field at all, so "nil loses to any value"
    // preserves whichever machine happens to be the target — and A→B and B→A
    // differ in exactly those two fields. That is not a defect in the rule:
    // §10.2 declares cached data excluded and re-fetchable, so a cache-free
    // file is by definition not a complete description of its store.
    let mineCached = MergeFixture.ref(
        7, lastFetchedAt: MergeFixture.at(50.1), cachedSummary: "In review")
    let theirsCached = MergeFixture.ref(
        7, lastFetchedAt: MergeFixture.at(90.4), cachedSummary: "Merged, 4 comments")

    let mine = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [mineCached])
    let theirs = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [theirsCached])
    // What each would actually send with the default option: the ref, no cache.
    let mineOnTheWire = try MergeFixture.store(
        projects: [baseProject()], tasks: [baseTask()], refs: [MergeFixture.ref(7)])

    let forward = try StoreMerge.merge(local: theirs, incoming: mineOnTheWire).store
    let backward = try StoreMerge.merge(local: mine, incoming: mineOnTheWire).store

    #expect(forward.sourceRefs.first?.cachedSummary == "Merged, 4 comments")
    #expect(backward.sourceRefs.first?.cachedSummary == "In review")
    #expect(forward != backward)
}
