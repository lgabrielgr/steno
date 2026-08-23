import Foundation

/// One status section of the task list (REQUIREMENTS.md FR-3).
public struct TaskGroup: Identifiable {
    public let status: Status
    public let tasks: [TaskItem]

    public var id: Status { status }
}

/// Turns a flat array of tasks into FR-3's status sections.
///
/// Pure and free-standing rather than a method on the view model: this and the
/// DONE cutoff are the two rules in the main window worth testing exhaustively,
/// and as free functions they are tested against literal arrays with no
/// container, no context, and no clock.
public enum TaskGrouping {
    /// FR-3's order, which is **not** `Status`'s declaration order.
    ///
    /// Named here, and asserted in a test, so that reordering the enum for any
    /// other reason cannot silently reorder the user's window.
    public static let order: [Status] = [.inProgress, .blocked, .todo, .done]

    /// Sections in FR-3 order, omitting any that would be empty.
    ///
    /// `doneSince` scopes the DONE section. FR-3 scopes it to the current
    /// report window; see `MainWindowModel.doneCutoff()` for why a fixed 24
    /// hours is the same answer until M2-01 lands.
    public static func groups(from tasks: [TaskItem], doneSince cutoff: Date) -> [TaskGroup] {
        order.compactMap { status in
            let matching = tasks
                .filter { task in
                    guard task.status == status else { return false }
                    guard status == .done else { return true }
                    // A DONE task with no completedAt cannot be placed in the
                    // window, so it is not shown rather than always shown.
                    guard let completedAt = task.completedAt else { return false }
                    return completedAt >= cutoff
                }
                .sorted { $0.statusChangedAt > $1.statusChangedAt }

            guard !matching.isEmpty else { return nil }
            return TaskGroup(status: status, tasks: matching)
        }
    }
}
