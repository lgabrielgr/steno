import Foundation

/// Which half of FR-4's flow the draft sheet is showing.
public enum StandupDraftPhase: Equatable, Sendable {
    /// Step 6: the editable draft, nothing written yet.
    case editing
    /// Step 7 has run. The store is committed; the sheet stays up.
    case copied
}

/// FR-4 steps 6–7: the draft, what the user did to it, and what Copy did.
///
/// **In `StenoKit`, not as `@State` in the sheet**, for `NoteComposerModel`'s
/// reason: D-010 puts view state beyond the headless bundle, and this task's
/// acceptance criteria — the draft is editable and the *edited* text is what
/// reaches the clipboard and `markdownBody`, Copy applies all its effects or
/// none — are all statements about this logic.
///
/// **It holds no reference back to `MainWindowModel`.** Its inputs — the
/// window, the project — arrive as parameters, so there is no closure web to
/// initialise and no retain cycle to weaken. `MainWindowModel+Standup` is the
/// thin wrapper that supplies them and reloads when this type says to.
@Observable
@MainActor
public final class StandupDraftModel {
    /// The draft. Bound directly by the sheet's `TextEditor`, so every
    /// keystroke lands here and `commit` reads it back verbatim.
    public var text: String = ""

    public private(set) var phase: StandupDraftPhase = .editing

    /// The window the draft was built from, frozen at generate time.
    ///
    /// **Frozen, not recomputed at Copy.** A user who previews at 09:00 and
    /// copies at 09:30 copies the 09:00 window — re-gathering would either
    /// discard their edits or contradict them, and FR-4 step 6's editable draft
    /// would become a lie. D-076 makes that safe rather than merely
    /// defensible: the clock advances to this window's end, so anything
    /// captured in between lands in the next report rather than in a gap.
    public private(set) var window: GatheredWindow?

    /// Set when the write could not be saved. The text is kept while this is
    /// non-nil so the user retries rather than retypes — `CaptureFieldModel`'s
    /// contract, for the same reason.
    public private(set) var lastError: String?

    /// Set when nothing failed to save but the user still needs telling — the
    /// report was recorded and the clipboard refused it.
    ///
    /// Its own property rather than a reading of `lastError`, for
    /// `NoteComposerModel`'s reason: one means the write failed and retrying is
    /// safe, the other means the write succeeded and retrying would report the
    /// window twice. A single field cannot say which.
    public private(set) var notice: String?

    private let service: StandupService

    public init(service: StandupService) {
        self.service = service
    }

    /// Copy is live only with a window to commit, and only once.
    public var canCopy: Bool { window != nil && phase == .editing }

    /// FR-4 steps 5–6: show `text` as the draft for `window`.
    ///
    /// Writes nothing. Every caller reaches this through
    /// `MainWindowModel.prepareStandup()`, which gathers and renders and does
    /// nothing else — which is what makes "generating a preview has zero side
    /// effects" true by construction rather than by care.
    public func begin(window: GatheredWindow, text: String) {
        self.window = window
        self.text = text
        phase = .editing
        lastError = nil
        notice = nil
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    ///
    /// Discards the draft in every case. The draft belongs to the moment it was
    /// generated and regenerating is free of side effects, so there is nothing
    /// worth preserving — and a draft surviving into the next Copy would let
    /// one project's edited prose be filed against another project's window.
    public func dismiss() {
        window = nil
        text = ""
        phase = .editing
        lastError = nil
        notice = nil
    }

    /// FR-4 step 7. Never throws — a sheet has nowhere to propagate to.
    ///
    /// Returns whether the window must refetch. `false` only when nothing was
    /// attempted; **`true` after a failure**, because a rollback keeps the
    /// refused write off disk but what it leaves in the objects this window
    /// still holds is not dependable (D-051). Refetching is the only state
    /// worth trusting.
    @discardableResult
    public func commit(to project: Project) -> Bool {
        guard let window, phase == .editing else { return false }
        // Read once so the clipboard and `markdownBody` are provably the same
        // string. Not a concurrency guard — this method is synchronous and
        // `@MainActor`, with no suspension point for a keystroke to land in.
        let draft = text

        do {
            let result = try service.commit(draft, of: window, for: project)
            phase = .copied
            lastError = nil
            notice =
                result.didReachClipboard
                ? nil
                : "Your stand-up was recorded, but the clipboard refused it. "
                    + "Select the text above and copy it manually."
        } catch {
            Log.app.error(
                "could not copy the stand-up: \(String(describing: error), privacy: .public)")
            // Stays `.editing` with `text` untouched: the store rolled back, so
            // pressing Copy again is safe and is the obvious next move.
            lastError = "Could not copy your stand-up. Nothing was saved — try again."
        }
        return true
    }
}
