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

    public let merged: MergedStore
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
            uniqueKeysWithValues: local.tasks.map { ($0.id, $0.status) })

        self.init(
            merged: merged,
            projects: Self.counts(local: local.projects, merged: merged.projects),
            tasks: Self.counts(local: local.tasks, merged: merged.tasks),
            events: Self.counts(local: local.events, merged: merged.events),
            sourceRefs: Self.counts(local: local.sourceRefs, merged: merged.sourceRefs),
            reports: Self.counts(local: local.reports, merged: merged.reports),
            statusChanged: merged.tasks
                .filter { task in localStatus[task.id].map { $0 != task.status } ?? false }
                .map(\.id),
            unparsedStatusBodies: result.unparsedStatusBodies)
    }

    private static func counts<Element: ExportRecord>(
        local: [Element], merged: [Element]
    ) -> Counts {
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var inserted = 0
        var updated = 0
        var unchanged = 0

        for record in merged {
            guard let mine = localByID[record.id] else {
                inserted += 1
                continue
            }
            if mine == record { unchanged += 1 } else { updated += 1 }
        }
        return Counts(inserted: inserted, updated: updated, unchanged: unchanged)
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
