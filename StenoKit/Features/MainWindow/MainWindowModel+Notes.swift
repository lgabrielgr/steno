import Foundation

/// FR-2's note actions: the thin layer between the composer and the store.
///
/// `NoteComposerModel` holds the draft and decides what a write means;
/// this supplies the two things it deliberately does not hold — the selected
/// task and the visible timeline — and reloads when it says to.
///
/// **Every path that can fail reloads.** What a rollback leaves in the
/// `Event` objects the window still holds is not dependable — measured twice
/// during M1-06, with contradictory results that tracked the composition of
/// the test suite rather than anything about the code under test. What *is*
/// dependable is that the store itself was left clean. So the failure path
/// refetches rather than reasoning about what survived.
extension MainWindowModel {
    /// FR-3 gates its shortcuts on having a subject.
    public var canAddNote: Bool { selectedTaskID != nil }

    /// FR-2's one keystroke — `N` from the task list, `⌘⇧A` from the Task menu.
    /// Both only move focus; nothing is written until `⌘↩`.
    public func addNoteToSelection() {
        guard canAddNote else { return }
        noteComposer.requestFocus()
    }

    /// Begin FR-2's grace-period correction of one event.
    public func beginNoteCorrection(of eventID: UUID) {
        noteComposer.beginCorrection(of: eventID, in: selectedTaskEvents)
    }

    /// Commit the draft — a new note, or a correction.
    public func commitNote() {
        // Named `subject`, not `task`: `let task = … { task(withID: $0) }`
        // shadows the method with the constant being declared, and Swift 6
        // reports it as "failed to produce diagnostic for expression" rather
        // than as the shadowing it is.
        let subject = selectedTaskID.flatMap { task(withID: $0) }
        // A successful write reloads twice: `NoteService.commit()` posts
        // `.stenoDidWrite` synchronously, which this window's own observer
        // turns into a `reload()`, and then this line reloads again on the
        // returned `true`. Known and harmless — `reload()` is idempotent —
        // and the same shape as the `NewTaskSheet` case documented in
        // `MainWindowModel.swift` (`redactEvent` below is the third instance).
        // Left alone rather than deduplicated: the return value is what tells
        // *this* call site the write happened, and the notification is what
        // serves surfaces with no return value to read. Deleting either one
        // silently breaks the other's case.
        if noteComposer.commit(on: subject, in: selectedTaskEvents) { reload() }
    }

    /// §3.3's soft delete, behind the timeline's confirmation.
    public func redactEvent(_ eventID: UUID) {
        if noteComposer.redact(eventID, in: selectedTaskEvents) { reload() }
    }

    /// Re-evaluate FR-2's window against the clock.
    ///
    /// Driven by the detail pane's timer. Its own method rather than a full
    /// `reload()` because it must not fetch: it fires every few seconds, and
    /// the answer depends only on `now()` and events already in hand.
    public func refreshNoteCorrectability() {
        noteComposer.refreshCorrectability(in: selectedTaskEvents)
    }
}
