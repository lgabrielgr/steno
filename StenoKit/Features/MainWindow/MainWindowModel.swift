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

    public var selectedTaskID: UUID? {
        didSet { if selectedTaskID != oldValue { reloadSelectedTaskEvents() } }
    }

    /// The selected task's timeline, newest first, redacted events excluded.
    ///
    /// Published as stored state rather than fetched by the detail pane on
    /// demand, and that is load-bearing in two ways. A fetch during `body`
    /// would set `lastError` on failure — mutating observed state inside a
    /// SwiftUI update pass, which `MainWindowView` reads, so the failure would
    /// re-invalidate the view that triggered it and spin. And a method call
    /// mid-render is invisible to observation, so the pane would refresh only
    /// by accident, through whatever else it happened to read — fragile now
    /// and wrong once M1-06 appends notes.
    public private(set) var selectedTaskEvents: [Event] = []

    /// Whether the last timeline read *failed*, as opposed to finding nothing.
    ///
    /// Its own flag rather than a reading of `lastError`, which any failed save
    /// also sets — that would let an unrelated write failure relabel a
    /// genuinely empty timeline as unreadable. The pane needs to tell those
    /// apart because, per §3.3, every task carries a `created` event: an empty
    /// timeline is never a normal state, so rendering one as "no events" would
    /// assert something about the task that cannot be true.
    public private(set) var selectedTaskTimelineFailed = false

    /// Which modal is on screen, if any. See `ActiveSheet` for why this is one
    /// optional rather than a `Bool` per sheet.
    public var activeSheet: ActiveSheet?

    /// FR-1.4: a task needs a project to belong to, and this window offers no
    /// way to create one implicitly.
    public var canCreateTask: Bool { !projects.isEmpty }

    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void

    /// `now` is injected so the DONE window is testable without waiting.
    /// `save` is injected so the rollback path in `perform(_:_:)` is testable
    /// — a real `ModelContext` cannot be made to fail its save on demand.
    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.now = now
        self.save = save
        reload()
    }

    // MARK: - Reading

    public func reload() {
        projects = fetchProjects()
        groups = TaskGrouping.groups(from: fetchTasks(), doneSince: doneCutoff())

        // A task that has scrolled out of the DONE window, or whose project was
        // just archived, must not leave the detail pane showing a stale row.
        if let id = selectedTaskID,
            !groups.contains(where: { group in group.tasks.contains { $0.id == id } })
        {
            selectedTaskID = nil
        }

        // Unconditional: the selection may be unchanged while its timeline is
        // not — M1-06 appending a note is exactly that case.
        reloadSelectedTaskEvents()
    }

    private func reloadSelectedTaskEvents() {
        guard let id = selectedTaskID else {
            selectedTaskEvents = []
            selectedTaskTimelineFailed = false
            return
        }
        let loaded = fetchEvents(forTaskID: id)
        selectedTaskTimelineFailed = loaded == nil
        selectedTaskEvents = loaded ?? []
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
        fetchEvents(forTaskID: id) ?? []
    }

    private func fetchEvents(forTaskID id: UUID) -> [Event]? {
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate { $0.taskID == id && !$0.isRedacted },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return fetchOrNil(descriptor, "load the timeline")
    }

    /// Fetch, or surface the failure. A failed fetch must not look like an
    /// empty store: for a recall tool, "you have no projects" over a store
    /// that is full is the worst possible lie — the read-side twin of the
    /// write-side guarantee `perform(_:_:)` makes (D-018).
    ///
    /// `what` is an infinitive phrase, matching `perform`'s convention.
    private func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: String
    ) -> [T] {
        fetchOrNil(descriptor, what) ?? []
    }

    /// As `fetch`, but `nil` on failure rather than `[]`.
    ///
    /// Display code cannot act on the difference — an empty list renders the
    /// same either way — but a caller deriving *new* data from a read must not
    /// treat "the read failed" as "there is nothing there". See
    /// `createProject(named:)`, where conflating the two mints a project whose
    /// `sortOrder` and colour collide with one already stored.
    private func fetchOrNil<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        _ what: String
    ) -> [T]? {
        do {
            return try context.fetch(descriptor)
        } catch {
            Log.app.error(
                "could not \(what, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not \(what)."
            return nil
        }
    }

    private func fetchProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return fetch(descriptor, "load your projects")
    }

    /// Superseded by M2-01: FR-3 scopes DONE to the current report window,
    /// which is computed from `project.lastStandupAt` (D8) and does not exist
    /// until M2-01. That field stays nil until M2-03 ships the Copy action
    /// that advances it, and FR-4 step 2 makes the first-run window 24 hours —
    /// so for every state reachable today this returns the same answer.
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

    // MARK: - Writing

    public func createProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The max must run over *all* projects, archived included — `projects`
        // is the visible set, and if the highest-sortOrder project is
        // archived, taking the max of the visible set would let the next
        // project reuse both its order and (via ProjectPalette) its colour.
        //
        // Fail closed if that read fails: `[]` would yield order 0 and mint a
        // project colliding with a stored one, which is the write-side version
        // of the lie `perform(_:_:)`'s rollback exists to prevent (D-018).
        // `lastError` is already set by the fetch, so the user sees why.
        guard let allProjects = fetchOrNil(FetchDescriptor<Project>(), "load your projects") else {
            return
        }
        let order = (allProjects.map(\.sortOrder).max() ?? -1) + 1
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

    /// FR-1's capture, through the shared path (D15).
    ///
    /// The routing, the `created` event and the ref extraction all live in
    /// `CaptureService`, so this window, M1-03's floating window and M1-04's
    /// popover cannot drift apart. What stays here is this surface's own
    /// context — the sidebar selection — and the error presentation.
    public func createTask(titled title: String) {
        // Constructed per call rather than stored: three retained references
        // is nothing against a SwiftData save, and it keeps `now` and `save`
        // from being captured at init and going stale in tests.
        let capture = CaptureService(context: context, now: now, save: save)
        do {
            try capture.capture(text: title, preferred: preferredProjectID())
            lastError = nil
        } catch CaptureError.noProjectAvailable {
            lastError = "Create a project before adding a task."
        } catch {
            Log.app.error(
                "could not create the task: \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not create the task. Your change was not saved."
        }
        reload()
    }

    /// FR-1.4 rung 2: this surface's own context.
    ///
    /// Under "All" the window has no opinion about where a task belongs, so it
    /// says so with `nil` and the ladder falls through to the last-used
    /// project — rather than asserting the first project, which is what
    /// D-021's stand-in did before this task retired it.
    private func preferredProjectID() -> UUID? {
        switch selection {
        case .project(let id): id
        case .all: nil
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
        activeSheet = .newTask
    }

    public func newProject() {
        activeSheet = .newProject
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
        return saved
    }
}
