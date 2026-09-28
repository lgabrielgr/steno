import Foundation
import OSLog
import SwiftData

/// Everything a pass reads before — and about — the rows it is going to fetch.
///
/// **Split from `SourceRefreshService.swift` for `file_length`**, on the seam the
/// pass already has: three files for reads, the pass itself, and writes.
/// `SourceRefreshService+Write.swift` and `MainWindowModel+Status.swift` split on the
/// same grounds.
///
/// Members here are `internal` rather than `private` because `private` is
/// file-scoped and these are halves of one type. Nothing outside the module can
/// reach them either way.
extension SourceRefreshService {

    // `internal`, not `private`: this file and `SourceRefreshService.swift` are two
    // halves of one type and `private` is file-scoped. Nothing outside the module can
    // reach it either way.
    //
    /// Each ref's resume point, recovered from the event log (D-184).
    ///
    /// **One fetch per task, not per ref.** `allEvents` is keyed on `taskID`, so a
    /// task carrying three Jira refs is one query and an in-memory split rather
    /// than three queries; D18 caps the dataset, so the fetch is the cost.
    ///
    /// A read that throws leaves those refs at `.none`, which means a `nil` since —
    /// the connector is asked for an anchor and reports no changes. That is the safe
    /// direction: a pass that cannot read the log says nothing false rather than
    /// re-reporting a ticket's history.
    func resumePoints(
        for refs: [SourceRefSnapshot], rows: [SourceRef]
    ) -> [UUID: ResumePoint] {
        let wanted = Set(refs.map(\.refID))
        let taskIDs = Set(rows.filter { wanted.contains($0.id) }.map(\.taskID))

        var payloads: [UUID: [ExternalUpdatePayload]] = [:]
        for taskID in taskIDs {
            let events: [Event]
            do {
                events = try context.fetch(EventQueries.allEvents(forTaskID: taskID))
            } catch {
                Log.sources.error(
                    "could not read a task's events for a resume point: \(String(describing: error), privacy: .public)"
                )
                continue
            }
            // Newest first, because the descriptor sorts that way and
            // `ResumePoint.from` depends on it for `presentIDs`.
            for event in events where event.kind == .externalUpdate {
                guard let payload = ExternalUpdatePayload.decoded(from: event.payload),
                    wanted.contains(payload.refID)
                else { continue }
                payloads[payload.refID, default: []].append(payload)
            }
        }
        return payloads.mapValues(ResumePoint.from(payloads:))
    }

    /// What every configured connector wants the user to know about its credential
    /// (§5.2, D-194).
    ///
    /// Reads `registry.all` rather than the dispatched connectors: a token expiring
    /// on Friday is worth saying even on a pass whose refs all belong to some other
    /// integration.
    func credentialWarnings() -> [SourceCredentialWarning] {
        registry.all.compactMap(\.credentialWarning)
    }

    // MARK: - Candidates

    /// Refs on tasks that are neither archived nor done (§5.5).
    ///
    /// **Two fetches and an in-memory filter**, because `Status` is an enum and an
    /// enum inside a SwiftData `#Predicate` does not compile in either spelling —
    /// `EventQueries` records the same constraint and filters kinds after its
    /// fetch for the same reason. D18 caps the dataset, so the fetch is the cost
    /// and the filter is free.
    func activeRefs() throws -> [SourceRef] {
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
    func refs(forTaskIDs taskIDs: Set<UUID>) throws -> [SourceRef] {
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
