import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 steps 6–7 as the sheet sees them.

/// A string the renderer would never produce, so "the edited text wins" cannot
/// pass against an implementation that re-renders the window.
private let editedDraft = "the user rewrote every word of this by hand"

@MainActor
private func draftReadyToCopy(
    _ fixture: ReportFixture,
    save: @escaping (ModelContext) throws -> Void = { try $0.save() },
    copy: @escaping @MainActor (String) -> Bool = { _ in true }
) throws -> (model: StandupDraftModel, window: GatheredWindow) {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900, save: save, copy: copy),
        undoService: fixture.standupUndoService(save: save))
    model.begin(window: window, text: "generated text")
    return (model, window)
}

@MainActor
@Test("beginning a draft shows the generated text and writes nothing")
func beginShowsTheDraft() throws {
    let fixture = try ReportFixture()
    let counter = WriteCounter()
    let (model, window) = try draftReadyToCopy(fixture)

    #expect(model.text == "generated text")
    #expect(model.phase == .editing)
    #expect(model.window == window)
    #expect(model.canCopy)
    #expect(counter.posts == 0)
    #expect(try fixture.reportsInStore().isEmpty)
}

@MainActor
@Test("the user's edit is what gets persisted, not the generated text")
func theEditedTextIsWhatCommits() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)

    // FR-4 step 6 and §7.3: the user's own last-second correction is the final
    // word. This is that requirement as an assertion.
    model.text = editedDraft
    #expect(model.commit(to: fixture.alpha))

    #expect(model.phase == .copied)
    #expect(model.lastError == nil)
    #expect(model.notice == nil)
    #expect(try fixture.reportsInStore().first?.markdownBody == editedDraft)
}

@MainActor
@Test("a failed Copy keeps the draft editable and the user's text intact")
func failedCopyKeepsTheText() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture, save: { _ in throw Boom() })
    model.text = editedDraft

    #expect(model.commit(to: fixture.alpha), "a failure still asks the window to refetch")

    // `CaptureFieldModel`'s contract: the user retries, never retypes. Staying
    // in `.editing` is what makes pressing Copy again the obvious next move,
    // and the store rolled back so it is also the safe one.
    #expect(model.phase == .editing)
    #expect(model.text == editedDraft)
    #expect(model.lastError != nil)
    #expect(model.canCopy)
}

@MainActor
@Test("a refused clipboard reports itself without claiming the save failed")
func refusedClipboardIsANoticeNotAnError() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture, copy: { _ in false })

    #expect(model.commit(to: fixture.alpha))

    // Two channels, because retrying is safe after a failed save and would
    // double-report after a refused clipboard. `lastError` must stay nil: the
    // write succeeded.
    #expect(model.phase == .copied)
    #expect(model.lastError == nil)
    #expect(model.notice != nil)
    #expect(try fixture.reportsInStore().count == 1)
}

@MainActor
@Test("Copy is refused a second time")
func copyIsNotRepeatable() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    #expect(model.commit(to: fixture.alpha))

    // Without this the confirmed sheet's Copy would report the same window
    // twice, advancing nothing but appending a second report and a second set
    // of events — which M2-04 could then only half undo.
    #expect(model.canCopy == false)
    #expect(model.commit(to: fixture.alpha) == false)
    #expect(try fixture.reportsInStore().count == 1)
}

@MainActor
@Test("dismissing discards the draft so it cannot be filed against the next project")
func dismissDiscardsTheDraft() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    model.text = editedDraft
    // Commit first, so `phase` is `.copied` going in and the reset below is a
    // proven clear rather than a value that was already correct.
    #expect(model.commit(to: fixture.alpha))
    #expect(model.phase == .copied, "precondition")

    model.dismiss()

    #expect(model.text.isEmpty)
    #expect(model.window == nil)
    #expect(model.canCopy == false)
    #expect(model.phase == .editing)
}

@MainActor
@Test("committing with no window does nothing")
func commitWithoutAWindowIsANoOp() throws {
    let fixture = try ReportFixture()
    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900),
        undoService: fixture.standupUndoService())

    #expect(model.commit(to: fixture.alpha) == false)
    #expect(try fixture.reportsInStore().isEmpty)
}

@MainActor
@Test("a successful retry clears the error the failed attempt left behind")
func successfulRetryClearsTheError() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    // One mutable flag rather than two services: the model holds its service
    // for life, so the only way to fail once and then succeed is for the
    // injected save to change its mind.
    // Still `nonisolated(unsafe)`, unlike the clipboard seam: this is captured by
    // the `save` closure, which is `(ModelContext) throws -> Void` across every
    // service in the app and is not main-actor-bound. Annotating that one is a
    // wider change than this task owns.
    nonisolated(unsafe) var shouldFail = true
    let flakySave: (ModelContext) throws -> Void = { context in
        if shouldFail { throw Boom() }
        try context.save()
    }
    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900, save: flakySave),
        undoService: fixture.standupUndoService(save: flakySave))
    model.begin(window: window, text: editedDraft)

    #expect(model.commit(to: fixture.alpha))
    #expect(model.lastError != nil, "precondition: the first attempt failed")

    shouldFail = false
    #expect(model.commit(to: fixture.alpha))

    // Without `lastError = nil` on the success branch, the sheet shows
    // "Nothing was saved — try again" in red directly beneath the bold
    // "Copied to clipboard" headline — the contradiction D-082 exists to
    // prevent, in the one state that reaches it.
    #expect(model.phase == .copied)
    #expect(model.lastError == nil)
    #expect(try fixture.reportsInStore().count == 1)
}

@MainActor
@Test("FR-4.1: undo moves the sheet to its third phase and closes Copy off")
func undoMovesTheSheetToUndone() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    #expect(model.canUndo == false, "nothing has been copied yet")

    #expect(model.commit(to: fixture.alpha))
    #expect(model.canUndo, "the sheet's Undo button is live the moment Copy lands")
    #expect(model.committedReport != nil)

    #expect(model.undo(to: fixture.alpha))

    #expect(model.phase == .undone)
    #expect(model.canUndo == false, "undo is not itself undoable")
    #expect(model.canCopy == false, "this window has already been reported once")
    #expect(model.lastError == nil)
    #expect(try fixture.reportsInStore().first?.isUndone == true)
}

@MainActor
@Test("a refused clipboard's notice does not outlive the report it described")
func undoClearsTheClipboardNotice() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture, copy: { _ in false })

    #expect(model.commit(to: fixture.alpha))
    #expect(model.notice != nil, "precondition: the clipboard refused the write")

    #expect(model.undo(to: fixture.alpha))

    // Left standing, the notice would tell the user to select and copy the text
    // manually — for a stand-up the app has just taken back.
    #expect(model.notice == nil)
    #expect(model.phase == .undone)
}

@MainActor
@Test("undoing before anything was copied does nothing")
func undoBeforeCopyIsANoOp() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)

    #expect(model.undo(to: fixture.alpha) == false)
    #expect(model.phase == .editing)
    #expect(try fixture.reportsInStore().isEmpty)
}

@MainActor
@Test("a failed undo keeps the sheet where it was, so pressing it again is safe")
func aFailedUndoKeepsTheCopiedPhase() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    // Succeeds for the Copy, then refuses the undo — the model holds its
    // services for life, so the only way to fail the second write and not the
    // first is for the injected save to change its mind.
    nonisolated(unsafe) var shouldFail = false
    let (model, _) = try draftReadyToCopy(
        fixture,
        save: { context in
            if shouldFail { throw Boom() }
            try context.save()
        })

    #expect(model.commit(to: fixture.alpha))
    shouldFail = true

    #expect(model.undo(to: fixture.alpha), "a rollback still asks the window to refetch (D-051)")

    #expect(model.phase == .copied, "still undoable — the store rolled back")
    #expect(model.canUndo)
    #expect(model.lastError != nil)
    #expect(try fixture.reportsInStore().first?.isUndone == false)
}

@MainActor
@Test("beginning a new draft forgets the report the last one committed")
func beginClearsTheCommittedReport() throws {
    let fixture = try ReportFixture()
    let (model, window) = try draftReadyToCopy(fixture)
    #expect(model.commit(to: fixture.alpha))
    #expect(model.committedReport != nil, "precondition")

    model.begin(window: window, text: "a fresh draft")

    // Otherwise ⌘R over a committed sheet would leave Undo pointing at the
    // previous report while the text on screen belongs to a new one.
    #expect(model.committedReport == nil)
    #expect(model.canUndo == false)
    #expect(model.phase == .editing)
}

@MainActor
@Test("dismissing forgets the report too")
func dismissClearsTheCommittedReport() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    #expect(model.commit(to: fixture.alpha))

    model.dismiss()

    #expect(model.committedReport == nil)
    #expect(model.canUndo == false)
}
