import Foundation

/// The detail pane's note composer: the draft, what it is doing with it, and
/// which rows are still correctable.
///
/// **In `StenoKit`, not as `@State` in the view**, for `CaptureFieldModel`'s
/// reason: D-010 puts view state beyond the headless bundle, and FR-2's
/// acceptance criteria are all statements about this logic.
///
/// **It holds no reference back to `MainWindowModel`.** Its inputs — the task,
/// the visible events — arrive as parameters, so there is no closure web to
/// initialise and no retain cycle to weaken. `MainWindowModel+Notes` is the
/// thin wrapper that supplies them and reloads when this type says to.
@Observable
@MainActor
public final class NoteComposerModel {
    /// The draft. Bound directly by the composer's `TextEditor`.
    public var text: String = ""

    public private(set) var mode: NoteComposerMode = .adding

    /// Why a correction stopped being possible, when it did. Distinct from
    /// `lastError`: nothing failed, the window simply closed.
    public private(set) var notice: String?

    /// Set when a write could not be saved. The text is kept while this is
    /// non-nil, so the user retries rather than retypes — `CaptureFieldModel`'s
    /// contract, for the same reason.
    public private(set) var lastError: String?

    /// The events still inside FR-2's window, recomputed as the clock moves.
    public private(set) var correctableEventIDs: Set<UUID> = []

    /// Bumped whenever the composer should take focus. The view watches this
    /// rather than a `Bool`, so a second request re-focuses instead of being
    /// swallowed as "already true".
    public private(set) var focusRequests = 0

    private let service: NoteService
    private let now: () -> Date

    public init(service: NoteService, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    /// `⌘↩` is live only with something to write.
    public var canCommit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// FR-2's one keystroke: `N` from the task list, `⌘⇧A` from the Task menu.
    public func requestFocus() {
        focusRequests += 1
    }

    /// Recompute which rows may still be corrected.
    ///
    /// Driven by the detail pane on a timer as well as on every reload — the
    /// "Correct" affordance has to *disappear* at five minutes, and nothing
    /// else would prompt that.
    public func refreshCorrectability(in events: [Event]) {
        let instant = now()
        correctableEventIDs = Set(
            events
                .filter {
                    NoteCorrection.isCorrectable(
                        kind: $0.kind, timestamp: $0.timestamp, isRedacted: $0.isRedacted,
                        at: instant)
                }
                .map(\.id))
    }

    /// Start correcting `eventID`, prefilled with its current body.
    ///
    /// Refuses a row that is no longer correctable rather than opening a
    /// composer whose commit is guaranteed to be refused.
    public func beginCorrection(of eventID: UUID, in events: [Event]) {
        guard let event = events.first(where: { $0.id == eventID }),
            NoteCorrection.isCorrectable(
                kind: event.kind, timestamp: event.timestamp, isRedacted: event.isRedacted,
                at: now())
        else { return }

        text = event.body
        mode = .correcting(eventID: eventID)
        notice = nil
        lastError = nil
        requestFocus()
    }

    /// `Esc`, or Cancel while correcting.
    ///
    /// **Discards the draft, in both modes.** The rule across this type is that
    /// the user cancelling discards and the system refusing does not — an
    /// abandoned correction must not survive as a new note's draft, because the
    /// text in the field is a copy of a note that already exists.
    public func cancel() {
        text = ""
        mode = .adding
        notice = nil
        lastError = nil
    }

    /// Write the draft. Never throws — a composer has nowhere to propagate to.
    ///
    /// Returns whether the window must refetch. `true` after a write **and
    /// after a failure**: a rollback keeps the refused write off disk, but what
    /// it leaves in the `Event` objects this window still holds is not
    /// dependable — measured, and it varied. Refetching is the only state worth
    /// trusting, so the failure path asks for one rather than reasoning about
    /// what survived.
    @discardableResult
    public func commit(on task: TaskItem?, in events: [Event]) -> Bool {
        guard let task, canCommit else { return false }
        let draft = text

        do {
            switch mode {
            case .adding:
                try service.addNote(draft, to: task)
                reset()
            case .correcting(let eventID):
                guard let event = events.first(where: { $0.id == eventID }) else {
                    // Redacted from another surface, or gone in a reload.
                    keepDraft("That note is no longer available — ⌘↩ adds this as a new note.")
                    return true
                }
                switch try service.correct(event, to: draft, on: task) {
                case .corrected, .unchanged:
                    reset()
                case .windowExpired, .notCorrectable:
                    keepDraft(
                        "That note can no longer be corrected — ⌘↩ adds this as a new note instead."
                    )
                }
            }
            lastError = nil
        } catch {
            Log.app.error(
                "could not save the note: \(String(describing: error), privacy: .public)")
            lastError = "Could not save the note. Your text was not saved — try again."
        }
        return true
    }

    /// §3.3's soft delete, behind the view's confirmation.
    ///
    /// Returns whether the window must refetch, on the same rule as `commit`.
    @discardableResult
    public func redact(_ eventID: UUID, in events: [Event]) -> Bool {
        guard let event = events.first(where: { $0.id == eventID }) else { return false }
        do {
            guard try service.redact(event) else { return false }
            lastError = nil
            // The row being corrected just went away underneath the composer.
            if mode == .correcting(eventID: eventID) { reset() }
        } catch {
            Log.app.error(
                "could not remove the note: \(String(describing: error), privacy: .public)")
            lastError = "Could not remove the note. Nothing was changed."
        }
        return true
    }

    /// The system refused: keep the text, drop to adding, say why.
    private func keepDraft(_ why: String) {
        mode = .adding
        notice = why
        lastError = nil
    }

    private func reset() {
        text = ""
        mode = .adding
        notice = nil
    }
}
