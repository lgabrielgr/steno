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
    private let afterRead: () -> Void

    /// - Parameter afterRead: runs between the two readings `snapshot()` takes.
    ///   The only way to exercise the unstable-store path: a real concurrent
    ///   writer cannot be arranged in a headless single-process test (§9.4), and
    ///   a path that cannot be reached by a test is a path nobody has run.
    public init(
        context: ModelContext,
        includesCachedExternalData: Bool = false,
        now: @escaping () -> Date = Date.init,
        exportedBy: String = ExportDocument.userAgent(),
        afterRead: @escaping () -> Void = {}
    ) {
        self.context = context
        self.includesCachedExternalData = includesCachedExternalData
        self.now = now
        self.exportedBy = exportedBy
        self.afterRead = afterRead
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
    /// **Read twice, and only return a reading that repeated.**
    ///
    /// The five fetches below are five separate reads of the store, with no
    /// transaction around them. A writer committing between two of them yields a
    /// document whose parts come from different generations — tasks whose
    /// project was fetched before it existed, events whose task was not. Nothing
    /// is lost on this Mac; the *file* is incoherent, and it fails much later as
    /// `ImportError.danglingReference` on the machine trying to restore from it.
    /// With sync cancelled (§10, D1) that file may be the only copy, and
    /// M2.5-05's auto-export writes unattended while the app is running, which is
    /// exactly when a concurrent writer exists. Raised in review of PR #31.
    ///
    /// **It compares two readings rather than validating one.** The obvious
    /// alternative — run `StoreMerge.validateShape` over the document and refuse
    /// if it fails — would refuse to export a store that was *already* malformed,
    /// and `BackupWriter` goes through this method: Replace could then no longer
    /// back up the damaged store it exists to recover from (D-106, D-110), and
    /// §10's "a row this type declines to write is user data with no second copy"
    /// would be violated by the safety check itself. Two equal readings mean the
    /// store held still; they say nothing about whether it is healthy, which is
    /// correct — that is not this type's business.
    ///
    /// The cost is a second pass over the store per export. Export is
    /// user-initiated or runs on quit; it is not on §1.1's capture path.
    public func snapshot() throws -> ExportDocument {
        var previous = try read()
        for _ in 0..<Self.stableReadAttempts {
            afterRead()
            let current = try read()
            if current.holdsSameRecords(as: previous) { return current }
            previous = current
        }
        throw ExportError.storeChangedWhileReading
    }

    /// Two retries after the first comparison. A store under continuous write
    /// never settles and must fail rather than spin; a single passing writer
    /// costs one extra pass.
    private static let stableReadAttempts = 2

    /// One reading of the store, which may or may not be a coherent one.
    private func read() throws -> ExportDocument {
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
