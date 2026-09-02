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
}
