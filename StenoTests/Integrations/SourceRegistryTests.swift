import Foundation
import Testing

@testable import StenoKit

/// §5.1's routing, and D-166's three outcomes.

private func ref(_ kind: SourceRefKind = .jiraIssue) -> SourceRefSnapshot {
    SourceRefSnapshot(refID: UUID(), kind: kind, identifier: "PAY-421")
}

@Test("a configured connector that claims the ref is ready")
func aConfiguredClaimantIsReady() {
    let registry = SourceRegistry(connectors: [StubSourceConnector(id: "jira")])

    guard case .ready(let connector) = registry.dispatch(ref()) else {
        Issue.record("expected .ready")
        return
    }
    #expect(connector.id == "jira")
}

@Test("D-166: a claimant with no credential dispatches .notConfigured, not .unhandled")
func anUnconfiguredClaimantIsNotConfigured() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", isConfigured: false)])

    #expect(registry.dispatch(ref()) == .notConfigured)
}

@Test("D-166: a ref no connector claims is unhandled, and that is not an error")
func anUnclaimedRefIsUnhandled() {
    // A bare `.url` ref is what FR-1.5's extractor makes of every pasted link,
    // and no connector in any planned milestone handles one.
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", kinds: [.jiraIssue])])

    #expect(registry.dispatch(ref(.url)) == .unhandled)
}

@Test("an empty registry leaves every ref unhandled (D-179: what ships this milestone)")
func anEmptyRegistryHandlesNothing() {
    #expect(SourceRegistry().dispatch(ref()) == .unhandled)
    #expect(SourceRegistry().dispatch(ref(.confluencePage)) == .unhandled)
}

@Test("D-166: registration order is priority among two claimants")
func registrationOrderDecides() {
    // **The expectation order disagrees with a plausible implementation's:**
    // "second" is declared after "first" and is the one that must win when it is
    // listed first, so a registry that ignored order and returned the
    // lexicographically smaller id, or the last match, fails here.
    let second = StubSourceConnector(id: "second")
    let first = StubSourceConnector(id: "first")

    guard case .ready(let winner) = SourceRegistry(connectors: [second, first]).dispatch(ref())
    else {
        Issue.record("expected .ready")
        return
    }
    #expect(winner.id == "second")

    guard case .ready(let reversed) = SourceRegistry(connectors: [first, second]).dispatch(ref())
    else {
        Issue.record("expected .ready")
        return
    }
    #expect(reversed.id == "first")
}

@Test("configuration is part of routing: an unconfigured first claimant does not shadow")
func anUnconfiguredClaimantDoesNotShadow() {
    let unconfigured = StubSourceConnector(id: "mcp", isConfigured: false)
    let configured = StubSourceConnector(id: "jira")

    guard
        case .ready(let winner) = SourceRegistry(connectors: [unconfigured, configured])
            .dispatch(ref())
    else {
        Issue.record("expected .ready")
        return
    }
    #expect(winner.id == "jira")
}

@Test("M4-04 reaches one connector by id")
func connectorsAreAddressableByID() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira"), StubSourceConnector(id: "confluence")])

    #expect(registry.connector(withID: "confluence")?.id == "confluence")
    #expect(registry.connector(withID: "github") == nil)
    #expect(registry.all.count == 2)
}

extension SourceDispatch: @retroactive Equatable {
    /// Test-only, and deliberately coarse: `.ready` compares by connector id
    /// because `any SourceConnector` is not `Equatable` and the tests that care
    /// which connector won destructure the case instead.
    public static func == (lhs: SourceDispatch, rhs: SourceDispatch) -> Bool {
        switch (lhs, rhs) {
        case (.ready(let left), .ready(let right)): return left.id == right.id
        case (.notConfigured, .notConfigured), (.unhandled, .unhandled): return true
        default: return false
        }
    }
}

// MARK: - The production shape (D-179)

@Test("§5.3: one credential, two APIs — a Jira ref and a Confluence ref each reach their own")
func theProductionRegistryRoutesBothAtlassianKinds() throws {
    // **This stands in for `StenoApp`'s array**, which no test can reach: the test bundle
    // links `StenoKit`, not the application (D-010). What it asserts is the shape that
    // array has, so the wiring is checked even though the composition root is not.
    //
    // **It said the opposite until PR #44's review.** Written for M4-01 and updated for
    // M4-02, it registered Jira alone and asserted that a Confluence ref was `.unhandled`
    // — so the test that claims to mirror the composition root encoded the behaviour
    // M4-03 exists to change, and stayed green while doing it. A proxy that is not updated
    // with the thing it proxies is worse than no proxy: it reports on a shape nobody has.
    //
    // **What this still cannot do, stated so nobody relies on it.** Deleting a connector
    // from `StenoApp`'s array breaks nothing here — verified by doing it, and the suite
    // stayed green. The array is in the app target, which this bundle does not link, so
    // this test asserts the *shape* the array is supposed to have and nothing about the
    // array. A reviewer comparing the two is the check; `make run` (D-179) is the only
    // end-to-end one.
    //
    // **One store instance, deliberately**, because that is §5.3's whole claim: both
    // connectors read the same Keychain item, so configuring Atlassian once enables both.
    let credentials = InMemoryAtlassianStore(JiraFixture.credential())
    let registry = SourceRegistry(connectors: [
        JiraConnector(credentials: credentials, transport: StubJiraTransport(routes: [:])),
        ConfluenceConnector(
            credentials: credentials, transport: StubConfluenceTransport(routes: [:])),
    ])

    let jiraRef = SourceRefSnapshot(refID: UUID(), kind: .jiraIssue, identifier: "PAY-421")
    guard case .ready(let jira) = registry.dispatch(jiraRef) else {
        Issue.record("a Jira issue ref did not reach a ready connector")
        return
    }
    #expect(jira.id == "jira")

    // A page on the configured site (D-204 requires the URL, and requires the host to
    // match — the same fixture site the credential above names).
    let pageRef = SourceRefSnapshot(
        refID: UUID(), kind: .confluencePage, identifier: "12345",
        url: "https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Plan")
    guard case .ready(let confluence) = registry.dispatch(pageRef) else {
        Issue.record("a Confluence page ref did not reach a ready connector")
        return
    }
    #expect(confluence.id == "confluence")

    // And neither claims what the other handles, so one credential does not become one
    // connector answering for both APIs (§5.3: "do not conflate them").
    #expect(jira.canHandle(pageRef) == false)
    #expect(confluence.canHandle(jiraRef) == false)
}

@Test("an unconfigured Jira connector reports the ref as awaiting setup")
func anUnconfiguredJiraConnectorIsNotConfigured() throws {
    // The distinction D-166 exists for: "no credential yet" is a sentence about Settings,
    // where "nothing claims it" is silence.
    let registry = SourceRegistry(connectors: [
        JiraConnector(
            credentials: InMemoryAtlassianStore(nil),
            transport: StubJiraTransport(routes: [:]))
    ])

    let jiraRef = SourceRefSnapshot(refID: UUID(), kind: .jiraIssue, identifier: "PAY-421")
    guard case .notConfigured = registry.dispatch(jiraRef) else {
        Issue.record("an unconfigured connector did not report itself as unconfigured")
        return
    }
}
