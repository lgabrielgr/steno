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
/// **Cross-surface writes.** A manual fetch does not refresh when another
/// surface writes, so this model observes `.stenoDidWrite` and reloads.
/// M1-03's floating panel and M1-04's popover therefore reach it without
/// either one knowing this type exists.
@Observable
@MainActor
public final class MainWindowModel: MainWindowActions {
    public private(set) var projects: [Project] = []
    public private(set) var groups: [TaskGroup] = []

    /// `internal(set)` rather than `private(set)`: `MainWindowModel+Status.swift`
    /// sets this too, and that split exists only to keep this file under
    /// SwiftLint's `file_length` limit — it is not a widening of who may set
    /// this from outside the module.
    public internal(set) var lastError: String?

    public var selection: ProjectSelection = .all {
        didSet { if selection != oldValue { reload() } }
    }

    public var selectedTaskID: UUID? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            // A draft belongs to the task it was typed against. Carrying it
            // across a selection change would let the next ⌘↩ file one task's
            // prose on another — and in `.correcting` mode, file a correction
            // of one task's note as a new note on a different task. The user
            // navigating away is the discard; see `cancel()`'s third case.
            noteComposer.cancel()
            reloadSelectedTaskEvents()
        }
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

    /// FR-2's note composer. A `let` built in `init`, holding no reference back
    /// to this model — its inputs arrive as parameters from
    /// `MainWindowModel+Notes`, which is what lets it be a `let` at all rather
    /// than an optional assigned after `self` becomes available.
    public let noteComposer: NoteComposerModel

    /// FR-4's draft sheet. A `let` built in `init` for `noteComposer`'s reason:
    /// it holds no reference back to this model, so it needs nothing that only
    /// becomes available after `self` does.
    public let standupDraft: StandupDraftModel

    /// FR-1.4: a task needs a project to belong to, and this window offers no
    /// way to create one implicitly.
    public var canCreateTask: Bool { !projects.isEmpty }

    /// FR-3's status actions need a subject.
    public var canChangeStatus: Bool { selectedTaskID != nil }

    /// Not `private`: `MainWindowModel+Status.swift` builds a `StatusService`
    /// over these three, the same way `captureService()` does in this file.
    /// Internal, not public — the app target still cannot reach them, so
    /// D-019's "views get no store access" is untouched outside this module.
    let context: ModelContext
    let now: () -> Date
    let save: (ModelContext) throws -> Void

    /// FR-6's settings, reached by the capture sheet through
    /// `defaultProjectIDForCapture`. Held rather than read at the call site so
    /// a test can supply a scratch suite instead of the developer's own
    /// preferences (§9.4).
    let settings: AppSettings

    /// Kept alive so the observation lives exactly as long as this model. See
    /// `WriteObservation` for why the token is not a plain stored property.
    private var writeObservation: WriteObservation?

    /// `now` is injected so the DONE window is testable without waiting.
    /// `save` is injected so the rollback path in `perform(_:_:)` is testable
    /// — a real `ModelContext` cannot be made to fail its save on demand.
    /// `copy` is injected so the headless bundle never reaches the real
    /// pasteboard: a test that did would mutate the developer's clipboard and
    /// would be order-dependent on anything else in the process that copies
    /// (§9.4).
    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        copy: @escaping (String) -> Bool = SystemClipboard.write,
        settings: AppSettings = AppSettings()
    ) {
        self.context = context
        self.now = now
        self.save = save
        self.settings = settings
        self.noteComposer = NoteComposerModel(
            service: NoteService(context: context, now: now, save: save), now: now)
        self.standupDraft = StandupDraftModel(
            service: StandupService(context: context, now: now, save: save, copy: copy))
        reload()

        // Registered last, deliberately: `self` may only be captured once
        // every stored property has a value. This is what closes the gap
        // this type's doc comment above describes — a capture from the
        // floating panel or the menu bar popover now reaches this model.
        // A capture from this window's own "New Task" sheet reloads twice:
        // once here, and once via the `onCaptured: { _ in model.reload() }`
        // closure `NewTaskSheet` passes straight to `CaptureFieldModel`
        // (M1-02). Known and harmless — `reload()` is idempotent — and left
        // alone rather than deduplicated: this observer exists for captures
        // from *other* surfaces (the floating panel, the popover), which have
        // no closure of their own to call.
        writeObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
    }

    // MARK: - Reading

    public func reload() {
        // `projects` first: `doneCutoff(for:at:)` resolves each task's project
        // through it, so the order of these two lines is load-bearing.
        projects = fetchProjects()
        // One clock reading for the whole reload. `doneCutoff(for:at:)` is
        // called once per task, so reading `now()` inside it would evaluate two
        // tasks against cutoffs microseconds apart — and a completion sitting
        // on the boundary could then be included for one task and excluded for
        // the next, or flicker between reloads. `StandupService.commit` takes a
        // single `stamp` for the same reason: one logical operation gets one
        // clock reading, so its own facts cannot disagree.
        let instant = now()
        groups = TaskGrouping.groups(from: fetchTasks()) { doneCutoff(for: $0, at: instant) }

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
            noteComposer.refreshCorrectability(in: [])
            return
        }
        let loaded = fetchEvents(forTaskID: id)
        selectedTaskTimelineFailed = loaded == nil
        selectedTaskEvents = loaded ?? []
        // FR-2's window is a function of the clock, so this is refreshed on a
        // timer as well (see `TaskDetailView`) — but it must also be correct
        // the instant the timeline changes, which is here.
        noteComposer.refreshCorrectability(in: selectedTaskEvents)
    }

    public func project(withID id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    public func task(withID id: UUID) -> TaskItem? {
        groups.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    /// The redaction exclusion lives in `EventQueries`, not here: §3.3 hides a
    /// redacted event from summaries too, so M2-01's gathering and M3-03's
    /// prompt read the same rule rather than each restating it.
    private func fetchEvents(forTaskID id: UUID) -> [Event]? {
        fetchOrNil(EventQueries.timeline(forTaskID: id), "load the timeline")
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
    func fetchOrNil<T: PersistentModel>(
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
    private func doneCutoff(for task: TaskItem, at instant: Date) -> Date {
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

    // MARK: - MainWindowActions
    //
    // The status actions (`setStatus`, `addBlockedReason`,
    // `cycleStatusOnSelection`, `markSelectionBlocked`) live in
    // `MainWindowModel+Status.swift`, not here — SwiftLint's `file_length`
    // limit, not a change in what belongs in this section.

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
