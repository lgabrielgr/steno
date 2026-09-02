import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

private struct SaveFailure: Error {}

/// A clock the test can advance between calls.
@MainActor
private final class Clock {
    var instant: Date
    init(_ instant: Date) { self.instant = instant }
}

/// A struct, not a tuple: SwiftLint's `large_tuple` caps tuples at two
/// members, and `CaptureFieldModelTests` already established the fixture shape.
@MainActor
private struct ComposerFixture {
    let composer: NoteComposerModel
    let task: TaskItem
    let context: ModelContext
    let clock: Clock
}

@MainActor
private func makeComposer(
    failing shouldFail: @escaping () -> Bool = { false }
) throws -> ComposerFixture {
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    context.insert(task)
    try context.save()
    let clock = Clock(origin)
    let service = NoteService(
        context: context, now: { clock.instant },
        save: { context in
            if shouldFail() { throw SaveFailure() }
            try context.save()
        })
    return ComposerFixture(
        composer: NoteComposerModel(service: service, now: { clock.instant }),
        task: task, context: context, clock: clock)
}

@MainActor
private func timeline(_ context: ModelContext, _ task: TaskItem) throws -> [Event] {
    try context.fetch(EventQueries.timeline(forTaskID: task.id))
}

@MainActor
@Test("a blank draft cannot be committed")
func aBlankDraftCannotBeCommitted() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    #expect(!composer.canCommit)
    composer.text = "   \n "
    #expect(!composer.canCommit)
    composer.text = "real"
    #expect(composer.canCommit)
}

@MainActor
@Test("each focus request is observable, even when already focused")
func focusRequestsAccumulate() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    #expect(composer.focusRequests == 0)
    composer.requestFocus()
    composer.requestFocus()
    // A `Bool` would have collapsed these into one, and the second `N` press
    // would not re-focus a composer the user had clicked away from.
    #expect(composer.focusRequests == 2)
}

@MainActor
@Test("committing a new note appends it and clears the draft")
func committingANewNoteClearsTheDraft() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    composer.text = "Repro'd the race"

    #expect(composer.commit(on: task, in: []))

    #expect(composer.text.isEmpty)
    #expect(composer.mode == .adding)
    #expect(composer.lastError == nil)
    #expect(try timeline(context, task).count == 1)
}

@MainActor
@Test("beginning a correction prefills the draft and refuses an expired row")
func beginningACorrectionPrefills() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    let clock = fixture.clock
    composer.text = "fixed PAY-42"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)

    clock.instant = origin.addingTimeInterval(60)
    composer.beginCorrection(of: note.id, in: [note])
    #expect(composer.text == "fixed PAY-42")
    #expect(composer.mode == .correcting(eventID: note.id))

    composer.cancel()
    clock.instant = origin.addingTimeInterval(600)
    composer.beginCorrection(of: note.id, in: [note])
    // Past the window the composer refuses to open rather than opening a
    // correction whose commit is guaranteed to be refused.
    #expect(composer.mode == .adding)
    #expect(composer.text.isEmpty)
}

@MainActor
@Test("a window that closes mid-correction keeps the draft and says so")
func expiryMidCorrectionKeepsTheDraft() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    let clock = fixture.clock
    composer.text = "fixed PAY-42"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)

    clock.instant = origin.addingTimeInterval(298)
    composer.beginCorrection(of: note.id, in: [note])
    composer.text = "fixed PAY-421"

    // The user typed for a few seconds and the window closed underneath them.
    clock.instant = origin.addingTimeInterval(360)
    #expect(composer.commit(on: task, in: [note]))

    // Nothing lost, nothing written, and the reason is on screen.
    #expect(composer.text == "fixed PAY-421")
    #expect(composer.mode == .adding)
    #expect(composer.notice != nil)
    #expect(composer.lastError == nil)
    #expect(try timeline(context, task).count == 1)
    #expect(!note.isRedacted)
}

@MainActor
@Test("cancelling discards the draft in both modes")
func cancellingDiscardsTheDraft() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    composer.text = "half-typed"
    composer.cancel()
    #expect(composer.text.isEmpty)

    composer.text = "fixed PAY-42"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)
    composer.beginCorrection(of: note.id, in: [note])
    composer.cancel()

    // The abandoned correction must not survive as a new note's draft — the
    // text in the field is a copy of a note that already exists.
    #expect(composer.text.isEmpty)
    #expect(composer.mode == .adding)
}

@MainActor
@Test("correctability follows the clock")
func correctabilityFollowsTheClock() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    let clock = fixture.clock
    composer.text = "a note"
    _ = composer.commit(on: task, in: [])
    let events = try timeline(context, task)
    let note = try #require(events.first)

    composer.refreshCorrectability(in: events)
    #expect(composer.correctableEventIDs.contains(note.id))

    clock.instant = origin.addingTimeInterval(301)
    composer.refreshCorrectability(in: events)
    // This is what makes the "Correct" affordance disappear on its own.
    #expect(composer.correctableEventIDs.isEmpty)
}

@MainActor
@Test("a failed save keeps the text and explains itself")
func aFailedSaveKeepsTheText() throws {
    var shouldFail = false
    let fixture = try makeComposer(failing: { shouldFail })
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    shouldFail = true
    composer.text = "Repro'd the race"

    #expect(composer.commit(on: task, in: []))

    // CaptureFieldModel's contract: retry, don't retype.
    #expect(composer.text == "Repro'd the race")
    #expect(composer.lastError != nil)
    #expect(try timeline(context, task).isEmpty)
}

@MainActor
@Test("redacting hides the row from the timeline and stops a correction of it")
func redactingStopsACorrectionOfTheSameRow() throws {
    let fixture = try makeComposer()
    let composer = fixture.composer
    let task = fixture.task
    let context = fixture.context
    composer.text = "a mistake"
    _ = composer.commit(on: task, in: [])
    let note = try #require(try timeline(context, task).first)
    composer.beginCorrection(of: note.id, in: [note])

    #expect(composer.redact(note.id, in: [note]))

    #expect(try timeline(context, task).isEmpty)
    #expect(composer.mode == .adding)
    #expect(composer.text.isEmpty)
}
