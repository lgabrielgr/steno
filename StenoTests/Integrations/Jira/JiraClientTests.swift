import Foundation
import Testing

@testable import StenoKit

/// D-196's paging, and the failure shapes §5.5 degrades from.

private let inWindow = "2026-09-25T18:04:11.000+0000"
private let outOfWindow = "2026-09-20T09:00:00.000+0000"
private let since = JiraDate.parse("2026-09-22T00:00:00.000+0000")

/// Routes that answer every endpoint with an empty, well-formed page.
private func quietRoutes() -> [String: [StubJiraTransport.Answer]] {
    [
        "issue": [.ok(JiraFixture.issue())],
        "changelog@0": [.ok(JiraFixture.changelog([], total: 0, isLast: true))],
        "comment@0": [.ok(JiraFixture.comments([], total: 0))],
        "remotelink": [.ok(JiraFixture.remoteLinks([]))],
    ]
}

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

@Test("D5: every request in a full fetch is a GET")
func everyRequestInAFetchIsAGet() async throws {
    let transport = StubJiraTransport(routes: quietRoutes())

    _ = try await JiraClient(transport: transport).changeSet(
        key: JiraFixture.key, since: since, credential: JiraFixture.credential())

    // The second of D5's three enforcement points, end to end rather than per endpoint.
    let methods = await transport.methods
    #expect(methods.isEmpty == false)
    #expect(methods.allSatisfy { $0 == .get })
}

@Test("all four reads are required: a failed link request fails the fetch")
func afailedLinkRequestFailsTheFetch() async throws {
    var routes = quietRoutes()
    routes["remotelink"] = [.status(503)]
    let transport = StubJiraTransport(routes: routes)

    // **Not "no links present".** `present` is a state set (D-187), so an empty one
    // would make every existing PR reference look new on the next pass — §5.5 prefers
    // one degraded ref over a false event.
    await #expect(throws: SourceError.unavailable(status: 503)) {
        try await JiraClient(transport: transport).changeSet(
            key: JiraFixture.key, since: since, credential: JiraFixture.credential())
    }
}

@Test("§5.2: a 401 on any of the four reads becomes credentialExpired")
func afourOhOneBecomesCredentialExpired() async throws {
    var routes = quietRoutes()
    routes["comment@0"] = [.status(401)]
    let transport = StubJiraTransport(routes: routes)

    await #expect(throws: SourceError.credentialExpired) {
        try await JiraClient(transport: transport).changeSet(
            key: JiraFixture.key, since: since, credential: JiraFixture.credential())
    }
}

@Test("a body that will not decode is reported as an unreadable response")
func anUndecodableBodyIsInvalidResponse() async throws {
    var routes = quietRoutes()
    routes["issue"] = [.ok("{\"fields\": \"not an object\"}")]
    let transport = StubJiraTransport(routes: routes)

    await #expect(throws: SourceError.invalidResponse) {
        try await JiraClient(transport: transport).changeSet(
            key: JiraFixture.key, since: since, credential: JiraFixture.credential())
    }
}

@Test("a credential whose site is not Atlassian Cloud never reaches the network")
func abadSiteNeverReachesTheNetwork() async throws {
    let transport = StubJiraTransport(routes: quietRoutes())
    let credential = AtlassianCredential(site: "evil.com", email: "leo@example.com", apiToken: "t")

    await #expect(throws: SourceError.notConfigured) {
        try await JiraClient(transport: transport).changeSet(
            key: JiraFixture.key, since: since, credential: credential)
    }
    // The assertion that matters: the token was never sent anywhere (D-190).
    #expect(await transport.received.isEmpty)
}

@Test("a mistyped key is refused before a request is spent on it")
func amistypedKeyIsRefusedLocally() async throws {
    let transport = StubJiraTransport(routes: quietRoutes())

    await #expect(throws: SourceError.notFound) {
        try await JiraClient(transport: transport).changeSet(
            key: "PAY 421", since: since, credential: JiraFixture.credential())
    }
    #expect(await transport.received.isEmpty)
}

@Test("FR-6: the connection test asks who the credential belongs to")
func theConnectionTestAsksMyself() async throws {
    let transport = StubJiraTransport(routes: ["myself": [.ok(JiraFixture.currentUser)]])

    try await JiraClient(transport: transport).verify(credential: JiraFixture.credential())

    let asked = await transport.received.map(StubJiraTransport.endpointKey)
    // `/myself` rather than an issue: a test must distinguish a rejected credential from
    // a ticket the account cannot see, and any issue key would confuse the two.
    #expect(asked == ["myself"])
}

@Test("FR-6: a rejected credential is distinguishable from an unreachable host")
func theConnectionTestDistinguishesItsFailures() async throws {
    let rejected = StubJiraTransport(routes: ["myself": [.status(403)]])
    await #expect(throws: SourceError.invalidCredential) {
        try await JiraClient(transport: rejected).verify(credential: JiraFixture.credential())
    }

    let offline = StubJiraTransport(
        routes: ["myself": [.fail(URLError(.notConnectedToInternet))]])
    await #expect(throws: SourceError.network) {
        try await JiraClient(transport: offline).verify(credential: JiraFixture.credential())
    }
}
