import Foundation
import SwiftData

/// §10.1's merge, row by row: insert what is absent, and write only the
/// fields the merge actually resolved.
///
/// Split out of `ImportService.swift` on SwiftLint's 400-line limit, and
/// worth keeping apart: **none of this is used by `.replace`.** For a row
/// present on both sides these branches flip `isRedacted` / `isUndone` or
/// refresh a cache and nothing else, which is correct only because a merge
/// guarantees an id collision means identical content — `mergeEvents` refuses
/// anything else. Replace merges against an empty base, so that guarantee
/// does not hold there and it wipes and reinstalls instead. See
/// `ImportService+Delete.swift` and D-112.
extension ImportService {
    func existing<Model: PersistentModel>(
        _ type: Model.Type, id: (Model) -> UUID, in context: ModelContext
    ) throws -> [UUID: Model] {
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`, which **traps**
        // on a duplicate key. §6 forbids `@Attribute(.unique)`, so nothing in the
        // store enforces that our `id` field is unique — a store that somehow
        // holds two rows under one id would take the process down here, during
        // an import, which is the one operation that must fail cleanly (§10.4).
        //
        // **Unreachable through `plan`/`apply` today**, and fixed anyway: the
        // merge's own duplicate guard refuses a locally duplicated store first,
        // so this is defence in depth for a caller that does not come through
        // the service. "Unreachable today" is what both of the traps found in
        // review of PR #29 were, right until they were not. Found auditing the
        // five record paths as a set — the merge was hardened against exactly
        // this twice, and this call site, shared by all five, was missed both
        // times.
        do {
            return Dictionary(
                try context.fetch(FetchDescriptor<Model>()).map { (id($0), $0) },
                uniquingKeysWith: { first, _ in first })
        } catch {
            throw ImportError.storeUnreadable(detail: error.localizedDescription)
        }
    }

    func applyProjects(
        _ records: [ExportedProject], writing ids: Set<UUID>, into context: ModelContext
    ) throws {
        let rows = try existing(Project.self, id: { $0.id }, in: context)
        for record in records where ids.contains(record.id) {
            if let row = rows[record.id] {
                row.applyImported(record)
                continue
            }
            let project = Project(
                id: record.id, name: record.name, colorHex: record.colorHex,
                modifiedAt: record.modifiedAt)
            context.insert(project)
            project.applyImported(record)
        }
    }

    func applyTasks(
        _ records: [ExportedTask], writing ids: Set<UUID>, into context: ModelContext
    ) throws {
        let rows = try existing(TaskItem.self, id: { $0.id }, in: context)
        for record in records where ids.contains(record.id) {
            if let row = rows[record.id] {
                row.applyImported(record)
                continue
            }
            let task = TaskItem(
                id: record.id, title: record.title, projectID: record.projectID,
                createdAt: record.createdAt)
            context.insert(task)
            task.applyImported(record)
        }
    }

    /// §3.3: an event is inserted or its one flag is flipped. There is no third
    /// case, and the model exposes no mutator that would allow one.
    func applyEvents(
        _ records: [ExportedEvent], writing ids: Set<UUID>, into context: ModelContext
    ) throws {
        let rows = try existing(Event.self, id: { $0.id }, in: context)
        for record in records where ids.contains(record.id) {
            if let row = rows[record.id] {
                if record.isRedacted && !row.isRedacted { row.redact() }
                continue
            }
            let event = Event(
                id: record.id, taskID: record.taskID, timestamp: record.timestamp,
                kind: record.kind, body: record.body, payload: record.payload)
            context.insert(event)
            // Held, not looked up again: `rows` was fetched before this insert,
            // so `rows[record.id]` is nil here and a redacted event would have
            // landed un-redacted — putting text the user took back into the next
            // stand-up. Caught by `ImportApplyTests`.
            if record.isRedacted { event.redact() }
        }
    }

    func applyRefs(
        _ records: [ExportedSourceRef], writing ids: Set<UUID>, into context: ModelContext
    ) throws {
        let rows = try existing(SourceRef.self, id: { $0.id }, in: context)
        let tasks = try existing(TaskItem.self, id: { $0.id }, in: context)
        for record in records where ids.contains(record.id) {
            if let row = rows[record.id] {
                // **Repair the relationship before touching the cache.** §3.4
                // makes `taskID` authoritative and the relationship is never
                // serialized, so a persisted row can carry the right `taskID`
                // and a nil or stale `task` — rows written before this path set
                // it, or built through the initializer, which permits it. Such a
                // ref has correct data and is invisible in the detail pane, and
                // an import that only refreshed its cache left it that way.
                if let owner = tasks[record.taskID], row.task !== owner {
                    row.task = owner
                }
                // Unconditional when the merge produced a cache: the previous
                // form compared `row.lastFetchedAt` — a full-precision `Date` —
                // against the merged, wire-rounded one, so it was never equal
                // and the "skip" branch was dead. Writing the resolved value is
                // what the other four record types do.
                if let fetchedAt = record.lastFetchedAt {
                    row.recordFetch(summary: record.cachedSummary, at: fetchedAt)
                }
                continue
            }
            let ref = SourceRef(
                id: record.id, taskID: record.taskID, kind: record.kind,
                identifier: record.identifier, url: record.url)
            context.insert(ref)
            // **Load-bearing, and silent if forgotten.** `taskID` is the
            // authoritative link (§3.4, D-016), but `TaskItem.sourceRefs` is the
            // inverse relationship the detail pane reads — a ref inserted
            // without this has correct data and is invisible in the UI.
            ref.task = tasks[record.taskID]
            if let fetchedAt = record.lastFetchedAt {
                ref.recordFetch(summary: record.cachedSummary, at: fetchedAt)
            }
        }
    }

    func applyReports(
        _ records: [ExportedReport], writing ids: Set<UUID>, into context: ModelContext
    ) throws {
        let rows = try existing(StandupReport.self, id: { $0.id }, in: context)
        for record in records where ids.contains(record.id) {
            if let row = rows[record.id] {
                if record.isUndone && !row.isUndone { row.markUndone() }
                continue
            }
            let report = StandupReport(
                id: record.id, projectID: record.projectID, generatedAt: record.generatedAt,
                windowStart: record.windowStart, windowEnd: record.windowEnd,
                markdownBody: record.markdownBody, wasAIGenerated: record.wasAIGenerated,
                modelUsed: record.modelUsed)
            context.insert(report)
            if record.isUndone { report.markUndone() }
        }
    }
}
