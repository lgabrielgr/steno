import Foundation
import SwiftData

/// The menu bar popover's model: its capture field, the in-progress list, and
/// the status action behind the rows' menus.
///
/// **It does not reach for `MainWindowModel`.** The popover must open, list,
/// route and write when no main window exists at all — that is most of the
/// point of a menu bar item. It shares the *code path* with the main window
/// per D15, not the main window's state. The other direction is handled for
/// it: `CaptureService` and `StatusService` post `.stenoDidWrite`, and this
/// model reloads on it.
@Observable
@MainActor
public final class MenuBarModel {
    /// The shared capture field — the same type the main window's sheet and
    /// M1-03's panel use, so FR-1.4's chip cannot drift between surfaces.
    public let field: CaptureFieldModel

    /// Every IN-PROGRESS task, across every non-archived project, newest
    /// transition first (D-037).
    public private(set) var rows: [MenuBarRow] = []

    /// Set when the most recent `reload()` failed to read from the store.
    /// Cleared at the top of every `reload()`, so a later successful reload
    /// clears it purely by running — no separate dismissal path is needed.
    /// The popover shows it rather than reverting the list silently, and —
    /// because a failed read still returns `[]` — it is also how the view
    /// knows an empty list may be unread rather than genuinely empty. See
    /// `fetch(_:_:)`.
    ///
    /// Kept apart from `writeError`: the two used to share one property, and
    /// a successful `reload()` triggered by another surface's write could
    /// clear a write failure's message before the user had seen it, or a
    /// stale read failure could survive a `reload()` that just fixed it,
    /// depending on which happened to write last. Splitting them makes each
    /// one's clearing rule a fact about its own owner rather than a race.
    public private(set) var readError: String?

    /// Set when the most recent `setStatus` write failed. Cleared by a later
    /// `setStatus` call that succeeds, and by `prepareForShow()` — reopening
    /// the popover is the only dismissal gesture this surface has.
    ///
    /// **Not cleared by `reload()`.** `setStatus`'s catch sets this and then
    /// calls `reload()` immediately to restore the rolled-back row; if
    /// `reload()` cleared it, that same call would erase the message it was
    /// just asked to show. See `readError` for the property this replaced.
    public private(set) var writeError: String?

    /// How many times the popover has been prepared for display.
    ///
    /// The view keys the capture field on this so that each open gives the
    /// field a fresh identity, and with it a fresh `@FocusState`. A reused
    /// identity is what would make focus unreliable, by either of two routes:
    /// `.onAppear` may not be resent on a later show, and if `isFocused`
    /// survived the close still `true`, setting it `true` again changes
    /// nothing. A new identity moots both — the view is built, `.onAppear`
    /// runs, and `isFocused` goes false to true. §1.1 calls a capture field
    /// that needs a click a defect, so this is not cosmetic.
    public private(set) var showCount = 0

    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void
    private let failFetch: () throws -> Void
    private let projectBox: ProjectBox

    /// The same tasks `rows` describes, in the same order, kept for the status
    /// action's lookup. Built in lockstep with `rows` so the two cannot
    /// disagree about what is on screen.
    private var tasks: [TaskItem] = []

    /// Kept alive so the observation lives exactly as long as this model. See
    /// `WriteObservation` for why the token is not a plain stored property.
    private var writeObservation: WriteObservation?

    /// `now` and `save` are injected for the reasons `MainWindowModel` gives:
    /// timestamps assertable without waiting, and a save that can be made to
    /// fail, which a real `ModelContext` cannot.
    ///
    /// `failFetch` is the same idea applied to reads: `fetch<T>` calls it
    /// immediately before `context.fetch`, and it defaults to a no-op, so a
    /// real caller sees no change. It is not generic over `T` — a fetch
    /// failure a test wants to inject does not depend on which model type is
    /// being read, and a property typed over `T` cannot be stored on a
    /// non-generic class. Calling it *before* the real fetch, rather than
    /// wrapping the result, keeps it from having to fabricate a `[T]`.
    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        failFetch: @escaping () throws -> Void = {}
    ) {
        let box = ProjectBox()
        self.projectBox = box
        self.context = context
        self.now = now
        self.save = save
        self.failFetch = failFetch
        self.field = CaptureFieldModel(
            service: CaptureService(context: context, now: now, save: save),
            projects: { box.projects },
            // The popover has no surface context to prefer, so FR-1.4's ladder
            // falls through to the ticket key and then to last-used.
            // `CaptureService.capture` names this surface explicitly.
            preferred: { nil }
            // No `onCaptured:` hook. Nothing here needs one: the list refresh
            // arrives through the `.stenoDidWrite` observer below, and the
            // popover is closed by `CaptureFieldView.commit()` calling its
            // `onDismiss`, which is the controller's own closure.
        )
        reload()

        // Registered last: `self` may only be captured once every stored
        // property has a value. This is what makes a capture or a status
        // change made in the main window show up here without either type
        // knowing the other exists.
        writeObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
    }

    /// Called on every open.
    ///
    /// Refetches so a task started elsewhere is listed, and re-derives the
    /// chip because the draft survives a dismissal and the project list can
    /// have changed underneath it — `QuickCaptureModel.prepareForShow`
    /// documents that argument in full.
    ///
    /// Clearing `writeError` here is what makes that message dismissable on a
    /// surface with no Dismiss control: reopening the popover is the gesture.
    /// It has to be *here* rather than in `reload()` — `setStatus`'s catch
    /// calls `reload()` immediately after setting the message, so clearing it
    /// there would erase it in the same call that set it. Nothing calls
    /// `prepareForShow()` on that path.
    ///
    /// `readError` needs no explicit clear: `reload()`, called below, clears
    /// it at its own top.
    public func prepareForShow() {
        showCount += 1
        writeError = nil
        reload()
        field.refreshChip()
    }

    /// Rebuild the list from the store.
    ///
    /// Clears `readError` first, so a reload that goes on to fail sets it
    /// again but one that succeeds leaves it cleared — the property is owned
    /// entirely by this method, with no other clearing path to race against.
    public func reload() {
        readError = nil
        let projects = fetchProjects()
        projectBox.projects = projects

        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`: `Project.id`
        // carries no `@Attribute(.unique)`, so a duplicate id is representable
        // in the store even though nothing in the app's own API constructs
        // one. `uniqueKeysWithValues:` traps on a duplicate; degrading to
        // "first one wins" keeps `reload()` — called on every popover open —
        // from crashing on malformed data.
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Sorted before the project join so the two arrays below are built in
        // one pass and cannot fall out of order.
        let live =
            fetchTasks()
            .filter { $0.status == .inProgress }
            .sorted { $0.statusChangedAt > $1.statusChangedAt }

        var nextTasks: [TaskItem] = []
        var nextRows: [MenuBarRow] = []
        for task in live {
            guard let project = byID[task.projectID] else { continue }
            nextTasks.append(task)
            nextRows.append(
                MenuBarRow(
                    id: task.id,
                    title: task.title,
                    status: task.status,
                    projectName: project.name,
                    colorHex: project.colorHex))
        }
        tasks = nextTasks
        rows = nextRows
    }

    /// D-033's one path for status, over this surface's context.
    ///
    /// **Blocking here does not offer D-036's reason sheet** (D-039). §3.3
    /// makes the reason optional, a sheet would dismiss the `.transient`
    /// popover that spawned it, and the detail pane still offers it.
    ///
    /// A successful write reloads twice — once here, once via the
    /// `.stenoDidWrite` observer — for the reason `MainWindowModel+Status`
    /// gives: that observer exists for writes from *other* surfaces, and a
    /// caller that leans on it to see its own write breaks silently the day it
    /// is scoped to ignore self-originated posts. `reload()` is idempotent.
    public func setStatus(_ new: Status, on taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        do {
            let changed = try StatusService(context: context, now: now, save: save)
                .setStatus(new, on: task)
            writeError = nil
            // Nothing written means nothing to fetch.
            guard changed else { return }
            reload()
        } catch {
            Log.app.error(
                "could not change the status: \(String(describing: error), privacy: .public)")
            writeError = "Could not change the status. Your change was not saved."
            // Not cosmetic: `rollback()` leaves the held task reporting the
            // rejected status, and this fetch is what refreshes it.
            reload()
        }
    }

    private func fetchProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return fetch(descriptor, "load your projects")
    }

    /// Status is filtered in memory rather than in the `#Predicate`, matching
    /// `MainWindowModel.fetchTasks` — D18 makes the fetch the cost, not the
    /// filter — and because the predicate form does not exist. Both spellings
    /// fail to compile, verified rather than assumed:
    /// `$0.status == .inProgress` is "member access without an explicit base
    /// is not supported in this predicate", and `$0.status == Status.inProgress`
    /// is "key path cannot refer to enum case".
    private func fetchTasks() -> [TaskItem] {
        fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isArchived }), "load your tasks")
    }

    /// A failed read must not look like an empty store: for a recall tool,
    /// "nothing in progress" over a store that is full is the worst lie the
    /// popover could tell.
    ///
    /// The empty array below is therefore only half the contract. `readError`
    /// is the other half — it is what tells the view the list is *unread*
    /// rather than empty, and `MenuBarPopoverView` withholds its empty-state
    /// text while it is set. Returning `[]` without setting it would restore
    /// exactly the lie this comment forbids.
    ///
    /// `failFetch()` runs before the real fetch so a test can make this throw
    /// without a store that can actually fail — see its doc comment on
    /// `init`.
    private func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>, _ what: String
    ) -> [T] {
        do {
            try failFetch()
            return try context.fetch(descriptor)
        } catch {
            Log.app.error(
                "could not \(what, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            readError = "Could not \(what)."
            return []
        }
    }
}
