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
            tasks
            .map { task in
                GatheredTask(
                    id: task.id,
                    title: task.title,
                    status: task.status,
                    ticketKeys: (task.sourceRefs ?? [])
                        .filter { $0.kind == .jiraIssue }
                        .map(\.identifier)
                        .sorted(),
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

    /// Record a clamped window (§5.2 of the design; §8 permits log metadata).
    ///
    /// Dates, never task content. The condition re-derives the clamp rather
    /// than having `ReportWindow.bounds` report it, so that stays a pure
    /// function of its arguments.
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
