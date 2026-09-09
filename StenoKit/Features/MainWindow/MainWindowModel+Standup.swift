import Foundation

/// FR-4's stand-up actions: the thin layer between the draft sheet and the
/// store.
///
/// `StandupDraftModel` holds the draft and decides what a Copy means; this
/// supplies the one thing it deliberately does not hold — the selected project
/// — and reloads when it says to. The same split `MainWindowModel+Notes` makes
/// for FR-2, for the same reason.
extension MainWindowModel {
    /// FR-4 needs exactly one project to report on.
    ///
    /// D16 — "each meeting covers exactly one project" — and `lastStandupAt` is
    /// per-project, so the "All" pseudo-project has no coherent answer: there
    /// is no single window to compute and no single clock to advance. The
    /// footer button and the ⌘R menu item both read this, so they cannot
    /// disagree about when the action is live.
    public var canPrepareStandup: Bool { selectedProject != nil }

    /// The project the stand-up acts on, or `nil` under "All".
    ///
    /// Resolved through `projects` rather than from `selection` alone, so a
    /// project archived from another surface stops being reportable the moment
    /// this model reloads.
    var selectedProject: Project? {
        guard case .project(let id) = selection else { return nil }
        return project(withID: id)
    }

    /// FR-4 steps 1–6: gather, render, and show the draft.
    ///
    /// **Writes nothing, and there is no write path here to fail on.**
    /// `ReportGatherer` has no `save` parameter and no `commit()` — D-065
    /// records that absence as the design — and rendering is two pure
    /// functions. That is what makes "the user can generate repeatedly, close
    /// the sheet, and their window is untouched" true by construction.
    ///
    /// A failed gather does **not** open the sheet: the error goes to the
    /// window's existing inline banner instead. A modal whose only content is
    /// an error asks the user to dismiss something they did not summon.
    public func prepareStandup() {
        guard let project = selectedProject else { return }

        let window: GatheredWindow
        do {
            window = try ReportGatherer(context: context, now: now).gather(for: project)
        } catch {
            Log.app.error(
                "could not prepare the stand-up: \(String(describing: error), privacy: .public)")
            lastError = "Could not prepare your stand-up. Nothing was changed."
            return
        }

        standupDraft.begin(
            window: window,
            text: SlackMarkdown.render(RawReportSections.build(from: window)))
        activeSheet = .standupDraft
    }

    /// FR-4 step 7, from the sheet's Copy button.
    ///
    /// Reloads on every outcome the draft model reports, including failures —
    /// see `StandupDraftModel.commit(to:)` for why a rollback is not something
    /// to reason about from the objects still in hand.
    ///
    /// A successful Copy reloads twice: `StandupService` posts `.stenoDidWrite`
    /// synchronously, which this window's own observer turns into a `reload()`,
    /// and then this line reloads again. Known and harmless — `reload()` is
    /// idempotent — and the same shape `MainWindowModel+Notes` documents.
    /// The reload is load-bearing here beyond the timeline: advancing
    /// `lastStandupAt` moves FR-3's DONE cutoff for this project, so the task
    /// list is stale until it runs.
    public func copyStandup() {
        guard let project = selectedProject else { return }
        if standupDraft.commit(to: project) { reload() }
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    public func dismissStandupDraft() {
        standupDraft.dismiss()
        activeSheet = nil
    }
}
