import Foundation
import Testing

@testable import StenoKit

// Which configuration a connection verdict describes, and when it must be dropped.

// MARK: - A verdict must not outlive the configuration it describes (Copilot, PR #45)

@Test("a verdict names the saved site, not the one being typed")
@MainActor
func aVerdictNamesTheSavedSite() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    #expect(fixture.model.siteHost == JiraFixture.site)

    // Every verdict describes the saved credential, so the host a verdict names must
    // not follow the edit — otherwise "Reached acme.atlassian.net" silently becomes
    // "Reached corrected.atlassian.net", naming a host nothing was sent to.
    // Mutation: read `site` first in `siteHost`. Red.
    fixture.model.site = "corrected.atlassian.net"

    #expect(fixture.model.siteHost == JiraFixture.site)
}

@Test("with nothing saved, the host names what the user typed")
@MainActor
func anUnsavedHostNamesTheEdit() throws {
    let fixture = try IntegrationsFixture()

    fixture.model.site = "https://acme.atlassian.net/jira/software/projects/PAY/boards/1"

    // The fallback: with no stored credential there is nothing else to name, and a
    // pasted URL is still reduced to its host.
    #expect(fixture.model.siteHost == "acme.atlassian.net")
}

@Test("a test still in flight does not resurrect a verdict after the toggle changed")
@MainActor
func anInFlightTestDoesNotResurrectAVerdict() async throws {
    let gate = TaskGate()
    let connector = StubSourceConnector(
        id: "jira", displayName: "Jira", connectionGate: gate)
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), connectors: [connector])

    let test = Task { await fixture.model.testConnection(id: "jira") }

    // Wait for the connection to be genuinely in flight — a `Task` has not started
    // when its initializer returns, so asserting here without waiting would be a
    // race rather than a test.
    while connector.testConnectionCalls == 0 { await Task.yield() }
    #expect(fixture.model.rows.first?.test == .testing)

    // The toggle stays usable during a test, and clears the verdicts.
    fixture.model.setIntegration("jira", enabled: false)
    #expect(fixture.model.rows.first?.test == .untested)

    gate.openNow()
    await test.value

    // Mutation: drop the generation guard in `testConnection`. Red — the late
    // result writes `.passed` back for a configuration that no longer exists.
    #expect(fixture.model.rows.first?.test == .untested)
}

@Test("a test still in flight does not resurrect a verdict after the credential changed")
@MainActor
func anInFlightTestDoesNotOutliveItsCredential() async throws {
    let gate = TaskGate()
    let connector = StubSourceConnector(
        id: "jira", displayName: "Jira", connectionGate: gate)
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), connectors: [connector])

    let test = Task { await fixture.model.testConnection(id: "jira") }
    while connector.testConnectionCalls == 0 { await Task.yield() }

    // Replacing the token is the case that matters most: a green tick beside Jira
    // afterwards is a claim about a credential that no longer exists.
    fixture.model.tokenEntry = "replacement-token"
    fixture.model.saveCredential()

    gate.openNow()
    await test.value

    #expect(fixture.model.rows.first?.test == .untested)
}

@Test("a test that nothing interrupted still records its verdict")
@MainActor
func anUninterruptedTestStillRecordsItsVerdict() async throws {
    let gate = TaskGate()
    let connector = StubSourceConnector(
        id: "jira", displayName: "Jira", connectionGate: gate)
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), connectors: [connector])

    let test = Task { await fixture.model.testConnection(id: "jira") }
    while connector.testConnectionCalls == 0 { await Task.yield() }

    gate.openNow()
    await test.value

    // The other direction, so the guard is not a blanket suppression of every
    // result that crossed a suspension point.
    #expect(fixture.model.rows.first?.test == .passed)
}
