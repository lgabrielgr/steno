import Foundation
import OSLog

/// §5.2's Jira connector: read-only, Atlassian Cloud, REST v3.
///
/// **The first real `SourceConnector`.** M4-01 shipped the protocol, the registry,
/// the cache and a refresh that cannot block a report, with the production registry
/// deliberately empty (D-179); this is what fills it.
///
/// It holds no store and writes nothing: `SourceRefreshService` is the only writer
/// (D-172), so §3.3's append-only invariant is enforced once rather than once per
/// connector. And it never issues anything but a GET — `JiraEndpoint` builds the
/// requests, `ReadOnlyTransport` traps on anything else, and the tests walk both
/// (D5, D-191).
public struct JiraConnector: SourceConnector {
    /// Stable across launches: it keys `RefreshOutcome.Failure` and M4-04's
    /// per-integration settings.
    public let id = "jira"

    /// What Settings and the staleness banner show.
    public let displayName = "Jira"

    private let credentials: any AtlassianCredentialStore
    private let client: JiraClient
    private let now: @Sendable () -> Date

    /// Memoizes the credential for a moment, so **routing does not read the Keychain once
    /// per ref**.
    ///
    /// `SourceRegistry.dispatch` asks `isConfigured` for every ref it routes, and
    /// `SourceConnector` states that the property must be cheap — then this connector
    /// answered it with a `SecItemCopyMatching`, which is twenty synchronous Keychain
    /// reads on the main actor for a twenty-ref pass. Raised by Copilot in review of
    /// PR #43.
    private let cache = AtlassianCredentialCache()

    /// - Parameters:
    ///   - transport: injected so `make test` can exercise every path with
    ///     networking denied (§9.4). The default is the real adapter, and the client
    ///     wraps whatever it is given in `ReadOnlyTransport`.
    ///   - now: injected so `fetchedAt` and the expiry warning are assertable
    ///     without waiting.
    public init(
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.client = JiraClient(transport: transport)
        self.now = now
    }

    /// Whether there is a usable credential.
    ///
    /// **`baseURL != nil` rather than "a credential exists"** (D-190): a stored site
    /// that is not an Atlassian Cloud host cannot be used, and reporting the ref as
    /// not-configured sends the user to Settings, where the problem is, instead of
    /// failing mid-pass with a message about the network.
    public var isConfigured: Bool {
        credential?.baseURL != nil
    }

    /// §5.2's 14-day warning, as a fact for `SourceNotice` to phrase (D-194).
    ///
    /// **One Keychain read per pass, not per ref**, which is the contract
    /// `SourceConnector` states: the service collects warnings once before it
    /// dispatches anything.
    public var credentialWarning: SourceCredentialWarning? {
        AtlassianTokenExpiry.warning(
            displayName: displayName, expiresAt: credential?.expiresAt, now: now())
    }

    /// §5.2's "with a direct link" (D-193). Constant, so a 401 carries it even when
    /// no expiry date was ever entered.
    public var credentialRenewalURL: URL? {
        AtlassianTokenExpiry.renewalURL
    }

    /// Jira issues only. Confluence pages are M4-03's, on the same credential
    /// (§5.3) — "Jira and Confluence are distinct REST APIs; do not conflate them".
    public func canHandle(_ ref: SourceRefSnapshot) -> Bool {
        ref.kind == .jiraIssue
    }

    public func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        guard let credential, let base = credential.baseURL else {
            throw SourceError.notConfigured
        }

        let changeSet = try await client.changeSet(
            key: ref.identifier, since: since, credential: credential)

        return SourceUpdate(
            summary: changeSet.summary,
            changes: changeSet.changes,
            // The human-facing page, not the API endpoint: this URL ends up on an
            // event payload and is what a later feature would open.
            url: URL(string: "\(base.absoluteString)/browse/\(ref.identifier)"),
            // The connector's own clock, diagnostic only — `lastFetchedAt` is
            // stamped by the service from the app's (D-171).
            fetchedAt: now(),
            present: changeSet.present,
            watermark: changeSet.watermark)
    }

    public func testConnection() async throws {
        // **Deliberately uncached.** FR-6's test exists to say whether what is stored
        // *right now* works, and answering it from a memo would make a freshly pasted
        // token look broken for as long as the cache lives.
        guard let credential = credential(fresh: true) else { throw SourceError.notConfigured }
        try await client.verify(credential: credential)
    }

    /// The stored credential, or `nil`.
    ///
    /// **A Keychain failure reads as absent.** `isConfigured` and
    /// `credentialWarning` are synchronous and non-throwing by contract, and the
    /// honest reading of "the Keychain would not answer" is that the integration is
    /// not usable right now — which produces the not-configured wording rather than
    /// a crash in a refresh that §5.5 says must never block a report.
    private var credential: AtlassianCredential? {
        credential(fresh: false)
    }

    /// - Parameter fresh: bypasses the memo. Used by `testConnection()` only.
    private func credential(fresh: Bool) -> AtlassianCredential? {
        cache.credential(now: now(), fresh: fresh) {
            do {
                return try credentials.credential()
            } catch {
                Log.sources.error(
                    "could not read the Atlassian credential: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
    }
}

/// A short-lived memo over one Keychain read.
///
/// **Thirty seconds, chosen against two failure modes.** Shorter than a refresh pass's own
/// budget would put several Keychain reads back into one pass, which is what this exists to
/// prevent; much longer would make a credential the user has just saved look absent. M4-04
/// writes the credential and should call `invalidate()` when it does, which removes the
/// staleness question entirely — `testConnection()` already bypasses the memo, so the button
/// that matters is never answered from it.
///
/// A `final class` with a lock because `JiraConnector` is a `Sendable` struct and four
/// fetches run concurrently: an unsynchronized memo would be a data race in the one place
/// that reads a secret.
final class AtlassianCredentialCache: @unchecked Sendable {
    static let ttl: TimeInterval = 30

    private let lock = NSLock()
    private var stored: (credential: AtlassianCredential?, readAt: Date)?

    /// The memoized credential, reading through `read` when the memo is cold, stale, or
    /// bypassed.
    ///
    /// **A `nil` result is memoized too.** "No credential" is the ordinary state of a
    /// machine nobody has configured, and re-reading the Keychain per ref to learn it again
    /// is exactly the cost being avoided.
    func credential(
        now: Date, fresh: Bool, read: () -> AtlassianCredential?
    ) -> AtlassianCredential? {
        lock.withLock {
            if !fresh, let stored, now.timeIntervalSince(stored.readAt) < Self.ttl {
                return stored.credential
            }
            let value = read()
            stored = (value, now)
            return value
        }
    }

    /// Drop the memo. For M4-04, after it writes a credential.
    func invalidate() {
        lock.withLock { stored = nil }
    }
}
