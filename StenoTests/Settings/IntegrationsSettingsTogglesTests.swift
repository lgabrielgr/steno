import Foundation
import Testing

@testable import StenoKit

// FR-6's per-integration toggle, connection test, expiry warning and purge.

// MARK: - FR-6's toggle (D-216)

@Test("D-216: the toggle writes settings and changes routing in the same process")
@MainActor
func theToggleChangesRoutingWithoutARelaunch() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", displayName: "Jira")],
        isEnabled: { fixture.settings.isIntegrationEnabled($0) })
    let ref = SourceRefSnapshot(refID: UUID(), kind: .jiraIssue, identifier: "PAY-421")

    #expect(registry.dispatch(ref) != .disabled)

    fixture.model.setIntegration("jira", enabled: false)

    // **The guarantee a registry filtered at construction would lose.** This is the
    // whole reason `isEnabled` is a closure read per dispatch.
    #expect(registry.dispatch(ref) == .disabled)
    #expect(fixture.settings.disabledIntegrationIDs == ["jira"])
}

@Test("the fourth acceptance criterion: disabling does not delete the credential")
@MainActor
func disablingKeepsTheCredential() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    fixture.model.setIntegration("jira", enabled: false)

    #expect(try fixture.store.credential()?.apiToken == "token-value")
    #expect(fixture.model.hasStoredCredential)
}

@Test("a row is listed even when it is switched off")
@MainActor
func aDisabledRowIsStillListed() throws {
    let fixture = try IntegrationsFixture(
        connectors: [
            StubSourceConnector(id: "jira", displayName: "Jira"),
            StubSourceConnector(id: "confluence", displayName: "Confluence"),
        ])

    fixture.model.setIntegration("confluence", enabled: false)

    // A row that vanished when switched off would offer no way to switch it back on.
    #expect(fixture.model.rows.map(\.id) == ["jira", "confluence"])
    #expect(fixture.model.rows.first { $0.id == "confluence" }?.isEnabled == false)
    #expect(fixture.model.rows.first { $0.id == "jira" }?.isEnabled == true)
}

@Test("toggling an integration drops its stale verdict")
@MainActor
func togglingDropsTheVerdict() async throws {
    let fixture = try IntegrationsFixture()

    await fixture.model.testConnection(id: "jira")
    #expect(fixture.model.rows.first?.test == .passed)

    fixture.model.setIntegration("jira", enabled: false)

    // A verdict obtained under a configuration that is no longer in force is worse
    // than no verdict.
    #expect(fixture.model.rows.first?.test == .untested)
}

@Test("saving a credential drops every verdict obtained with the previous one")
@MainActor
func savingDropsEveryVerdict() async throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    await fixture.model.testConnection(id: "jira")
    #expect(fixture.model.rows.first?.test == .passed)

    fixture.model.tokenEntry = "replacement-token"
    fixture.model.saveCredential()

    // A green tick beside Jira after the token was replaced is a claim about a
    // credential that no longer exists.
    #expect(fixture.model.rows.first?.test == .untested)
}

// MARK: - FR-6's connection test

@Test("a connection test reports the connector's own error, not a generic failure")
@MainActor
func aTestReportsTheConnectorsError() async throws {
    let connector = StubSourceConnector(
        id: "jira", displayName: "Jira", connectionFailure: SourceError.credentialExpired)
    let fixture = try IntegrationsFixture(connectors: [connector])

    await fixture.model.testConnection(id: "jira")

    // §5.2: a 401 is never a generic network error. The four verdicts the third
    // acceptance criterion requires are these cases, unflattened.
    #expect(fixture.model.rows.first?.test == .failed(.credentialExpired))
}

@Test("an unconfigured connector is refused before any request is made")
@MainActor
func anUnconfiguredConnectorIsNotTested() async throws {
    let connector = StubSourceConnector(id: "jira", displayName: "Jira", isConfigured: false)
    let fixture = try IntegrationsFixture(connectors: [connector])

    await fixture.model.testConnection(id: "jira")

    // The token must not be sent to a host D19 does not allow, and `isConfigured`
    // is that check. Mutation: drop the guard — red, because the stub would then
    // record a call.
    #expect(fixture.model.rows.first?.test == .failed(.notConfigured))
    #expect(connector.testConnectionCalls == 0)
}

@Test("a connector that breaks its contract is presented as a network failure, not a crash")
@MainActor
func aNonSourceErrorDegrades() async throws {
    struct Surprise: Error {}
    let connector = StubSourceConnector(
        id: "jira", displayName: "Jira", connectionFailure: Surprise())
    let fixture = try IntegrationsFixture(connectors: [connector])

    await fixture.model.testConnection(id: "jira")

    // §5.5 must degrade on any failure, and `.network` is the reading it degrades
    // most usefully from.
    #expect(fixture.model.rows.first?.test == .failed(.network))
}

@Test("testing an id nothing registered does nothing at all")
@MainActor
func testingAnUnknownIDIsANoOp() async throws {
    let fixture = try IntegrationsFixture()

    await fixture.model.testConnection(id: "mcp-github")

    #expect(fixture.model.rows.first?.test == .untested)
    #expect(fixture.model.isBusy == false)
}

// MARK: - §5.2's 14-day warning

@Test("D-194: the expiry warning appears at 14 days and not at 15")
@MainActor
func theWarningBoundaryIsFourteenDays() throws {
    let atFourteen = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(14 * IntegrationsFixture.day)))
    let atFifteen = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(15 * IntegrationsFixture.day)))

    // The fifth acceptance criterion, in both directions. A warning that fires
    // early is one the user learns to ignore (FR-5's reasoning).
    #expect(atFourteen.model.expiryWarning?.daysRemaining == 14)
    #expect(atFifteen.model.expiryWarning == nil)
}

@Test("§5.2: a credential with no recorded expiry cannot be warned about")
@MainActor
func noExpiryMeansNoWarning() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential(expiresAt: nil))

    // D-192: the date is hand-entered, which is why the 401 path never depends on
    // it. Here it means silence rather than a guess.
    #expect(fixture.model.expiryWarning == nil)
    #expect(fixture.model.recordsExpiry == false)
}

@Test("the warning describes the stored expiry, not the one being typed")
@MainActor
func theWarningIgnoresTheEditedDate() throws {
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(90 * IntegrationsFixture.day)))

    // Half-typing a date into the picker is not a fact about the token in the
    // Keychain, and warning on it would fire on every keystroke.
    fixture.model.expiresAt = IntegrationsFixture.now.addingTimeInterval(IntegrationsFixture.day)
    fixture.model.recordsExpiry = true

    #expect(fixture.model.expiryWarning == nil)
}

@Test("an expiry the user switched off is stored as absent")
@MainActor
func clearingTheExpiryStoresNil() throws {
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(IntegrationsFixture.day)))

    fixture.model.recordsExpiry = false
    fixture.model.saveCredential()

    #expect(try fixture.store.credential()?.expiresAt == nil)
    #expect(fixture.model.expiryWarning == nil)
}

// MARK: - The purge, and the store that may not open

@Test("§13: with no store the purge is unavailable and the credential half still works")
@MainActor
func aFailedStoreDisablesOnlyThePurge() throws {
    let fixture = try IntegrationsFixture()

    #expect(fixture.model.canPurge == false)
    #expect(fixture.model.storeFailureNote?.contains("no cached data to purge") == true)

    // A credential lives in the Keychain, so none of this depends on the store.
    fixture.model.site = "acme.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.tokenEntry = "token-value"
    fixture.model.saveCredential()

    #expect(try fixture.store.credential()?.site == "acme.atlassian.net")
    #expect(fixture.model.credentialProblem == nil)
}

@Test("purging with no store does nothing rather than reporting a success")
@MainActor
func purgingWithNoStoreIsANoOp() throws {
    let fixture = try IntegrationsFixture()

    fixture.model.purgeCache()

    #expect(fixture.model.purgeState == .idle)
}

// MARK: - What a verdict is about, and which site it names

@Test("a pasted site URL is named back as a host, not as the whole URL")
@MainActor
func aPastedURLIsNamedAsAHost() throws {
    let fixture = try IntegrationsFixture()

    // A URL is what people actually have in their clipboard, and `cloudHost`
    // deliberately accepts one — so the pane must not echo it verbatim. This is the
    // defect PR #44 fixed in `ConfluenceSelftest`, which interpolated `site` where
    // `baseURL` was meant. Mutation: return `site` from `siteHost`. Red.
    fixture.model.site = "https://acme.atlassian.net/jira/software/projects/PAY/boards/1"

    #expect(fixture.model.siteHost == "acme.atlassian.net")
}

@Test("a site that is not usable is still shown back to the user who typed it")
@MainActor
func anUnusableSiteIsStillEchoed() throws {
    let fixture = try IntegrationsFixture()
    fixture.model.site = "example.com"

    // Falling back to the raw value matters: a sentence about a site the user can't
    // see is a sentence they can't act on.
    #expect(fixture.model.siteHost == "example.com")
}

@Test("the pane can tell that a verdict would be about the saved credential, not the typed one")
@MainActor
func unsavedChangesAreDetected() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    #expect(fixture.model.hasUnsavedChanges == false)

    // The sequence that misleads: correct the site, press Test, read a verdict about
    // the credential you were trying to replace.
    fixture.model.site = "corrected.atlassian.net"
    #expect(fixture.model.hasUnsavedChanges)

    fixture.model.saveCredential()
    #expect(fixture.model.hasUnsavedChanges == false)
}

@Test("a half-typed token counts as an unsaved change")
@MainActor
func aTypedTokenCountsAsUnsaved() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    fixture.model.tokenEntry = "new-token"

    #expect(fixture.model.hasUnsavedChanges)
}

@Test("toggling the expiry switch without touching the picker is not a change")
@MainActor
func togglingTheExpirySwitchIsNotAChange() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential(expiresAt: nil))

    // The stored credential records no expiry, and `recordsExpiry` is therefore
    // false. Turning it on *is* a change; turning it back off is not.
    #expect(fixture.model.hasUnsavedChanges == false)
    fixture.model.recordsExpiry = true
    #expect(fixture.model.hasUnsavedChanges)
    fixture.model.recordsExpiry = false
    #expect(fixture.model.hasUnsavedChanges == false)
}

@Test("with nothing stored, a typed site is an unsaved change")
@MainActor
func typingIntoAnEmptyPaneIsUnsaved() throws {
    let fixture = try IntegrationsFixture()

    #expect(fixture.model.hasUnsavedChanges == false)
    fixture.model.site = "acme.atlassian.net"
    #expect(fixture.model.hasUnsavedChanges)
}
