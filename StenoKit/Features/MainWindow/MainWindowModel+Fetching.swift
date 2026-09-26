import Foundation
import SwiftData

/// FR-3's list queries: which projects and tasks the window shows.
///
/// **Split out for `file_length`, not because the responsibility differs** —
/// the same reason `MainWindowModel+Status.swift` holds the status actions, and
/// the note in this model's `MainWindowActions` section says so. M4-01 pushed
/// the main file three lines past the limit; these three functions are the
/// coherent group to move, because `reload()` is their only caller and they are
/// the only members that read the store to build a list.
///
/// The three are `internal` rather than `private` because `reload()` stays in
/// `MainWindowModel.swift`, and `private` is file-scoped. No wider than the
/// members the other five extensions already reach.
extension MainWindowModel {
    func fetchProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return fetch(descriptor, "load your projects")
    }

    /// FR-3's "current report window", for one task.
    ///
    /// **This used to be a flat `now() - 24h`**, correct only because
    /// `lastStandupAt` stayed nil until M2-03 shipped the Copy action that
    /// advances it. M2-03 shipped it, so the constant became a live FR-3
    /// violation the first time the user copied a stand-up — the shape of
    /// documented exception that is really a bug filed against whichever task
    /// makes it reachable.
    ///
    /// Delegates to `ReportWindow.bounds` rather than restating the rule, which
    /// also keeps the first-run case right for free: a project never reported
    /// on still gets 24 hours, from the one place that decision lives (D-077).
    ///
    /// The `nil` path — a task whose project is not in `projects` — is
    /// unreachable by construction rather than merely unlikely: `fetchTasks()`
    /// filters against the same `projects` snapshot this resolves through, and
    /// `reload()` assigns `projects` first with no suspension point between.
    /// It resolves to the same 24-hour first-run window a never-reported
    /// project gets, which is the right answer if a later caller does reach it.
    /// `instant` is passed in rather than read here — see `reload()`.
    func doneCutoff(for task: TaskItem, at instant: Date) -> Date {
        ReportWindow.bounds(
            lastStandupAt: project(withID: task.projectID)?.lastStandupAt,
            now: instant
        ).start
    }

    /// Tasks for the current selection.
    ///
    /// The project filter is applied in memory rather than in the `#Predicate`
    /// because it is a set-membership test against the visible projects, and
    /// D18 caps the whole dataset under 20 live tasks — the fetch is the cost,
    /// not the filter.
    func fetchTasks() -> [TaskItem] {
        let visible = Set(projects.map(\.id))
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isArchived })
        let all = fetch(descriptor, "load your tasks")

        switch selection {
        case .all:
            // Archiving a project takes its tasks with it — otherwise
            // archiving would not actually get a finished project out of the
            // way, which is the whole point (§3.1).
            return all.filter { visible.contains($0.projectID) }
        case .project(let id):
            guard visible.contains(id) else { return [] }
            return all.filter { $0.projectID == id }
        }
    }
}
