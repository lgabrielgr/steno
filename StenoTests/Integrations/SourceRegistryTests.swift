import Foundation
import Testing

@testable import StenoKit

/// §5.1's routing, and D-166's three outcomes plus D-216's fourth.

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

// MARK: - FR-6's per-integration toggle (D-216)

@Test("D-216: a switched-off claimant dispatches .disabled, not .notConfigured")
func aDisabledClaimantIsDisabled() {
    // The distinction the case exists for: `.notConfigured` makes the stand-up
    // sheet say "no integration set up yet", which is false and is an
    // instruction the user already declined.
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira")], isEnabled: { $0 != "jira" })

    #expect(registry.dispatch(ref()) == .disabled)
}

@Test("D-216: a disabled connector is skipped even though it has a credential")
func aDisabledConnectorWithACredentialStillDoesNotFetch() {
    // The sixth acceptance criterion: disabling stops fetches without deleting
    // the credential, so `isConfigured` is true here and must not matter.
    let configured = StubSourceConnector(id: "jira", isConfigured: true)
    let registry = SourceRegistry(connectors: [configured], isEnabled: { _ in false })

    #expect(registry.dispatch(ref()) == .disabled)
}

@Test("D-216: the default registry enables everything, so M4-01's call sites are unchanged")
func theDefaultRegistryEnablesEverything() {
    // Every `SourceRegistry(connectors:)` written before this task keeps its
    // behaviour. Mutation: default `isEnabled` to `{ _ in false }`. Red here and
    // in most of this file.
    #expect(
        SourceRegistry(connectors: [StubSourceConnector(id: "jira")]).dispatch(ref()) != .disabled)
}

@Test("D-216: an enabled-but-unconfigured claimant outranks a disabled one")
func notConfiguredOutranksDisabled() {
    // Precedence: a sentence the user can act on beats silence. The disabled
    // connector is listed *first*, so a registry that returned the first
    // claimant's verdict rather than applying precedence fails here.
    let switchedOff = StubSourceConnector(id: "confluence", isConfigured: true, kinds: [.jiraIssue])
    let unconfigured = StubSourceConnector(id: "jira", isConfigured: false, kinds: [.jiraIssue])
    let registry = SourceRegistry(
        connectors: [switchedOff, unconfigured], isEnabled: { $0 != "confluence" })

    #expect(registry.dispatch(ref()) == .notConfigured)
}

@Test("D-216: a ready claimant outranks a disabled one whatever the order")
func readyOutranksDisabled() {
    let switchedOff = StubSourceConnector(id: "confluence", kinds: [.jiraIssue])
    let switchedOn = StubSourceConnector(id: "jira", kinds: [.jiraIssue])

    guard
        case .ready(let winner) = SourceRegistry(
            connectors: [switchedOff, switchedOn], isEnabled: { $0 != "confluence" }
        ).dispatch(ref())
    else {
        Issue.record("expected .ready")
        return
    }
    #expect(winner.id == "jira")
}

@Test("D-216: disabling every claimant does not turn an unhandled ref into .disabled")
func anUnclaimedRefStaysUnhandledWhenEverythingIsOff() {
    // `.unhandled` is the ordinary state of a pasted link (D-166) and must not
    // start reporting as a switched-off integration.
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", kinds: [.jiraIssue])],
        isEnabled: { _ in false })

    #expect(registry.dispatch(ref(.url)) == .unhandled)
}

@Test("D-216: `enabled` hides what the user switched off and `all` still lists it")
func enabledAndAllDisagreeDeliberately() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira"), StubSourceConnector(id: "confluence")],
        isEnabled: { $0 != "confluence" })

    #expect(registry.enabled.map(\.id) == ["jira"])
    // The pane reads `all`: an integration that vanished when switched off would
    // offer no way to switch it back on.
    #expect(registry.all.map(\.id) == ["jira", "confluence"])
}

@Test("D-216: the toggle is read per dispatch, so it takes effect without a relaunch")
func theToggleIsReadPerDispatch() {
    // **The guarantee a registry filtered at construction would lose.**
    // `StenoApp` builds the registry once for the process, so this is the only
    // thing standing between a live toggle and one that needs a relaunch.
    let box = DisabledIDBox()
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira")],
        isEnabled: { !box.contains($0) })

    #expect(registry.dispatch(ref()) != .disabled)

    box.insert("jira")

    #expect(registry.dispatch(ref()) == .disabled)
}

/// A mutable, `Sendable` box, so the `@Sendable` closure above can observe a
/// change made after the registry was built.
private final class DisabledIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) { lock.withLock { ids.insert(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}

extension SourceDispatch: @retroactive Equatable {
    /// Test-only, and deliberately coarse: `.ready` compares by connector id
    /// because `any SourceConnector` is not `Equatable` and the tests that care
    /// which connector won destructure the case instead.
    public static func == (lhs: SourceDispatch, rhs: SourceDispatch) -> Bool {
        switch (lhs, rhs) {
        case (.ready(let left), .ready(let right)): return left.id == right.id
        case (.notConfigured, .notConfigured), (.unhandled, .unhandled), (.disabled, .disabled):
            return true
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
