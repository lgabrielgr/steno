import Foundation

@testable import StenoKit

/// `ImportPlan` values built by hand, for the tests that are about **rendering**
/// a plan rather than computing one.
///
/// `ImportPreviewSummary` is a pure function of the counts, so giving it exact
/// counts is both precise and honest — contriving a fixture store that happens
/// to produce "4 updated tasks and 3 new projects" would test the merge all over
/// again on the way to testing a sentence. The counts themselves are checked
/// against what `apply` really does in `ImportPreviewAccuracyTests`, which is
/// where that property belongs.
enum PlanFixture {
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    static func counts(inserted: Int = 0, updated: Int = 0, unchanged: Int = 0)
        -> ImportPlan.Counts
    {
        ImportPlan.Counts(inserted: inserted, updated: updated, unchanged: unchanged)
    }

    /// `n` distinct ids, so a deletion set's *count* is what the preview reads.
    static func ids(_ number: Int) -> Set<UUID> {
        Set(
            (0..<number).map { index in
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID()
            })
    }

    static func writes(
        projects: Int = 0, tasks: Int = 0, events: Int = 0, sourceRefs: Int = 0, reports: Int = 0
    ) -> ImportPlan.Writes {
        ImportPlan.Writes(
            projects: ids(projects), tasks: ids(tasks), events: ids(events),
            sourceRefs: ids(sourceRefs), reports: ids(reports))
    }

    static func origin(
        exportedAt: Date = PlanFixture.origin,
        exportedBy: String = "steno/0.1.0 (macOS)",
        includesCachedExternalData: Bool = false
    ) -> ImportPlan.Origin {
        ImportPlan.Origin(
            exportedAt: exportedAt, exportedBy: exportedBy,
            includesCachedExternalData: includesCachedExternalData)
    }

    static func plan(
        mode: ImportMode = .merge,
        origin: ImportPlan.Origin = PlanFixture.origin(),
        projects: ImportPlan.Counts = counts(),
        tasks: ImportPlan.Counts = counts(),
        events: ImportPlan.Counts = counts(),
        sourceRefs: ImportPlan.Counts = counts(),
        reports: ImportPlan.Counts = counts(),
        deletions: ImportPlan.Writes = .none,
        deletedRows: ImportPlan.RowCounts? = nil,
        statusChanged: [UUID] = []
    ) -> ImportPlan {
        ImportPlan(
            mode: mode,
            origin: origin,
            merged: MergedStore(),
            writes: .none,
            deletions: deletions,
            // Defaults to one row per doomed id — the well-formed case. A test
            // that needs them to disagree passes `deletedRows` explicitly.
            deletedRows: deletedRows
                ?? ImportPlan.RowCounts(
                    projects: deletions.projects.count, tasks: deletions.tasks.count,
                    events: deletions.events.count, sourceRefs: deletions.sourceRefs.count,
                    reports: deletions.reports.count),
            source: MergedStore(),
            projects: projects,
            tasks: tasks,
            events: events,
            sourceRefs: sourceRefs,
            reports: reports,
            statusChanged: statusChanged,
            unparsedStatusBodies: [])
    }
}
