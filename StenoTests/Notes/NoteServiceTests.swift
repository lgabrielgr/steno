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

// MARK: - Correcting

@MainActor
@Test("a correction redacts the original and appends a replacement keeping its timestamp")
func aCorrectionRedactsAndReappends() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("fixed PAY-42", to: task))
    let originalID = original.id
    clock = withinWindow

    #expect(try service.correct(original, to: "fixed PAY-421", on: task) == .corrected)

    let events = try allEvents(context)
    #expect(events.count == 2)

    let kept = try #require(events.first { $0.id == originalID })
    #expect(kept.isRedacted)
    // Untouched apart from the flag — the invariant, asserted directly.
    #expect(kept.body == "fixed PAY-42")
    #expect(kept.timestamp == origin)
    #expect(kept.kind == .note)

    let replacement = try #require(events.first { $0.id != originalID })
    #expect(!replacement.isRedacted)
    #expect(replacement.body == "fixed PAY-421")
    // FR-2: the original timestamp, so the timeline does not reorder mid-correction.
    #expect(replacement.timestamp == origin)
    #expect(replacement.kind == .note)
    #expect(replacement.taskID == task.id)
}

@MainActor
@Test("correcting a blocked reason reappends a blocked reason, not a note")
func correctingABlockedReasonKeepsItsKind() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let context2 = context
    let statuses = StatusService(context: context2, now: { clock })
    let notes = NoteService(context: context2, now: { clock })

    try statuses.setStatus(.blocked, on: task)
    try statuses.addBlockedReason("waiting on infra", to: task)
    let reason = try #require(try allEvents(context2).first { $0.kind == .blockedReason })
    clock = withinWindow

    #expect(try notes.correct(reason, to: "waiting on staging infra", on: task) == .corrected)

    let reasons = try allEvents(context2).filter { $0.kind == .blockedReason }
    #expect(reasons.count == 2)
    // FR-2 says "a new note event"; taken literally this would relabel the row.
    #expect(reasons.contains { !$0.isRedacted && $0.body == "waiting on staging infra" })
}

@MainActor
@Test("past the window a correction writes nothing")
func pastTheWindowNothingIsWritten() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("fixed PAY-42", to: task))
    clock = pastWindow
    let counter = WriteCounter()

    #expect(try service.correct(original, to: "fixed PAY-421", on: task) == .windowExpired)

    #expect(try allEvents(context).count == 1)
    #expect(!original.isRedacted)
    #expect(original.body == "fixed PAY-42")
    #expect(counter.posts == 0)
}

@MainActor
@Test("the window does not restart when a correction is itself corrected")
func theWindowDoesNotRestart() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("first", to: task))
    clock = origin.addingTimeInterval(240)
    #expect(try service.correct(original, to: "second", on: task) == .corrected)

    let replacement = try #require(try allEvents(context).first { !$0.isRedacted })
    // The replacement carries the ORIGINAL timestamp, so at T+4m it is still
    // inside the window — and at T+6m it is not, even though it was written
    // only two minutes earlier.
    clock = origin.addingTimeInterval(290)
    #expect(try service.correct(replacement, to: "third", on: task) == .corrected)

    let third = try #require(try allEvents(context).first { !$0.isRedacted })
    clock = origin.addingTimeInterval(360)
    #expect(try service.correct(third, to: "fourth", on: task) == .windowExpired)
}

@MainActor
@Test("a blank or unchanged correction writes nothing")
func aBlankOrUnchangedCorrectionWritesNothing() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let service = NoteService(context: context, now: { clock })

    let original = try #require(try service.addNote("unchanged", to: task))
    clock = withinWindow

    #expect(try service.correct(original, to: "   ", on: task) == .unchanged)
    #expect(try service.correct(original, to: "unchanged", on: task) == .unchanged)
    // Emptying a correction must not be a back door into redaction.
    #expect(!original.isRedacted)
    #expect(try allEvents(context).count == 1)
}

@MainActor
@Test("system-authored events are not correctable")
func systemEventsAreNotCorrectable() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { origin })
    context.insert(Event(taskID: task.id, timestamp: origin, kind: .created, body: "Task created"))
    try context.save()
    let created = try #require(try allEvents(context).first { $0.kind == .created })

    #expect(try service.correct(created, to: "nope", on: task) == .notCorrectable)
    #expect(try service.redact(created) == false)
    #expect(!created.isRedacted)
}

// MARK: - Redacting

@MainActor
@Test("redacting keeps the row and hides it from the timeline query")
func redactingKeepsTheRow() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { origin })
    let note = try #require(try service.addNote("a mistake", to: task))

    #expect(try service.redact(note))

    // Hidden from the shared query...
    #expect(try context.fetch(EventQueries.timeline(forTaskID: task.id)).isEmpty)
    // ...but the row still exists, which is what §3.3 requires.
    #expect(try allEvents(context).count == 1)
    #expect(try #require(try allEvents(context).first).body == "a mistake")
}

@MainActor
@Test("redacting twice writes only once")
func redactingTwiceWritesOnce() throws {
    let (task, context) = try makeTask()
    let service = NoteService(context: context, now: { origin })
    let note = try #require(try service.addNote("a mistake", to: task))
    try service.redact(note)
    let counter = WriteCounter()

    #expect(try service.redact(note) == false)
    #expect(counter.posts == 0)
}

// MARK: - Failure

@MainActor
@Test("a failed correction rolls back on disk, and the held reference agrees")
func aFailedCorrectionRollsBack() throws {
    let (task, context) = try makeTask()
    var clock = origin
    var shouldFail = false
    let service = NoteService(
        context: context, now: { clock },
        save: { context in
            if shouldFail { throw SaveFailure() }
            try context.save()
        })

    let original = try #require(try service.addNote("fixed PAY-42", to: task))
    clock = withinWindow
    shouldFail = true

    #expect(throws: SaveFailure.self) {
        _ = try service.correct(original, to: "fixed PAY-421", on: task)
    }

    // `commit()` has already rolled back. Measured, not assumed: the
    // replacement insert is discarded and the stored row is clean...
    let stored = try allEvents(context)
    #expect(stored.count == 1)
    #expect(try #require(stored.first).isRedacted == false)
    #expect(try #require(stored.first).body == "fixed PAY-42")

    // ...and here the held reference agrees with the store, rather than
    // staying stale at the rejected value.
    //
    // This is the opposite of `StatusService`'s rollback (a pure property
    // mutation, no pending insert): there, the held reference keeps reporting
    // the rejected value until a refetch. Isolated directly: calling
    // `NoteService.redact(_:)` alone (mutate-only, same context, same
    // failing save) reproduces that stale-true behavior. It is only once a
    // `context.insert(_:)` for the replacement `Event` joins the same pending
    // transaction that `context.rollback()` also re-faults `original` back to
    // its clean, on-disk value. Task 8 must not assume either direction for
    // `correct()`'s failure path — reload regardless, exactly as the brief
    // already prescribes — but this specific assertion has to track what
    // SwiftData actually does here, not the mutate-only pattern.
    #expect(original.isRedacted == false)
}
