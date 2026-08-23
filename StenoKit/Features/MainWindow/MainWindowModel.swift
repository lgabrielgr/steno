import Foundation
import SwiftData

/// The main window's single source of truth.
///
/// **Views get no store access at all** — no `@Query`, no
/// `@Environment(\.modelContext)`. ARCHITECTURE §2 rule 2 requires view models
/// to mediate, §14 lists that separation as retained and not to be stripped,
/// and the justification is testability (§9.4): everything this type does is
/// exercised by the headless, network-denied test bundle, which a `@Query` in
/// a view never could be.
///
/// **Known limit.** A manual fetch does not refresh when another surface
/// writes. Every mutation that goes through this model reloads itself, so the
/// window is correct for everything M0-05 can do — but M1-03's floating window
/// and M1-04's popover will insert tasks this model does not notice. Closing
/// that belongs to whichever of them lands first; a `reload()` on window
/// activation is the likely minimum.
@Observable
@MainActor
public final class MainWindowModel: MainWindowActions {
    public private(set) var projects: [Project] = []
    public private(set) var groups: [TaskGroup] = []
    public private(set) var lastError: String?

    public var selection: ProjectSelection = .all {
        didSet { if selection != oldValue { reload() } }
    }

    public var selectedTaskID: UUID?
    public var isPresentingNewProject = false
    public var isPresentingNewTask = false

    /// FR-1.4: a task needs a project to belong to, and this window offers no
    /// way to create one implicitly.
    public var canCreateTask: Bool { !projects.isEmpty }

    private let context: ModelContext
    private let now: () -> Date

    /// `now` is injected so the DONE window is testable without waiting.
    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
        reload()
    }

    // MARK: - Reading

    public func reload() {
        projects = fetchProjects()
        groups = TaskGrouping.groups(from: fetchTasks(), doneSince: doneCutoff())

        // A task that has scrolled out of the DONE window, or whose project was
        // just archived, must not leave the detail pane showing a stale row.
        if let id = selectedTaskID,
            !groups.contains(where: { group in group.tasks.contains { $0.id == id } }) {
            selectedTaskID = nil
        }
    }

    public func project(withID id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    public func task(withID id: UUID) -> TaskItem? {
        groups.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    /// The task's timeline, newest first, excluding redacted events (§3.3).
    ///
    /// The exclusion is a property of this query rather than of each caller,
    /// so M1-06's redaction cannot be forgotten by one of them.
    public func events(forTaskID id: UUID) -> [Event] {
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate { $0.taskID == id && !$0.isRedacted },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // Named placeholder, not stale debt; see M0-05 task 3 brief.
    // swiftlint:disable:next todo
    /// TODO(M2-01): FR-3 scopes DONE to the current report window, which is
    /// computed from `project.lastStandupAt` (D8) and does not exist until
    /// M2-01. That field stays nil until M2-03 ships the Copy action that
    /// advances it, and FR-4 step 2 makes the first-run window 24 hours — so
    /// for every state reachable today this returns the same answer.
    private func doneCutoff() -> Date {
        now().addingTimeInterval(-24 * 60 * 60)
    }

    /// Tasks for the current selection.
    ///
    /// The project filter is applied in memory rather than in the `#Predicate`
    /// because it is a set-membership test against the visible projects, and
    /// D18 caps the whole dataset under 20 live tasks — the fetch is the cost,
    /// not the filter.
    private func fetchTasks() -> [TaskItem] {
        let visible = Set(projects.map(\.id))
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isArchived })
        let all = (try? context.fetch(descriptor)) ?? []

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

    // MARK: - Writing

    public func createProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let order = (projects.map(\.sortOrder).max() ?? -1) + 1
        let stamp = now()
        perform("create the project") {
            self.context.insert(
                Project(
                    name: trimmed,
                    colorHex: ProjectPalette.hex(forIndex: order),
                    sortOrder: order,
                    modifiedAt: stamp
                )
            )
        }
    }

    public func createTask(titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let projectID = targetProjectID() else { return }

        let stamp = now()
        perform("create the task") {
            let task = TaskItem(title: trimmed, projectID: projectID, createdAt: stamp)
            self.context.insert(task)
            // §3.3's EventKind table: `created` is written when a task is
            // created. A task without one is a hole in the append-only log —
            // M2-01's gathering would skip it and M2.5-02's merge would reason
            // from it. M1-02's capture service takes over this call site.
            self.context.insert(
                Event(taskID: task.id, timestamp: stamp, kind: .created, body: "Task created")
            )
        }
    }

    // Named placeholder, not stale debt; see M0-05 task 3 brief.
    // swiftlint:disable todo
    /// FR-1.4: never block on project selection.
    ///
    /// TODO(M1-02): the specified rule is "default to the last-used project",
    /// which M1-02 owns along with the first-launch behaviour. Until then the
    /// first project by `sortOrder` stands in — and the task row shows its
    /// project, so the assignment is visible rather than silent.
    private func targetProjectID() -> UUID? {
        switch selection {
        case .project(let id): id
        case .all: projects.first?.id
        }
    }
    // swiftlint:enable todo

    /// §3.1: archived projects are hidden, never deleted. There is no delete.
    public func archive(projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }

        let stamp = now()
        let saved = perform("archive the project") { project.setArchived(true, at: stamp) }

        // Only after the save is known to have succeeded. `rollback()` can undo
        // the `isArchived` mutation, but it cannot undo a selection change — so
        // moving the selection first would leave a failed archive showing "All"
        // while the project is still in the sidebar.
        if saved, selection == .project(projectID) { selection = .all }
    }

    // MARK: - MainWindowActions

    public func newTask() {
        guard canCreateTask else { return }
        isPresentingNewTask = true
    }

    public func newProject() {
        isPresentingNewProject = true
    }

    public func selectNextProject() {
        selection = .next(after: selection, in: projects.map(\.id))
    }

    public func selectPreviousProject() {
        selection = .previous(before: selection, in: projects.map(\.id))
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Saving

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
    private func perform(_ what: String, _ mutation: () -> Void) -> Bool {
        mutation()
        var saved = true
        do {
            try context.save()
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
        return saved
    }
}
