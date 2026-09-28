import Foundation
import Testing

@testable import StenoKit

/// D-190: the credential, and the site validation that keeps a work token from
/// travelling to the wrong host.

@Test(
    "an Atlassian Cloud host is accepted, however it was typed",
    arguments: [
        "acme.atlassian.net",
        "ACME.Atlassian.NET",
        "  acme.atlassian.net  ",
        "https://acme.atlassian.net",
        "https://acme.atlassian.net/",
        "https://acme.atlassian.net/jira/software/projects/PAY/boards/1",
    ])
func aCloudHostIsAccepted(site: String) {
    // All six are what a user actually pastes, and the last one is what the browser
    // gives them when they copy the URL of the board they are looking at.
    #expect(AtlassianCredential.cloudHost(in: site) == "acme.atlassian.net")
}

@Test(
    "anything that is not an Atlassian Cloud host is refused",
    arguments: [
        "",
        "   ",
        "atlassian.net",
        "acme.atlassian.net.evil.com",
        "evil.com/acme.atlassian.net",
        "https://evil.com/acme.atlassian.net",
        "acme.example.com",
        "acme.atlassian.net@evil.com",
        "acme.atlassian.net/path",
        "https://evil.com?x=acme.atlassian.net",
    ])
func aNonCloudHostIsRefused(site: String) {
    // **The interesting rejections are the ones that look right.**
    // `evil.com/acme.atlassian.net` parses to the host `evil.com`;
    // `acme.atlassian.net.evil.com` does not end where it claims to; and the `@` form
    // is credentials smuggled into what should be a bare host. This credential travels
    // as HTTP Basic, so a wrong answer here sends the user's work token to whoever
    // owns that name.
    #expect(AtlassianCredential.cloudHost(in: site) == nil)
}

@Test("the scheme is always https, never the stored value's")
func theSchemeIsAlwaysHTTPS() {
    // A stored `http://` must not be able to downgrade the connection that carries the
    // token. The scheme is ours; only the host comes from the credential.
    let credential = AtlassianCredential(
        site: "http://acme.atlassian.net", email: "leo@example.com", apiToken: "t")
    #expect(credential.baseURL?.absoluteString == "https://acme.atlassian.net")
}

@Test("a refused site has no base URL, so the connector reads as unconfigured")
func aRefusedSiteHasNoBaseURL() {
    let credential = AtlassianCredential(
        site: "evil.com", email: "leo@example.com", apiToken: "t")
    #expect(credential.baseURL == nil)
}

@Test("§5.2: the credential travels as email and token over HTTP Basic")
func theCredentialIsBasicAuth() throws {
    let credential = AtlassianCredential(
        site: "acme.atlassian.net", email: "leo@example.com", apiToken: "token-value")

    let header = credential.basicAuthorization
    #expect(header.hasPrefix("Basic "))

    let encoded = String(header.dropFirst("Basic ".count))
    let decoded = try #require(Data(base64Encoded: encoded))
    #expect(String(bytes: decoded, encoding: .utf8) == "leo@example.com:token-value")
}

@Test("the credential round-trips through its stored form")
func theCredentialRoundTrips() throws {
    // This is the shape of the bytes in the Keychain item, so a change that stops it
    // decoding is a user who silently loses their token.
    let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    let credential = AtlassianCredential(
        site: "acme.atlassian.net", email: "leo@example.com", apiToken: "token-value",
        expiresAt: expiry)

    let data = try JSONEncoder().encode(credential)
    #expect(try JSONDecoder().decode(AtlassianCredential.self, from: data) == credential)
}

@Test("an absent expiry date is a valid credential")
func anAbsentExpiryIsValid() throws {
    // §5.2 asks the user to enter it, and a user who has not must still be able to
    // fetch — which is also why the 401 path never depends on this value (D-192).
    let credential = AtlassianCredential(
        site: "acme.atlassian.net", email: "leo@example.com", apiToken: "t")
    #expect(credential.expiresAt == nil)
    #expect(credential.baseURL != nil)
}

@Test("D-190: the Atlassian item is not stored under the AI layer's service name")
func theServiceNamesAreSeparate() {
    // One namespace must not mean two things: an Atlassian token is not an AI
    // credential, and `KeychainQuery` takes the service as a parameter precisely so
    // these two cannot collide.
    #expect(AtlassianKeychainStore.service != KeychainCredentialStore.service)
    #expect(AtlassianKeychainStore.account == "atlassian")
}

/// An `AtlassianCredentialStore` that never touches the Keychain (D-134).
///
/// The real store's round trip belongs to `make atlassian-login` against the signed
/// binary; every test that needs *a* store rather than *the* store uses this.
final class InMemoryAtlassianStore: AtlassianCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AtlassianCredential?
    private let readError: (any Error)?
    private let writeError: (any Error)?
    private var reads = 0

    /// How many times the credential was read, for the routing contract: `isConfigured` is
    /// asked once per ref, and the connector must not answer it with a Keychain read each
    /// time (Copilot, PR #43).
    var readCount: Int { lock.withLock { reads } }

    /// - Parameters:
    ///   - readError: injected so the connector's "a Keychain failure reads as absent" path
    ///     can be exercised — the one that keeps a refresh from crashing where §5.5 says it
    ///     must never block a report.
    ///   - writeError: injected so `atlassian-login` can be shown reporting a refused write
    ///     rather than printing "stored" over it.
    init(
        _ credential: AtlassianCredential? = nil, readError: (any Error)? = nil,
        writeError: (any Error)? = nil
    ) {
        self.stored = credential
        self.readError = readError
        self.writeError = writeError
    }

    func store(_ credential: AtlassianCredential) throws {
        if let writeError { throw writeError }
        lock.withLock { stored = credential }
    }

    func credential() throws -> AtlassianCredential? {
        if let readError { throw readError }
        return lock.withLock {
            reads += 1
            return stored
        }
    }

    func delete() throws {
        lock.withLock { stored = nil }
    }
}
