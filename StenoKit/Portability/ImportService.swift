import Foundation
import OSLog
import SwiftData

/// §10's import: read a file, say what it will change, then change it in one
/// transaction.
///
/// **Two calls, and cancelling is not making the second one.** M2.5-03's preview
/// renders a plan and applies that same plan; M2.5-04's CLI calls both in a row.
/// Neither surface reimplements any of the merge.
///
/// `@MainActor` because `ModelContext` is not `Sendable`, and `save` injected so
/// a failing transaction is testable — both for the reasons `StatusService`,
/// `NoteService` and `StandupService` already record.
@MainActor
public struct ImportService {
    private let context: ModelContext
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.save = save
    }

    /// Decode, validate, merge, diff. **Reads the store; writes nothing.**
    ///
    /// A caller that lets time pass between this and `apply` should call it
    /// again first. Steno is single-user and single-window, so the gap is
    /// theoretical — and a locking scheme to close it would be more machinery
    /// than the risk earns.
    public func plan(_ data: Data) throws -> ImportPlan {
        let document = try ImportReader.read(data)
        let local = try localStore()
        let result = try StoreMerge.merge(local: local, incoming: MergedStore(document))
        return ImportPlan(local: local, result: result)
    }

    /// The local store as a file would express it.
    ///
    /// **`includesCachedExternalData: true` is not optional here**, and the
    /// parameter defaults to `false`, so nothing but this comment and a test
    /// will ever ask. A cache-free snapshot presents every local `cachedSummary`
    /// and `lastFetchedAt` as `nil`, and §10.1's "nil loses to any value" would
    /// then hand every ref's cache to the incoming file — one word, and the
    /// user's offline summaries are gone.
    ///
    /// `exportedBy` is passed rather than defaulted for D-010's reason: the test
    /// bundle is unhosted, so `Bundle.main` there is the xctest runner. The
    /// value is discarded; passing it is cheaper than explaining that.
    private func localStore() throws -> MergedStore {
        let snapshot = try ExportEncoder(
            context: context,
            includesCachedExternalData: true,
            exportedBy: "steno/import (macOS)"
        ).snapshot()
        return try MergedStore(snapshot).wireNormalized()
    }
}

extension ImportService {
    /// Apply exactly what `plan` described, in one transaction.
    ///
    /// Every validation already ran on values, before this is reached, so the
    /// only failure left in flight is the save itself — which rolls back.
    public func apply(_ plan: ImportPlan) throws {
        // **An empty plan writes nothing and posts nothing.** It used to reapply
        // every merged row, save, and post `.stenoDidWrite` — so the second
        // import of a file made every observer reload, and would in M2.5-05 have
        // dirtied the store enough to trigger an auto-export, all while the
        // preview said there was nothing to do.
        guard !plan.isEmpty else { return }

        // The plan describes a diff against a store that may since have moved.
        guard try localStore() == plan.source else {
            throw ImportError.storeChanged
        }

        let store = plan.merged
        do {
            // **The whole sequence is inside the rollback, not just the save.**
            // Each `apply*` fetches before it writes, and a fetch that throws
            // after an earlier one has inserted rows would otherwise leave the
            // context partly mutated with no rollback — a later save by any
            // other service would then commit half an import.
            //
            // Parents first. SwiftData does not require it; a debugger stepping
            // through this does.
            try applyProjects(store.projects, writing: plan.writes.projects)
            try applyTasks(store.tasks, writing: plan.writes.tasks)
            try applyEvents(store.events, writing: plan.writes.events)
            try applyRefs(store.sourceRefs, writing: plan.writes.sourceRefs)
            try applyReports(store.reports, writing: plan.writes.reports)
            try save(context)
        } catch {
            context.rollback()
            throw ImportError.saveFailed(detail: error.localizedDescription)
        }

        // After the save, never before: an observer that reloads must not read a
        // context whose write has not landed (D-019).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
        Log.app.info("import applied: \(plan.tasks.inserted, privacy: .public) new tasks")
    }

    private func existing<Model: PersistentModel>(
        _ type: Model.Type, id: (Model) -> UUID
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
        Dictionary(
            try context.fetch(FetchDescriptor<Model>()).map { (id($0), $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private func applyProjects(
        _ records: [ExportedProject], writing ids: Set<UUID>
    ) throws {
        let rows = try existing(Project.self, id: { $0.id })
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

    private func applyTasks(
        _ records: [ExportedTask], writing ids: Set<UUID>
    ) throws {
        let rows = try existing(TaskItem.self, id: { $0.id })
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
    private func applyEvents(
        _ records: [ExportedEvent], writing ids: Set<UUID>
    ) throws {
        let rows = try existing(Event.self, id: { $0.id })
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

    private func applyRefs(
        _ records: [ExportedSourceRef], writing ids: Set<UUID>
    ) throws {
        let rows = try existing(SourceRef.self, id: { $0.id })
        let tasks = try existing(TaskItem.self, id: { $0.id })
        for record in records where ids.contains(record.id) {
            if let row = rows[record.id] {
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

    private func applyReports(
        _ records: [ExportedReport], writing ids: Set<UUID>
    ) throws {
        let rows = try existing(StandupReport.self, id: { $0.id })
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
