import Foundation

/// The link from a `standupReported` event back to the report that appended it
/// (§3.3's `payload`, "JSON blob for structured external data").
///
/// **This exists for M2-04.** FR-4.1 must redact the `standupReported` events
/// appended by *one particular* report, and nothing else on the row identifies
/// which. `taskID` says where the event landed and `kind` says what it is;
/// neither says which Copy produced it, and a project reported on twice in a
/// day has two sets of them.
///
/// The rejected alternative was matching on `timestamp == report.generatedAt`.
/// It works today — `StandupService` stamps both from one `now()` — but it
/// couples undo to a coincidence rather than to a statement, and a later change
/// that stamped events independently would break undo silently, with nothing in
/// either file recording why the two values had to agree.
struct StandupReportedPayload: Codable, Equatable {
    let reportID: UUID

    /// `nil` rather than `throws`: a failure here must not abort a Copy whose
    /// four real effects are all fine. The cost of a missing payload is that
    /// M2-04 cannot undo *this* report, which is worse than a lost stand-up but
    /// far better than refusing to produce one. `JSONEncoder` on a single
    /// `UUID` has no reachable failure, so this is a total function in practice.
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode a payload written by `encoded()`. `nil` for a row that carries
    /// none — every `standupReported` event written before this type existed,
    /// and every event of every other kind.
    static func decoded(from data: Data?) -> Self? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
