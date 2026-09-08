import Foundation
import SwiftData

/// The event log's shared query vocabulary.
///
/// **Redaction is excluded here, not by each caller.** §3.3 hides a redacted
/// event from summaries, and M2-01's gathering and M3-03's prompt both have to
/// honour that — so the predicate lives in one place rather than being
/// rewritten, and eventually mis-written, per call site.
public enum EventQueries {
    /// One task's timeline: newest first, redacted events excluded.
    ///
    /// The predicate stays `UUID == UUID && !Bool` deliberately. An enum inside
    /// a SwiftData `#Predicate` does not compile in either spelling, so any
    /// kind-based filtering happens in memory after the fetch; D18 caps the
    /// dataset, so the fetch is the cost and the filter is free.
    ///
    /// **Ties are possible and benign.** A correction gives its replacement the
    /// original's timestamp, so two rows can share one instant — but the
    /// original is redacted and this descriptor excludes it, so the two never
    /// both appear. `SortDescriptor` could not break the tie by `id` anyway:
    /// `UUID` is not `Comparable`.
    public static func timeline(forTaskID id: UUID) -> FetchDescriptor<Event> {
        FetchDescriptor<Event>(
            predicate: #Predicate { $0.taskID == id && !$0.isRedacted },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
    }

    /// Every non-redacted event in `[start, end]`, oldest first (FR-4 step 3).
    ///
    /// **Closed at both ends, as FR-4 specifies**, and that is load-bearing
    /// rather than incidental: M2-03's Copy stamps `project.lastStandupAt` and
    /// the `standupReported` events it appends with the same instant, so the
    /// next report's `start` equals those events' timestamps exactly. The
    /// interval therefore returns them every time — which is why
    /// `ReportGatherer` drops the kind, rather than this descriptor narrowing
    /// to a half-open range that would also drop a legitimate note stamped on
    /// the boundary.
    ///
    /// Not scoped to a task or a project. `Event` carries no `projectID` and
    /// this predicate stays `Date && Date && !Bool` — a `taskIDs.contains(...)`
    /// clause is the kind of construct that compiles and then throws at fetch
    /// time. The caller intersects with its own task set in memory; D18 caps
    /// the dataset, so the fetch is the cost and the filter is free.
    ///
    /// Ascending, unlike `timeline(forTaskID:)`: a report narrates a window
    /// forwards, while a timeline shows the newest note first.
    public static func inWindow(start: Date, end: Date) -> FetchDescriptor<Event> {
        FetchDescriptor<Event>(
            predicate: #Predicate {
                $0.timestamp >= start && $0.timestamp <= end && !$0.isRedacted
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
    }
}
