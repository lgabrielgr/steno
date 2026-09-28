import Foundation
import Testing

@testable import StenoKit

/// The `SourceConnector` conformance (§5.2, D5, D-190, D-193, D-194).

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 24 * 60 * 60

private func ref(_ kind: SourceRefKind = .jiraIssue) -> SourceRefSnapshot {
    SourceRefSnapshot(refID: UUID(), kind: kind, identifier: JiraFixture.key)
}

private func connector(
    credential: AtlassianCredential? = JiraFixture.credential(),
    readError: (any Error)? = nil,
    routes: [String: [StubJiraTransport.Answer]] = [:]
) -> (JiraConnector, StubJiraTransport) {
    let transport = StubJiraTransport(routes: routes)
    let store = InMemoryAtlassianStore(credential, readError: readError)
    return (JiraConnector(credentials: store, transport: transport, now: { now }), transport)
}

private func fullRoutes() -> [String: [StubJiraTransport.Answer]] {
    [
        "issue": [.ok(JiraFixture.issue())],
        "changelog@0": [
            .ok(
                JiraFixture.changelog(
                    [
                        JiraFixture.Entry.status(
                            id: "10001", created: "2026-09-25T18:04:11.000+0000",
                            from: "In Progress", to: "In Review")
                    ], total: 1, isLast: true))
        ],
        "comment@0": [
            .ok(
                JiraFixture.comments(
                    [JiraFixture.Comment(id: "9001", created: "2026-09-25T19:00:00.000+0000")],
                    total: 1))
        ],
        "remotelink": [.ok(JiraFixture.remoteLinks([JiraFixture.Link()]))],
    ]
}

@Test("it claims Jira issues and nothing else")
func itClaimsJiraIssuesOnly() {
    let (jira, _) = connector()
    #expect(jira.canHandle(ref(.jiraIssue)))
    // Confluence pages are M4-03's, on the same credential (§5.3) — "distinct REST
    // APIs; do not conflate them".
    #expect(jira.canHandle(ref(.confluencePage)) == false)
    #expect(jira.canHandle(ref(.githubPR)) == false)
    #expect(jira.canHandle(ref(.url)) == false)
    #expect(jira.canHandle(ref(.mcpResource)) == false)
}

@Test("its id and name are stable, because settings and the banner key on them")
func itsIdentityIsStable() {
    let (jira, _) = connector()
    #expect(jira.id == "jira")
    #expect(jira.displayName == "Jira")
}

@Test("no credential means not configured")
func noCredentialMeansNotConfigured() {
    let (jira, _) = connector(credential: nil)
    #expect(jira.isConfigured == false)
}

@Test("D-190: a credential whose site is not Atlassian Cloud reads as not configured")
func abadSiteReadsAsNotConfigured() {
    // The user is sent to Settings, where the problem is, rather than to a failing pass
    // that talks about the network.
    let (jira, _) = connector(
        credential: AtlassianCredential(site: "evil.com", email: "leo@example.com", apiToken: "t"))
    #expect(jira.isConfigured == false)
}

@Test("a usable credential means configured")
func ausableCredentialMeansConfigured() {
    let (jira, _) = connector()
    #expect(jira.isConfigured)
}

@Test("a Keychain failure reads as absent rather than crashing a refresh")
func akeychainFailureReadsAsAbsent() async {
    struct Refused: Error {}
    let (jira, _) = connector(readError: Refused())

    // `isConfigured` and `credentialWarning` are synchronous and non-throwing by
    // contract, and §5.5 says a refresh must never block a report — so the honest
    // reading of "the Keychain would not answer" is that the integration is unusable
    // right now.
    #expect(jira.isConfigured == false)
    #expect(jira.credentialWarning == nil)
    await #expect(throws: SourceError.notConfigured) {
        _ = try await jira.fetch(ref(), since: nil)
    }
}

@Test("§5.2: a token expiring inside 14 days produces a warning")
func anExpiringTokenWarns() throws {
    let (jira, _) = connector(
        credential: JiraFixture.credential(expiresAt: now.addingTimeInterval(9 * day)))

    let warning = try #require(jira.credentialWarning)
    #expect(warning.displayName == "Jira")
    #expect(warning.daysRemaining == 9)
}

@Test("a token expiring later says nothing")
func adistantTokenIsSilent() {
    let (jira, _) = connector(
        credential: JiraFixture.credential(expiresAt: now.addingTimeInterval(90 * day)))
    #expect(jira.credentialWarning == nil)
}

@Test("D-193: the renewal link is there even with no expiry date recorded")
func therenewalLinkIsUnconditional() {
    // A 401 arrives exactly when the hand-entered expiry date is wrong or missing, so a
    // link derived from the warning would be absent at the one moment §5.2 requires it.
    let (jira, _) = connector(credential: JiraFixture.credential(expiresAt: nil))
    #expect(jira.credentialWarning == nil)
    #expect(jira.credentialRenewalURL == AtlassianTokenExpiry.renewalURL)
}

@Test("a fetch becomes a SourceUpdate the refresh service can apply")
func afetchBecomesASourceUpdate() async throws {
    let (jira, _) = connector(routes: fullRoutes())

    let update = try await jira.fetch(ref(), since: JiraDate.parse("2026-09-22T00:00:00.000+0000"))

    #expect(update.summary == "Add the migration plan — In Review · assigned to Leo Gutierrez")
    #expect(
        Set(update.changes.map(\.text)) == [
            "status: In Progress → In Review",
            "comment from Ana Ruiz: Could you add the migration plan?",
        ])
    #expect(update.present.map(\.text) == ["linked acme/api#421"])
    #expect(update.watermark == JiraDate.parse("2026-09-25T19:00:00.000+0000"))
    // The human-facing page, not the API endpoint: this reaches an event payload.
    #expect(update.url?.absoluteString == "https://acme.atlassian.net/browse/PAY-421")
    // The connector's own clock, diagnostic only — the row's stamp is the app's (D-171).
    #expect(update.fetchedAt == now)
}

@Test("D5: a whole fetch through the connector issues only GETs")
func awholeFetchIssuesOnlyGets() async throws {
    let (jira, transport) = connector(routes: fullRoutes())

    _ = try await jira.fetch(ref(), since: nil)

    // The third of D5's enforcement points: the endpoint cases, the transport's own
    // guard, and this — the whole path as the app actually calls it.
    let methods = await transport.methods
    #expect(methods.count == 4)
    #expect(methods.allSatisfy { $0 == .get })
}

@Test("the connector throws SourceError and nothing else")
func theConnectorThrowsOnlySourceError() async throws {
    let (jira, _) = connector(routes: ["issue": [.fail(URLError(.notConnectedToInternet))]])

    // `SourceConnector`'s contract, which `SourceRefreshService` catches violations of
    // rather than trusting: a `URLError` escaping here would reach a non-throwing pass
    // as an unhandled type.
    await #expect(throws: SourceError.network) {
        _ = try await jira.fetch(ref(), since: nil)
    }
}

@Test("FR-6: testConnection needs a credential before it needs a network")
func testConnectionNeedsACredential() async {
    let (jira, transport) = connector(credential: nil)

    await #expect(throws: SourceError.notConfigured) {
        try await jira.testConnection()
    }
    #expect(await transport.received.isEmpty)
}

@Test("FR-6: testConnection succeeds against a live credential")
func testConnectionSucceeds() async throws {
    let (jira, _) = connector(routes: ["myself": [.ok(JiraFixture.currentUser)]])
    try await jira.testConnection()
}

// MARK: - D19's instance boundary (review round 3)

@Test("a bare ticket key with no URL is claimed")
func abareKeyIsClaimed() {
    // D7's common case: a ticket key in a task title, whose only possible instance is the
    // configured one.
    let (jira, _) = connector()
    #expect(
        jira.canHandle(SourceRefSnapshot(refID: UUID(), kind: .jiraIssue, identifier: "PAY-421")))
}

@Test("a URL on the configured site is claimed")
func aurlOnTheConfiguredSiteIsClaimed() {
    let (jira, _) = connector()
    #expect(
        jira.canHandle(
            SourceRefSnapshot(
                refID: UUID(), kind: .jiraIssue, identifier: "PAY-421",
                url: "https://acme.atlassian.net/browse/PAY-421")))
}

@Test("D19: a self-hosted Jira URL is not this connector's, however Jira-shaped it is")
func aselfHostedJiraURLIsRefused() {
    // `SourceURLClassifier` classifies by path shape on purpose, so this arrives as a
    // `.jiraIssue` ref — and claiming it meant fetching `PAY-421` from the configured Cloud
    // site and filing a different instance's ticket against it. Raised by Copilot in review
    // round 3 of PR #43.
    let (jira, _) = connector()
    #expect(
        jira.canHandle(
            SourceRefSnapshot(
                refID: UUID(), kind: .jiraIssue, identifier: "PAY-421",
                url: "https://jira.corp.net/browse/PAY-421")) == false)
}

@Test("another Atlassian Cloud site is refused too, because the same key exists on both")
func anotherCloudSiteIsRefused() {
    let (jira, _) = connector()
    #expect(
        jira.canHandle(
            SourceRefSnapshot(
                refID: UUID(), kind: .jiraIssue, identifier: "PAY-421",
                url: "https://other.atlassian.net/browse/PAY-421")) == false)
}

@Test("with nothing configured, a Cloud URL is still claimed so the user is told to set it up")
func acloudURLIsClaimedWhenUnconfigured() {
    // `false` would mean `.unhandled` — silence — where the useful answer is "this integration
    // isn't set up yet".
    let (jira, _) = connector(credential: nil)
    #expect(
        jira.canHandle(
            SourceRefSnapshot(
                refID: UUID(), kind: .jiraIssue, identifier: "PAY-421",
                url: "https://acme.atlassian.net/browse/PAY-421")))
}

@Test("with nothing configured, a self-hosted URL is still refused")
func aselfHostedURLIsRefusedWhenUnconfigured() {
    let (jira, _) = connector(credential: nil)
    #expect(
        jira.canHandle(
            SourceRefSnapshot(
                refID: UUID(), kind: .jiraIssue, identifier: "PAY-421",
                url: "https://jira.corp.net/browse/PAY-421")) == false)
}
