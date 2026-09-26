import Foundation
import OSLog
import SwiftData

/// The write half of §5.5's pass: apply, save once, notify once.
///
/// **Split from `SourceRefreshService.swift` for `file_length`**, along the seam
/// the pass already has: everything here runs on the main actor with the rows in
/// hand and no network in sight, where everything there is dispatch and
/// concurrency. `MainWindowModel+Status.swift` and `CLIRunner+Export.swift` split
/// on the same grounds.
extension SourceRefreshService {
    /// What applying the results wrote, before anything is saved.
    struct Applied {
        var cached = 0
        var changed = 0
        var failures: [RefreshOutcome.Failure] = []
    }

    /// Apply every result to its row, save once, post once.
    func applyAndSave(
        _ fetched: (results: [FetchResult], skipped: Int),
        rows: [SourceRef],
        attempted: Int,
        notConfigured: Int
    ) -> RefreshOutcome {
        let applied = apply(fetched.results, rows: rows)
        let saveFailed = applied.cached > 0 || applied.changed > 0 ? !persist() : false

        let outcome = RefreshOutcome(
            attempted: attempted,
            cached: saveFailed ? 0 : applied.cached,
            changed: saveFailed ? 0 : applied.changed,
            failures: applied.failures,
            notConfigured: notConfigured,
            skipped: fetched.skipped,
            oldestFetch: Self.oldestFetch(of: rows),
            saveFailed: saveFailed)

        Log.sources.info(
            """
            refresh: attempted \(outcome.attempted, privacy: .public) \
            cached \(outcome.cached, privacy: .public) \
            changed \(outcome.changed, privacy: .public) \
            failed \(outcome.failures.count, privacy: .public) \
            skipped \(outcome.skipped, privacy: .public)
            """)

        // After the save, never before, and only when something landed: an
        // observer that reloads must not read a context whose write has not
        // committed (`CaptureService`'s rule), and a pass that wrote nothing must
        // not make three surfaces refetch.
        if outcome.didWrite {
            NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
        }
        return outcome
    }

    /// Write every successful fetch to its row, and count what happened.
    private func apply(_ results: [FetchResult], rows: [SourceRef]) -> Applied {
        var byID: [UUID: SourceRef] = [:]
        for row in rows { byID[row.id] = row }

        var applied = Applied()
        let stamp = now()

        for result in results {
            switch result.outcome {
            case .failure(let error):
                applied.failures.append(
                    RefreshOutcome.Failure(
                        connectorID: result.connectorID, displayName: result.displayName,
                        error: error))
            case .success(let update):
                guard let row = byID[result.refID] else { continue }
                let isFirst = row.lastFetchedAt == nil

                if let body = ExternalUpdateBody.text(
                    identifier: row.identifier, summary: update.summary,
                    changes: update.changes, isFirstObservation: isFirst)
                {
                    context.insert(
                        Event(
                            taskID: row.taskID, timestamp: stamp, kind: .externalUpdate,
                            body: body,
                            payload: ExternalUpdatePayload(
                                refID: row.id, kind: row.kind, identifier: row.identifier,
                                changes: update.changes, url: update.url?.absoluteString,
                                fetchedAt: update.fetchedAt
                            ).encoded()))
                    applied.changed += 1
                }

                // **`stamp`, not `update.fetchedAt`** (D-171). §10.1 orders the
                // cache pair on this field, and a value from a remote clock would
                // make that comparison depend on two machines' skew against a
                // third. Nothing here stamps `task.modifiedAt` (D-173): a refresh
                // did not modify the task, and bumping it would outrank a real
                // title edit from another Mac in §10.1's merge.
                row.recordFetch(summary: update.summary, at: stamp)
                applied.cached += 1
            }
        }
        return applied
    }

    /// The pass's single save. `false` when it was refused and rolled back.
    private func persist() -> Bool {
        do {
            try save(context)
            return true
        } catch {
            // **Load-bearing, not tidiness** (D-172). Inserted events left in a
            // dirty context are committed by the next unrelated save — a capture,
            // a status change, a note — which turns a refresh failure into
            // phantom `externalUpdate` rows in a later report with nothing to
            // trace them to.
            context.rollback()
            Log.sources.error(
                "refresh could not be saved, rolled back: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}
