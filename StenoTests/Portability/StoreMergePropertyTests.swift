import Foundation
import Testing

@testable import StenoKit

/// §10.6's three algebraic properties, asserted over values.
///
/// None of these needs a `ModelContainer`, and that is the point of `StoreMerge`
/// being pure: a commutativity test written against two live SwiftData stores
/// would be slow, long, and hard to read at exactly the place the reasoning
/// matters most.
///
/// **The two stores diverge the way two Macs actually diverge**, rather than in
/// one field at a time: a rename on one, a status transition on the other, a
/// redaction on one, a cache fetch on the other, and records each side has never
/// seen. A single-field fixture would pass under a merge that resolved whole
/// records wrongly.

/// The shared history both machines start from.
private struct CommonHistory {
    let projects: [ExportedProject]
    let tasks: [ExportedTask]
    let events: [ExportedEvent]
}

private func commonHistory() -> CommonHistory {
    CommonHistory(
        projects: [MergeFixture.project(1, name: "Payments", modifiedAt: MergeFixture.at(10.3))],
        tasks: [
            MergeFixture.task(
                2, title: "Fix the retry handler", createdAt: MergeFixture.at(20.7),
                modifiedAt: MergeFixture.at(20.7))
        ],
        events: [
            MergeFixture.event(3, at: MergeFixture.at(21.1), body: "task created"),
            MergeFixture.transition(
                4, from: .todo, into: .inProgress, at: MergeFixture.at(30.9)),
        ]
    )
}

/// Machine A: renamed the task, redacted an event, fetched a ref, wrote a report.
private func storeA() throws -> MergedStore {
    let common = commonHistory()
    return try MergeFixture.store(
        projects: common.projects,
        tasks: [
            MergeFixture.task(
                2, title: "Fix the retry handler (renamed on A)", status: .inProgress,
                createdAt: MergeFixture.at(20.7), statusChangedAt: MergeFixture.at(30.9),
                modifiedAt: MergeFixture.at(100.4))
        ],
        events: common.events + [
            MergeFixture.event(
                5, at: MergeFixture.at(40.2), body: "a typo I took back", redacted: true),
            MergeFixture.event(6, at: MergeFixture.at(45.6), body: "only on A"),
        ],
        refs: [
            MergeFixture.ref(
                7, lastFetchedAt: MergeFixture.at(50.1), cachedSummary: "In review, 2 comments")
        ],
        reports: [
            MergeFixture.report(
                8, generatedAt: MergeFixture.at(60.8), windowStart: MergeFixture.at(0),
                windowEnd: MergeFixture.at(60.8))
        ])
}

/// Machine B: moved the task on, never saw the rename, has a task A has not.
private func storeB() throws -> MergedStore {
    let common = commonHistory()
    return try MergeFixture.store(
        projects: common.projects,
        tasks: [
            MergeFixture.task(
                2, title: "Fix the retry handler", status: .inProgress,
                createdAt: MergeFixture.at(20.7), statusChangedAt: MergeFixture.at(30.9),
                modifiedAt: MergeFixture.at(20.7)),
            MergeFixture.task(
                9, title: "Only on B", createdAt: MergeFixture.at(70.5),
                modifiedAt: MergeFixture.at(70.5)),
        ],
        events: common.events + [
            MergeFixture.transition(10, from: .inProgress, into: .done, at: MergeFixture.at(80.3)),
            MergeFixture.event(11, task: 9, at: MergeFixture.at(71.2), body: "only on B"),
        ],
        refs: [MergeFixture.ref(7)],
        reports: [])
}

@Test("§10.6: merging in either direction converges on the same store")
func mergeIsCommutative() throws {
    let forward = try StoreMerge.merge(local: storeA(), incoming: storeB())
    let backward = try StoreMerge.merge(local: storeB(), incoming: storeA())

    #expect(forward.store == backward.store)
}

@Test("§10.6: importing the same file twice changes nothing the second time")
func mergeIsIdempotent() throws {
    let once = try StoreMerge.merge(local: storeA(), incoming: storeB()).store
    let twice = try StoreMerge.merge(local: once, incoming: storeB()).store

    #expect(twice == once)

    // And a third pass, because an operation can be stable on its second
    // application and not its third — which is exactly how the truncating wire
    // format failed before D-101.
    let thrice = try StoreMerge.merge(local: twice, incoming: storeB()).store
    #expect(thrice == once)
}

@Test("§10.6: a merge never drops a record either side had")
func mergeIsNonDestructive() throws {
    let first = try storeA()
    let second = try storeB()
    let merged = try StoreMerge.merge(local: first, incoming: second).store

    // Checked in both directions. "Everything in the file arrived" cannot see a
    // local record that was dropped, and "everything local survived" cannot see
    // one from the file that never landed.
    for side in [first, second] {
        #expect(Set(side.projects.map(\.id)).isSubset(of: Set(merged.projects.map(\.id))))
        #expect(Set(side.tasks.map(\.id)).isSubset(of: Set(merged.tasks.map(\.id))))
        #expect(Set(side.events.map(\.id)).isSubset(of: Set(merged.events.map(\.id))))
        #expect(Set(side.sourceRefs.map(\.id)).isSubset(of: Set(merged.sourceRefs.map(\.id))))
        #expect(Set(side.reports.map(\.id)).isSubset(of: Set(merged.reports.map(\.id))))
    }

    // Two tasks, not three: A has task 2, B has tasks 2 and 9, and the union of
    // those is two. Six events, because each side contributed two beyond the
    // shared pair.
    #expect(merged.tasks.count == 2)
    #expect(merged.events.count == 6)
}

@Test("§10.6: importing an older export after a newer one loses nothing")
func anOlderExportLosesNothing() throws {
    let newer = try StoreMerge.merge(local: storeA(), incoming: storeB()).store
    // `storeB` is the older file here: it has neither the rename nor the
    // redaction, and it is the one being imported *second*.
    let afterOlder = try StoreMerge.merge(local: newer, incoming: storeB()).store

    #expect(afterOlder == newer)

    let task = try #require(afterOlder.tasks.first { $0.id == MergeFixture.id(2) })
    #expect(task.title == "Fix the retry handler (renamed on A)")
    #expect(task.status == .done)

    let redacted = try #require(afterOlder.events.first { $0.id == MergeFixture.id(5) })
    #expect(redacted.isRedacted)
}

@Test("the merge resolves whole records, not one field at a time")
func theMergeResolvesTheDivergentFields() throws {
    let merged = try StoreMerge.merge(local: storeA(), incoming: storeB()).store
    let task = try #require(merged.tasks.first { $0.id == MergeFixture.id(2) })

    // Title from A: later `modifiedAt`.
    #expect(task.title == "Fix the retry handler (renamed on A)")
    // Status from B's event, which is the newest `statusChanged` across both —
    // *not* from A's cached `.inProgress`, and not from B's cached field either,
    // which still reads `.inProgress` because B never refreshed it.
    #expect(task.status == .done)
    #expect(task.completedAt != nil)
    // The ref A fetched keeps its cache: B's copy has none, and nil loses.
    let ref = try #require(merged.sourceRefs.first { $0.id == MergeFixture.id(7) })
    #expect(ref.cachedSummary == "In review, 2 comments")
    // A's report advanced the clock; B never saw it.
    let project = try #require(merged.projects.first)
    #expect(project.lastStandupAt != nil)
}
