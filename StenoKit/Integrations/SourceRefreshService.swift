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
    private let perFetch: Duration
    private let budget: Duration

    /// - Parameters:
    ///   - perFetch: one ref's deadline (D-178). One unresponsive ticket must not
    ///     consume the pass.
    ///   - budget: the pass's wall clock. Tests pass milliseconds — an
    ///     eight-second hang in `make test` is how a suite stops being run.
    public init(
        context: ModelContext,
        registry: SourceRegistry,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        perFetch: Duration = .seconds(8),
        budget: Duration = .seconds(10)
    ) {
        self.context = context
        self.registry = registry
        self.now = now
        self.save = save
        self.perFetch = perFetch
        self.budget = budget
    }

    /// §5.5's launch pass: refs on non-done, non-archived tasks that have not
    /// been fetched within `staleness`.
    public func refreshDue(
        olderThan staleness: Duration = RefreshPolicy.launchStaleness
    ) async -> RefreshOutcome {
        let rows: [SourceRef]
        do {
            rows = try activeRefs()
        } catch {
            Log.sources.error(
                "could not read refs to refresh: \(String(describing: error), privacy: .public)")
            return RefreshOutcome(readFailed: true)
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
        guard !taskIDs.isEmpty else { return .idle }

        let rows: [SourceRef]
        do {
            rows = try refs(forTaskIDs: Set(taskIDs))
        } catch {
            Log.sources.error(
                "could not read refs to refresh: \(String(describing: error), privacy: .public)")
            return RefreshOutcome(readFailed: true)
        }

        return await run(rows.map(\.snapshot), rows: rows)
    }

    // MARK: - The pass

    /// Dispatch, fetch, apply, save, notify.
    private func run(_ refs: [SourceRefSnapshot], rows: [SourceRef]) async -> RefreshOutcome {
        var ready: [(snapshot: SourceRefSnapshot, connector: any SourceConnector)] = []
        var notConfigured = 0
        for ref in refs {
            switch registry.dispatch(ref) {
            case .ready(let connector):
                ready.append((ref, connector))
            case .notConfigured:
                notConfigured += 1
            case .unhandled:
                // Silent, by D-166: a bare `.url` ref is every link the user has
                // ever pasted, and it is not a problem.
                break
            }
        }

        guard !ready.isEmpty else {
            return RefreshOutcome(
                notConfigured: notConfigured, oldestFetch: Self.oldestFetch(of: rows))
        }

        let fetched = await fetchAll(ready)
        return applyAndSave(
            fetched, rows: rows, attempted: ready.count, notConfigured: notConfigured)
    }

    /// One fetch's result, as it crosses back to this actor.
    struct FetchResult: Sendable {
        let refID: UUID
        let connectorID: String
        let displayName: String

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
        _ ready: [(snapshot: SourceRefSnapshot, connector: any SourceConnector)]
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
                    .fetched(
                        await Self.fetch(next.snapshot, from: next.connector, within: deadline))
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
        _ ref: SourceRefSnapshot, from connector: any SourceConnector, within deadline: Duration
    ) async -> FetchResult {
        func result(_ outcome: Result<SourceUpdate, SourceError>) -> FetchResult {
            FetchResult(
                refID: ref.refID, connectorID: connector.id,
                displayName: connector.displayName, observedAt: ref.lastFetchedAt,
                outcome: outcome)
        }

        do {
            let update = try await withDeadline(deadline, throwing: SourceError.timedOut) {
                try await connector.fetch(ref, since: ref.lastFetchedAt)
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

    // MARK: - Candidates

    /// Refs on tasks that are neither archived nor done (§5.5).
    ///
    /// **Two fetches and an in-memory filter**, because `Status` is an enum and an
    /// enum inside a SwiftData `#Predicate` does not compile in either spelling —
    /// `EventQueries` records the same constraint and filters kinds after its
    /// fetch for the same reason. D18 caps the dataset, so the fetch is the cost
    /// and the filter is free.
    private func activeRefs() throws -> [SourceRef] {
        let tasks = try context.fetch(
            FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isArchived }))
        let active = Set(tasks.filter { $0.status != .done }.map(\.id))
        return try refs(forTaskIDs: active)
    }

    /// The refs belonging to `taskIDs`.
    ///
    /// **Keyed on `SourceRef.taskID`, never on `TaskItem.sourceRefs`.** D-016
    /// keeps both the foreign key and the relationship, and `SourceRef` names the
    /// key as authoritative — "what export, import, and merge read". Both refresh
    /// paths therefore agree about what "this task's refs" means; reading the
    /// relationship in one and the key in the other would make a fixture that set
    /// only one of them pass one path and silently skip the other.
    ///
    /// Filtered in memory: a `taskIDs.contains(...)` clause inside a
    /// `#Predicate` is the construct `EventQueries` records as compiling and then
    /// throwing at fetch time.
    private func refs(forTaskIDs taskIDs: Set<UUID>) throws -> [SourceRef] {
        guard !taskIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<SourceRef>())
            .filter { taskIDs.contains($0.taskID) }
    }

    /// The oldest observation among `rows`, or `nil` when none has been fetched.
    ///
    /// Read *after* the pass, so a successful fetch has already moved its row's
    /// timestamp forward and only genuinely stale refs remain — which is what
    /// makes it the right input to §5.2's staleness label.
    static func oldestFetch(of rows: [SourceRef]) -> Date? {
        rows.compactMap(\.lastFetchedAt).min()
    }
}

extension SourceRef {
    /// This row as a connector sees it (D-164).
    var snapshot: SourceRefSnapshot {
        SourceRefSnapshot(
            refID: id, kind: kind, identifier: identifier, url: url,
            lastFetchedAt: lastFetchedAt)
    }
}
