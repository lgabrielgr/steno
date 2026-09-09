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
    ///
    /// **False while the draft sheet is up**, which is what keeps ⌘R from
    /// silently overwriting an edited draft: `begin(window:text:)` replaces
    /// `text` unconditionally, and the sheet does not re-present, so the user
    /// would watch their own words disappear with nothing to undo. FR-4 step 6
    /// and §7.3 make the user's phrasing the final word; this is the one path
    /// that could take it away. It also protects the `.copied` state M2-04
    /// hangs undo on from being reset to `.editing`.
    public var canPrepareStandup: Bool { selectedProject != nil && activeSheet == nil }

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
        // Gates on the same property the button and menu item read, so a path
        // that bypasses the UI cannot do what the UI refuses to offer.
        guard canPrepareStandup, let project = selectedProject else { return }

        let window: GatheredWindow
        do {
            window = try ReportGatherer(context: context, now: now).gather(for: project)
        } catch {
            Log.app.error(
                "could not prepare the stand-up: \(String(describing: error), privacy: .public)")
            lastError = "Could not prepare your stand-up. Nothing was changed."
            return
        }

        // Matches `perform(_:_:)`: a success clears the banner its own failure
        // would have left behind, so a retry does not open the sheet with a
        // stale "could not prepare" message sitting behind it.
        lastError = nil

        standupDraft.begin(
            window: window,
            text: SlackMarkdown.render(RawReportSections.build(from: window)))
        activeSheet = .standupDraft
    }

    /// FR-4 step 7, from the sheet's Copy button.
    ///
    /// **The project comes from the draft's own window, not from `selection`.**
    /// The window was frozen when the user pressed Prepare, while `selection`
    /// stays live — and "Next Project" (⌘⌥↓) is reachable from the menu while
    /// this sheet is up. Reading `selection` here would hand one project's
    /// window to another project's row, which the service refuses, leaving the
    /// user in a sheet whose only advice ("try again") can never work. Resolving
    /// from the window makes the draft self-contained: what the user reviewed is
    /// what gets committed, whatever the sidebar has since done.
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
        guard let projectID = standupDraft.window?.projectID,
            let project = project(withID: projectID)
        else { return }
        if standupDraft.commit(to: project) { reload() }
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    public func dismissStandupDraft() {
        standupDraft.dismiss()
        activeSheet = nil
    }
}
