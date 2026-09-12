import Foundation

/// §10.1's merge: union by UUID, with deterministic resolution for the fields
/// that are not append-only.
///
/// **Pure, and `nonisolated` deliberately.** Nothing here touches SwiftData or
/// the main actor, which is what lets §10.6's three algebraic properties —
/// idempotent, commutative, non-destructive — be asserted as comparisons between
/// values rather than as round-trips through two live stores.
///
/// **No record is ever removed.** Union in both directions; a local row the file
/// lacks survives untouched, and a file row the store lacks is inserted. The
/// only writes to a record present on both sides are the ones the table below
/// describes.
///
/// | Record | Rule |
/// |---|---|
/// | `Event` | Insert if absent; `isRedacted` sticky-true, and nothing else |
/// | `StandupReport` | Insert if absent; `isUndone` sticky-true |
/// | `SourceRef` | Insert if absent; later `lastFetchedAt` wins, `nil` loses |
/// | `TaskItem` | Status group derived from events; rest by later `modifiedAt` |
/// | `Project` | `lastStandupAt` derived; rest by later `modifiedAt` |
enum StoreMerge {
    static func merge(local: MergedStore, incoming: MergedStore) throws -> MergeResult {
        // Events before tasks and reports before projects: both derivations read
        // the *merged* set, not either side's.
        let events = try mergeEvents(local.events, incoming.events)
        let reports = try mergeReports(local.reports, incoming.reports)
        let refs = try mergeRefs(local.sourceRefs, incoming.sourceRefs)
        let (tasks, unparsed) = try mergeTasks(local.tasks, incoming.tasks, events: events)
        let projects = try mergeProjects(local.projects, incoming.projects, reports: reports)

        // D-092's order, so `merge(A,B) == merge(B,A)` is an assertion about
        // convergence rather than about the order a dictionary happened to
        // enumerate in.
        let merged = MergedStore(
            projects: projects.sorted(by: ExportOrdering.precedes),
            tasks: ExportOrdering.sortedByWireInstant(
                tasks, instant: { $0.createdAt }, id: { $0.id }),
            events: ExportOrdering.sortedByWireInstant(
                events, instant: { $0.timestamp }, id: { $0.id }),
            sourceRefs: refs.sorted(by: ExportOrdering.precedes),
            reports: ExportOrdering.sortedByWireInstant(
                reports, instant: { $0.generatedAt }, id: { $0.id }))

        try validateClosure(of: merged)
        return MergeResult(store: merged, unparsedStatusBodies: unparsed)
    }

    /// Union by id, resolving collisions.
    ///
    /// The dictionary's enumeration order is unspecified and does not matter:
    /// every array is sorted into D-092's total order before it leaves `merge`.
    private static func union<Element>(
        _ local: [Element],
        _ incoming: [Element],
        id: (Element) -> UUID,
        kind: String,
        resolve: (Element, Element) throws -> Element
    ) throws -> [Element] {
        // **Both sides go through `indexed`, which throws on a duplicate id.**
        // This built the map with a plain subscript until review of PR #29: a
        // duplicate in `local` silently overwrote the earlier row — losing a
        // physical record before the immutable-field checks ever ran — and a
        // duplicate in `incoming` was folded through `resolve` as though it were
        // the other machine's copy of the same record. `mergeTasks` and
        // `mergeProjects` already refused both; events, reports and refs did
        // not, so three of the five types bypassed the guard.
        var byID = try indexed(local, id: id, kind: kind)
        for (key, element) in try indexed(incoming, id: id, kind: kind) {
            byID[key] = try byID[key].map { try resolve($0, element) } ?? element
        }
        return Array(byID.values)
    }
}

// MARK: - Append-only records: insert, or flip one flag

extension StoreMerge {
    private static func mergeEvents(
        _ local: [ExportedEvent], _ incoming: [ExportedEvent]
    ) throws -> [ExportedEvent] {
        try union(
            local, incoming, id: { $0.id }, kind: "event",
            resolve: { mine, theirs in
                // §3.3: an event's content is never rewritten, so one id must mean
                // one event. A file that disagrees is a different lineage under a
                // colliding UUID, and picking a winner would silently discard the
                // other — refusing is the only honest option.
                guard mine.taskID == theirs.taskID, mine.timestamp == theirs.timestamp,
                    mine.kind == theirs.kind, mine.body == theirs.body,
                    mine.payload == theirs.payload
                else {
                    throw ImportError.inconsistentRecord(
                        detail: "Two different events share the id \(mine.id).")
                }
                // The one permitted write, and the whole of O-8's answer for events.
                return ExportedEvent(
                    id: mine.id, taskID: mine.taskID, timestamp: mine.timestamp, kind: mine.kind,
                    body: mine.body, payload: mine.payload,
                    isRedacted: mine.isRedacted || theirs.isRedacted)
            })
    }

    private static func mergeReports(
        _ local: [ExportedReport], _ incoming: [ExportedReport]
    ) throws -> [ExportedReport] {
        // **Checked here as well as in `ImportReader`**, for the reason the cache
        // pair is: `merge` is the value-level entry point and takes input it
        // cannot trace. An undone report with `windowStart > windowEnd` makes
        // `LastStandupClock` advance the project's clock past the report's own
        // window end, so an invalid result must not be able to escape this
        // function even when nobody read a file.
        for report in local + incoming where report.windowStart > report.windowEnd {
            throw ImportError.malformed(
                detail:
                    "A stand-up report covers a window that ends before it starts "
                    + "(\(report.windowStart) to \(report.windowEnd)).")
        }

        return try union(
            local, incoming, id: { $0.id }, kind: "stand-up report",
            resolve: { mine, theirs in
                guard mine.projectID == theirs.projectID, mine.generatedAt == theirs.generatedAt,
                    mine.windowStart == theirs.windowStart, mine.windowEnd == theirs.windowEnd,
                    mine.markdownBody == theirs.markdownBody,
                    mine.wasAIGenerated == theirs.wasAIGenerated, mine.modelUsed == theirs.modelUsed
                else {
                    throw ImportError.inconsistentRecord(
                        detail: "Two different stand-up reports share the id \(mine.id).")
                }
                return ExportedReport(
                    id: mine.id, projectID: mine.projectID, generatedAt: mine.generatedAt,
                    windowStart: mine.windowStart, windowEnd: mine.windowEnd,
                    markdownBody: mine.markdownBody, wasAIGenerated: mine.wasAIGenerated,
                    modelUsed: mine.modelUsed, isUndone: mine.isUndone || theirs.isUndone)
            })
    }
}

// MARK: - SourceRef: the cached pair, and the duplicates that are kept

extension StoreMerge {
    /// **Duplicates by §3.4's dedup key are kept, not collapsed.**
    ///
    /// Two machines that each extract `PAY-421` onto a task they both already
    /// have produce two rows with different ids and the same
    /// `(taskID, kind, identifier)`. Collapsing them would converge too, and it
    /// would make import the only path in the product outside Replace mode that
    /// deletes a row — "import never deletes, except duplicate refs" is the kind
    /// of documented exception that becomes the next task's bug. Keeping both
    /// satisfies every §10.6 property, since `merge(A,B)` and `merge(B,A)` both
    /// yield the pair. The cost is a duplicate chip in the detail pane; O-10
    /// already owns §3.4 ref reconciliation and is extended to name this.
    private static func mergeRefs(
        _ local: [ExportedSourceRef], _ incoming: [ExportedSourceRef]
    ) throws -> [ExportedSourceRef] {
        // **Validated for every ref on both sides, before the union.** This ran
        // only inside the collision resolver until review of PR #29, so a
        // malformed ref present on just one side passed straight through — and
        // the comment below claimed this layer guarded callers that do not come
        // via `ImportReader`, which it did not. `merge` could then return a
        // record carrying `cachedSummary` with no `lastFetchedAt`, which
        // `ImportService.applyRefs` cannot apply: it records a fetch only when it
        // has a date, so the summary was dropped and the plan described something
        // that did not happen.
        for ref in local + incoming { try validateCachePair(of: ref) }

        return try union(
            local, incoming, id: { $0.id }, kind: "source reference",
            resolve: { mine, theirs in
                guard mine.taskID == theirs.taskID, mine.kind == theirs.kind,
                    mine.identifier == theirs.identifier, mine.url == theirs.url
                else {
                    throw ImportError.inconsistentRecord(
                        detail: "Two different source references share the id \(mine.id).")
                }
                let cache = try resolveCache(mine, theirs)
                return ExportedSourceRef(
                    id: mine.id, taskID: mine.taskID, kind: mine.kind, identifier: mine.identifier,
                    url: mine.url, lastFetchedAt: cache.fetchedAt, cachedSummary: cache.summary)
            })
    }

    /// §10.1: later `lastFetchedAt` wins, `nil` loses to any value, and the two
    /// travel together — exactly as `SourceRef.recordFetch` moves them.
    ///
    /// The pair matters: resolving the summary independently of its timestamp
    /// would let a store claim a summary was fetched at a moment it was not.
    private static func resolveCache(
        _ mine: ExportedSourceRef, _ theirs: ExportedSourceRef
    ) throws -> (fetchedAt: Date?, summary: String?) {
        switch (mine.lastFetchedAt, theirs.lastFetchedAt) {
        case (nil, .some):
            return (theirs.lastFetchedAt, theirs.cachedSummary)
        case (.some, nil):
            return (mine.lastFetchedAt, mine.cachedSummary)
        case (.some(let mineAt), .some(let theirsAt)) where theirsAt > mineAt:
            return (theirs.lastFetchedAt, theirs.cachedSummary)
        case (.some(let mineAt), .some(let theirsAt)) where mineAt > theirsAt:
            return (mine.lastFetchedAt, mine.cachedSummary)
        case (nil, nil), (.some, .some):
            // A tie on the governing clock. The summaries must therefore agree,
            // and validating that is what makes "local wins" commutative rather
            // than merely convenient.
            guard mine.cachedSummary == theirs.cachedSummary else {
                throw ImportError.inconsistentRecord(
                    detail:
                        "Source reference \(mine.identifier) has two different cached summaries "
                        + "fetched at the same moment.")
            }
            return (mine.lastFetchedAt, mine.cachedSummary)
        }
    }
}

// MARK: - Closure

extension StoreMerge {
    /// Every child's parent exists **in the merged store** — which is to say, in
    /// the file or already on this Mac.
    ///
    /// Checking the union rather than the file alone is what keeps §10.2's
    /// hand-editability promise: trimming one project out of an export still
    /// imports cleanly on a machine that already has that project, and only a
    /// file that would actually leave a broken store is refused. A genuine Steno
    /// export always has closure, since it is whole-store and nothing is ever
    /// deleted, so a file that lacks it is truncated or hand-trimmed.
    ///
    /// The alternative was importing orphans: rows that appear under no sidebar
    /// project and in no timeline, invisible in the preview counts, with nothing
    /// that would ever surface them.
    private static func validateClosure(of store: MergedStore) throws {
        let projectIDs = Set(store.projects.map { $0.id })
        let taskIDs = Set(store.tasks.map { $0.id })

        for task in store.tasks where !projectIDs.contains(task.projectID) {
            throw ImportError.danglingReference(
                detail: "The task \"\(task.title)\" belongs to a project that is missing.")
        }
        for event in store.events where !taskIDs.contains(event.taskID) {
            throw ImportError.danglingReference(
                detail: "A timeline entry belongs to a task that is missing.")
        }
        for ref in store.sourceRefs where !taskIDs.contains(ref.taskID) {
            throw ImportError.danglingReference(
                detail: "The reference to \(ref.identifier) belongs to a task that is missing.")
        }
        for report in store.reports where !projectIDs.contains(report.projectID) {
            throw ImportError.danglingReference(
                detail: "A stand-up report belongs to a project that is missing.")
        }
    }
}

extension StoreMerge {
    /// §10.2 writes `lastFetchedAt` and `cachedSummary` together or omits both,
    /// and `SourceRef.recordFetch` cannot produce any other state.
    ///
    /// `ImportReader` refuses such a file first. This is the guard for callers
    /// that do not come through the reader — `merge` takes values and does not
    /// know where they came from — and it runs over **every** ref on both sides,
    /// not only refs that collide on an id.
    static func validateCachePair(of ref: ExportedSourceRef) throws {
        guard ref.cachedSummary == nil || ref.lastFetchedAt != nil else {
            throw ImportError.malformed(
                detail:
                    "The reference to \(ref.identifier) has a cached summary but no fetch time; "
                    + "§10.2 writes those two together or not at all.")
        }
    }
}
