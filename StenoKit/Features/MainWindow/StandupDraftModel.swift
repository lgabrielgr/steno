import Foundation

/// Which half of FR-4's flow the draft sheet is showing.
public enum StandupDraftPhase: Equatable, Sendable {
    /// Step 6: the editable draft, nothing written yet.
    case editing
    /// Step 7 has run. The store is committed; the sheet stays up.
    case copied
    /// FR-4.1 has run against the report step 7 wrote. The store is back where
    /// Copy found it, and there is nothing left to do but close.
    case undone
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

    /// The row Copy wrote, which FR-4.1's undo acts on.
    ///
    /// M2-03 discarded this value: `commit(to:)` read `didReachClipboard` off
    /// the result and dropped the report. Undo is what needs it — the sheet
    /// undoes *the report it just wrote*, not "whatever is most recent", so
    /// that identity has to survive the commit rather than be re-derived.
    public private(set) var committedReport: StandupReport?

    /// Whether §7.3's call is still in flight (D-148).
    ///
    /// Drives the sheet's "Polishing…" affordance and nothing else. **Copy is
    /// deliberately live while this is true**: the text on screen is M2-02's
    /// raw report, which is a usable stand-up, and §7.4's promise is that the
    /// user is never left holding nothing while a network call decides.
    public private(set) var isPolishing = false

    /// The model that produced the text now on screen, or `nil` for the raw
    /// report (D-151).
    ///
    /// Set in exactly one place — `install(_:)` — and never cleared while the
    /// draft stands, so editing AI text keeps the report marked AI-generated.
    /// That is the honest record: it *was* AI-generated, and FR-4 step 6
    /// intends the user to polish it.
    public private(set) var aiModelUsed: String?

    /// The text as last installed, against which "has the user typed?" is
    /// answered.
    ///
    /// **A stored string rather than a dirty flag.** A user who types and then
    /// undoes back to the original still receives the upgrade, which is what
    /// they would expect, and it costs one comparison.
    private var pristineText = ""

    private var polishTask: Task<Void, Never>?

    /// Which polish `isPolishing` is describing.
    ///
    /// **Cancellation is cooperative, so a superseded call still finishes** (PR
    /// #37 review). Dismissing a sheet and preparing another one inside D-145's
    /// twenty-second budget leaves the first call suspended on the network; it
    /// resumes, finds the phase and the text guards against it, and — without
    /// this — has already cleared `isPolishing` for the *second* call on its way
    /// past. The sheet then drops "Polishing…" while a draft is still in
    /// flight. Bumped by `begin` and by `dismiss`, so a result whose generation
    /// has moved on touches no state at all.
    private var polishGeneration = 0

    private let service: StandupService
    private let undoService: StandupUndoService
    private let polish: @MainActor (GatheredWindow) async -> SummarizedStandup

    /// - Parameter polish: §7.3's call, injected as a closure for the reason
    ///   `service` and `copy` are injected — a seam the headless suite can
    ///   drive without a provider, a credential, or a network (§9.4).
    ///
    ///   **`@MainActor`, like `copy`.** The work inside it is one string build
    ///   and then a suspension on the network, so nothing blocks; isolating the
    ///   closure is what lets the composition root capture `AppSettings` and
    ///   read the selected model at call time rather than at launch.
    ///
    ///   **The default performs no polish**, returning the same raw report the
    ///   caller already rendered. That is not a stub: it is exactly what an
    ///   unconfigured install does, and it is what every launch does until
    ///   M3-04 ships the key field and the model picker.
    public init(
        service: StandupService,
        undoService: StandupUndoService,
        polish: @escaping @MainActor (GatheredWindow) async -> SummarizedStandup = {
            SummarizedStandup(markdown: StandupSummarizer.rawMarkdown(for: $0), modelUsed: nil)
        }
    ) {
        self.service = service
        self.undoService = undoService
        self.polish = polish
    }

    /// Copy is live only with a window to commit, and only once.
    public var canCopy: Bool { window != nil && phase == .editing }

    /// Undo is live only over a report this sheet actually wrote, and only
    /// before it has been undone.
    ///
    /// Reads `committedReport` as well as `phase` rather than `phase` alone:
    /// the two are set together, but a `.copied` phase with no report is a
    /// state `undo(to:)` would have to refuse anyway, and a button that is live
    /// only to refuse is worse than one that is not offered.
    public var canUndo: Bool { committedReport != nil && phase == .copied }

    /// FR-4 steps 5–6: show `text` as the draft for `window`.
    ///
    /// Writes nothing. Every caller reaches this through
    /// `MainWindowModel.prepareStandup()`, which gathers and renders and does
    /// nothing else — which is what makes "generating a preview has zero side
    /// effects" true by construction rather than by care.
    /// **Starting the polish is this method's job, not a second call the
    /// caller must remember** (D-148). A step that cannot be forgotten beats
    /// one documented as required, and every path into the sheet goes through
    /// here.
    public func begin(window: GatheredWindow, text: String) {
        polishTask?.cancel()
        self.window = window
        self.text = text
        pristineText = text
        phase = .editing
        committedReport = nil
        lastError = nil
        notice = nil
        aiModelUsed = nil
        isPolishing = true
        polishGeneration &+= 1
        let generation = polishGeneration
        polishTask = Task { [weak self] in
            let result = await self?.polish(window)
            guard let self, let result else { return }
            install(result, from: generation)
        }
    }

    /// The AI draft, if it is still wanted (D-148).
    ///
    /// Four conditions, and each one is a way the result stops being wanted:
    /// the task was cancelled, the sheet moved past `.editing`, the user typed,
    /// or the summarizer fell back.
    ///
    /// **Nothing is installed when `modelUsed` is `nil`.** The fallback markdown
    /// is byte-identical to the text `begin` already installed — same pure
    /// functions, same frozen window — so assigning it would be a no-op that
    /// relied on that coincidence. Skipping it makes the no-op a fact about the
    /// branch instead.
    private func install(_ result: SummarizedStandup, from generation: Int) {
        // Before anything, including `isPolishing`: a superseded call answers
        // for a draft that is no longer on screen, and the sheet's in-flight
        // state belongs to whichever call is current.
        guard generation == polishGeneration else { return }

        isPolishing = false
        guard !Task.isCancelled, phase == .editing, text == pristineText,
            let model = result.modelUsed
        else { return }

        text = result.markdown
        pristineText = result.markdown
        aiModelUsed = model
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    ///
    /// Discards the draft in every case. The draft belongs to the moment it was
    /// generated and regenerating is free of side effects, so there is nothing
    /// worth preserving — and a draft surviving into the next Copy would let
    /// one project's edited prose be filed against another project's window.
    public func dismiss() {
        polishTask?.cancel()
        polishTask = nil
        polishGeneration &+= 1
        isPolishing = false
        window = nil
        text = ""
        pristineText = ""
        phase = .editing
        committedReport = nil
        lastError = nil
        notice = nil
        aiModelUsed = nil
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
        // The window is about to be reported; a draft that arrived after this
        // could not be installed anyway (`install` requires `.editing`), and
        // leaving the call in flight would keep "Polishing…" on screen above a
        // stand-up that has already been copied.
        polishTask?.cancel()
        isPolishing = false
        // Read once so the clipboard and `markdownBody` are provably the same
        // string. Not a concurrency guard — this method is synchronous and
        // `@MainActor`, with no suspension point for a keystroke to land in.
        let draft = text

        do {
            let result = try service.commit(
                draft, of: window, for: project, modelUsed: aiModelUsed)
            phase = .copied
            committedReport = result.report
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

    /// FR-4.1, from the sheet's Undo button. Never throws, for `commit(to:)`'s
    /// reason — a sheet has nowhere to propagate to.
    ///
    /// Returns whether the window must refetch, on the same contract:
    /// `false` only when nothing was attempted, and **`true` after a failure**,
    /// because what a rolled-back write leaves in the objects this window still
    /// holds is not dependable (D-051).
    ///
    /// **The clipboard is deliberately untouched.** The markdown is already in
    /// the user's paste buffer and may already be in Slack; §7 of this task's
    /// design records why putting it back is neither possible to verify nor one
    /// of the three effects FR-4.1 names.
    @discardableResult
    public func undo(to project: Project) -> Bool {
        guard let committedReport, phase == .copied else { return false }

        do {
            try undoService.undo(committedReport, for: project)
            phase = .undone
            lastError = nil
            // Cleared, not kept: it said the clipboard refused a report that no
            // longer exists, so leaving it up would have the sheet advising the
            // user to copy text for a stand-up it has just taken back.
            notice = nil
        } catch {
            Log.app.error(
                "could not undo the stand-up: \(String(describing: error), privacy: .public)")
            // Stays `.copied` with `committedReport` intact: the store rolled
            // back, so pressing Undo again is safe and is the obvious next move.
            lastError = "Could not undo your stand-up. Nothing was changed — try again."
        }
        return true
    }
}
