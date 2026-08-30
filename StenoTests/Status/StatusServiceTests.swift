import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)
private let later = epoch.addingTimeInterval(3600)

private struct SaveFailure: Error {}

@MainActor
private func makeTask(_ status: Status = .todo) throws -> (TaskItem, ModelContext) {
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: epoch)
    context.insert(task)
    task.setStatus(status, at: epoch)
    try context.save()
    return (task, context)
}

@MainActor
private func events(_ context: ModelContext, _ kind: EventKind) throws -> [Event] {
    // Filtered in memory rather than in a `#Predicate`: D18 caps the dataset,
    // and a predicate over an enum-typed property is the kind of thing that
    // compiles and then fails at fetch time.
    try context.fetch(FetchDescriptor<Event>()).filter { $0.kind == kind }
}

/// Every ordered pair of distinct statuses — §3.2's "any status may move to
/// any other", enumerated rather than sampled.
private let orderedPairs: [(Status, Status)] = Status.allCases.flatMap { from in
    Status.allCases.filter { $0 != from }.map { (from, $0) }
}

@MainActor
@Test("any status moves to any other, appending one event that names it", arguments: orderedPairs)
private func anyStatusMovesToAnyOther(from: Status, into: Status) throws {
    let (task, context) = try makeTask(from)
    let service = StatusService(context: context, now: { later })

    let changed = try service.setStatus(into, on: task)

    #expect(changed)
    #expect(task.status == into)
    let appended = try events(context, .statusChanged)
    #expect(appended.count == 1)
    #expect(appended.first?.body == "\(from.displayName) → \(into.displayName)")
    #expect(appended.first?.taskID == task.id)
}

@MainActor
@Test("setting the status a task already has writes nothing at all")
func nonTransitionWritesNothing() throws {
    let (task, context) = try makeTask(.inProgress)
    let counter = WriteCounter()
    let service = StatusService(context: context, now: { later })

    let changed = try service.setStatus(.inProgress, on: task)

    #expect(!changed)
    #expect(try events(context, .statusChanged).isEmpty)
    // Unmoved: re-stamping would reset the clock M6-01's stale rule reads.
    #expect(task.statusChangedAt == epoch)
    #expect(counter.posts == 0)
}

@MainActor
@Test("entering done sets completedAt and leaving it clears it")
func statusServiceCompletedAtFollowsDone() throws {
    let (task, context) = try makeTask(.inProgress)
    let service = StatusService(context: context, now: { later })

    try service.setStatus(.done, on: task)
    #expect(task.completedAt == later)

    try service.setStatus(.todo, on: task)
    #expect(task.completedAt == nil)
}

@MainActor
@Test("every transition stamps statusChangedAt — M6-01's stale rule depends on it")
func transitionStampsStatusChangedAt() throws {
    let (task, context) = try makeTask(.todo)
    let service = StatusService(context: context, now: { later })

    try service.setStatus(.inProgress, on: task)

    #expect(task.statusChangedAt == later)
}

@MainActor
@Test("a blocked task takes a reason as its own event")
func blockedReasonIsAppended() throws {
    let (task, context) = try makeTask(.blocked)
    let service = StatusService(context: context, now: { later })

    let added = try service.addBlockedReason("Waiting on infra", to: task)

    #expect(added)
    let appended = try events(context, .blockedReason)
    #expect(appended.map(\.body) == ["Waiting on infra"])
}

@MainActor
@Test("a reason on a task that is not blocked writes nothing")
func blockedReasonRequiresBlocked() throws {
    let (task, context) = try makeTask(.inProgress)
    let service = StatusService(context: context, now: { later })

    let added = try service.addBlockedReason("Waiting on infra", to: task)

    #expect(!added)
    #expect(try events(context, .blockedReason).isEmpty)
}

@MainActor
@Test("whitespace-only text appends no reason — the sheet's Esc path")
func blankBlockedReasonWritesNothing() throws {
    let (task, context) = try makeTask(.blocked)
    let service = StatusService(context: context, now: { later })

    let added = try service.addBlockedReason("   \n ", to: task)

    #expect(!added)
    #expect(try events(context, .blockedReason).isEmpty)
}

@MainActor
@Test("a successful transition posts .stenoDidWrite exactly once")
func transitionPostsOnce() throws {
    let (task, context) = try makeTask(.todo)
    let counter = WriteCounter()

    try StatusService(context: context, now: { later }).setStatus(.done, on: task)

    #expect(counter.posts == 1)
}

@MainActor
@Test("a failed save leaves no event, no stored transition, and no post")
func statusServiceFailedSaveRollsBack() throws {
    let (task, context) = try makeTask(.todo)
    let counter = WriteCounter()
    let service = StatusService(
        context: context, now: { later }, save: { _ in throw SaveFailure() })

    #expect(throws: SaveFailure.self) {
        try service.setStatus(.done, on: task)
    }

    // Refetched from the service's OWN context, not read off `task`. After
    // `rollback()` the held reference still reports the rejected value; it is
    // the fetch that refreshes it. Reading `task.status` here would assert
    // SwiftData's staleness and call it a passing rollback.
    let refetched = try #require(context.fetch(FetchDescriptor<TaskItem>()).first)
    #expect(refetched.status == .todo)
    #expect(refetched.completedAt == nil)
    #expect(try events(context, .statusChanged).isEmpty)
    #expect(counter.posts == 0)
}

@MainActor
@Test("after a failed save the held reference is stale until the context refetches")
func failedSaveLeavesHeldReferenceStaleUntilRefetch() throws {
    let (task, context) = try makeTask(.todo)
    let service = StatusService(
        context: context, now: { later }, save: { _ in throw SaveFailure() })

    #expect(throws: SaveFailure.self) {
        try service.setStatus(.done, on: task)
    }

    // This pins observed SwiftData behaviour the design depends on rather than
    // behaviour anyone wants: `rollback()` protects the store and clears
    // `hasChanges`, but does not restore the in-memory object. `MainWindowModel`
    // is safe because it calls `reload()` on the failure path — and the test
    // exists so that a future caller which does not is a failing test rather
    // than a window showing a status the store rejected (D-018).
    #expect(task.status == .done)

    let refetched = try #require(context.fetch(FetchDescriptor<TaskItem>()).first)
    #expect(refetched === task)
    #expect(refetched.status == .todo)
}
