import Foundation

/// What an import will do, and the merged store it will do it from.
///
/// **The plan carries `merged`, so `apply` writes what the preview displayed.**
/// M2.5-03's acceptance criterion is that the preview's counts match what the
/// import actually does, and a preview that under-reports is worse than no
/// preview. Recomputing the merge at apply time would make that a property of
/// two code paths agreeing; carrying it makes it true by construction.
public struct ImportPlan: Equatable, Sendable {
    /// §10.4's three categories: `+ new`, `~ updated`, `= already present`.
    public struct Counts: Equatable, Sendable {
        public let inserted: Int
        public let updated: Int
        public let unchanged: Int

        var isNoOp: Bool { inserted == 0 && updated == 0 }
    }

    /// The ids `apply` will write, per type. **It touches nothing else.**
    ///
    /// Derived in the same pass as the counts, so "the preview's counts match
    /// what the import actually does" is one computation rather than two that
    /// agree. Before this existed, `apply` wrote every merged row — including
    /// rows it had just counted as unchanged, which quantized their
    /// full-precision local timestamps to wire precision for no reason, and did
    /// it even when the plan was empty.
    public struct Writes: Equatable, Sendable {
        public let projects: Set<UUID>
        public let tasks: Set<UUID>
        public let events: Set<UUID>
        public let sourceRefs: Set<UUID>
        public let reports: Set<UUID>
    }

    public let merged: MergedStore
    public let writes: Writes

    /// The local store this plan was computed against.
    ///
    /// `apply` refuses a plan whose store has moved underneath it. The preview
    /// is the user's only chance to inspect before committing (§10.4), and a
    /// plan applied to a store that has since changed describes something other
    /// than what happens — it would also overwrite the newer rows with the
    /// merge's older resolution of them.
    ///
    /// **The whole snapshot, not a hash of it.** This was an `Int` fingerprint
    /// until review of PR #29 pointed out that `Hashable` promises only that
    /// equal values hash equally — two different snapshots may collide, and the
    /// consequence of a collision here is a stale plan applied over newer data.
    /// A 64-bit collision is vanishingly unlikely and that is not a good enough
    /// reason to reason probabilistically about whether the user's edits
    /// survive. The plan already carries `merged`, so this roughly doubles a
    /// value that lives only as long as the preview is open.
    public let source: MergedStore

    public let projects: Counts
    public let tasks: Counts
    public let events: Counts
    public let sourceRefs: Counts
    public let reports: Counts

    /// Tasks whose status the merge changed — §10.4's parenthetical, "status
    /// changed on the other machine".
    public let statusChanged: [UUID]

    /// Events whose `statusChanged` body would not parse. Not a failure; see
    /// `StatusTransition.init?(eventBody:)`.
    public let unparsedStatusBodies: [UUID]

    /// Nothing to do. **The second import of the same file is this**, which is
    /// §10.6's idempotency criterion stated as one property, and M2.5-03's cue
    /// to say "nothing to import" rather than show an empty preview.
    public var isEmpty: Bool {
        projects.isNoOp && tasks.isNoOp && events.isNoOp && sourceRefs.isNoOp && reports.isNoOp
    }
}

extension ImportPlan {
    /// The diff of `local` against the merge's output.
    ///
    /// Both sides are already at wire precision, which is why "has this record
    /// changed?" can be a plain `==` on the record structs. Comparing
    /// full-precision `Date`s here would report every row as updated on every
    /// import, and D-101 is the reason.
    init(local: MergedStore, result: MergeResult) {
        let merged = result.store
        let localStatus = Dictionary(
            local.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })

        let projects = Self.diff(local: local.projects, merged: merged.projects)
        let tasks = Self.diff(local: local.tasks, merged: merged.tasks)
        let events = Self.diff(local: local.events, merged: merged.events)
        let refs = Self.diff(local: local.sourceRefs, merged: merged.sourceRefs)
        let reports = Self.diff(local: local.reports, merged: merged.reports)

        self.init(
            merged: merged,
            writes: Writes(
                projects: projects.writes, tasks: tasks.writes, events: events.writes,
                sourceRefs: refs.writes, reports: reports.writes),
            source: local,
            projects: projects.counts,
            tasks: tasks.counts,
            events: events.counts,
            sourceRefs: refs.counts,
            reports: reports.counts,
            statusChanged: merged.tasks
                .filter { task in localStatus[task.id].map { $0 != task.status } ?? false }
                .map(\.id),
            unparsedStatusBodies: result.unparsedStatusBodies)
    }

    /// Counts and write set from one walk, so they cannot disagree.
    private static func diff<Element: ExportRecord>(
        local: [Element], merged: [Element]
    ) -> (counts: Counts, writes: Set<UUID>) {
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: this side comes
        // from our own snapshot so duplicates should be impossible, and trapping
        // on "should be impossible" is how a malformed store takes the process
        // down instead of producing an error.
        let localByID = Dictionary(
            local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var writes: Set<UUID> = []

        for record in merged {
            guard let mine = localByID[record.id] else {
                inserted += 1
                writes.insert(record.id)
                continue
            }
            if mine == record {
                unchanged += 1
            } else {
                updated += 1
                writes.insert(record.id)
            }
        }
        return (Counts(inserted: inserted, updated: updated, unchanged: unchanged), writes)
    }
}

/// The one thing the five record types have in common, so the diff is written
/// once rather than five times.
///
/// Declared here rather than on the records themselves: §10.2's DTOs mirror
/// their §3 field tables top to bottom, and a protocol conformance in that file
/// would be the first thing in it that is not a field.
protocol ExportRecord: Equatable {
    var id: UUID { get }
}

extension ExportedProject: ExportRecord {}
extension ExportedTask: ExportRecord {}
extension ExportedEvent: ExportRecord {}
extension ExportedSourceRef: ExportRecord {}
extension ExportedReport: ExportRecord {}
