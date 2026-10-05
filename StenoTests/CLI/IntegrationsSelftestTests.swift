import Foundation
import Testing

@testable import StenoKit

/// D-220's harness. **The sequence is what these tests check**; whether a real
/// resolver answers `cannotFindHost` is what `make verify-integrations` checks,
/// and nothing here can stand in for it (§9.4 denies the network).

/// Collects the harness's output so the wording can be asserted — and so §8's
/// "never prints the token" is a property of the text rather than of a reading.
private final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var text: String { lock.withLock { lines.joined(separator: "\n") } }

    func record(_ line: String) { lock.withLock { lines.append(line) } }
}

@Test("with no credential stored it says what to run, and fails")
func noCredentialIsAnInstruction() async {
    let transcript = Transcript()

    let code = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(nil),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    #expect(code == 1)
    #expect(transcript.text.contains("make atlassian-login"))
    #expect(transcript.text.contains("Settings → Integrations"))
}

@Test("a Keychain that refuses is reported as a refusal, not as a missing credential")
func aRefusedKeychainIsItsOwnFailure() async {
    struct Refused: Error {}
    let transcript = Transcript()

    let code = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(JiraFixture.credential(), readError: Refused()),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    #expect(code == 1)
    #expect(transcript.text.contains("the Keychain refused"))
    #expect(transcript.text.contains("make atlassian-login") == false)
}

@Test("D19: a stored site that is not Atlassian Cloud fails before anything is asked")
func aNonCloudSiteFailsEarly() async {
    let transcript = Transcript()
    let credential = AtlassianCredential(
        site: "example.com", email: "leo@example.com", apiToken: "token-value")

    let code = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(credential),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    #expect(code == 1)
    #expect(transcript.text.contains("not an *.atlassian.net host"))
}

@Test("§8: the token never appears in the output, on any path")
func theTokenIsNeverPrinted() async {
    let transcript = Transcript()

    // A credential that works for the report, with a token distinctive enough that
    // any accidental interpolation of it is visible.
    let credential = AtlassianCredential(
        site: JiraFixture.site, email: "leo@example.com",
        apiToken: "SUPER-SECRET-TOKEN-VALUE",
        expiresAt: Date().addingTimeInterval(9 * 24 * 60 * 60))

    _ = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(credential),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    // Mutation: print `credential.apiToken` anywhere in `report`. Red.
    #expect(transcript.text.contains("SUPER-SECRET-TOKEN-VALUE") == false)
    // And it does report the things §5.2 treats as configuration rather than
    // secrets, so the harness is still useful.
    #expect(transcript.text.contains("leo@example.com"))
    #expect(transcript.text.contains(JiraFixture.site))
}

@Test("§5.2: the expiry line states the arithmetic, and whether the warning is due")
func theExpiryLineStatesTheArithmetic() async {
    let transcript = Transcript()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let credential = AtlassianCredential(
        site: JiraFixture.site, email: "leo@example.com", apiToken: "token-value",
        expiresAt: now.addingTimeInterval(9 * 24 * 60 * 60))

    _ = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(credential),
        transport: StubJiraTransport(routes: [:]),
        now: { now },
        out: transcript.record)

    #expect(transcript.text.contains("9 day(s) remaining, warning due"))
}

@Test("§5.2: a credential with no expiry says so rather than inventing one")
func noExpiryIsStated() async {
    let transcript = Transcript()

    _ = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(JiraFixture.credential(expiresAt: nil)),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    #expect(transcript.text.contains("none recorded"))
}

@Test("D-190: the foreign-host probe is refused locally, with no request made")
func theForeignHostProbeIsRefusedLocally() async {
    let transcript = Transcript()

    _ = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(JiraFixture.credential()),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    // This credential travels as HTTP Basic, so a host that is not the user's site
    // must be refused before a request carries the token anywhere.
    #expect(transcript.text.contains("refused locally, no request sent"))
}

@Test("the unresolvable probe site is shaped correctly, or it would prove nothing")
func theProbeSiteReachesTheResolver() {
    // **The point of the probe.** A site refused by `cloudHost` never reaches DNS,
    // so it could not establish which URLError the resolver returns — which is the
    // one fact D-217 rests on and the suite cannot check.
    #expect(AtlassianCredential.cloudHost(in: IntegrationsSelftest.unresolvableSite) != nil)
    #expect(AtlassianCredential.cloudHost(in: IntegrationsSelftest.foreignSite) == nil)
}

@Test("§8: a credential-store error that quotes the credential is not printed")
func aQuotingStoreErrorIsNarrowed() async {
    // **Copilot, PR #45.** The harness interpolated `String(describing: error)`, and
    // an arbitrary error describes itself by quoting the value it choked on — which
    // on this path is the credential. A `DecodingError` is exactly that shape, and
    // the real `AtlassianKeychainStore` throws one when the stored JSON will not
    // decode.
    struct Quoting: Error, CustomStringConvertible {
        var description: String { "could not decode {\"apiToken\":\"SUPER-SECRET\"}" }
    }
    let transcript = Transcript()

    let code = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(JiraFixture.credential(), readError: Quoting()),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    #expect(code == 1)
    // Mutation: restore `String(describing: error)`. Red.
    #expect(transcript.text.contains("SUPER-SECRET") == false)
    // The type name still reaches the operator, so the failure is diagnosable.
    #expect(transcript.text.contains("Quoting"))
}
