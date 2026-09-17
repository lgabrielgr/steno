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
    ///
    /// **No `deleted` field, deliberately.** A per-type deletion count is
    /// already `deletions.<type>.count`, and storing it here as well would be
    /// two representations of one fact with nothing keeping them in step. The
    /// preview reads the sets.
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
    ///
    /// Reused for `deletions`, which names ids rather than records for the same
    /// reason: the row itself is already in the store.
    public struct Writes: Equatable, Sendable {
        public let projects: Set<UUID>
        public let tasks: Set<UUID>
        public let events: Set<UUID>
        public let sourceRefs: Set<UUID>
        public let reports: Set<UUID>

        public static let none = Writes(
            projects: [], tasks: [], events: [], sourceRefs: [], reports: [])

        public var isEmpty: Bool {
            projects.isEmpty && tasks.isEmpty && events.isEmpty && sourceRefs.isEmpty
                && reports.isEmpty
        }
    }

    /// How many **physical rows** each type's deletion actually removes.
    ///
    /// **Not the same as `deletions.<type>.count`, and the difference is a
    /// preview that lies.** The deletion set holds one entry per doomed *id*,
    /// while `delete` removes every row carrying one — so a malformed store
    /// with two rows under one id had the preview announce "1 task will be
    /// deleted" over work that destroyed two. §10.4's whole point is that the
    /// counts match what the import does, and "a preview that under-reports is
    /// worse than no preview". Raised in review of PR #30, against the fix for
    /// the duplicate-row defect earlier in the same review.
    ///
    /// Equal to the set counts for any well-formed store, which is every store
    /// reachable through `.merge` — `validateShape` refuses a duplicate there.
    public struct RowCounts: Equatable, Sendable {
        public let projects: Int
        public let tasks: Int
        public let events: Int
        public let sourceRefs: Int
        public let reports: Int

        public static let none = RowCounts(
            projects: 0, tasks: 0, events: 0, sourceRefs: 0, reports: 0)
    }

    /// The envelope the file arrived in — §10.2's `exportedAt`, `exportedBy`
    /// and `includesCachedExternalData`.
    ///
    /// Carried so the preview can say where the file came from. The task asks
    /// the summary to be "specific enough to catch importing the wrong file",
    /// and counts alone are not: twelve new tasks looks identical whichever
    /// file produced them. A provenance line is what catches last month's
    /// export.
    public struct Origin: Equatable, Sendable {
        public let exportedAt: Date
        public let exportedBy: String
        public let includesCachedExternalData: Bool
    }

    public let mode: ImportMode
    public let origin: Origin
    public let merged: MergedStore
    public let writes: Writes

    /// The ids `apply` will **delete**, per type.
    ///
    /// **Empty in `.merge`, by construction rather than by care.** The merged
    /// store is a union of both sides there, so no local id can be absent from
    /// it and this set cannot be populated. That is §10.1's "a merge never
    /// deletes a task the import file lacks" expressed as a value a test can
    /// assert over every fixture in the suite, rather than as a promise in
    /// prose.
    ///
    /// It is also the whole of the exception to the append-only rule. §3.3 and
    /// CLAUDE.md's non-negotiable #3 forbid removing an `Event`; §10.1's
    /// Replace mode requires it. Confining the deletion to this one field means
    /// the only way to reach it is to have built a plan in `.replace` — see
    /// D-106.
    public let deletions: Writes

    /// Physical rows the deletion removes — see `RowCounts`.
    public let deletedRows: RowCounts

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
    ///
    /// **In `.replace` this is still the real local store**, not the empty one
    /// the merge ran against — the staleness question is about the rows that
    /// are there now, whatever the merge chose to ignore.
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
    ///
    /// **Deletions count.** A Replace whose file happens to contain every local
    /// record but fewer of them would otherwise read as nothing to do, and the
    /// one preview that most needs showing would be suppressed.
    public var isEmpty: Bool {
        projects.isNoOp && tasks.isNoOp && events.isNoOp && sourceRefs.isNoOp && reports.isNoOp
            && deletions.isEmpty && !replaceWouldCollapseDuplicates
    }

    /// Does a `.replace` still have work to do even though every id agrees?
    ///
    /// **Id-level emptiness is not row-level emptiness, and only Replace can
    /// tell the difference.** `id` carries no `@Attribute(.unique)`, so a
    /// damaged store can hold two physical rows under one id — and `.replace` is
    /// the one mode that reaches `plan` without `StoreMerge.validateShape`
    /// refusing such a store first (D-106), because refusing it would disable
    /// recovery in exactly the situation Replace exists for.
    ///
    /// For such a row whose id *is* in the file with identical content: `writes`
    /// is empty (it is `unchanged`), `deletions` is empty (the id survives), and
    /// `deletedRows` is 0 — it counts rows under *doomed* ids, so it cannot see
    /// this one either. `isEmpty` was therefore true, `apply` returned without
    /// writing, and the duplicate survived while Replace reported success and
    /// promises the store *is* the file. Raised in review of PR #31.
    ///
    /// Comparing totals is enough because `.replace` installs the file whole:
    /// any disagreement between what the store physically holds and what the
    /// file describes is work. A merge is unaffected — it never removes a row,
    /// so its totals legitimately differ.
    private var replaceWouldCollapseDuplicates: Bool {
        guard mode == .replace else { return false }
        return source.projects.count != merged.projects.count
            || source.tasks.count != merged.tasks.count
            || source.events.count != merged.events.count
            || source.sourceRefs.count != merged.sourceRefs.count
            || source.reports.count != merged.reports.count
    }
}

extension ImportPlan {
    /// The diff of `local` against the merge's output.
    ///
    /// Both sides are already at wire precision, which is why "has this record
    /// changed?" can be a plain `==` on the record structs. Comparing
    /// full-precision `Date`s here would report every row as updated on every
    /// import, and D-101 is the reason.
    ///
    /// **`local` is always the real local store, in both modes.** In `.replace`
    /// the merge ran against an empty store, so `result.store` is the file
    /// alone — but the diff is still taken against what is actually here, which
    /// is what keeps "61 records already present" true and meaningful in a
    /// Replace preview. Diffing against the empty store the merge used would
    /// report every record in the file as new, including the ones already
    /// there.
    init(local: MergedStore, result: MergeResult, mode: ImportMode, origin: Origin) {
        let merged = result.store
        let localStatus = Dictionary(
            local.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })

        let projects = Self.diff(local: local.projects, merged: merged.projects)
        let tasks = Self.diff(local: local.tasks, merged: merged.tasks)
        let events = Self.diff(local: local.events, merged: merged.events)
        let refs = Self.diff(local: local.sourceRefs, merged: merged.sourceRefs)
        let reports = Self.diff(local: local.reports, merged: merged.reports)

        self.init(
            mode: mode,
            origin: origin,
            merged: merged,
            writes: Writes(
                projects: projects.writes, tasks: tasks.writes, events: events.writes,
                sourceRefs: refs.writes, reports: reports.writes),
            deletions: Writes(
                projects: projects.deletions, tasks: tasks.deletions, events: events.deletions,
                sourceRefs: refs.deletions, reports: reports.deletions),
            deletedRows: RowCounts(
                projects: projects.deletedRows, tasks: tasks.deletedRows,
                events: events.deletedRows, sourceRefs: refs.deletedRows,
                reports: reports.deletedRows),
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

    /// One record type's diff: what it says, what to write, what to delete.
    ///
    /// A named type rather than a three-member tuple, which SwiftLint's
    /// `large_tuple` rejects under `--strict` — and which reads worse at both
    /// call sites anyway.
    struct Diff {
        let counts: Counts
        let writes: Set<UUID>
        let deletions: Set<UUID>
        /// Physical rows behind `deletions`, which collapses duplicate ids.
        let deletedRows: Int
    }

    /// Counts, write set and deletion set from one walk, so they cannot
    /// disagree.
    private static func diff<Element: ExportRecord>(
        local: [Element], merged: [Element]
    ) -> Diff {
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: this side comes
        // from our own snapshot so duplicates should be impossible, and trapping
        // on "should be impossible" is how a malformed store takes the process
        // down instead of producing an error. Load-bearing in `.replace`, where
        // `plan` no longer refuses a locally duplicated store first — see
        // `ImportService.plan`.
        let localByID = Dictionary(
            local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var writes: Set<UUID> = []
        var survivors: Set<UUID> = []

        for record in merged {
            survivors.insert(record.id)
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
        let doomed = Set(localByID.keys).subtracting(survivors)
        return Diff(
            counts: Counts(inserted: inserted, updated: updated, unchanged: unchanged),
            writes: writes,
            deletions: doomed,
            // Counted over `local`, not over `localByID` — the dictionary is
            // exactly what collapses the duplicates this number exists to see.
            deletedRows: local.filter { doomed.contains($0.id) }.count)
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
