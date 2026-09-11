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

    /// The store as a typed document, ordered per `ExportOrdering`.
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
            .map(ExportedProject.init).sorted(by: ExportOrdering.precedes)
        let tasks = ExportOrdering.sortedByWireInstant(
            try context.fetch(FetchDescriptor<TaskItem>()).map(ExportedTask.init),
            instant: { $0.createdAt }, id: { $0.id })
        let events = ExportOrdering.sortedByWireInstant(
            try context.fetch(FetchDescriptor<Event>()).map(ExportedEvent.init),
            instant: { $0.timestamp }, id: { $0.id })
        let refs = try context.fetch(FetchDescriptor<SourceRef>())
            .map { ExportedSourceRef($0, includingCachedData: includesCachedExternalData) }
            .sorted(by: ExportOrdering.precedes)
        let reports = ExportOrdering.sortedByWireInstant(
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
