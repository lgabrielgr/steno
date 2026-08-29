import Foundation

/// M1-05's status actions, split out of `MainWindowModel.swift` to keep that
/// file under SwiftLint's `file_length` limit. Same type, same rules: the
/// view never sees a `ModelContext`, it calls the model, which holds the
/// service — exactly as `captureService()` arranges for capture.
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
            reload()
            // Only on a real transition. Re-selecting BLOCKED on a task that is
            // already blocked wrote nothing, so prompting for a reason would
            // offer to annotate an event that does not exist.
            if changed, new == .blocked { activeSheet = .blockedReason(taskID) }
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
            try statusService().addBlockedReason(text, to: task)
            lastError = nil
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
