import Foundation
import Security

/// The one Atlassian credential, shared by Jira and Confluence (§5.3: one config,
/// two APIs).
///
/// **One value, one Keychain item** (D-190). §5.2 asks for a site, an email, an
/// API token and a user-entered expiry date, and only the token is a secret — but
/// they are one fact, and a token in the Keychain with its expiry in
/// `AppSettings` is two writes that can half-fail, leaving an expiry date
/// describing a token that is no longer there. Storing them together also means
/// deleting the credential leaves nothing behind.
public struct AtlassianCredential: Sendable, Equatable, Codable {
    /// The site, as the user typed it. `acme.atlassian.net`, or a pasted
    /// `https://acme.atlassian.net/jira/software/...` — `baseURL` is what decides
    /// whether it is usable.
    public let site: String

    public let email: String

    /// The API token. **The only secret here**, and it never leaves this type
    /// except as an `Authorization` header value.
    public let apiToken: String

    /// §5.2's user-entered expiry date. Not a secret; stored here anyway, for the
    /// reason above.
    public let expiresAt: Date?

    public init(site: String, email: String, apiToken: String, expiresAt: Date? = nil) {
        self.site = site
        self.email = email
        self.apiToken = apiToken
        self.expiresAt = expiresAt
    }
}

extension AtlassianCredential {
    /// The API root, or `nil` when `site` is not an Atlassian Cloud host.
    ///
    /// **Validated, not trusted, and that is a security property** (D-190). This
    /// credential authenticates with HTTP Basic, so a mistyped or hostile site value
    /// would send `Authorization: Basic …` — the user's work token — to whatever
    /// host it named. D19 locks the app to Atlassian Cloud, so requiring
    /// `*.atlassian.net` costs nothing a supported deployment needs.
    ///
    /// **The scheme is ours, never the stored value's.** The URL is always built
    /// `https`, so a stored `http://` cannot downgrade the connection that carries
    /// the token.
    ///
    /// A credential whose site fails this reads as absent — `isConfigured` is
    /// false — so the ref is reported as not-configured rather than failing
    /// mid-pass, which is the wording that actually tells the user to go and fix
    /// Settings.
    public var baseURL: URL? {
        guard let host = Self.cloudHost(in: site) else { return nil }
        return URL(string: "https://\(host)")
    }

    /// The `Authorization` header value: §5.2's email-plus-token over HTTP Basic.
    ///
    /// Computed rather than stored so the encoded form has no second lifetime in
    /// memory beyond the request that uses it.
    public var basicAuthorization: String {
        let encoded = Data("\(email):\(apiToken)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Whether this credential's site is the one a ref's URL names (D-214).
    ///
    /// **Routing already asks this, and routing is not enough.** `canHandle` runs during
    /// `SourceRegistry.dispatch`; `fetch` runs later, re-reads the credential, and the
    /// credential can have changed in between — Settings replacing site A with site B
    /// posts `.stenoCredentialsDidChange`, which drops the memo, so the fetch genuinely
    /// uses the new one. A Confluence page id is numeric and exists on every site, so the
    /// fetch would then return a real, plausible, wrong page, and `SourceRefreshService`
    /// would append it to a log that cannot be edited. Raised by Copilot in review of
    /// PR #44.
    ///
    /// - Returns: `true` when the ref carries no URL — a bare Jira key means the
    ///   configured instance and nothing else (D-199) — and otherwise only when the URL's
    ///   Cloud host is this credential's. A URL that is not an Atlassian Cloud host is
    ///   refused, which matches what `canHandle` decided at routing time.
    func serves(refURL: String?) -> Bool {
        guard let refURL else { return true }
        guard let host = Self.cloudHost(in: refURL), let configured = Self.cloudHost(in: site)
        else { return false }
        return host == configured
    }

    /// The Atlassian Cloud host in `value`, or `nil`.
    ///
    /// Accepts a bare host or a full URL, because both are what a user pastes.
    /// Rejects everything else, and the interesting rejections are the ones that
    /// look right: `evil.com/acme.atlassian.net` parses to the host `evil.com`, and
    /// `acme.atlassian.net.evil.com` does not end where it claims to.
    static func cloudHost(in value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // A pasted URL goes through `URLComponents` so the host is whatever a
        // browser would resolve, not whatever a substring match hopes for.
        let host: String
        if trimmed.contains("://") {
            guard let parsed = URLComponents(string: trimmed)?.host else { return nil }
            host = parsed
        } else {
            // A bare value must be *only* a host: a path, a query or credentials
            // smuggled in with `@` mean this is not the shape it claims to be.
            guard !trimmed.contains("/"), !trimmed.contains("@"), !trimmed.contains("?") else {
                return nil
            }
            host = trimmed
        }

        let suffix = ".atlassian.net"
        guard host.hasSuffix(suffix), host.count > suffix.count else { return nil }
        return host
    }
}

/// Where the Atlassian credential lives.
///
/// **A protocol for `CredentialStore`'s reason** (D-134): `make test` must never
/// write into the developer's login keychain, so every test uses a double and the
/// real store's round trip is verified by `make atlassian-login` against the
/// signed binary (D-197).
///
/// Absence is `nil`, not an error: a user who has not set up Atlassian yet is the
/// ordinary state, and it is what becomes `isConfigured == false` one layer up.
public protocol AtlassianCredentialStore: Sendable {
    func store(_ credential: AtlassianCredential) throws
    func credential() throws -> AtlassianCredential?
    func delete() throws
}

/// §8's "Keychain only", for the Atlassian credential.
///
/// One item, because there is one credential (§5.3). Built on the same plumbing
/// as the AI provider's store, which is why that plumbing moved to `Support/`
/// (D-189) — and under its **own service name**, because an Atlassian token is not
/// an AI credential and one namespace must not mean two things.
public struct AtlassianKeychainStore: AtlassianCredentialStore {
    /// This store's Keychain service.
    static let service = "com.lgabrielgr.steno.integrations"

    /// The account. One credential serves both Atlassian APIs, so this is
    /// `atlassian` rather than `jira`: a second item for Confluence would be two
    /// places for §5.3's one config to drift apart.
    static let account = "atlassian"

    public init() {}

    /// Add, then update if an item is already there.
    ///
    /// **Not delete-then-add**, for `KeychainCredentialStore`'s reason: if the add
    /// half of that pair failed, the user would be left with no stored credential
    /// and integrations that silently stopped working, having asked only to change
    /// their token.
    public func store(_ credential: AtlassianCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemAdd(
            KeychainQuery.insert(data, service: Self.service, account: Self.account)
                as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            announceChange()
            return
        case errSecDuplicateItem:
            let updated = SecItemUpdate(
                KeychainQuery.lookup(service: Self.service, account: Self.account) as CFDictionary,
                KeychainQuery.update(data) as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError.from(updated) }
            announceChange()
        default:
            throw KeychainError.from(status)
        }
    }

    /// Tell every memo of this credential to forget it (D-198).
    ///
    /// **Posted here rather than by each caller**, for `.stenoDidWrite`'s reason: a writer that
    /// forgets to post is a staleness bug that looks like the Keychain being flaky, and the one
    /// place that cannot forget is the write itself.
    private func announceChange() {
        NotificationCenter.default.post(name: .stenoCredentialsDidChange, object: nil)
    }

    public func credential() throws -> AtlassianCredential? {
        var query = KeychainQuery.lookup(service: Self.service, account: Self.account)
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpected(status) }
            return try JSONDecoder().decode(AtlassianCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.from(status)
        }
    }

    /// Deleting what is not there is success, not failure — the caller asked for an
    /// end state, and that end state holds.
    public func delete() throws {
        let status = SecItemDelete(
            KeychainQuery.lookup(service: Self.service, account: Self.account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
        announceChange()
    }
}
