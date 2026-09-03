import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

/// `NoteService.correct` takes an `Event` and a `TaskItem` separately, so the
/// pair can disagree. It files the replacement under `event.taskID` but
/// attaches extracted `SourceRef`s to `task`, which would split one correction
/// across two tasks.
///
/// Its own file rather than an addition to `NoteServiceTests`: that one is at
/// 383 of SwiftLint's 400-line cap.
/// A struct, not a tuple: SwiftLint's `large_tuple` caps tuples at two members,
/// and `NoteComposerModelTests.ComposerFixture` already established the shape.
@MainActor
private struct TwoTasks {
    let context: ModelContext
    let owner: TaskItem
    let bystander: TaskItem
}

@MainActor
private func makeTwoTasks() throws -> TwoTasks {
    // `ModelContext(container)`, never `container.mainContext` — the latter
    // does not retain its container and dangles the moment this returns.
    let context = ModelContext(try StenoStore.inMemory())
    let owner = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    let bystander = TaskItem(title: "Chase the flaky test", projectID: UUID(), createdAt: origin)
    context.insert(owner)
    context.insert(bystander)
    try context.save()
    return TwoTasks(context: context, owner: owner, bystander: bystander)
}

@MainActor
@Test("correcting an event through the wrong task writes nothing to either")
func aMismatchedTaskIsRefused() throws {
    let fixture = try makeTwoTasks()
    let context = fixture.context
    let owner = fixture.owner
    let bystander = fixture.bystander
    let service = NoteService(context: context, now: { origin })
    let note = try #require(try service.addNote("about PAY-42", to: owner))

    let outcome = try service.correct(note, to: "about PAY-421", on: bystander)

    #expect(outcome == .notCorrectable)
    #expect(!note.isRedacted)
    #expect(try context.fetch(EventQueries.timeline(forTaskID: owner.id)).count == 1)
    #expect(try context.fetch(EventQueries.timeline(forTaskID: bystander.id)).isEmpty)
    // The ref that would have been misfiled is the point of the guard.
    #expect(bystander.sourceRefs?.isEmpty ?? true)
}
