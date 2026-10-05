import Foundation
import OSLog
import SwiftData

/// §5.5's refresh, and the only thing in this app that writes external state.
///
/// **Neither refresh method throws, and that is §5.5 expressed as a type**
/// (D-167). "A failed integration must never block report generation", and §7.4
/// makes arriving empty-handed a P0 failure — so there is no error a caller could
/// be handed, and therefore no path on which a caller could forget to degrade.
/// `StandupSummarizer.summarize` has no `throws` for exactly this reason. A rule
/// a type enforces survives the next four connectors; a rule review enforces does
/// not.
///
/// `@MainActor` because `ModelContext` is not `Sendable`; `now` injected so
/// timestamps are assertable; `save` injected because a real `ModelContext`
/// cannot be made to fail on demand and the rollback is the path that most needs
/// a test. All three for the reasons `NoteService`, `StatusService` and
/// `CaptureService` already record.
///
/// **No `@Model` row ever leaves this actor.** Connectors receive
/// `SourceRefSnapshot` values and answer with `SourceUpdate` values; the rows
/// stay here and are written after the group returns (D-164).
@MainActor
public struct SourceRefreshService {
    /// D-178: four fetches in flight. A `periodic` window under D18's 20-task cap
    /// can carry around twenty refs — serial at a second each is twenty seconds
    /// of a stand-up the user is already late for, and twenty-wide is how a
    /// connector gets rate limited on its first pass.
    static let maxInFlight = 4

    // `internal`, not `private`: `SourceRefreshService+Write.swift` is the other
    // half of this type and `private` is file-scoped. Nothing outside the module
    // can reach them either way — the type's only `public` members are its
    // initializer and its two refresh methods.
    let context: ModelContext
    let registry: SourceRegistry
    let now: () -> Date
    let save: (ModelContext) throws -> Void

    /// How a task's events are read, injected for `save`'s reason: a real `ModelContext`
    /// cannot be made to fail its fetch, and the failure path is the one that most needs a
    /// test — a pass that cannot read the log must not fetch, or it re-reports history
    /// (Copilot, PR #43).
    let readEvents: (ModelContext, UUID) throws -> [Event]
    private let perFetch: Duration
    private let budget: Duration
    private let gate: SourceRefreshGate

    /// - Parameters:
    ///   - perFetch: one ref's deadline (D-178). One unresponsive ticket must not
    ///     consume the pass.
    ///   - budget: the pass's wall clock. Tests pass milliseconds — an
    ///     eight-second hang in `make test` is how a suite stops being run.
    ///   - gate: serializes passes against every other trigger (D-183). Defaults to
    ///     the shared instance, so a new trigger is serialized by construction
    ///     rather than by remembering to be; a test passes its own so one test's
    ///     pass never waits on another's.
    public init(
        context: ModelContext,
        registry: SourceRegistry,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        readEvents: @escaping (ModelContext, UUID) throws -> [Event] = {
            try $0.fetch(EventQueries.allEvents(forTaskID: $1))
        },
        perFetch: Duration = .seconds(8),
        budget: Duration = .seconds(10),
        gate: SourceRefreshGate = .shared
    ) {
        self.context = context
        self.registry = registry
        self.now = now
        self.save = save
        self.readEvents = readEvents
        self.perFetch = perFetch
        self.budget = budget
        self.gate = gate
    }

    /// §5.5's launch pass: refs on non-done, non-archived tasks that have not
    /// been fetched within `staleness`.
    public func refreshDue(
        olderThan staleness: Duration = RefreshPolicy.launchStaleness
    ) async -> RefreshOutcome {
        await gate.serialize { await self.performRefreshDue(olderThan: staleness) }
    }

    private func performRefreshDue(olderThan staleness: Duration) async -> RefreshOutcome {
        let rows: [SourceRef]
        do {
            rows = try activeRefs()
        } catch {
            Log.sources.error(
                "could not read refs to refresh: \(String(describing: error), privacy: .public)")
            return RefreshOutcome(readFailed: true).warning(about: credentialWarnings())
        }

        let due = RefreshPolicy.due(rows.map(\.snapshot), now: now(), olderThan: staleness)
        return await run(due, rows: rows)
    }

    /// FR-4 step 4: every ref on the tasks in the report window.
    ///
    /// Unconditional, unlike `refreshDue`: the user asked for a stand-up, so the
    /// 30-minute rule is not the question — §5.5 says "on Prepare Stand-up,
    /// refresh all refs in the window".
    public func refresh(taskIDs: [UUID]) async -> RefreshOutcome {
        guard !taskIDs.isEmpty else { return .idle.warning(about: credentialWarnings()) }
        return await gate.serialize { await self.performRefresh(taskIDs: taskIDs) }
    }

    private func performRefresh(taskIDs: [UUID]) async -> RefreshOutcome {
        let rows: [SourceRef]
        do {
            rows = try refs(forTaskIDs: Set(taskIDs))
        } catch {
            Log.sources.error(
                "could not read refs to refresh: \(String(describing: error), privacy: .public)")
            return RefreshOutcome(readFailed: true).warning(about: credentialWarnings())
        }

        return await run(rows.map(\.snapshot), rows: rows)
    }

    // MARK: - The pass

    /// Dispatch, fetch, apply, save, notify.
    private func run(_ refs: [SourceRefSnapshot], rows: [SourceRef]) async -> RefreshOutcome {
        // Once per pass, before anything is dispatched (D-194). One Keychain read
        // per configured connector, not one per ref.
        let warnings = credentialWarnings()

        let tally = classify(refs)
        let claimed = tally.claimed
        let notConfigured = tally.notConfigured
        let disabled = tally.disabled
        // A switched-off integration's cache age must not reach the staleness label
        // (Copilot, PR #45) — see `oldestFetch(of:)`.
        let stale = oldestFetch(of: rows)

        guard !claimed.isEmpty else {
            logEmptyPass(notConfigured: notConfigured, disabled: disabled)
            return RefreshOutcome(
                notConfigured: notConfigured, disabled: disabled, credentialWarnings: warnings,
                oldestFetch: stale)
        }

        // **One map, computed once, read twice** (D-186). The dispatch half turns
        // it into `since`; the write half de-duplicates against it. Reading the log
        // again after the fetches would be a second query per ref and — worse — a
        // second chance for the two halves to disagree about what had already been
        // reported.
        let (resume, unreadable) = resumePoints(for: claimed.map(\.snapshot), rows: rows)
        let stamp = now()

        // **A ref whose log could not be read is not fetched at all**, because a pass
        // that cannot tell what it has already reported would report it again (Copilot,
        // PR #43). Counted as skipped rather than failed: nothing went wrong with the
        // ref, the same reading `skipped` already carries for the pass budget.
        let ready =
            claimed
            .filter { !unreadable.contains($0.snapshot.refID) }
            .map {
                ReadyFetch(
                    snapshot: $0.snapshot, connector: $0.connector,
                    since: resume[$0.snapshot.refID]?.since(now: stamp))
            }
        let unread = claimed.count - ready.count
        if unread > 0 {
            Log.sources.error(
                "refresh skipped \(unread, privacy: .public) ref(s) whose event log could not be read"
            )
        }

        guard !ready.isEmpty else {
            return RefreshOutcome(
                notConfigured: notConfigured, disabled: disabled, skipped: unread,
                credentialWarnings: warnings, oldestFetch: stale)
        }

        let fetched = await fetchAll(ready)
        return applyAndSave(
            fetched, rows: rows,
            context: PassContext(
                attempted: ready.count, notConfigured: notConfigured, disabled: disabled,
                resume: resume, warnings: warnings, unreadable: unread))
    }

    /// One ref about to be fetched, carrying the `since` its resume point produced.
    ///
    /// A struct rather than a third tuple element: `since` is computed from the log
    /// and is the part of this pass most worth being able to name in a signature.
    struct ReadyFetch: Sendable {
        let snapshot: SourceRefSnapshot
        let connector: any SourceConnector

        /// D-185's window start — the watermark less the overlap — or `nil` when
        /// nothing has been reported for this ref yet, which asks the connector for
        /// an anchor rather than for history (D-188).
        let since: Date?
    }

    /// One fetch's result, as it crosses back to this actor.
    struct FetchResult: Sendable {
        let refID: UUID
        let connectorID: String
        let displayName: String

        /// The connector's credential-renewal page, carried so the write phase can
        /// put it on a `Failure` without holding the connector (D-193).
        let renewalURL: URL?

        /// The row's `lastFetchedAt` when this fetch was dispatched — the value
        /// that was also sent as `since`.
        ///
        /// **Carried so the write phase can tell whether the row moved underneath
        /// it.** Two passes can overlap: §5.5's launch pass is fire-and-forget, and
        /// the user can press Prepare while it is still in flight, which builds a
        /// second service over the same `mainContext`. Both would snapshot the same
        /// ref with the same `since`, and both would then apply — producing two
        /// first-observation events for one ref and a last-writer cache. Raised by
        /// Copilot in review of PR #42.
        let observedAt: Date?

        let outcome: Result<SourceUpdate, SourceError>
    }

    /// What the task group yields: a finished fetch, or the pass clock running
    /// out.
    ///
    /// **The clock is a member of the group, not a check between results.** An
    /// earlier version tested the elapsed time each time `group.next()` returned,
    /// which cannot fire while every fetch is still in flight — so a pass whose
    /// connectors all hang ran for the *per-fetch* deadline instead of the pass
    /// budget, and the first hang to time out was recorded as a failure rather
    /// than skipped. Caught by the budget test, which asserted `failures.isEmpty`.
    private enum GroupEvent: Sendable {
        case fetched(FetchResult)
        case budgetExpired
    }

    /// Run every ready fetch, at most `maxInFlight` at a time, stopping at the
    /// pass budget.
    ///
    /// **The budget is not a deadline around the group**, which would discard
    /// every completed fetch because the slowest one overran — the opposite of
    /// best-effort. Instead the elapsed time is checked as each result arrives:
    /// past the budget nothing further is started, the in-flight fetches are
    /// cancelled, and everything already fetched is kept.
    private func fetchAll(
        _ ready: [ReadyFetch]
    ) async -> (results: [FetchResult], skipped: Int) {
        let started = ContinuousClock.now
        let deadline = perFetch
        var results: [FetchResult] = []
        var skipped = 0
        var expired = false

        await withTaskGroup(of: GroupEvent.self) { group in
            var pending = ready.makeIterator()
            var inFlight = 0

            func startNext() -> Bool {
                guard let next = pending.next() else { return false }
                group.addTask {
                    .fetched(await Self.fetch(next, within: deadline))
                }
                inFlight += 1
                return true
            }

            let passBudget = budget
            group.addTask { await Self.sentinel(after: passBudget) }

            for _ in 0..<Self.maxInFlight where startNext() {}

            /// Stop starting work and count what never got its turn.
            ///
            /// Everything not yet started is `skipped`, not failed: nothing went
            /// wrong with a ref the clock ran out on. Reached from two places — the
            /// sleeper firing, and a fetch returning after the budget has already
            /// passed — so it lives here rather than being written twice.
            func expire() {
                expired = true
                group.cancelAll()
                while pending.next() != nil { skipped += 1 }
            }

            while let event = await group.next() {
                switch event {
                case .budgetExpired:
                    if !expired { expire() }

                case .fetched(let result):
                    inFlight -= 1
                    // A fetch that beat the cancellation still carries data, and
                    // discarding it would waste a completed request.
                    if expired, case .failure = result.outcome {
                        skipped += 1
                    } else {
                        results.append(result)
                    }

                    // The sleeper is about to say the same thing; acting on
                    // whichever arrives first keeps the boundary tight when a fetch
                    // returns at the same instant.
                    if !expired, ContinuousClock.now - started >= budget {
                        expire()
                    } else if !expired {
                        _ = startNext()
                    }
                }

                // **The sentinel is a child of this group, so the loop cannot end
                // while it is still sleeping** — and once the last fetch has landed
                // there is no other event left to arrive. Without this break, every
                // *successful* pass waited out the whole budget before returning,
                // delaying the polish stage by ten seconds on a refresh that had
                // already finished. Raised by Copilot in review of PR #42; the
                // millisecond budgets the tests inject made it look like nothing
                // worse than a slightly slow suite.
                //
                // `cancelAll` settles the sleeper, and `break` is what keeps its
                // `.budgetExpired` — which `try?` turns into an ordinary return
                // under cancellation — from being read as a real expiry.
                if inFlight == 0 && !expired {
                    group.cancelAll()
                    break
                }
            }
        }

        return (results, skipped)
    }

    /// The pass clock, as a member of the fetch group.
    ///
    /// **A group member rather than a check between results**, because the elapsed
    /// time cannot be consulted while every fetch is still in flight: a pass whose
    /// connectors all hang would then run for the per-fetch deadline instead of the
    /// budget. Cancelled with the rest once the pass settles, so it never outlives
    /// the group it bounds — and `try?` is what turns that cancellation into an
    /// ordinary return rather than a thrown error the group would surface.
    private nonisolated static func sentinel(after budget: Duration) async -> GroupEvent {
        try? await Task.sleep(for: budget)
        return .budgetExpired
    }

    /// One ref, behind its own deadline.
    ///
    /// `nonisolated static` so it runs off the main actor: the whole point of
    /// snapshotting is that a fetch does not need this actor, and a method on a
    /// `@MainActor` type would hop back for every await.
    private nonisolated static func fetch(
        _ ready: ReadyFetch, within deadline: Duration
    ) async -> FetchResult {
        let ref = ready.snapshot
        let connector = ready.connector

        func result(_ outcome: Result<SourceUpdate, SourceError>) -> FetchResult {
            FetchResult(
                refID: ref.refID, connectorID: connector.id,
                displayName: connector.displayName,
                renewalURL: connector.credentialRenewalURL, observedAt: ref.lastFetchedAt,
                outcome: outcome)
        }

        do {
            let update = try await withDeadline(deadline, throwing: SourceError.timedOut) {
                // **`ready.since`, not `ref.lastFetchedAt`** (D-184). The row's
                // timestamp is our own clock, so a change the source reveals after
                // the pass that should have seen it would be behind the next window
                // forever. This value is the watermark the log recorded, less
                // D-185's overlap.
                try await connector.fetch(ref, since: ready.since)
            }
            return result(.success(update))
        } catch let error as SourceError {
            return result(.failure(error))
        } catch {
            // **An error the protocol says cannot occur.** `SourceConnector`'s
            // contract is `SourceError` and nothing else. Without this line a
            // connector leaking a `URLError` would escape into a non-throwing
            // pass as an unhandled type; with it, the pass degrades and the log
            // names the connector that broke its contract.
            Log.sources.error(
                "\(connector.id, privacy: .public) threw a non-SourceError; contract broken")
            return result(.failure(.invalidResponse))
        }
    }
}
