import Foundation
import OSLog
import SwiftData

/// Reads one project's report window (FR-4 steps 2–3, D8, D16).
///
/// **Named `Gatherer`, not `Service`, deliberately.** `CaptureService`,
/// `StatusService` and `NoteService` share a shape: each injects `save`,
/// mutates, and posts `.stenoDidWrite`. This type does none of those, and doing
/// any of them would break the guarantee FR-4 states outright — "generating a
/// preview must be free of side effects, so the user can peek without
/// corrupting their window". A name ending in `Service` is an invitation to add
/// the `save` parameter its siblings have, by symmetry, without noticing what
/// that symmetry costs here.
///
/// `@MainActor` because `ModelContext` is not `Sendable`, and `now` injected so
/// the window is assertable — both for the reasons the sibling services record.
/// There is no `save` parameter and no `commit()`; that absence is the design.
@MainActor
public struct ReportGatherer {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// D8's window for `project`, with every event inside it. Writes nothing.
    ///
    /// `throws` covers `context.fetch` failing, and nothing else.
    public func gather(for project: Project) throws -> GatheredWindow {
        let (start, end) = ReportWindow.bounds(lastStandupAt: project.lastStandupAt, now: now())
        warnIfClamped(project: project, end: end)

        // D16 is enforced here. `Event` has no `projectID` — its only link is
        // `taskID`, per §3.3 — so "this project's events" is necessarily "the
        // events of the tasks whose projectID matches", and scoping the task
        // fetch is what makes another project's rows unreachable from this
        // result. Nothing in this type reads another project's lastStandupAt.
        let tasks = try context.fetch(Self.tasks(inProjectID: project.id))
        let buckets = try eventsByTaskID(start: start, end: end, taskIDs: Set(tasks.map(\.id)))

        let gathered =
            try tasks
            .filter { Self.isReportable($0, hasEvents: !(buckets[$0.id] ?? []).isEmpty) }
            .sorted(by: Self.precedes)
            .map { task in
                GatheredTask(
                    id: task.id,
                    title: task.title,
                    status: task.status,
                    ticketKeys: (task.sourceRefs ?? [])
                        .filter { $0.kind == .jiraIssue }
                        .map(\.identifier)
                        .sorted(),
                    blockedReason: try blockedReason(for: task),
                    events: buckets[task.id] ?? []
                )
            }

        return GatheredWindow(
            projectID: project.id, cadence: project.reportCadence,
            start: start, end: end, tasks: gathered)
    }

    /// The window's events, bucketed by task, oldest first within each bucket.
    ///
    /// **One fetch, filtered in memory, and both halves of that are deliberate.**
    /// An `EventKind` inside a SwiftData `#Predicate` does not compile in either
    /// spelling — `EventQueries` already records this and already filters kinds
    /// after the fetch for the same reason — and a `taskIDs.contains(...)`
    /// predicate is the other construct not worth betting a fetch on. D18 caps a
    /// project under 20 tasks, so the fetch is the cost and the filtering is
    /// free.
    private func eventsByTaskID(
        start: Date, end: Date, taskIDs: Set<UUID>
    ) throws -> [UUID: [GatheredEvent]] {
        var buckets: [UUID: [GatheredEvent]] = [:]
        for event in try context.fetch(EventQueries.inWindow(start: start, end: end))
        where taskIDs.contains(event.taskID) && event.kind != .standupReported {
            buckets[event.taskID, default: []].append(
                GatheredEvent(timestamp: event.timestamp, kind: event.kind, body: event.body))
        }
        return buckets
    }

    /// `GatheredTask.blockedReason`: the most recent non-redacted
    /// `blockedReason` event's body for a task currently `.blocked`, `nil`
    /// otherwise.
    ///
    /// **Independent of the window, on purpose** — the same reason
    /// `ticketKeys` reads `task.sourceRefs` rather than an in-window event. A
    /// task blocked before the window opened, still blocked, with nothing new
    /// said, is exactly the case FR-4's Blockers section describes, and it has
    /// no event inside `[start, end]` to carry the reason.
    ///
    /// Reuses `EventQueries.timeline(forTaskID:)` rather than a bespoke fetch:
    /// it is already sorted newest-first and already excludes redacted rows,
    /// so "most recent non-redacted" is just "first match" here. The kind
    /// check happens after the fetch, for `EventQueries`' own reason — an
    /// `EventKind` inside a `#Predicate` does not compile, in either spelling.
    private func blockedReason(for task: TaskItem) throws -> String? {
        guard task.status == .blocked else { return nil }
        return try context.fetch(EventQueries.timeline(forTaskID: task.id))
            .first { $0.kind == .blockedReason }?.body
    }

    /// The project's live tasks. Archived tasks are not reported on.
    ///
    /// The predicate stays `UUID == UUID && !Bool` for `EventQueries`' reason:
    /// a `Status` inside a `#Predicate` does not compile, so the status half of
    /// `isReportable` happens in memory.
    private static func tasks(inProjectID id: UUID) -> FetchDescriptor<TaskItem> {
        FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.projectID == id && !$0.isArchived }
        )
    }

    /// Report order: oldest task first, ties broken by id.
    ///
    /// Explicit, because SwiftData does not specify fetch order without a
    /// `SortDescriptor`, and M2-02 must render the same markdown from the same
    /// window every time.
    ///
    /// **The tie-break is not decoration.** `sorted(by:)` is not documented as
    /// stable, so two tasks created in the same instant would otherwise have an
    /// unspecified relative order — the exact nondeterminism this sort exists to
    /// remove. It is a named function rather than a closure because that
    /// instability does not reproduce at the sizes D18 permits: a test on a
    /// handful of tasks cannot distinguish a missing tie-break from a stable
    /// sort, so the rule is asserted here directly instead of inferred from an
    /// output order that would agree either way.
    ///
    /// `UUID` is not `Comparable`, so the tie-break goes through `uuidString`.
    static func precedes(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }

    /// Whether `task` belongs in the report: active **or** open.
    ///
    /// The obvious reading of FR-4 step 3 — gather the events in the window — is
    /// not sufficient, because FR-4's own report structure two paragraphs later
    /// needs more than activity. **Today** is "current IN-PROGRESS tasks" and
    /// **Blockers** is "BLOCKED tasks with reasons": both are defined by current
    /// status, not by window activity. A task set in progress on Friday and left
    /// quiet over the weekend is exactly what Monday's stand-up is for, and an
    /// activity-only rule drops it.
    ///
    /// Exhaustive with no `default`, so a status added later is a compile error
    /// here rather than a silent omission from every report.
    private static func isReportable(_ task: TaskItem, hasEvents: Bool) -> Bool {
        switch task.status {
        case .inProgress, .blocked:
            true
        case .todo, .done:
            hasEvents
        }
    }

    /// Record a clamped window (§5.2 of the design; §8 permits log metadata).
    ///
    /// Dates, never task content. The condition re-derives the clamp rather
    /// than having `ReportWindow.bounds` report it, so that stays a pure
    /// function of its arguments.
    ///
    /// **This condition must track `ReportWindow.bounds`'s clamp** (`min(requested,
    /// now)` there is `last > end` here, restated). The two are deliberately
    /// independent code, so a change to one's clamp rule does not fail loudly in
    /// the other — whoever edits either should read both.
    private func warnIfClamped(project: Project, end: Date) {
        guard let last = project.lastStandupAt, last > end else { return }
        Log.report.notice(
            """
            lastStandupAt is ahead of now; clamping the report window to empty. \
            project=\(project.id.uuidString, privacy: .public) \
            lastStandupAt=\(last.timeIntervalSince1970, privacy: .public) \
            now=\(end.timeIntervalSince1970, privacy: .public)
            """)
    }
}
