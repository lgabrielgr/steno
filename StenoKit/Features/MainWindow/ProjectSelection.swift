import Foundation

/// What the main window is currently showing: one project, or FR-3's "All"
/// pseudo-project at the top of the sidebar.
public enum ProjectSelection: Hashable, Sendable {
    case all
    case project(UUID)

    /// The sidebar's cycle order: "All" first, then projects in `sortOrder`.
    static func ring(_ projectIDs: [UUID]) -> [ProjectSelection] {
        [.all] + projectIDs.map(ProjectSelection.project)
    }

    /// The next selection, wrapping at the end (FR-3's "switch project").
    public static func next(
        after current: ProjectSelection,
        in projectIDs: [UUID]
    ) -> ProjectSelection {
        step(from: current, in: projectIDs, by: 1)
    }

    /// The previous selection, wrapping at the start.
    public static func previous(
        before current: ProjectSelection,
        in projectIDs: [UUID]
    ) -> ProjectSelection {
        step(from: current, in: projectIDs, by: -1)
    }

    /// Falls back to `.all` when `current` is not in the list — which happens
    /// whenever the selected project has just been archived.
    private static func step(
        from current: ProjectSelection,
        in projectIDs: [UUID],
        by offset: Int
    ) -> ProjectSelection {
        let ring = ring(projectIDs)
        guard let index = ring.firstIndex(of: current) else { return .all }
        // Swift's % is remainder, not modulo, so a negative step needs the
        // extra + count before the second % to land in range.
        let wrapped = ((index + offset) % ring.count + ring.count) % ring.count
        return ring[wrapped]
    }
}
