import Foundation
import SwiftData

/// The one write path shared by everything in this window that has no
/// service behind it.
///
/// Split out of `MainWindowModel.swift` for the reason `+Status` and
/// `+Standup` were: SwiftLint's `file_length` limit, not a change in what
/// belongs together. M2.5-03's portability properties pushed the main file
/// over 400 lines.
extension MainWindowModel {

    /// Apply a mutation, save it, and reload — rolling back if the save fails.
    ///
    /// **The rollback is load-bearing.** Without it a failed save leaves the
    /// object sitting in the context, the reload finds it, and the window
    /// displays a task that is not on disk. For a capture tool, silently
    /// accepting a write that evaporates is worse than refusing it, because
    /// the loss surfaces at the next stand-up (D-018, §1.1).
    ///
    /// `what` is an infinitive phrase — it is interpolated into both the log
    /// line and the user-facing message.
    ///
    /// Returns whether the save succeeded, so callers can make follow-up state
    /// changes conditional on it — `rollback()` restores the store, not the UI.
    @discardableResult
    func perform(_ what: String, _ mutation: () -> Void) -> Bool {
        mutation()
        var saved = true
        do {
            try save(context)
            lastError = nil
        } catch {
            context.rollback()
            // One interpolated literal: OSLogMessage has no `+` operator.
            Log.app.error(
                "could not \(what, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not \(what). Your change was not saved."
            saved = false
        }
        reload()

        // Project writes are the one write kind with no service behind them —
        // they go straight through this method — so this is their post site,
        // and D-031's "posted at the write" now covers all four kinds rather
        // than three. Without it a cache of projects held anywhere else goes
        // stale: FR-6's default-project picker kept offering a project the user
        // had just archived, and the menu bar popover kept listing its tasks.
        //
        // Only on success, for the reason `MainWindowModel+Status` gives about
        // no-op transitions: a save that failed was rolled back, and telling
        // every surface to refetch would announce a write that did not happen.
        //
        // After `reload()`, so this model is consistent by the time the others
        // read. Its own observer then reloads a second time — the same
        // idempotent double-reload `+Status` documents, over a dataset D18
        // caps.
        if saved { NotificationCenter.default.post(name: .stenoDidWrite, object: nil) }
        return saved
    }
}
