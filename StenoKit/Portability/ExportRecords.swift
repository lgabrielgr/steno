import Foundation

/// The five record types of §10.2, one per §3 field table.
///
/// Flat structs rather than `Codable` on the `@Model` classes: the macro and
/// the synthesis conflict, `SourceRef.task` is a cycle, and the wire format
/// would become whatever the persistence layer happened to hold. §10.2's
/// format is a compatibility contract M2.5-02 reads and that outlives any one
/// schema, so it gets its own declaration.
///
/// **Property order is key order in every one of these** — see `ExportDocument`.
/// Each mirrors its §3 table top to bottom.
///
/// Optionals rely on synthesized `encodeIfPresent`, so an absent value omits
/// its key rather than writing `null`. That is also how §10.2's
/// `includesCachedExternalData` toggle works; see `ExportedSourceRef`.
public struct ExportedProject: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let colorHex: String
    public let jiraProjectKeys: [String]
    public let isArchived: Bool
    public let sortOrder: Int
    public let lastStandupAt: Date?
    public let reportCadence: ReportCadence
    public let staleThresholdDays: Int?
    public let modifiedAt: Date
}

/// §3.2. Carries no `sourceRefs`: §3.4 makes `SourceRef.taskID` the
/// authoritative link and gives refs their own top-level array, and a file
/// holding both could disagree with itself — leaving M2.5-02 to pick a winner.
public struct ExportedTask: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let projectID: UUID
    public let status: Status
    public let createdAt: Date
    public let statusChangedAt: Date
    public let completedAt: Date?
    public let isArchived: Bool
    public let modifiedAt: Date
}

/// §3.3, `isRedacted` included.
///
/// **A redacted event is exported like any other.** The tempting filter —
/// redacted events are hidden from summaries, so why carry them? — is the worst
/// bug available here: exported into an empty store, a dropped redacted event
/// does not lose its visibility, it loses its row, and §3.3's log is what every
/// summary is derived from. `isRedacted` is also half of what O-8 leaves open
/// for M2.5-02, and a merge cannot resolve a flag it never received.
///
/// `payload` is `Data`, so it encodes as base64 — neither greppable nor
/// diffable. It is `nil` for every event the app currently creates; only M4's
/// `externalUpdate` will populate one, and embedding it as nested JSON belongs
/// to the task that first writes one and knows its shape.
public struct ExportedEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let timestamp: Date
    public let kind: EventKind
    public let body: String
    public let payload: Data?
    public let isRedacted: Bool
}

/// §3.4. The `task` relationship is never serialized — it is the same fact as
/// `taskID`, expressed as a cycle.
public struct ExportedSourceRef: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let kind: SourceRefKind
    public let identifier: String
    public let url: String?

    /// Cached external data, omitted unless §10.2's opt-in is set.
    ///
    /// The two travel together because §10.1 resolves them as a pair — later
    /// `lastFetchedAt` wins, `nil` loses to any value — exactly as
    /// `SourceRef.recordFetch` moves them together.
    public let lastFetchedAt: Date?
    public let cachedSummary: String?
}

/// §3.5, `isUndone` included, for `ExportedEvent.isRedacted`'s reason.
public struct ExportedReport: Codable, Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let generatedAt: Date
    public let windowStart: Date
    public let windowEnd: Date
    public let markdownBody: String
    public let wasAIGenerated: Bool
    public let modelUsed: String?
    public let isUndone: Bool
}

// The model-to-record mappings live in extensions so each struct keeps its
// synthesized memberwise initialiser, which the tests build expectations with.

extension ExportedProject {
    init(_ project: Project) {
        self.init(
            id: project.id,
            name: project.name,
            colorHex: project.colorHex,
            jiraProjectKeys: project.jiraProjectKeys,
            isArchived: project.isArchived,
            sortOrder: project.sortOrder,
            lastStandupAt: project.lastStandupAt,
            reportCadence: project.reportCadence,
            staleThresholdDays: project.staleThresholdDays,
            modifiedAt: project.modifiedAt)
    }
}

extension ExportedTask {
    init(_ task: TaskItem) {
        self.init(
            id: task.id,
            title: task.title,
            projectID: task.projectID,
            status: task.status,
            createdAt: task.createdAt,
            statusChangedAt: task.statusChangedAt,
            completedAt: task.completedAt,
            isArchived: task.isArchived,
            modifiedAt: task.modifiedAt)
    }
}

extension ExportedEvent {
    init(_ event: Event) {
        self.init(
            id: event.id,
            taskID: event.taskID,
            timestamp: event.timestamp,
            kind: event.kind,
            body: event.body,
            payload: event.payload,
            isRedacted: event.isRedacted)
    }
}

extension ExportedSourceRef {
    /// - Parameter includingCachedData: §10.2's opt-in. When `false` the two
    ///   cached fields are `nil` here regardless of what the row holds, which
    ///   `encodeIfPresent` then omits. The ref itself, and every other field of
    ///   it, is always carried: §10.2 omits the two fields, never the array.
    init(_ ref: SourceRef, includingCachedData: Bool) {
        self.init(
            id: ref.id,
            taskID: ref.taskID,
            kind: ref.kind,
            identifier: ref.identifier,
            url: ref.url,
            lastFetchedAt: includingCachedData ? ref.lastFetchedAt : nil,
            cachedSummary: includingCachedData ? ref.cachedSummary : nil)
    }
}

extension ExportedReport {
    init(_ report: StandupReport) {
        self.init(
            id: report.id,
            projectID: report.projectID,
            generatedAt: report.generatedAt,
            windowStart: report.windowStart,
            windowEnd: report.windowEnd,
            markdownBody: report.markdownBody,
            wasAIGenerated: report.wasAIGenerated,
            modelUsed: report.modelUsed,
            isUndone: report.isUndone)
    }
}
