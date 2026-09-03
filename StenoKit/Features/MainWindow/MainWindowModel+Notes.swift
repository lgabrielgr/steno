import Foundation

/// FR-2's note actions: the thin layer between the composer and the store.
///
/// `NoteComposerModel` holds the draft and decides what a write means;
/// this supplies the two things it deliberately does not hold — the selected
/// task and the visible timeline — and reloads when it says to.
///
/// **Every path that can fail reloads**, because what `rollback()` leaves
/// behind depends on the shape of the transaction and no caller should have to
/// know which it got. Measured during M1-06: a failed `redact(_:)` — a pure
/// mutation — leaves the held `Event` still reporting the rejected
/// `isRedacted`, matching `+Status.swift`; a failed `correct(_:to:on:)`, whose
/// transaction also carries an insert, re-faults the held object back to its
/// clean stored value. Reloading is correct under both, and a caller that
/// reasons about only one of them is right by accident.
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
