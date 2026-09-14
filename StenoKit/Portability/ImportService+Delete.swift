import Foundation
import SwiftData

/// **The only code in this product that removes a row**, in a file of its own.
///
/// Split out of `ImportService.swift` when that file crossed SwiftLint's
/// 400-line limit, and kept split for a better reason than line count: §3.3
/// and CLAUDE.md's non-negotiable #3 forbid deleting an `Event`, §10.1's
/// Replace requires it, and D-106 resolves that by confining the exception.
/// A reader looking for "what in Steno can delete my data" should find one
/// file with one answer.
///
/// Nothing here is reachable without an `ImportPlan` built in `.replace`:
/// every call reads `plan.deletions`, and a `.merge` plan cannot populate it
/// because the merged store it is diffed against is a union of both sides.
extension ImportService {
    /// §10.1's Replace, and **the only code in this product that removes a
    /// row.**
    ///
    /// CLAUDE.md's non-negotiable #3 and §3.3 forbid deleting an `Event`;
    /// §10.1 requires exactly that of Replace. The exception is confined here,
    /// and the confinement is structural rather than documentary: this reads
    /// `plan.deletions`, which a `.merge` plan cannot populate because the
    /// merged store it is diffed against is a union of both sides. D-106
    /// records the reasoning.
    ///
    /// **Children before parents**, the mirror of the write order. The one real
    /// relationship is `TaskItem.sourceRefs` ⟷ `SourceRef.task` under the
    /// default nullify rule, so deleting a task first would write every one of
    /// its refs on the way past — rows that are themselves about to be deleted.
    /// The file's referential closure (D-102) is what guarantees this set is
    /// itself closed: a surviving ref's task survives, so a deleted task's refs
    /// are always in this set too.
    func deleteRecords(_ ids: ImportPlan.Writes, from context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        try delete(StandupReport.self, id: { $0.id }, ids: ids.reports, in: context)
        try delete(SourceRef.self, id: { $0.id }, ids: ids.sourceRefs, in: context)
        try delete(Event.self, id: { $0.id }, ids: ids.events, in: context)
        try delete(TaskItem.self, id: { $0.id }, ids: ids.tasks, in: context)
        try delete(Project.self, id: { $0.id }, ids: ids.projects, in: context)
    }

    /// **Every row carrying a doomed id, not one row per id.**
    ///
    /// This went through `existing(_:id:in:)` — a `[UUID: Model]` built with
    /// `uniquingKeysWith:` — so a store holding two physical rows under one id
    /// lost exactly one of them and kept the other. That state is *reachable
    /// only on this path*, because D-107 has Replace skip the duplicate check
    /// precisely so a malformed store can still be recovered; leaving a row
    /// behind is the one outcome Replace must not produce. Raised in review of
    /// PR #30, against a D-107 that claimed the opposite.
    func delete<Model: PersistentModel>(
        _ type: Model.Type, id: (Model) -> UUID, ids: Set<UUID>, in context: ModelContext
    ) throws {
        guard !ids.isEmpty else { return }
        let rows: [Model]
        do {
            rows = try context.fetch(FetchDescriptor<Model>())
        } catch {
            throw ImportError.storeUnreadable(detail: error.localizedDescription)
        }
        for row in rows where ids.contains(id(row)) {
            context.delete(row)
        }
    }
}
