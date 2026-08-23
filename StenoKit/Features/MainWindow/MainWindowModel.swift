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
    }

    public func project(withID id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    private func fetchProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
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
