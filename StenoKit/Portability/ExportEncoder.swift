import Foundation
import SwiftData

/// Serializes the whole store to §10.2's JSON document.
///
/// **Named `Encoder`, not `Service`, for `ReportGatherer`'s reason.**
/// `CaptureService`, `StatusService` and `NoteService` share a shape: inject
/// `save`, mutate, post `.stenoDidWrite`. This type does none of those, and a
/// name ending in `Service` is an invitation to add the `save` parameter its
/// siblings have, by symmetry — a write on the export path is a bug with no
/// symptom until a merge disagrees months later.
///
/// `@MainActor` because `ModelContext` is not `Sendable`; `now` injected so
/// `exportedAt` is assertable. Both for the reasons the sibling types record.
///
/// **Nothing is filtered.** Archived projects, archived tasks, redacted events
/// and undone reports all export, carrying their flags. Export is the only way
/// Steno moves between machines (§10, D1), so a row this type declines to write
/// is user data with no second copy anywhere.
@MainActor
public struct ExportEncoder {
    private let context: ModelContext
    private let includesCachedExternalData: Bool
    private let now: () -> Date
    private let exportedBy: String

    public init(
        context: ModelContext,
        includesCachedExternalData: Bool = false,
        now: @escaping () -> Date = Date.init,
        exportedBy: String = ExportDocument.userAgent()
    ) {
        self.context = context
        self.includesCachedExternalData = includesCachedExternalData
        self.now = now
        self.exportedBy = exportedBy
    }

    /// The store as a typed document, ordered per `precedes` and
    /// `sortedByWireInstant`.
    ///
    /// Separate from `encode()` because the tests need different things from
    /// each: ordering, field selection and value mapping are properties of a
    /// typed value, while key order and the absence of credential patterns are
    /// properties of bytes. Collapsing the two would force half the suite to
    /// parse JSON to ask questions this type already answers.
    ///
    /// `throws` covers `context.fetch` failing, and nothing else. An empty
    /// store is not a failure: it yields five empty arrays, which matters
    /// because M2.5-05 auto-exports on quit and defaults ON, so the first
    /// export on a new machine is likely this one.
    public func snapshot() throws -> ExportDocument {
        let projects = try context.fetch(FetchDescriptor<Project>())
            .map(ExportedProject.init).sorted(by: Self.precedes)
        let tasks = Self.sortedByWireInstant(
            try context.fetch(FetchDescriptor<TaskItem>()).map(ExportedTask.init),
            instant: { $0.createdAt }, id: { $0.id })
        let events = Self.sortedByWireInstant(
            try context.fetch(FetchDescriptor<Event>()).map(ExportedEvent.init),
            instant: { $0.timestamp }, id: { $0.id })
        let refs = try context.fetch(FetchDescriptor<SourceRef>())
            .map { ExportedSourceRef($0, includingCachedData: includesCachedExternalData) }
            .sorted(by: Self.precedes)
        let reports = Self.sortedByWireInstant(
            try context.fetch(FetchDescriptor<StandupReport>()).map(ExportedReport.init),
            instant: { $0.generatedAt }, id: { $0.id })

        return ExportDocument(
            schemaVersion: ExportDocument.currentSchemaVersion,
            exportedAt: now(),
            exportedBy: exportedBy,
            includesCachedExternalData: includesCachedExternalData,
            projects: projects,
            tasks: tasks,
            events: events,
            sourceRefs: refs,
            reports: reports)
    }

    /// The document as the bytes §10.2 describes.
    public func encode() throws -> Data {
        try ExportDocument.encoder().encode(snapshot())
    }
}

extension ExportEncoder {
    // Every comparator ends in `id.uuidString`, and that tie-break carries the
    // weight. `sorted(by:)` is not documented as stable, so without it two
    // records sharing a timestamp have an unspecified relative order: two
    // exports of an unchanged store would differ, and M2.5-05's auto-export
    // history would be churn rather than a backup log. `UUID` is not
    // `Comparable`, so the tie-break goes through `uuidString`.
    //
    // Sorting happens in memory rather than through `FetchDescriptor.sortBy` so
    // the comparators sit together, and so `SourceRefKind` is not a special
    // case — an enum inside a SwiftData `#Predicate` does not compile in either
    // spelling (`EventQueries.swift`, D-085).

    /// Projects in the order the UI shows them.
    ///
    /// `(sortOrder, name)` is `MainWindowModel.fetchProjects`'s order, and
    /// `sortOrder` is not unique — so sorting on `(sortOrder, id)` would put two
    /// equally-ordered projects in a different sequence from the one the user
    /// sees in the sidebar. The id stays as a third component, because `name`
    /// is not unique either and the order still has to be total.
    static func precedes(_ lhs: ExportedProject, _ rhs: ExportedProject) -> Bool {
        (lhs.sortOrder, lhs.name, lhs.id.uuidString)
            < (rhs.sortOrder, rhs.name, rhs.id.uuidString)
    }

    /// Order `items` by the timestamp **as the file carries it**, then by id.
    ///
    /// **The sort key is the emitted string, not the in-memory `Date`.** Two
    /// events a fraction of a millisecond apart are distinguishable in memory
    /// and identical on the wire, so ordering on the `Date` puts them in a
    /// sequence the file cannot express: any store built from that file ties on
    /// them, falls through to the id, and can reverse the pair relative to the
    /// export it came from. Keying on the emitted value makes the array's order
    /// derivable from the file's own contents — which is what M2.5-05's backup
    /// history and M2.5-02's convergence actually need.
    ///
    /// Formatting rather than quantizing arithmetically, and that is the second
    /// attempt: a `(seconds * 1000).rounded(.down)` key disagreed with the
    /// formatter at `.999` — a second implementation of truncation, drifting
    /// from the first in the third decimal place. There is now only one.
    /// Fixed-width UTC ISO-8601 sorts lexicographically as it does
    /// chronologically, and the key is computed once per record rather than
    /// once per comparison.
    static func sortedByWireInstant<Element>(
        _ items: [Element],
        instant: (Element) -> Date,
        id: (Element) -> UUID
    ) -> [Element] {
        items
            .map {
                (
                    key: instant($0).formatted(ExportDocument.fractionalSeconds),
                    tieBreak: id($0).uuidString,
                    value: $0
                )
            }
            .sorted { ($0.key, $0.tieBreak) < ($1.key, $1.tieBreak) }
            .map(\.value)
    }

    /// §3.4's dedup key, which groups a task's refs together.
    static func precedes(_ lhs: ExportedSourceRef, _ rhs: ExportedSourceRef) -> Bool {
        (lhs.taskID.uuidString, lhs.kind.rawValue, lhs.identifier, lhs.id.uuidString)
            < (rhs.taskID.uuidString, rhs.kind.rawValue, rhs.identifier, rhs.id.uuidString)
    }

}
