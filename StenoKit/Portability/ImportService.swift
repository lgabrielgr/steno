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
    public func plan(_ data: Data, mode: ImportMode = .merge) throws -> ImportPlan {
        // **A context with unsaved work cannot be imported into coherently.**
        // `plan` snapshots this context, and a fetch sees pending inserts and
        // edits — but `apply` stages into a scratch context built from the
        // *persisted* container, which does not have them. The merge would then
        // resolve against rows the transaction cannot see: an event whose task
        // exists only as a pending insert would commit orphaned. Every service in
        // this app saves as it writes, so this is a guard on a state the app does
        // not normally produce, not a workflow restriction.
        guard !context.hasChanges else { throw ImportError.unsavedLocalChanges }

        let document = try ImportReader.read(data)
        let local = try localStore()
        // **Validated before the merge, so the blame lands on the right side.**
        // `merge` checks both stores and reports only that something was
        // malformed — and `ImportError.malformed`'s message opens "This file
        // isn't a readable Steno export." For corruption in *this Mac's* store
        // that tells the user to repair a file that is perfectly good.
        //
        // **Skipped entirely in `.replace`, and that is the point of Replace.**
        // §10.1 has it exist "for restoring a known-good snapshot", so refusing
        // to run it because *this Mac's* store is malformed would disable the
        // recovery operation in precisely the situation it was built for. The
        // local store is not an input to a replace merge — nothing it contains
        // can reach the result — so its shape cannot corrupt what gets written.
        // It is still read, because the diff and the staleness check both need
        // it; `ImportPlan.diff` tolerates a duplicated id rather than trapping
        // on one. See D-106.
        if mode == .merge {
            do {
                try StoreMerge.validateShape(of: local)
            } catch let error as ImportError {
                throw ImportError.storeUnreadable(detail: error.detail)
            }
        }
        // **The incoming side is normalized too, and that is not belt-and-braces.**
        // It was not, on the reasoning that a file is already at wire precision —
        // true of files this app writes, and §10.2 chose JSON precisely so a
        // person could edit one. `ExportDocument.decoder()` accepts more than
        // three fractional digits, and `…20.4817Z` parses to a value that
        // re-emits as `…20.482Z`. Left un-normalized it lands in the store at a
        // precision the format cannot hold: the first export silently changes
        // it, and for an event — whose timestamp is immutable — the next import
        // of the same file is refused as an inconsistent record.
        let incoming = try MergedStore(document).wireNormalized()
        // **`.replace` merges the file against an empty store, and one
        // substitution is the whole of it.** Three things fall out rather than
        // being written separately: D-102's closure check then runs over the
        // file alone, which is correct because the rows it would otherwise
        // resolve against are about to be deleted; D-100's status and D-099's
        // `lastStandupAt` are still derived, now from the file's own events and
        // reports, so a hand-edited file whose `status` field disagrees with
        // its own log installs the log's answer; and D-098's sticky-true flags
        // become a no-op, which is what they should be when there is no local
        // opinion to preserve.
        let base = mode == .replace ? MergedStore() : local
        let result = try StoreMerge.merge(local: base, incoming: incoming)
        return ImportPlan(
            local: local,
            result: result,
            mode: mode,
            origin: ImportPlan.Origin(
                exportedAt: document.exportedAt,
                exportedBy: document.exportedBy,
                includesCachedExternalData: document.includesCachedExternalData))
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
        do {
            let snapshot = try ExportEncoder(
                context: context,
                includesCachedExternalData: true,
                exportedBy: "steno/import (macOS)"
            ).snapshot()
            return try MergedStore(snapshot).wireNormalized()
        } catch let error as ImportError {
            throw error
        } catch {
            // `snapshot()` throws when a fetch fails and `wireNormalized()` when
            // the round trip does. Both are this store failing to be read, and
            // both escaped as raw `Error`s — uncategorized out of `plan`, and
            // mislabelled `.saveFailed` out of `apply`, which is the error this
            // same review round had just corrected one layer down.
            throw ImportError.storeUnreadable(detail: error.localizedDescription)
        }
    }
}

extension ImportService {
    /// Apply exactly what `plan` described, in one transaction.
    ///
    /// Every validation already ran on values, before this is reached, so the
    /// only failure left in flight is the save itself — which rolls back.
    /// - Parameter backup: takes §10.1's mandatory pre-Replace backup. Required
    ///   for a `.replace` plan, unused for a `.merge` one.
    ///
    /// **The writer, not a receipt handed in by the caller.** A receipt only
    /// proves that *a* backup exists somewhere, not that it describes the store
    /// about to be wiped — a caller could mint one, let the store change, plan a
    /// fresh Replace and reuse it, so the only recovery file would hold the
    /// older state. Raised in review of PR #30. Taking the backup here binds it
    /// to this transaction: it runs after the staleness check and immediately
    /// before the first write.
    ///
    /// - Parameter backupTo: the path the confirmation sheet already showed the
    ///   user; `nil` lets the writer choose. See `BackupWriter.write(to:)`.
    @discardableResult
    public func apply(
        _ plan: ImportPlan, backupWith writer: BackupWriter? = nil, backupTo url: URL? = nil
    ) throws -> BackupReceipt? {
        // **The backup is enforced here, not only in the UI.** It was a property
        // of `MainWindowModel.applyImport()` alone, which left the destructive
        // engine itself unguarded for every other caller — and M2.5-04's
        // `steno import --replace` is one. §10.1 makes the backup a property of
        // Replace, so it belongs at the boundary Replace actually crosses.
        if plan.mode == .replace, writer == nil {
            throw ImportError.backupRequired
        }
        // **An empty plan writes nothing and posts nothing.** It used to reapply
        // every merged row, save, and post `.stenoDidWrite` — so the second
        // import of a file made every observer reload, and would in M2.5-05 have
        // dirtied the store enough to trigger an auto-export, all while the
        // preview said there was nothing to do.
        guard !plan.isEmpty else { return nil }

        // The plan describes a diff against a store that may since have moved,
        // and the same pending-change reasoning applies to the gap since `plan`.
        guard !context.hasChanges else { throw ImportError.unsavedLocalChanges }
        guard try localStore() == plan.source else {
            throw ImportError.storeChanged
        }

        // **After the staleness check, before the first write.** Ordering it
        // here means a refused plan never writes a spare backup, and the file
        // that does get written describes the store this transaction is about
        // to change rather than some earlier one.
        let receipt = try writer?.write(to: url)

        // **The writes go to a context of their own.** `context.rollback()`
        // restores the persisted store but *not* the values already held by
        // live model instances — behaviour `StatusServiceTests` pins for the
        // services. A save failing partway therefore left the caller's objects
        // holding imported values that were never saved: the UI could show them
        // as imported, and any later mutation of one of those objects would
        // persist them, which is exactly what §10.4's "nothing was changed"
        // forbids. A scratch context is discarded whole, so there is nothing to
        // restore and nothing to get wrong.
        //
        // The caller learns about the import through `.stenoDidWrite` and
        // refetches, which is the path every write in this app already takes
        // (D-019).
        let scratch = ModelContext(context.container)
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
            //
            // Deletions before any of it: §10.1's Replace makes the file the
            // whole store, and a row the file lacks must be gone before the
            // rows it shares an id space with are written.
            switch plan.mode {
            case .replace:
                // **§10.1 says "wipes the local store first", and this is that,
                // literally.** The merge-mode helpers below cannot express
                // Replace: for a row present on both sides their existing-row
                // branch only flips `isRedacted` / `isUndone` or refreshes a
                // cache, because in a *merge* an id collision means identical
                // content — `mergeEvents` refuses anything else. Replace merges
                // against an empty base, so that check never runs, and a file
                // whose event body differs from the local one silently kept the
                // local wording. `Event` exposes no mutator for its body and
                // must not gain one (§3.3), so the only honest way to install
                // the file's version is to remove the row and insert it fresh.
                // Raised in review of PR #30.
                try deleteEverything(from: scratch)
                installFresh(store, into: scratch)
            case .merge:
                try deleteRecords(plan.deletions, from: scratch)
                try applyProjects(store.projects, writing: plan.writes.projects, into: scratch)
                try applyTasks(store.tasks, writing: plan.writes.tasks, into: scratch)
                try applyEvents(store.events, writing: plan.writes.events, into: scratch)
                try applyRefs(store.sourceRefs, writing: plan.writes.sourceRefs, into: scratch)
                try applyReports(store.reports, writing: plan.writes.reports, into: scratch)
            }
            try save(scratch)
        } catch let error as ImportError {
            // A read failure from `existing(...)` is already classified, and
            // re-wrapping it as `.saveFailed` would tell the user their import
            // could not be *saved* when the store could not be *read*.
            scratch.rollback()
            throw error
        } catch {
            scratch.rollback()
            throw ImportError.saveFailed(detail: error.localizedDescription)
        }

        // After the save, never before: an observer that reloads must not read a
        // context whose write has not landed (D-019).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
        // `deletedRows`, not `deletions.count`: the latter counts ids, and a
        // malformed store can carry two rows under one — so destructive
        // telemetry would under-report the work exactly as the preview did
        // before D-111. Raised in review of PR #30.
        Log.app.info(
            "import applied: \(plan.tasks.inserted, privacy: .public) new tasks, \(plan.deletedRows.tasks, privacy: .public) rows removed"
        )
        return receipt
    }
}
