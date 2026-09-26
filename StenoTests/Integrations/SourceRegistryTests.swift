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
