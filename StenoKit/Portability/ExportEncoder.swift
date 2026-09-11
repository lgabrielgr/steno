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

    /// The store as a typed document, ordered per `precedes`.
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
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
            .map(ExportedTask.init).sorted(by: Self.precedes)
        let events = try context.fetch(FetchDescriptor<Event>())
            .map(ExportedEvent.init).sorted(by: Self.precedes)
        let refs = try context.fetch(FetchDescriptor<SourceRef>())
            .map { ExportedSourceRef($0, includingCachedData: includesCachedExternalData) }
            .sorted(by: Self.precedes)
        let reports = try context.fetch(FetchDescriptor<StandupReport>())
            .map(ExportedReport.init).sorted(by: Self.precedes)

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
    static func precedes(_ lhs: ExportedProject, _ rhs: ExportedProject) -> Bool {
        (lhs.sortOrder, lhs.id.uuidString) < (rhs.sortOrder, rhs.id.uuidString)
    }

    /// Oldest task first, so new tasks land at the end of the array.
    static func precedes(_ lhs: ExportedTask, _ rhs: ExportedTask) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }

    /// Oldest event first. This is the large array, and appending at the end is
    /// what makes a day-over-day diff readable.
    static func precedes(_ lhs: ExportedEvent, _ rhs: ExportedEvent) -> Bool {
        (lhs.timestamp, lhs.id.uuidString) < (rhs.timestamp, rhs.id.uuidString)
    }

    /// §3.4's dedup key, which groups a task's refs together.
    static func precedes(_ lhs: ExportedSourceRef, _ rhs: ExportedSourceRef) -> Bool {
        (lhs.taskID.uuidString, lhs.kind.rawValue, lhs.identifier, lhs.id.uuidString)
            < (rhs.taskID.uuidString, rhs.kind.rawValue, rhs.identifier, rhs.id.uuidString)
    }

    /// Oldest report first, for `ExportedEvent`'s reason.
    static func precedes(_ lhs: ExportedReport, _ rhs: ExportedReport) -> Bool {
        (lhs.generatedAt, lhs.id.uuidString) < (rhs.generatedAt, rhs.id.uuidString)
    }
}
