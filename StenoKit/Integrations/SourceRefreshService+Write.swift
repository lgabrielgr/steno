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
        var superseded = 0

        /// Changes the log says were already reported (D-186). Non-zero on a
        /// healthy pass: it is the deliberate overlap working.
        var duplicates = 0

        var failures: [RefreshOutcome.Failure] = []
    }

    /// Apply every result to its row, save once, post once.
    /// What the dispatch half of a pass learned, handed to the write half.
    ///
    /// **One value rather than four parameters.** The two halves of a pass exchange
    /// exactly this, and a signature that lists them separately grows every time the
    /// pass learns something new — which is how it reached six parameters and a lint
    /// failure. Naming it also documents the handoff.
    struct PassContext {
        /// Refs handed to a configured connector.
        let attempted: Int

        /// Refs a connector claimed but could not fetch for want of a credential.
        let notConfigured: Int

        /// Refs claimed only by connectors the user switched off (D-216).
        let disabled: Int

        /// Each ref's resume point, computed before dispatch and read again here
        /// (D-186).
        let resume: [UUID: ResumePoint]

        /// Credential warnings collected once for the whole pass (D-194).
        let warnings: [SourceCredentialWarning]

        /// Refs dropped before dispatch because their event log could not be read.
        /// Added to `skipped`, never to `failures`.
        let unreadable: Int
    }

    /// The `sources` line for a pass that attempted nothing (Copilot, PR #45).
    ///
    /// **`applyAndSave` is never reached on those paths**, and its summary line was
    /// the only logger — so `RefreshOutcome.disabled`, whose stated purpose is
    /// explaining exactly such a pass, explained nothing. Here rather than inline in
    /// `run` because `SourceRefreshService.swift` is at SwiftLint's 400-line limit,
    /// and because the refresh log lines belong in one file.
    ///
    /// **Called from every zero-attempt return, which took two tries.** The first fix
    /// covered the one where nothing was claimed and missed the one where everything
    /// claimed had an unreadable event log — a mixed pass with disabled refs then
    /// still logged nothing about them. Raised twice by Copilot on PR #45, the second
    /// time against my own incomplete fix.
    func logEmptyPass(notConfigured: Int, disabled: Int, skipped: Int = 0) {
        Log.sources.info(
            """
            refresh: attempted 0 \
            notConfigured \(notConfigured, privacy: .public) \
            disabled \(disabled, privacy: .public) \
            skipped \(skipped, privacy: .public)
            """)
    }

    func applyAndSave(
        _ fetched: (results: [FetchResult], skipped: Int),
        rows: [SourceRef],
        context pass: PassContext
    ) -> RefreshOutcome {
        let applied = apply(fetched.results, rows: rows, resume: pass.resume)
        if applied.superseded > 0 {
            Log.sources.info(
                "refresh dropped \(applied.superseded, privacy: .public) result(s) a concurrent pass had already applied"
            )
        }
        let saveFailed = applied.cached > 0 || applied.changed > 0 ? !persist() : false

        let outcome = RefreshOutcome(
            attempted: pass.attempted,
            cached: saveFailed ? 0 : applied.cached,
            changed: saveFailed ? 0 : applied.changed,
            failures: applied.failures,
            notConfigured: pass.notConfigured,
            disabled: pass.disabled,
            skipped: fetched.skipped + pass.unreadable,
            superseded: applied.superseded,
            duplicates: applied.duplicates,
            credentialWarnings: pass.warnings,
            oldestFetch: oldestFetch(of: rows),
            saveFailed: saveFailed)

        Log.sources.info(
            """
            refresh: attempted \(outcome.attempted, privacy: .public) \
            cached \(outcome.cached, privacy: .public) \
            changed \(outcome.changed, privacy: .public) \
            failed \(outcome.failures.count, privacy: .public) \
            skipped \(outcome.skipped, privacy: .public) \
            notConfigured \(outcome.notConfigured, privacy: .public) \
            disabled \(outcome.disabled, privacy: .public) \
            duplicates \(outcome.duplicates, privacy: .public)
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
    private func apply(
        _ results: [FetchResult], rows: [SourceRef], resume: [UUID: ResumePoint]
    ) -> Applied {
        var byID: [UUID: SourceRef] = [:]
        for row in rows { byID[row.id] = row }

        var applied = Applied()
        let stamp = now()

        for result in results {
            switch result.outcome {
            case .failure(let error):
                // `cachedAt` is this row's own last observation, which a failed
                // fetch leaves untouched — so it is exactly "how old is the data
                // the draft will fall back on for this ref".
                applied.failures.append(
                    RefreshOutcome.Failure(
                        connectorID: result.connectorID, displayName: result.displayName,
                        error: error, cachedAt: byID[result.refID]?.lastFetchedAt,
                        renewalURL: result.renewalURL))
            case .success(let update):
                guard let row = byID[result.refID] else { continue }

                // **Another pass got here first.** The row's timestamp is no longer
                // the one this fetch was dispatched against, so a concurrent pass
                // has already applied a fetch for it — and applying this one too
                // would append a second event for one change and move the cache
                // backwards to an older read. Dropping it loses nothing: `since`
                // for the next pass is the newer stamp, so anything this fetch saw
                // and the other did not is reported then.
                guard row.lastFetchedAt == result.observedAt else {
                    applied.superseded += 1
                    continue
                }

                let resumePoint = resume[row.id] ?? .none

                // **First observation means the log has never reported this ref**, not
                // that the cache column is empty. §10.2 omits `lastFetchedAt` from an
                // export by default while the `externalUpdate` payloads travel, so an
                // imported ref has a resume point and a nil row timestamp — and reading
                // only the column made the first post-import pass suppress real changes
                // *and* record their ids, so they were never reported at all. Raised by
                // Copilot in review of PR #43.
                let isFirst = row.lastFetchedAt == nil && resume[row.id] == nil

                // **De-duplication, because the window overlaps on purpose**
                // (D-185, D-186). Every pass re-reads items it has already
                // reported; the log says which, and an id the log has seen is
                // dropped here rather than appended a second time.
                let fresh = update.changes.filter { !resumePoint.reportedIDs.contains($0.id) }

                // State items — Jira's PR links — carry no timestamp, so "new"
                // is set difference against the last recorded set (D-187).
                let newcomers = update.present.filter { !resumePoint.presentIDs.contains($0.id) }

                applied.duplicates +=
                    (update.changes.count - fresh.count) + (update.present.count - newcomers.count)

                // **A first observation reports the summary and nothing else**
                // (D-169), even though everything it saw is recorded below (D-188).
                let reported = isFirst ? [] : fresh + newcomers

                if let body = ExternalUpdateBody.text(
                    identifier: row.identifier, summary: update.summary,
                    changes: reported, isFirstObservation: isFirst)
                {
                    context.insert(
                        Event(
                            taskID: row.taskID, timestamp: stamp, kind: .externalUpdate,
                            body: body,
                            payload: ExternalUpdatePayload(
                                refID: row.id, kind: row.kind, identifier: row.identifier,
                                changes: reported.map(\.text), url: update.url?.absoluteString,
                                fetchedAt: update.fetchedAt,
                                // The watermark the next window starts from (D-184).
                                watermark: update.watermark,
                                // **Every id seen, not only the ids reported**
                                // (D-188). The next window overlaps this one, so an
                                // id missing from the log comes back as news — which
                                // on a first observation would be the ticket's whole
                                // recent history, one pass later.
                                changeIDs: update.changes.map(\.id),
                                presentIDs: update.present.map(\.id),
                                // `nil` rather than `false`, so an ordinary fetch's payload keeps
                                // the bytes it had before this field existed (§10.2).
                                windowCapped: update.isWindowCapped ? true : nil
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
