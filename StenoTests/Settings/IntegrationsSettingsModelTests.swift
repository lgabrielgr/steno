import Foundation
import Testing

@testable import StenoKit

// FR-6's Integrations pane: §8's rules about the credential behind it.

// MARK: - D-218: the credential is rewritten from the Keychain, never from view state

@Test("§8: the stored token reaches no property of the model")
@MainActor
func theStoredTokenReachesNoProperty() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    // The site, the email and the expiry are prefilled — none is a secret, and a
    // user who cannot see the configured site cannot fix a typo in it.
    #expect(fixture.model.site == JiraFixture.site)
    #expect(fixture.model.email == "leo@example.com")
    #expect(fixture.model.tokenEntry.isEmpty)

    // **A `Mirror`, not a list of properties I remembered to check.** `encodeIfPresent`
    // taught this codebase that an allowlist written by hand misses the field added
    // next; this walks every stored property the type actually has. Mutation: assign
    // `stored.apiToken` to any property in `load()`. Red.
    let holders = Mirror(reflecting: fixture.model).children.compactMap { child -> String? in
        guard let value = child.value as? String else { return nil }
        return value.contains("token-value") ? (child.label ?? "<unlabelled>") : nil
    }
    #expect(holders.isEmpty, "these properties hold the token: \(holders)")
}

@Test("D-218: saving with an empty token field keeps the stored token")
@MainActor
func savingWithoutATokenKeepsTheStoredOne() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    // The partial edit this decision exists for: all four values live in one
    // Keychain item, so changing only the site rewrites the item — which needs a
    // token the field does not have.
    fixture.model.site = "newsite.atlassian.net"
    fixture.model.saveCredential()

    let stored = try #require(try fixture.store.credential())
    #expect(stored.site == "newsite.atlassian.net")
    // Mutation: store `tokenEntry` unconditionally. Red — the token becomes "".
    #expect(stored.apiToken == "token-value")
    #expect(stored.email == "leo@example.com")
    #expect(fixture.model.credentialProblem == nil)
}

@Test("D-218: a typed token replaces the stored one and is then forgotten")
@MainActor
func aTypedTokenReplacesTheStoredOne() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    fixture.model.tokenEntry = "  replacement-token\n"
    fixture.model.saveCredential()

    // Trimmed, because the common way to produce a token is a paste from a web page.
    #expect(try fixture.store.credential()?.apiToken == "replacement-token")
    #expect(fixture.model.tokenEntry.isEmpty)
}

@Test("D-218: saving with no token anywhere is refused rather than storing an empty one")
@MainActor
func savingWithNoTokenAtAllIsRefused() throws {
    let fixture = try IntegrationsFixture()

    fixture.model.site = "acme.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.saveCredential()

    #expect(try fixture.store.credential() == nil)
    #expect(fixture.model.credentialProblem?.contains("Paste your API token") == true)
}

@Test("D-218: a refused Keychain read does not overwrite the credential with an empty token")
@MainActor
func aRefusedReadDoesNotOverwriteTheToken() throws {
    struct Refused: Error {}
    // Present, and unreadable: the state a locked keychain produces.
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), readError: Refused())

    // Both fields by hand: the read that would have prefilled them is the one
    // being refused, so the earlier guards would otherwise reject on an empty
    // email and never reach the token branch under test.
    fixture.model.site = "newsite.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.tokenEntry = ""
    fixture.model.saveCredential()

    // **The dangerous path.** Treating a failed read as "no token" would write an
    // empty token over a working one. Mutation: `try? credentials.credential()`
    // with a `?? ""` fallback. Red.
    //
    // The evidence is the *absence of a write*, because the store this needs is one
    // whose reads fail — so reading it back to check is not available.
    #expect(fixture.model.credentialProblem?.contains("didn't change it") == true)
    #expect(fixture.store.writeCount == 0)
}

@Test("D-190: a site that is not an Atlassian Cloud host is refused before anything is stored")
@MainActor
func aNonCloudSiteIsRefusedLocally() throws {
    let fixture = try IntegrationsFixture()

    fixture.model.site = "evil.com/acme.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.tokenEntry = "token-value"
    fixture.model.saveCredential()

    // This credential travels as HTTP Basic, so a mistyped host would send the
    // user's work token wherever it named. Nothing is stored, and the sentence says
    // why.
    #expect(try fixture.store.credential() == nil)
    #expect(fixture.model.credentialProblem?.contains("*.atlassian.net") == true)
}

@Test("a Keychain read that is refused is not reported as no credential")
@MainActor
func aRefusedReadIsItsOwnState() throws {
    struct Refused: Error {}
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), readError: Refused())

    // Telling a user with a locked keychain that nothing is stored sends them to
    // retype a token that is already there.
    guard case .unreadable = fixture.model.storedCredential else {
        Issue.record("a refused read must be its own state, not .absent")
        return
    }
    #expect(fixture.model.hasStoredCredential == false)
    #expect(fixture.model.credentialProblem?.contains("could not read") == true)
}

@Test("removing the credential clears the fields and leaves the toggles alone")
@MainActor
func removingTheCredentialKeepsTheToggles() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())
    fixture.settings.setIntegration("jira", enabled: false)

    fixture.model.removeCredential()

    #expect(try fixture.store.credential() == nil)
    #expect(fixture.model.storedCredential == .absent)
    #expect(fixture.model.site.isEmpty)
    #expect(fixture.model.tokenEntry.isEmpty)
    // A toggle is not a secret, and a user who rotates a token should not find
    // their integrations silently rearranged.
    #expect(fixture.settings.isIntegrationEnabled("jira") == false)
}

@Test("the token field is emptied on every appearance, of a model that outlives them")
@MainActor
func forgetEntryEmptiesTheField() throws {
    let fixture = try IntegrationsFixture()
    fixture.model.tokenEntry = "half-typed"

    fixture.model.forgetEntry()

    #expect(fixture.model.tokenEntry.isEmpty)
}
