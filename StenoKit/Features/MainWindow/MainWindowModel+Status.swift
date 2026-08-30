import Foundation

/// M1-05's status actions, split out of `MainWindowModel.swift` to keep that
/// file under SwiftLint's `file_length` limit. Same type, same rules: the
/// view never sees a `ModelContext`, it calls the model, which holds the
/// service — exactly as `captureService()` arranges for capture.
///
/// **A successful write here reloads twice: once via the `.stenoDidWrite`
/// observer, once explicitly.** Deliberate, for the same reason the
/// registration in `MainWindowModel` gives about the New Task sheet — that
/// observer exists for writes from *other* surfaces, and a caller that leans
/// on it to see its own write breaks silently the day the observer is scoped
/// to ignore self-originated posts. `reload()` is idempotent and writes
/// nothing, so the cost is one extra fetch over a dataset D18 caps.
/// A write that did not happen reloads zero times — see the guards below.
extension MainWindowModel {
    /// D-033's one path for status, over this window's context.
    private func statusService() -> StatusService {
        StatusService(context: context, now: now, save: save)
    }

    /// Move a task, then offer a reason if it just became blocked.
    public func setStatus(_ new: Status, on taskID: UUID) {
        guard let task = task(withID: taskID) else { return }
        do {
            let changed = try statusService().setStatus(new, on: task)
            lastError = nil
            // Nothing written means nothing to fetch: a no-op transition saved
            // no rows and posted no notification, so a reload here would refetch
            // state that cannot have moved.
            guard changed else { return }
            reload()
            // Reachable only on a real transition, because the no-op returned
            // above — so this never offers to annotate an event that does not
            // exist.
            if new == .blocked { activeSheet = .blockedReason(taskID) }
        } catch {
            Log.app.error(
                "could not change the status: \(String(describing: error), privacy: .public)")
            lastError = "Could not change the status. Your change was not saved."
            // Not cosmetic: `rollback()` leaves the held task reporting the
            // rejected status, and it is this fetch that refreshes it. Without
            // it the window would show a status the store refused (D-018).
            reload()
        }
    }

    /// §3.3's optional reason, committed after the transition.
    public func addBlockedReason(_ text: String, to taskID: UUID) {
        guard let task = task(withID: taskID) else { return }
        do {
            let added = try statusService().addBlockedReason(text, to: task)
            lastError = nil
            // Same rule as `setStatus`: a rejected reason — blank after
            // trimming, or the task is no longer blocked — wrote nothing.
            guard added else { return }
            reload()
        } catch {
            Log.app.error(
                "could not save the blocked reason: \(String(describing: error), privacy: .public)")
            lastError = "Could not save the reason. Your change was not saved."
            reload()
        }
    }

    public func cycleStatusOnSelection() {
        guard let id = selectedTaskID, let task = task(withID: id) else { return }
        setStatus(task.status.next, on: id)
    }

    public func markSelectionBlocked() {
        guard let id = selectedTaskID else { return }
        setStatus(.blocked, on: id)
    }
}
