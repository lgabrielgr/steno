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
        let store = plan.merged
        // Parents first. SwiftData does not require it; a debugger stepping
        // through this does.
        try applyProjects(store.projects)
        try applyTasks(store.tasks)
        try applyEvents(store.events)
        try applyRefs(store.sourceRefs)
        try applyReports(store.reports)

        do {
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
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Model>()).map { (id($0), $0) })
    }

    private func applyProjects(_ records: [ExportedProject]) throws {
        let rows = try existing(Project.self, id: { $0.id })
        for record in records {
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

    private func applyTasks(_ records: [ExportedTask]) throws {
        let rows = try existing(TaskItem.self, id: { $0.id })
        for record in records {
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
    private func applyEvents(_ records: [ExportedEvent]) throws {
        let rows = try existing(Event.self, id: { $0.id })
        for record in records {
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

    private func applyRefs(_ records: [ExportedSourceRef]) throws {
        let rows = try existing(SourceRef.self, id: { $0.id })
        let tasks = try existing(TaskItem.self, id: { $0.id })
        for record in records {
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

    private func applyReports(_ records: [ExportedReport]) throws {
        let rows = try existing(StandupReport.self, id: { $0.id })
        for record in records {
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
