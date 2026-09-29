import Foundation
import OSLog

/// §5.3's Confluence connector: read-only, Atlassian Cloud, REST v2.
///
/// **The second `SourceConnector`, on the first one's credential.** §5.3 asks for "one
/// config, two APIs", and that is literally what this is: the same
/// `AtlassianCredentialStore`, the same expiry warning, the same renewal link, the same
/// read-only transport — and its own client, because the two REST APIs share nothing
/// below that line (§5.3: "do not conflate them").
///
/// It holds no store and writes nothing: `SourceRefreshService` is the only writer
/// (D-172), so §3.3's append-only invariant is enforced once rather than once per
/// connector.
public struct ConfluenceConnector: SourceConnector {
    /// Stable across launches: it keys `RefreshOutcome.Failure` and M4-04's
    /// per-integration settings.
    public let id = "confluence"

    /// What Settings and the staleness banner show.
    public let displayName = "Confluence"

    private let credentials: any AtlassianCredentialStore
    private let client: ConfluenceClient
    private let now: @Sendable () -> Date

    /// Its own memo, not one shared with `JiraConnector` (D-198, D-202).
    ///
    /// Both connectors read the same Keychain item, so a shared memo would save one
    /// read per pass — and would need to be owned by something neither connector is, at
    /// the cost of an invalidation question with two answers. Thirty seconds and one
    /// read each is the proportionate trade; the memo drops itself on
    /// `.stenoCredentialsDidChange` either way.
    private let cache = AtlassianCredentialCache()

    /// - Parameters:
    ///   - transport: injected so `make test` can exercise every path with networking
    ///     denied (§9.4). The default is the real adapter, and the client wraps whatever
    ///     it is given in `ReadOnlyTransport`.
    ///   - now: injected so `fetchedAt` and the expiry warning are assertable without
    ///     waiting.
    public init(
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.client = ConfluenceClient(transport: transport)
        self.now = now
    }

    /// Whether there is a usable credential — `baseURL != nil` rather than "a credential
    /// exists" (D-190), for the reason `JiraConnector` states: a stored site that is not
    /// an Atlassian Cloud host cannot be used, and reporting the ref as not-configured
    /// sends the user to Settings, where the problem is.
    public var isConfigured: Bool {
        credential?.baseURL != nil
    }

    /// §5.2's 14-day warning, as a fact for `SourceNotice` to phrase (D-194).
    ///
    /// **The same date the Jira connector warns about**, because there is one credential
    /// (§5.3). Two connectors therefore produce two warnings from one expiry, and
    /// `SourceNotice` is the layer that decides how many sentences the user sees.
    public var credentialWarning: SourceCredentialWarning? {
        AtlassianTokenExpiry.warning(
            displayName: displayName, expiresAt: credential?.expiresAt, now: now())
    }

    /// §5.2's "with a direct link" (D-193). The same page: one token serves both APIs.
    public var credentialRenewalURL: URL? {
        AtlassianTokenExpiry.renewalURL
    }

    /// Confluence pages on **this** Atlassian Cloud site (D-204).
    ///
    /// **Three cases, and the middle one is the easy thing to leave out:**
    ///
    /// - A URL on the configured site is claimed.
    /// - A URL on *some* Atlassian Cloud site, with nothing configured yet, is claimed —
    ///   so the ref reports `.notConfigured` and the user is told to set Atlassian up.
    ///   Without this, an unconfigured machine would say "Atlassian is not set up" for a
    ///   Jira ref and stay silent about a Confluence one on the same task, which is the
    ///   opposite of the sentence §5.3's "one config, two APIs" is meant to produce.
    /// - Everything else is refused, and `false` means `.unhandled` rather than
    ///   `.notConfigured`: nothing here can serve those refs.
    ///
    /// **A ref with no URL is refused, and that is where this departs from D-199.**
    /// `JiraConnector` claims a bare ticket key because a key in a task title can only
    /// mean the configured site. A page id is a number no one types: `SourceURLClassifier`
    /// is the only thing that produces a `.confluencePage` ref and it always sets a URL,
    /// so a URL-less one arrived from a hand-edited import — and claiming it would mean
    /// fetching page 12 from the user's own wiki for a reference that came from
    /// somewhere else. The classifier also claims page ids **without a host check** and
    /// documents the consequence (`https://example.com/pages/12/34` is
    /// `.confluencePage "12"`), which is the other half of why a host is required here.
    public func canHandle(_ ref: SourceRefSnapshot) -> Bool {
        guard ref.kind == .confluencePage else { return false }
        guard let url = ref.url, let host = AtlassianCredential.cloudHost(in: url) else {
            return false
        }

        guard let configured = credential?.site,
            let configuredHost = AtlassianCredential.cloudHost(in: configured)
        else { return true }

        return host == configuredHost
    }

    public func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        guard let credential, let base = credential.baseURL else {
            throw SourceError.notConfigured
        }

        let changeSet = try await client.changeSet(
            pageID: ref.identifier, since: since, credential: credential)

        return SourceUpdate(
            summary: changeSet.summary,
            changes: changeSet.changes,
            url: pageURL(base: base, webui: changeSet.webui, ref: ref),
            // The connector's own clock, diagnostic only — `lastFetchedAt` is stamped by
            // the service from the app's (D-171).
            fetchedAt: now(),
            // **Empty, and not by omission.** `present` is D-187's set difference, which
            // exists for items that carry no timestamp of any kind — Jira's remote links.
            // Every Confluence version carries `createdAt`, so the window does the work
            // and there is no state stream here to difference.
            present: [],
            watermark: changeSet.watermark,
            isWindowCapped: changeSet.isWindowCapped)
    }

    public func testConnection() async throws {
        // **Deliberately uncached**, for `JiraConnector`'s reason: FR-6's test exists to
        // say whether what is stored *right now* works, and answering it from a memo
        // would make a freshly pasted token look broken for as long as the cache lives.
        guard let credential = credential(fresh: true) else { throw SourceError.notConfigured }
        try await client.verify(credential: credential)
    }

    /// The human-facing page, not the API endpoint: this URL ends up on an event payload
    /// and is what a later feature would open.
    ///
    /// `webui` is relative and rooted at the *Confluence site* — `/spaces/ENG/pages/…` —
    /// so `/wiki` goes between it and the Cloud host. A page whose links did not arrive
    /// falls back to the ref's own URL, which is where the ref came from in the first
    /// place (D-204 guarantees there is one).
    private func pageURL(base: URL, webui: String?, ref: SourceRefSnapshot) -> URL? {
        guard let webui, !webui.isEmpty else {
            return ref.url.flatMap(URL.init(string:))
        }
        let path = webui.hasPrefix("/") ? webui : "/\(webui)"
        // **The second fallback is a belt, and an honest comment says so.** A page
        // titled "Café Plan" arrives with characters a URL must encode, and this
        // Foundation's `URL(string:)` percent-encodes them rather than returning nil —
        // `a webui with characters a URL must encode still produces an openable link`
        // pins that. So this `??` covers only whatever it still refuses, and is kept
        // because losing the link entirely is worse than the line costs.
        return URL(string: "\(base.absoluteString)/wiki\(path)")
            ?? ref.url.flatMap(URL.init(string:))
    }

    /// The stored credential, or `nil`.
    ///
    /// **A Keychain failure reads as absent**, for `JiraConnector`'s reason:
    /// `isConfigured` and `credentialWarning` are synchronous and non-throwing by
    /// contract, and the honest reading of "the Keychain would not answer" is that the
    /// integration is not usable right now.
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
