import Foundation
import OSLog
import SwiftData

/// FR-6's "purge cached external data" (D-219).
///
/// **What it clears, and what it must not.** The task file is explicit: "Purging
/// must not delete tasks, events, or refs, only `cachedSummary` and
/// `lastFetchedAt`." So this clears two columns on every `SourceRef` and touches
/// nothing else — no row is deleted, no `Event` is written or removed, and
/// `ImportPlan.deletions` is not involved. §3.3's append-only invariant has exactly
/// one sanctioned exception and this is not it; a cache column on a `SourceRef` is
/// not an event.
///
/// **Why it is safe against the failure mode it looks like it should have.**
/// Clearing `lastFetchedAt` could plausibly make the next pass treat every ref as a
/// first observation — which reports the summary and nothing else (D-169) while
/// still recording every id it saw (D-188), so real changes would be swallowed and
/// never reported again. It does not happen, because
/// `SourceRefreshService.apply` computes that flag as
/// `row.lastFetchedAt == nil && resume[row.id] == nil`, and the resume point is
/// recovered from `externalUpdate` payloads in the log (D-184), which a purge leaves
/// untouched. This is the same reasoning that fixed the post-import case in PR #43:
/// first observation means the log has never reported this ref, not that the cache
/// column is empty.
///
/// `@MainActor` because `ModelContext` is not `Sendable`; `save` injected because a
/// real `ModelContext` cannot be made to fail on demand and the rollback is the path
/// that most needs a test — the posture `SourceRefreshService` and every service in
/// this codebase already take.
@MainActor
public struct SourceCachePurge {
    /// What one purge did.
    public enum Result: Equatable, Sendable {
        /// `cleared` refs had something to forget. **Zero is a success**, not a
        /// failure: a user who has never fetched anything asked for a state that
        /// already holds.
        case purged(cleared: Int)

        /// The store could not be read or written. Carries what is safe to show —
        /// a description of the error, which for a store failure names no user
        /// content.
        case failed(String)
    }

    private let context: ModelContext
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.save = save
    }

    /// Clear every ref's cached observation.
    ///
    /// **Does not throw**, for `SourceRefreshService`'s reason: the caller is a
    /// Settings pane that must report what happened rather than propagate it, and a
    /// typed result is what lets it say "nothing to purge" and "the store refused"
    /// in different words.
    public func purge() -> Result {
        let rows: [SourceRef]
        do {
            rows = try context.fetch(FetchDescriptor<SourceRef>())
        } catch {
            Log.sources.error(
                "purge could not read refs: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }

        // **Counted before the write, over the rows that actually hold something.**
        // `rows.count` would report "cleared 40" for a store where nothing had ever
        // been fetched, which is a number the user would reasonably read as "40
        // things were thrown away".
        let withCache = rows.filter { $0.cachedSummary != nil || $0.lastFetchedAt != nil }
        guard !withCache.isEmpty else {
            // **No save, so no notification.** Saving a context with no changes
            // would post `.stenoDidWrite` and make three surfaces refetch for
            // nothing.
            return .purged(cleared: 0)
        }

        for row in withCache {
            row.clearCache()
        }

        do {
            try save(context)
        } catch {
            // Rolled back for D-172's reason: cleared columns left in a dirty
            // context are committed by the next unrelated save — a capture, a note
            // — which would make a refused purge happen anyway, minutes later, with
            // nothing to trace it to.
            context.rollback()
            Log.sources.error(
                "purge could not be saved, rolled back: \(String(describing: error), privacy: .public)"
            )
            return .failed(String(describing: error))
        }

        Log.sources.info(
            "purged cached external data for \(withCache.count, privacy: .public) ref(s)")
        // After the save, never before: an observer that reloads must not read a
        // context whose write has not committed (`CaptureService`'s rule).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
        return .purged(cleared: withCache.count)
    }
}
