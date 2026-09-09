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

    /// `doneSince` scopes the DONE section to FR-3's "current report window".
    ///
    /// **A function of the task, not one date for the whole list** (D-077).
    /// Under the "All" pseudo-project the visible tasks span projects with
    /// different `lastStandupAt` values and different cadences, and a single
    /// cutoff has to pick one of them. The only safe pick — the earliest across
    /// visible projects — leaks a `periodic` project's fortnight-wide window
    /// into a `daily` project's DONE section, showing two weeks of finished
    /// work under a heading FR-3 scopes to one day.
    ///
    /// This stays free of `Project` and of the store: the caller resolves each
    /// task's window, so this remains testable against literal arrays with no
    /// container, no context, and no clock.
    public static func groups(
        from tasks: [TaskItem], doneSince cutoff: (TaskItem) -> Date
    ) -> [TaskGroup] {
        order.compactMap { status in
            let matching =
                tasks
                .filter { task in
                    guard task.status == status else { return false }
                    guard status == .done else { return true }
                    // A DONE task with no completedAt cannot be placed in the
                    // window, so it is not shown rather than always shown.
                    guard let completedAt = task.completedAt else { return false }
                    return completedAt >= cutoff(task)
                }
                .sorted { $0.statusChangedAt > $1.statusChangedAt }

            guard !matching.isEmpty else { return nil }
            return TaskGroup(status: status, tasks: matching)
        }
    }
}
