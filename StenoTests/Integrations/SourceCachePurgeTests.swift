import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-6's "purge cached external data" (D-219).

/// A second context, because a refetch on the writing context returns the objects
/// already held — so "the cache is gone" would pass even against a rollback.
/// `RefreshFixture` records the same reason.
@MainActor
private func refetch(_ container: ModelContainer) throws -> [SourceRef] {
    try ModelContext(container).fetch(FetchDescriptor<SourceRef>())
}

@Test("a purge clears both cache columns and leaves everything else standing")
@MainActor
func aPurgeClearsTheCacheAndNothingElse() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    let ref = try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")
    let refID = ref.id

    let result = SourceCachePurge(context: fixture.context).purge()

    #expect(result == .purged(cleared: 1))

    let rows = try refetch(fixture.container)
    let purged = try #require(rows.first { $0.id == refID })
    #expect(purged.cachedSummary == nil)
    #expect(purged.lastFetchedAt == nil)

    // The task file: "Purging must not delete tasks, events, or refs". The ref
    // itself, and everything identifying it, survives.
    #expect(rows.count == 1)
    #expect(purged.identifier == "PAY-421")
    #expect(purged.taskID == task.id)
    #expect(purged.kind == .jiraIssue)
    let tasks = try ModelContext(fixture.container).fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
}

@Test("§3.3: a purge writes and removes no event")
@MainActor
func aPurgeLeavesTheEventLogAlone() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    try fixture.ref("PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")

    // **Written here rather than assumed.** `RefreshFixture` builds rows directly
    // rather than through the services, so it writes no events — the first version
    // of this test asserted over an empty log and would have passed against a purge
    // that deleted every event in the store. The guard below is what caught it.
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin, kind: .note,
            body: "spoke to the payments team"))
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin, kind: .externalUpdate,
            body: "PAY-421: In Progress"))
    try fixture.context.save()

    let before = try ModelContext(fixture.container).fetch(FetchDescriptor<Event>())
    #expect(before.count == 2, "the fixture must write events, or this test proves nothing")

    _ = SourceCachePurge(context: fixture.context).purge()

    let after = try ModelContext(fixture.container).fetch(FetchDescriptor<Event>())
    // Mutation: have `purge()` delete the refs it clears. Red here and above.
    #expect(after.count == before.count)
    #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
}

@Test("D-219: a purged ref is not a first observation, so the next pass still reports changes")
@MainActor
func aPurgedRefIsNotAFirstObservation() throws {
    // **The failure mode this decision exists to rule out.** A first observation
    // reports the summary and nothing else (D-169) while recording every id it saw
    // (D-188) — so if clearing `lastFetchedAt` made a ref look new, the changes
    // that arrived after the purge would be swallowed and never reported again.
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    let ref = try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")

    // A reported change in the log, which is where the resume point lives (D-184).
    let payload = ExternalUpdatePayload(
        refID: ref.id, kind: .jiraIssue, identifier: "PAY-421",
        changes: ["moved to In Progress"], url: nil,
        fetchedAt: RefreshFixture.origin, watermark: RefreshFixture.origin,
        changeIDs: ["change-1"], presentIDs: nil, windowCapped: nil)
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin, kind: .externalUpdate,
            body: "PAY-421: In Progress", payload: payload.encoded()))
    try fixture.context.save()

    _ = SourceCachePurge(context: fixture.context).purge()

    // The log still carries the payload the resume point is built from, so
    // `row.lastFetchedAt == nil && resume[row.id] == nil` is false.
    let events = try ModelContext(fixture.container)
        .fetch(FetchDescriptor<Event>())
        .filter { $0.kind == .externalUpdate }
    #expect(events.count == 1)
    let survived = try #require(events.first)
    #expect(ExternalUpdatePayload.decoded(from: survived.payload)?.changeIDs == ["change-1"])
    #expect(
        ExternalUpdatePayload.decoded(from: survived.payload)?.watermark == RefreshFixture.origin)
}

@Test("purging a store that has never fetched anything is a success, and saves nothing")
@MainActor
func purgingAnUnfetchedStoreIsASuccess() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    try fixture.ref("PAY-421", on: task)

    // Zero is the honest count: the user asked for a state that already holds.
    // Mutation: return `.purged(cleared: rows.count)`. Red.
    #expect(SourceCachePurge(context: fixture.context).purge() == .purged(cleared: 0))
}

@Test("the count names refs that held something, not every ref in the store")
@MainActor
func theCountNamesOnlyCachedRefs() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    try fixture.ref("PAY-1", on: task, fetched: RefreshFixture.origin, summary: "Done")
    try fixture.ref("PAY-2", on: task)
    try fixture.ref("PAY-3", on: task, fetched: RefreshFixture.origin, summary: "In Progress")

    // "Cleared 3" for a store holding two observations is a number the user would
    // reasonably read as three things thrown away.
    #expect(SourceCachePurge(context: fixture.context).purge() == .purged(cleared: 2))
}

@Test("D-172: a refused save rolls back, so the cache is still there")
@MainActor
func aRefusedSaveRollsBack() throws {
    struct Refused: Error {}
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    let ref = try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")
    let refID = ref.id

    let purge = SourceCachePurge(context: fixture.context, save: { _ in throw Refused() })
    guard case .failed = purge.purge() else {
        Issue.record("a refused save must report itself")
        return
    }

    let rows = try refetch(fixture.container)
    let survivor = try #require(rows.first { $0.id == refID })
    #expect(survivor.cachedSummary == "In Progress")
    #expect(survivor.lastFetchedAt == RefreshFixture.origin)

    // **A later successful save is what makes the assertion above falsifiable.**
    // Without it, "the cache is still there" also passes when the rollback left
    // the context dirty and nothing was ever committed either way — and a dirty
    // context is committed by the next unrelated save, which is the bug D-172
    // exists for.
    try fixture.context.save()
    let afterLaterSave = try refetch(fixture.container)
    #expect(afterLaterSave.first { $0.id == refID }?.cachedSummary == "In Progress")
}
