import Foundation
import Testing

@testable import StenoKit

/// The `SourceConnector` conformance (§5.3, D5, D-190, D-194, D-204).

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 24 * 60 * 60

private func pageRef(
    kind: SourceRefKind = .confluencePage,
    url: String? = "https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Payments+Migration+Plan",
    identifier: String = ConfluenceFixture.pageID
) -> SourceRefSnapshot {
    SourceRefSnapshot(refID: UUID(), kind: kind, identifier: identifier, url: url)
}

private func connector(
    credential: AtlassianCredential? = ConfluenceFixture.credential(),
    readError: (any Error)? = nil,
    routes: [String: [StubConfluenceTransport.Answer]] = [:],
    users: [String: StubConfluenceTransport.Answer] = [:]
) -> (ConfluenceConnector, StubConfluenceTransport) {
    let transport = StubConfluenceTransport(routes: routes, users: users)
    let store = InMemoryAtlassianStore(credential, readError: readError)
    return (
        ConfluenceConnector(credentials: store, transport: transport, now: { now }), transport
    )
}

private func fullRoutes() -> [String: [StubConfluenceTransport.Answer]] {
    [
        "page": [.ok(ConfluenceFixture.page())],
        "versions": [
            .ok(
                ConfluenceFixture.versions([
                    ConfluenceFixture.version(
                        number: 9, createdAt: ConfluenceFixture.inWindow, message: "final pass")
                ]))
        ],
    ]
}

private let knownUsers: [String: StubConfluenceTransport.Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez"))
]

// MARK: - Identity

@Test("its id and name are stable, because settings and the banner key on them")
func confluenceConnectorIdentityIsStable() {
    let (confluence, _) = connector()

    #expect(confluence.id == "confluence")
    #expect(confluence.displayName == "Confluence")
}

// MARK: - Routing (D-204)

@Test("it claims Confluence pages and nothing else")
func confluenceConnectorClaimsOnlyConfluencePages() {
    let (confluence, _) = connector()

    #expect(confluence.canHandle(pageRef()))
    #expect(confluence.canHandle(pageRef(kind: .jiraIssue)) == false)
    #expect(confluence.canHandle(pageRef(kind: .githubPR)) == false)
    #expect(confluence.canHandle(pageRef(kind: .url)) == false)
    #expect(confluence.canHandle(pageRef(kind: .mcpResource)) == false)
}

@Test("D-204: a page on another site is not answered from ours")
func confluenceConnectorRefusesAnotherSite() {
    let (confluence, _) = connector()

    // The same page id exists on every Confluence instance, so answering from ours
    // would be confidently wrong — a stand-up line about a document the user has never
    // seen.
    #expect(
        confluence.canHandle(
            pageRef(url: "https://other.atlassian.net/wiki/spaces/X/pages/12345/Page")) == false)
}

@Test("D-204: the classifier's host-free page ids are refused here")
func confluenceConnectorRefusesNonAtlassianHosts() {
    // `SourceURLClassifier` claims any `/pages/<digits>/` URL by design and documents
    // the false positive. This is where that stops being harmless.
    let (confluence, _) = connector()

    #expect(confluence.canHandle(pageRef(url: "https://example.com/pages/12/34")) == false)
    #expect(confluence.canHandle(pageRef(url: "https://wiki.corp.net/pages/12345/x")) == false)
}

@Test("D-204: a ref with no URL is refused, because a page id means nothing alone")
func confluenceConnectorRefusesAURLlessRef() {
    let (confluence, _) = connector()

    #expect(confluence.canHandle(pageRef(url: nil)) == false)
}

@Test("D-204: with nothing configured, a Cloud page is claimed so the user is told")
func confluenceConnectorClaimsCloudPagesWhenUnconfigured() {
    // Without this the ref dispatches `.unhandled` and says nothing, while a Jira ref
    // on the same task says "Atlassian is not set up" — the opposite of §5.3's "one
    // config, two APIs".
    let (confluence, _) = connector(credential: nil)

    #expect(confluence.isConfigured == false)
    #expect(confluence.canHandle(pageRef()))
    #expect(confluence.canHandle(pageRef(url: "https://any.atlassian.net/wiki/pages/9/x")))
    #expect(confluence.canHandle(pageRef(url: "https://example.com/pages/12/34")) == false)
}

// MARK: - Configuration

@Test("D-190: a site that is not an Atlassian Cloud host reads as unconfigured")
func confluenceConnectorRejectsANonCloudSite() {
    let (confluence, _) = connector(
        credential: AtlassianCredential(
            site: "wiki.corp.net", email: "leo@example.com", apiToken: "t"))

    #expect(confluence.isConfigured == false)
}

@Test("a Keychain that will not answer reads as unconfigured, not as a crash")
func confluenceConnectorSurvivesAKeychainFailure() {
    let (confluence, _) = connector(
        credential: nil, readError: KeychainError.unexpected(-25300))

    #expect(confluence.isConfigured == false)
    #expect(confluence.credentialWarning == nil)
}

@Test("an unconfigured fetch throws notConfigured without touching the network")
func confluenceConnectorFetchRequiresACredential() async throws {
    let (confluence, transport) = connector(credential: nil)

    await #expect(throws: SourceError.notConfigured) {
        _ = try await confluence.fetch(pageRef(), since: nil)
    }
    let received = await transport.received
    #expect(received.isEmpty)
}

// MARK: - The expiry warning (§5.2, D-194)

@Test("§5.2: the shared credential's expiry warns under Confluence's own name")
func confluenceConnectorWarnsAboutTheSharedCredential() throws {
    let (confluence, _) = connector(
        credential: ConfluenceFixture.credential(expiresAt: now.addingTimeInterval(10 * day)))

    let warning = try #require(confluence.credentialWarning)
    #expect(warning.displayName == "Confluence")
    #expect(warning.daysRemaining == 10)
    #expect(warning.renewalURL == AtlassianTokenExpiry.renewalURL)
}

@Test("§5.2: fifteen days out is silent, so the warning does not become wallpaper")
func confluenceConnectorDoesNotWarnEarly() {
    let (confluence, _) = connector(
        credential: ConfluenceFixture.credential(expiresAt: now.addingTimeInterval(15 * day)))

    #expect(confluence.credentialWarning == nil)
}

@Test("D-193: the renewal link is constant, so a 401 carries it without an expiry date")
func confluenceConnectorAlwaysOffersARenewalLink() {
    let (confluence, _) = connector(credential: ConfluenceFixture.credential(expiresAt: nil))

    #expect(confluence.credentialWarning == nil)
    #expect(confluence.credentialRenewalURL == AtlassianTokenExpiry.renewalURL)
}

// MARK: - Fetch

@Test("§5.3: a fetch reports the title, the version, the editor and the delta")
func confluenceConnectorFetchReportsTheDelta() async throws {
    let (confluence, _) = connector(routes: fullRoutes(), users: knownUsers)

    let update = try await confluence.fetch(
        pageRef(), since: ConfluenceFixture.windowStart)

    #expect(update.summary == "Payments Migration Plan — v9, edited by Leo Gutierrez")
    #expect(update.changes.map(\.text) == ["v9 by Leo Gutierrez: final pass"])
    #expect(update.watermark == AtlassianDate.parse(ConfluenceFixture.inWindow))
    #expect(update.fetchedAt == now)
    #expect(update.isWindowCapped == false)
}

@Test("D-187 has nothing to do here, so the state set is empty by decision")
func confluenceConnectorReportsNoStateSet() async throws {
    // Every Confluence version carries `createdAt`, so the window does the work. An
    // accidentally-populated `present` would make the service difference a set that
    // nothing here maintains.
    let (confluence, _) = connector(routes: fullRoutes(), users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: ConfluenceFixture.windowStart)

    #expect(update.present.isEmpty)
}

@Test("the reported URL is the page a human would open")
func confluenceConnectorReportsTheHumanURL() async throws {
    let (confluence, _) = connector(routes: fullRoutes(), users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: nil)

    #expect(
        update.url?.absoluteString
            == "https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Payments+Migration+Plan")
}

@Test("a page whose links did not arrive falls back to the ref's own URL")
func confluenceConnectorFallsBackToTheRefURL() async throws {
    let (confluence, _) = connector(
        routes: [
            "page": [.ok(ConfluenceFixture.page(webui: nil))],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ], users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: nil)

    #expect(update.url?.absoluteString == pageRef().url)
}

@Test("the capped flag is forwarded, so a partial window cannot read as a whole one")
func confluenceConnectorForwardsTheCappedFlag() async throws {
    // `SourceUpdate.isWindowCapped` has no default precisely because the Jira adapter
    // forgot to forward it for a whole review round, and every capped walk reported a
    // complete window.
    let pages = (0..<12).map { index in
        StubConfluenceTransport.Answer.ok(
            ConfluenceFixture.versions(
                [
                    ConfluenceFixture.version(
                        number: 100 - index, createdAt: ConfluenceFixture.inWindow)
                ],
                next: ConfluenceFixture.next(cursor: "PAGE\(index)")))
    }
    let (confluence, _) = connector(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": pages], users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: ConfluenceFixture.windowStart)

    #expect(update.isWindowCapped)
}

@Test("D5: a whole fetch through the connector issues only GETs")
func confluenceConnectorFetchIsReadOnly() async throws {
    let (confluence, transport) = connector(routes: fullRoutes(), users: knownUsers)

    _ = try await confluence.fetch(pageRef(), since: ConfluenceFixture.windowStart)

    let methods = await transport.methods
    #expect(methods.isEmpty == false)
    #expect(methods.allSatisfy { $0 == .get })
}

// MARK: - testConnection

@Test("FR-6: the connection test reads through to Confluence")
func confluenceConnectorTestsTheConnection() async throws {
    let (confluence, transport) = connector(
        routes: ["spaces": [.ok(ConfluenceFixture.spaces())]])

    try await confluence.testConnection()

    let urls = await transport.urls
    #expect(urls.first?.contains("/wiki/api/v2/spaces") == true)
}

@Test("FR-6: the test reads the Keychain fresh, never the thirty-second memo")
func confluenceConnectorTestBypassesTheCredentialMemo() async throws {
    // D-198's memo exists so routing does not read the Keychain once per ref — but
    // FR-6's button asks whether what is stored *right now* works, and answering it
    // from a memo makes a freshly pasted token look broken for half a minute.
    let store = InMemoryAtlassianStore(ConfluenceFixture.credential())
    let transport = StubConfluenceTransport(
        routes: ["spaces": [.ok(ConfluenceFixture.spaces()), .ok(ConfluenceFixture.spaces())]])
    let confluence = ConfluenceConnector(
        credentials: store, transport: transport, now: { now })

    _ = confluence.isConfigured  // warms the memo with the old site
    try store.store(
        AtlassianCredential(
            site: "other.atlassian.net", email: "leo@example.com", apiToken: "token-value"))

    try await confluence.testConnection()

    let urls = await transport.urls
    #expect(urls.last?.contains("other.atlassian.net") == true)
    #expect(urls.last?.contains("acme.atlassian.net") == false)
}

@Test("FR-6: an expired token says so here too, not \"the network\"")
func confluenceConnectorTestReportsAnExpiredToken() async throws {
    let (confluence, _) = connector(routes: ["spaces": [.status(401)]])

    await #expect(throws: SourceError.credentialExpired) {
        try await confluence.testConnection()
    }
}

@Test("FR-6: with no credential the test says so rather than asking the network")
func confluenceConnectorTestWithoutACredential() async throws {
    let (confluence, transport) = connector(credential: nil)

    await #expect(throws: SourceError.notConfigured) {
        try await confluence.testConnection()
    }
    let received = await transport.received
    #expect(received.isEmpty)
}
