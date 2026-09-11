import Foundation

/// The five record arrays of §10.2, without the envelope.
///
/// Not `ExportDocument`: `exportedAt`, `exportedBy` and
/// `includesCachedExternalData` are facts about a *file*, and merging two of
/// them yields nonsense. This is the shape a merge operates on.
public struct MergedStore: Hashable, Sendable {
    public let projects: [ExportedProject]
    public let tasks: [ExportedTask]
    public let events: [ExportedEvent]
    public let sourceRefs: [ExportedSourceRef]
    public let reports: [ExportedReport]

    public init(
        projects: [ExportedProject] = [],
        tasks: [ExportedTask] = [],
        events: [ExportedEvent] = [],
        sourceRefs: [ExportedSourceRef] = [],
        reports: [ExportedReport] = []
    ) {
        self.projects = projects
        self.tasks = tasks
        self.events = events
        self.sourceRefs = sourceRefs
        self.reports = reports
    }
}

extension MergedStore {
    public init(_ document: ExportDocument) {
        self.init(
            projects: document.projects,
            tasks: document.tasks,
            events: document.events,
            sourceRefs: document.sourceRefs,
            reports: document.reports)
    }

    /// This store expressed as a file would express it, envelope included.
    ///
    /// The envelope values are placeholders — nothing reads them back. It
    /// exists so `wireNormalized` can go through the real encoder.
    func document() -> ExportDocument {
        ExportDocument(
            schemaVersion: ExportDocument.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 0),
            exportedBy: "steno/normalize (macOS)",
            includesCachedExternalData: true,
            projects: projects,
            tasks: tasks,
            events: events,
            sourceRefs: sourceRefs,
            reports: reports)
    }

    /// Every `Date` in this store, re-expressed at the precision the file uses.
    ///
    /// **Both sides of a merge must be at wire precision or nothing converges.**
    /// The local store holds full-precision `Date`s; the incoming file's were
    /// quantized on the way out. For the very same record the local value is
    /// then almost always the larger of the two, by a fraction of a
    /// millisecond — so every §10.1 rule that compares timestamps hands the
    /// local machine a win it did not earn, and `merge(A,B)` stops equalling
    /// `merge(B,A)`. Commutativity would not fail loudly; it would fail by half
    /// a millisecond.
    ///
    /// **Implemented by round-tripping the whole document through the exporter's
    /// own bytes**, rather than by mapping each `Date` through
    /// `ExportDocument.wireString`. The per-field version is cheaper and exactly
    /// equivalent today, and it is rejected anyway: there are twenty-odd date
    /// fields across five record types, a missed one is silent, and D-095
    /// records what happens to a rule that depends on someone remembering a
    /// field. Encoding the document cannot miss one. The cost is one
    /// pretty-printed intermediate of the whole store, on a path that is not
    /// §1.1's.
    func wireNormalized() throws -> MergedStore {
        let data = try ExportDocument.encoder().encode(document())
        return MergedStore(try ExportDocument.decoder().decode(ExportDocument.self, from: data))
    }
}

/// What a merge produced, and what it could not read.
public struct MergeResult: Equatable, Sendable {
    public let store: MergedStore

    /// Ids of `statusChanged` events whose body would not parse. Not an error —
    /// see `StatusTransition.init?(eventBody:)`.
    public let unparsedStatusBodies: [UUID]
}
