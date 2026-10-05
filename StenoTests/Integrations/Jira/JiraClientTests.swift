import Foundation
import Testing

@testable import StenoKit

private let inWindow = JiraFixture.inWindow
private let outOfWindow = JiraFixture.outOfWindow
private let since = JiraFixture.windowStart

private func quietRoutes() -> [String: [StubJiraTransport.Answer]] {
    JiraFixture.quietRoutes()
}

/// One request's shape, the failures §5.5 degrades from, and FR-6's connection test.
///
/// The paging lives in `JiraClientPagingTests`.

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

@Test("D-217 revised: a 404 from the verify endpoint is a wrong site, not a missing reference")
func theConnectionTestReportsAWrongSite() async throws {
    // **The defect `make verify-integrations` found.** `*.atlassian.net` has wildcard
    // DNS, so a mistyped-but-well-formed site resolves to an Atlassian edge and
    // answers 404 here — the live probe reported `notFound`, whose sentence is about a
    // missing *ticket* and sends the user looking for something they never named.
    //
    // `/rest/api/3/myself` answers 200 or 401 on a site serving the Jira API, so a 404
    // means this host is not serving it. Mutation: drop `notFound: .siteNotFound` from
    // `verify`. Red.
    let wrongSite = StubJiraTransport(routes: ["myself": [.status(404)]])
    await #expect(throws: SourceError.siteNotFound) {
        try await JiraClient(transport: wrongSite).verify(credential: JiraFixture.credential())
    }
}

@Test("D-217 revised: a 404 on a ref fetch still means the reference is missing")
func aFetchStillReportsAMissingReference() async throws {
    // The other half, and the reason the 404 is a parameter rather than a global
    // change: a mistyped ticket key must keep its own sentence.
    var routes = JiraFixture.quietRoutes()
    routes["issue"] = [.status(404)]
    let missing = StubJiraTransport(routes: routes)
    await #expect(throws: SourceError.notFound) {
        _ = try await JiraClient(transport: missing).changeSet(
            key: "PAY-421", since: since, credential: JiraFixture.credential())
    }
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
