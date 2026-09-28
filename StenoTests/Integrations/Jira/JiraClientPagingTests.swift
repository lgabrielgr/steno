import Foundation
import Testing

@testable import StenoKit

private let inWindow = JiraFixture.inWindow
private let outOfWindow = JiraFixture.outOfWindow
private let since = JiraFixture.windowStart

private func quietRoutes() -> [String: [StubJiraTransport.Answer]] {
    JiraFixture.quietRoutes()
}

/// D-196's paging: how a window is applied to two endpoints that offer no date filter, and what a
/// capped walk is allowed to claim.
///
/// **Split from `JiraClientTests` for `file_length`**, along the seam the subject already has:
/// everything here is about which offsets were asked for and what the watermark says afterwards,
/// where that file covers one request, its failures, and the connection test.

@Test("a changelog that fits one page is one request")
func aShortChangelogIsOneRequest() async throws {
    var routes = quietRoutes()
    routes["changelog@0"] = [
        .ok(
            JiraFixture.changelog(
                [.status(id: "1", created: inWindow, from: "In Progress", to: "In Review")],
                total: 1, isLast: true))
    ]
    let transport = StubJiraTransport(routes: routes)

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    #expect(set.changes.map(\.id) == ["1#status"])
    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("changelog") } == ["changelog@0"])
}

@Test("D-196: a long changelog is paged backwards from the end")
func aLongChangelogIsPagedBackwards() async throws {
    // 250 entries. Forward paging would read all of them to find yesterday's
    // transition; `total` is what makes the newest end reachable in one hop.
    var routes = quietRoutes()
    routes["changelog@0"] = [
        .ok(
            JiraFixture.changelog(
                [
                    .status(
                        id: "ancient", created: "2024-01-02T03:04:05.000+0000", from: "a", to: "b")
                ],
                total: 250, startAt: 0, isLast: false))
    ]
    routes["changelog@150"] = [
        .ok(
            JiraFixture.changelog(
                [.status(id: "newest", created: inWindow, from: "In Progress", to: "In Review")],
                total: 250, startAt: 150, isLast: false))
    ]
    routes["changelog@50"] = [
        .ok(
            JiraFixture.changelog(
                [.status(id: "older", created: outOfWindow, from: "To Do", to: "In Progress")],
                total: 250, startAt: 50, isLast: false))
    ]
    let transport = StubJiraTransport(routes: routes)

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(
        asked.filter { $0.hasPrefix("changelog") } == [
            "changelog@0", "changelog@150", "changelog@50",
        ])

    // The walk stops at the page whose oldest entry predates the window, and the probe
    // page's ancient entry is discarded rather than merged — otherwise an entry whose
    // timestamp failed to parse would be reported years later.
    #expect(set.changes.map(\.id) == ["newest#status"])
}

@Test("with no anchor, only the newest page is read")
func withNoAnchorOnlyTheNewestPageIsRead() async throws {
    var routes = quietRoutes()
    routes["changelog@0"] = [
        .ok(JiraFixture.changelog([], total: 250, startAt: 0, isLast: false))
    ]
    routes["changelog@150"] = [
        .ok(
            JiraFixture.changelog(
                [.status(id: "newest", created: inWindow, from: "In Progress", to: "In Review")],
                total: 250, startAt: 150, isLast: false))
    ]
    let transport = StubJiraTransport(routes: routes)

    _ = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: nil, credential: JiraFixture.credential())

    // Establishing an anchor needs the newest timestamp, not the history (D-188).
    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("changelog") } == ["changelog@0", "changelog@150"])
}

@Test("comments stop at the first page that predates the window")
func commentsStopEarly() async throws {
    var routes = quietRoutes()
    routes["comment@0"] = [
        .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "9001", created: outOfWindow)], total: 120))
    ]
    let transport = StubJiraTransport(routes: routes)

    _ = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    // `orderBy=-created` makes the first page the newest, so one page older than the
    // window ends the walk — however many hundred comments the ticket has.
    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("comment") } == ["comment@0"])
}

@Test("comments page on startAt plus total, because PageOfComments has no isLast")
func commentsPageOnTotal() async throws {
    var routes = quietRoutes()
    routes["comment@0"] = [
        .ok(
            JiraFixture.comments(
                [
                    JiraFixture.Comment(id: "9001", created: inWindow),
                    JiraFixture.Comment(id: "9002", created: inWindow),
                ], total: 3))
    ]
    routes["comment@2"] = [
        .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "9003", created: inWindow)], total: 3, startAt: 2))
    ]
    let transport = StubJiraTransport(routes: routes)

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("comment") } == ["comment@0", "comment@2"])
    #expect(set.changes.count == 3)
}

@Test("a runaway walk stops at the page cap")
func arunawayWalkStopsAtTheCap() async throws {
    // Every page is inside the window and `total` claims there is always more, which is
    // what a ticket being edited during the walk looks like. The cap bounds it; the
    // watermark is the newest item actually read, so the rest falls into the next pass.
    var routes = quietRoutes()
    routes["changelog@0"] = [.ok(JiraFixture.changelog([], total: 10_000, isLast: false))]
    let transport = StubJiraTransport(
        routes: routes,
        fallback: .ok(
            JiraFixture.changelog(
                [.status(id: "x", created: inWindow, from: "a", to: "b")], total: 10_000,
                isLast: false)))

    _ = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("changelog") }.count == JiraClient.maxPages + 1)
}

@Test("an edit to a comment created before the paged window is not detected")
func anEditOutsideThePagedWindowIsNotDetected() async throws {
    // **A limitation pinned as a test, not a bug hidden by one.** The endpoint orders by
    // `created` and offers no filter on `updated`, so an edit to an old comment sits on a
    // later page — and the early stop, which is what keeps a chatty ticket from costing ten
    // requests a pass, gets there first. §5.2 asks for "new comments", so this is inside the
    // requirement; catching it would mean reading every comment on every pass.
    //
    // Raised by Copilot in review of PR #43. If a future task decides the trade is wrong,
    // this test is where the decision is recorded, and it should fail when that changes.
    var routes = quietRoutes()
    routes["comment@0"] = [
        .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "9100", created: outOfWindow)], total: 2))
    ]
    // Page two holds an old comment edited *inside* the window. The walk never asks for it.
    routes["comment@1"] = [
        .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "9101", created: outOfWindow, updated: inWindow)],
                total: 2, startAt: 1))
    ]
    let transport = StubJiraTransport(routes: routes)

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("comment") } == ["comment@0"])
    #expect(set.changes.isEmpty)
}

@Test("a capped comment walk holds the watermark at the oldest comment it read")
func acommentWalkThatHitsTheCapStops() async throws {
    // Every page is inside the window and `total` claims there is always more — a ticket with
    // hundreds of recent comments. The walk stops at the cap, so the oldest comments inside
    // the window are never read.
    //
    // **The watermark is therefore held at the oldest comment read, not the newest.**
    // Advancing it would close over that gap, and the next pass — which starts from the
    // watermark — would never look at it again. Held back, the gap stays inside the window and
    // fills itself once the ticket quiets enough for the walk to reach past it. Raised by
    // Copilot in review round 2 of PR #43; the first attempt only logged the cap, and a
    // mutation of that log survived the suite, which is what showed the fix was in the wrong
    // place.
    //
    // **The pages carry different timestamps on purpose.** The first version of this test gave
    // every comment the same one, so `min` and `max` were the same value and the assertions
    // below could not tell a held-back watermark from an advanced one — two mutations survived
    // it. Page one is the newest comment; every later page is older but still inside the
    // window, so the walk runs to the cap.
    let midWindow = "2026-09-24T09:00:00.000+0000"
    var routes = quietRoutes()
    routes["comment@0"] = [
        .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "c0", created: inWindow)], total: 10_000))
    ]
    let transport = StubJiraTransport(
        routes: routes,
        fallback: .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "cN", created: midWindow)], total: 10_000)))

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    #expect(asked.filter { $0.hasPrefix("comment") }.count == JiraClient.maxPages)
    // What it read is still reported — a partial window beats an empty one (§5.5).
    #expect(set.changes.isEmpty == false)
    #expect(set.watermark == JiraDate.parse(midWindow))
    #expect(set.watermark != JiraDate.parse(inWindow))
}

@Test("a capped changelog walk also holds the watermark back")
func acappedChangelogWalkHoldsTheWatermarkBack() async throws {
    // The same rule on the other stream, because a fix that landed on only the stream in the
    // review comment would leave the other one closing over its own gap.
    let older = "2026-09-23T08:00:00.000+0000"
    var routes = quietRoutes()
    routes["changelog@0"] = [.ok(JiraFixture.changelog([], total: 10_000, isLast: false))]
    let transport = StubJiraTransport(
        routes: routes,
        fallback: .ok(
            JiraFixture.changelog(
                [
                    .status(id: "new", created: inWindow, from: "a", to: "b"),
                    .status(id: "old", created: older, from: "c", to: "d"),
                ], total: 10_000, isLast: false)))

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    #expect(set.watermark == JiraDate.parse(older))
}

@Test("a complete walk still reports the newest timestamp it saw")
func acompleteWalkReportsTheNewest() async throws {
    // The other direction, because "always hold the watermark back" would pass both tests
    // above and stall every ordinary ref's window forever.
    var routes = quietRoutes()
    routes["comment@0"] = [
        .ok(
            JiraFixture.comments(
                [
                    JiraFixture.Comment(id: "9001", created: inWindow),
                    JiraFixture.Comment(id: "9002", created: outOfWindow),
                ], total: 2))
    ]
    let transport = StubJiraTransport(routes: routes)

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    #expect(set.watermark == JiraDate.parse(inWindow))
}

@Test("when both streams cap, the watermark takes the older floor")
func bothStreamsCappedTakesTheOlderFloor() async throws {
    // **The test that can tell `min` from `max`.** Each capped stream was read down to its own
    // floor, so the unreported region is the union of what lies below them — and the older
    // boundary is the one that keeps more of that union inside the next window. The newer
    // boundary reads as "the point above which every stream is covered", which is true and
    // useless: it advances past the older stream's gap and skips it permanently. Raised by
    // Copilot in review round 3 of PR #43.
    let commentFloor = "2026-09-24T09:00:00.000+0000"
    let changelogFloor = "2026-09-23T09:00:00.000+0000"

    var routes: [String: [StubJiraTransport.Answer]] = [
        "issue": [.ok(JiraFixture.issue())],
        "remotelink": [.ok(JiraFixture.remoteLinks([]))],
        // Both probes claim far more than the caps can read, so both walks run to the cap.
        "changelog@0": [.ok(JiraFixture.changelog([], total: 10_000, isLast: false))],
    ]
    routes["comment@0"] = [
        .ok(
            JiraFixture.comments(
                [JiraFixture.Comment(id: "c0", created: inWindow)], total: 10_000))
    ]

    // Later pages of each stream sit at that stream's floor.
    let transport = TwoStreamCappedTransport(
        routes: routes, commentFloor: commentFloor, changelogFloor: changelogFloor)

    let set = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    // The older of the two floors, not the newer.
    #expect(set.watermark == JiraDate.parse(changelogFloor))
    #expect(set.watermark != JiraDate.parse(commentFloor))
}

/// Answers later pages of each stream at that stream's own floor.
///
/// A second double rather than a cleverer script: `StubJiraTransport`'s routes are keyed by
/// offset, and a both-streams-capped walk asks for ten offsets per stream that this test has no
/// reason to spell out.
private actor TwoStreamCappedTransport: HTTPTransport {
    private let inner: StubJiraTransport
    private let commentFloor: String
    private let changelogFloor: String

    init(
        routes: [String: [StubJiraTransport.Answer]], commentFloor: String, changelogFloor: String
    ) {
        self.inner = StubJiraTransport(routes: routes)
        self.commentFloor = commentFloor
        self.changelogFloor = changelogFloor
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = StubJiraTransport.endpointKey(request)
        switch key {
        case "comment@0", "changelog@0", "issue", "remotelink":
            return try await inner.send(request)
        case let key where key.hasPrefix("comment"):
            return HTTPResponse(
                status: 200,
                body: Data(
                    JiraFixture.comments(
                        [JiraFixture.Comment(id: "cN", created: commentFloor)], total: 10_000
                    ).utf8))
        default:
            return HTTPResponse(
                status: 200,
                body: Data(
                    JiraFixture.changelog(
                        [.status(id: "aN", created: changelogFloor, from: "a", to: "b")],
                        total: 10_000, isLast: false
                    ).utf8))
        }
    }
}
