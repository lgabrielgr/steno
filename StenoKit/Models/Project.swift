import Foundation
import SwiftData

/// A project or a non-project activity — "Payments Platform", "EM — Hiring"
/// (REQUIREMENTS.md §3.1).
///
/// Flat: no epics, no nesting, no hierarchy (D9).
@Model
public final class Project {
    public private(set) var id: UUID = UUID()
    public private(set) var name: String = ""
    public private(set) var colorHex: String = ""
    public private(set) var jiraProjectKeys: [String] = []
    public private(set) var isArchived: Bool = false
    public private(set) var sortOrder: Int = 0

    /// When this project was last reported on — the report window per D8.
    ///
    /// The user attends multiple different stand-ups, so each project tracks
    /// its own timestamp: a report for project A must not advance the clock for
    /// project B.
    ///
    /// A plain `var`, not `private(set)`, and that is the design. §10.1 gives
    /// this field its own merge rule — take the later timestamp — so it must
    /// **not** stamp `modifiedAt`. A plain property gets that by construction;
    /// a mutator would get it by remembering.
    public var lastStandupAt: Date?

    public private(set) var reportCadence: ReportCadence = ReportCadence.daily

    /// Per-project staleness override. `nil` means derive from cadence, then
    /// fall back to the global default (FR-5).
    public private(set) var staleThresholdDays: Int?

    /// Last mutation of a field whose import conflict rule is
    /// "later `modifiedAt` wins" (§10.1). See `lastStandupAt` for what is
    /// excluded and why.
    public private(set) var modifiedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        jiraProjectKeys: [String] = [],
        sortOrder: Int = 0,
        reportCadence: ReportCadence = .daily,
        staleThresholdDays: Int? = nil,
        modifiedAt: Date
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.jiraProjectKeys = jiraProjectKeys
        self.sortOrder = sortOrder
        self.reportCadence = reportCadence
        self.staleThresholdDays = staleThresholdDays
        self.modifiedAt = modifiedAt
    }

    func rename(to newName: String, at date: Date) {
        name = newName
        modifiedAt = date
    }

    func setColorHex(_ newColorHex: String, at date: Date) {
        colorHex = newColorHex
        modifiedAt = date
    }

    func setJiraProjectKeys(_ keys: [String], at date: Date) {
        jiraProjectKeys = keys
        modifiedAt = date
    }

    func setArchived(_ archived: Bool, at date: Date) {
        isArchived = archived
        modifiedAt = date
    }

    func setSortOrder(_ order: Int, at date: Date) {
        sortOrder = order
        modifiedAt = date
    }

    func setCadence(_ cadence: ReportCadence, at date: Date) {
        reportCadence = cadence
        modifiedAt = date
    }

    func setStaleThresholdDays(_ days: Int?, at date: Date) {
        staleThresholdDays = days
        modifiedAt = date
    }
}

extension Project {
    /// Overwrite every field from an imported record, `modifiedAt` included.
    ///
    /// **Deliberately bypasses the stamping mutators.** `rename(to:at:)` and its
    /// siblings exist to record *when an edit happened*; an import is restoring
    /// a value the merge already resolved, and stamping it would overwrite the
    /// very timestamp §10.1 used to decide the record's fate — making the next
    /// merge disagree with this one.
    ///
    /// In this file because `private(set)` is file-scoped: an extension
    /// elsewhere could not write these, which is the property that keeps the
    /// setters private in the first place.
    ///
    /// `id` is absent because it is the identity, not a field. Every other
    /// stored property is written here, and `ImportFieldCoverageTests` asserts
    /// that over `Mirror` rather than trusting this comment — D-095 records what
    /// happens to a rule that depends on someone remembering a field.
    func applyImported(_ record: ExportedProject) {
        name = record.name
        colorHex = record.colorHex
        jiraProjectKeys = record.jiraProjectKeys
        isArchived = record.isArchived
        sortOrder = record.sortOrder
        lastStandupAt = record.lastStandupAt
        reportCadence = record.reportCadence
        staleThresholdDays = record.staleThresholdDays
        modifiedAt = record.modifiedAt
    }
}
