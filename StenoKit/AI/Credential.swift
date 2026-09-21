import Foundation

/// §7.2's credential, as an enum so a subscription flow can be added later
/// without a refactor.
///
/// **`.oauth` is deliberately unreachable from the UI and deliberately not
/// dead.** §7.2 is explicit that there is no publicly documented OAuth flow
/// permitting a third-party app to consume a Claude.ai consumer subscription,
/// and that unofficial auth flows are out of bounds. The risk in an enum case
/// nothing constructs is that it rots — so the credential *store* serializes the
/// enum rather than a bare string, which means `.oauth` round-trips under test
/// alongside `.apiKey` and is exercised code rather than a declaration.
public enum Credential: Sendable, Equatable {
    case apiKey(String)
    case oauth(TokenSet)
}

/// The shape a future OAuth flow would store. Nothing constructs this today.
public struct TokenSet: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Which kinds of credential exist, and which Settings may offer.
///
/// **`userSelectable` is what makes §7.2's "surface API key as the only enabled
/// option" testable now**, a milestone before M3-04's picker exists. The
/// alternative is a doc comment that a future UI author has to find and honour,
/// with nothing failing if they render `allCases` instead.
public enum CredentialKind: String, Sendable, CaseIterable {
    case apiKey
    case oauth

    public static let userSelectable: [CredentialKind] = [.apiKey]
}

extension Credential {
    public var kind: CredentialKind {
        switch self {
        case .apiKey: return .apiKey
        case .oauth: return .oauth
        }
    }
}

extension Credential: Codable {
    /// Hand-written rather than synthesized.
    ///
    /// This is a **persisted** format — it is the bytes in the Keychain item —
    /// so it is spelled out. Swift's synthesized enum encoding is an
    /// implementation detail of the compiler (`{"apiKey":{"_0":"…"}}`), and a
    /// stored credential that stops decoding because a toolchain changed its
    /// mind is a user who silently loses their API key.
    private enum CodingKeys: String, CodingKey {
        case kind
        case apiKey
        case oauth
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(CredentialKind.self, forKey: .kind) {
        case .apiKey:
            self = .apiKey(try container.decode(String.self, forKey: .apiKey))
        case .oauth:
            self = .oauth(try container.decode(TokenSet.self, forKey: .oauth))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .apiKey(let key):
            try container.encode(key, forKey: .apiKey)
        case .oauth(let tokens):
            try container.encode(tokens, forKey: .oauth)
        }
    }
}

extension CredentialKind: Codable {}
