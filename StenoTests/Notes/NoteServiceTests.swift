import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)
private let withinWindow = origin.addingTimeInterval(120)
private let pastWindow = origin.addingTimeInterval(600)

private struct SaveFailure: Error {}

@MainActor
private func makeTask() throws -> (TaskItem, ModelContext) {
    // `ModelContext(container)`, never `container.mainContext` — the latter
    // does not retain its container and dangles the moment this returns.
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    context.insert(task)
    try context.save()
    return (task, context)
}

@MainActor
private func allEvents(_ context: ModelContext) throws -> [Event] {
    try context.fetch(FetchDescriptor<Event>())
}

// MARK: - Adding

@MainActor
@Test("adding a note appends one note event stamped now")
func addingANoteAppendsOneEvent() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { withinWindow })

    let note = try #require(try service.addNote("Repro'd the race condition", to: task))

    #expect(note.kind == .note)
    #expect(note.body == "Repro'd the race condition")
    #expect(note.timestamp == withinWindow)
    #expect(note.taskID == task.id)
    #expect(!note.isRedacted)
    #expect(try allEvents(context).count == 1)
}

@MainActor
@Test("a blank note writes nothing at all")
func aBlankNoteWritesNothing() throws {
    let (task, context) = try makeTask()
    let counter = WriteCounter()
    let service = NoteService(context: context, now: { withinWindow })

    #expect(try service.addNote("   \n  ", to: task) == nil)
    #expect(try allEvents(context).isEmpty)
    #expect(counter.posts == 0)
}

@MainActor
@Test("a note does not stamp modifiedAt")
func aNoteDoesNotStampModifiedAt() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { withinWindow })

    try service.addNote("progress", to: task)

    // §10.1 resolves task conflicts by "later modifiedAt wins". A note is not
    // an edit of the task, and stamping it would let a note outrank a title
    // genuinely edited on another Mac.
    #expect(task.modifiedAt == origin)
}

@MainActor
@Test("FR-1.5 runs over the note body, and re-noting the same key adds no second ref")
func extractionRunsOverNoteBodiesAndDedupes() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { withinWindow })

    try service.addNote("looking at PAY-421 now", to: task)
    #expect(task.sourceRefs?.count == 1)
    #expect(task.sourceRefs?.first?.identifier == "PAY-421")

    try service.addNote("still on PAY-421, nearly done", to: task)
    #expect(task.sourceRefs?.count == 1)
}

@MainActor
@Test("a failed save leaves no event, no ref, and no post")
func addNoteFailedSaveRollsBack() throws {
    let (task, context) = try makeTask()
    let counter = WriteCounter()
    let service = NoteService(
        context: context, now: { withinWindow }, save: { _ in throw SaveFailure() })

    #expect(throws: SaveFailure.self) {
        try service.addNote("fixed PAY-42", to: task)
    }

    // Refetched from the service's OWN context, not read off `task` or its
    // `sourceRefs` relationship. After `rollback()` a held reference still
    // reports the rejected value; it is the fetch that refreshes it. Reading
    // `task.sourceRefs` here would assert SwiftData's staleness and call it a
    // passing rollback — see `StatusServiceTests.statusServiceFailedSaveRollsBack`.
    #expect(try allEvents(context).isEmpty)
    // The half no other test in the plan covers: `addNote` is the only writer
    // that inserts a `SourceRef` alongside an `Event`, and a rollback that
    // undid the event but left the ref behind would be a silent leak.
    #expect(try context.fetch(FetchDescriptor<SourceRef>()).isEmpty)
    #expect(counter.posts == 0)
}
