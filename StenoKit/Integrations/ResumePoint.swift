import Foundation

/// Where a ref's next fetch resumes from, recovered from the event log (D-184).
///
/// **Pure, and built from payloads rather than from a store.** The read that
/// produces those payloads belongs to `SourceRefreshService`, which is the only
/// thing in this app that touches the log; what "resume from" *means* is one
/// testable expression, the way `RefreshPolicy` is.
struct ResumePoint: Sendable, Equatable {
    /// How far back of the watermark each request deliberately reaches (D-185).
    ///
    /// **The overlap is what fixes replication lag**, rather than merely
    /// re-anchoring the window on data. Atlassian Cloud is eventually consistent:
    /// an item created at 09:58 can become visible after one created at 10:01, so
    /// a window starting exactly at the watermark can still miss it. Re-asking the
    /// last fifteen minutes means the straggler is inside the window when it
    /// appears, and the id-based dedup discards the re-reads that costs.
    ///
    /// **It is free on an idle ref.** The window start only moves when something
    /// is reported, so what a request costs is proportional to what changed, not
    /// to how long the ref has existed. Fifteen minutes because the asymmetry
    /// points one way: a larger overlap costs duplicate work nobody sees, and a
    /// smaller one costs a change nobody ever hears about.
    static let overlap: TimeInterval = 15 * 60

    /// How many of a ref's newest payloads the dedup set is unioned over.
    ///
    /// **Ten rather than one.** A pass writes at most one event per ref, so a
    /// window one payload deep would forget everything the previous pass reported
    /// the moment a new event landed — and the overlap would then re-report it.
    static let scanDepth = 10

    /// The newest item timestamp this app has reported for the ref, or `nil` when
    /// it has reported none.
    let watermark: Date?

    /// Ids already reported, across the scanned payloads (D-186).
    let reportedIDs: Set<String>

    /// The complete state set as of the newest payload that recorded one (D-187).
    let presentIDs: Set<String>

    /// Nothing has ever been reported for this ref.
    static let none = ResumePoint(watermark: nil, reportedIDs: [], presentIDs: [])

    /// How far back a window may reach, however old the watermark is.
    ///
    /// **The watermark only advances when an event is written**, because that is where
    /// it is recorded (D-184) — so a ref whose every fetch finds nothing new keeps the
    /// same window, and on a long-lived ticket that means re-walking the same pages on
    /// every pass. Raised by Copilot in review of PR #43.
    ///
    /// Thirty days bounds that walk. What it gives up is an item the source reveals
    /// more than a month after it happened, which is not a shape this API produces;
    /// what it buys is a cost that cannot grow without limit on a ticket nobody is
    /// touching.
    static let maxLookback: TimeInterval = 30 * 24 * 60 * 60

    /// What to send as `since`.
    ///
    /// `nil` when there is no watermark, which asks the connector for an anchor rather
    /// than for history: a connector handed `nil` reports what one page holds and the
    /// service keeps it out of the event body (D-188), so a first look can never arrive
    /// as a hundred-line stand-up.
    ///
    /// Clamped to `maxLookback` before `now`, for the reason above.
    func since(now: Date) -> Date? {
        guard let watermark else { return nil }
        return max(
            watermark.addingTimeInterval(-Self.overlap),
            now.addingTimeInterval(-Self.maxLookback))
    }

    /// Recover the resume point from one ref's `externalUpdate` payloads,
    /// **newest first**.
    ///
    /// - Parameter payloads: already filtered to one `refID`. Order matters:
    ///   `presentIDs` is the newest recorded set exactly, not a union, because a
    ///   union could never see a link that was removed.
    static func from(payloads: [ExternalUpdatePayload]) -> ResumePoint {
        let scanned = payloads.prefix(scanDepth)
        guard !scanned.isEmpty else { return .none }

        // `max`, not "the first one that has a value": the payloads arrive newest
        // first by timestamp, and the *event* timestamps are the app's clock while
        // the watermarks are the source's. Those two orders can disagree across a
        // clock change, and a watermark that moved backwards would re-report
        // everything between the two values.
        let watermark = scanned.compactMap(\.watermark).max()

        let reported = scanned.reduce(into: Set<String>()) { ids, payload in
            ids.formUnion(payload.changeIDs ?? [])
        }

        // The newest payload that recorded a set wins outright. A payload written
        // before M4-02 has none, so this skips it rather than treating "not
        // recorded" as "nothing present" — which would report every existing link
        // as new on the first pass after an upgrade.
        let present = scanned.first { $0.presentIDs != nil }?.presentIDs ?? []

        return ResumePoint(
            watermark: watermark, reportedIDs: reported, presentIDs: Set(present))
    }
}
