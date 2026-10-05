import Foundation

/// The only error a `SourceConnector` may throw (§5.5, §5.2).
///
/// **No case carries a free-form `String`, and that is a security property
/// rather than a style preference** (D-165, inherited from D-132). The obvious
/// shape for `invalidResponse` is `(reason: String)`, and the obvious reason
/// string is built from the API's own response — which on this layer means
/// ticket titles, comment bodies and assignee names inside a value the logging
/// path prints, against §8. Typed cases make "a `SourceError` is always safe to
/// log" true of the type rather than of every future connector's discipline.
///
/// `.network` and `.timedOut` are separate because §5.5's degradation tells the
/// user different things, and because a retry policy applies to one and not the
/// other. `.invalidCredential` is separate from both because FR-6's connection
/// test has to distinguish a rejected credential from an unreachable host.
public enum SourceError: Error, Equatable, Sendable {
    /// No credential is stored for this connector.
    case notConfigured

    /// The service rejected the credential. Not retryable.
    ///
    /// Its sibling below handles §5.2's 401.
    case invalidCredential

    /// The service rejected the credential because it expired or was revoked
    /// (§5.2, D-192).
    ///
    /// **Its own case because the sentence has to be different.** Atlassian Cloud
    /// tokens created since December 2024 expire — one year maximum, set at
    /// creation — so this is a scheduled, guaranteed failure rather than an edge
    /// case, and §5.2 forbids reporting it as a generic network error: "a silent
    /// 401 during stand-up prep is the worst possible time to debug auth", which
    /// is exactly when it happens, because that is when the app fetches.
    ///
    /// **Mapped from a 401 without consulting the stored expiry date** (D-192).
    /// Gating on "is `expiresAt` in the past" sounds more precise and is worse:
    /// the date is typed in by hand, so it is precisely what is wrong or missing
    /// when a token silently expires.
    case credentialExpired

    /// The resource does not exist, or this credential cannot see it.
    ///
    /// **Its own case because it is permanent.** A mistyped ticket key in a task
    /// title will never resolve, and reporting it as `.network` sends the user
    /// to check their wifi over a typo. Nothing suppresses the retry — that
    /// would need a persisted per-ref failure record, and therefore export,
    /// import and merge rules for it, to save one request per pass on a ref the
    /// user will notice and fix.
    case notFound

    /// Offline, TLS failure — the request never arrived for a reason the user's
    /// settings cannot fix.
    ///
    /// **No longer "DNS failure"**: a name that does not resolve is
    /// `.siteNotFound` below (D-217), because the remedy is a setting rather than
    /// a connection.
    case network

    /// The configured host does not resolve (D-217).
    ///
    /// **Its own case because the remedy is a setting, not the network.** §5.2
    /// forbids reporting a 401 as a generic network error, and the same reasoning
    /// reaches every failure the user can actually fix: a site typed as
    /// `acmee.atlassian.net` is shaped correctly, passes `baseURL`'s validation,
    /// fails DNS, and was reported as "check your connection" — sending the user to
    /// their router over a typo, during stand-up prep.
    ///
    /// **Carries no host**, for this type's reason: the pane interpolates the site
    /// it already holds in view state, and a case with a free-form `String` would
    /// give up the property that makes a `SourceError` always safe to log.
    case siteNotFound

    /// The fetch exceeded `SourceRefreshService`'s per-fetch budget.
    case timedOut

    /// Rate limited. `retryAfter` is `nil` when the service named no interval.
    case rateLimited(retryAfter: Duration?)

    /// The service answered with a server-side failure.
    case unavailable(status: Int)

    /// The response arrived and could not be read as the resource it claimed to
    /// be. Carries nothing, for this type's reason.
    case invalidResponse
}

extension SourceError: LocalizedError {
    /// User-facing, and read by the stand-up sheet's staleness banner.
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This integration isn't set up yet."
        case .invalidCredential:
            return "The integration rejected the saved credential."
        case .credentialExpired:
            // §5.2 requires "your Atlassian token expired — create a new one".
            // **"or was revoked" is three deliberate words** (D-193): a 401 is
            // also what a revoked or mistyped token returns, and the unhedged
            // sentence would state something false in those cases. Expiry still
            // leads, and `SourceNotice` attaches the link §5.2 asks for.
            return "Your token expired or was revoked. Create a new one."
        case .notFound:
            return "That reference doesn't exist, or this account can't see it."
        case .network:
            return "Couldn't reach the integration. Check your connection."
        case .siteNotFound:
            // No host named: the type carries none. The Settings pane says which
            // site it could not find, because that is the surface that holds it.
            return "Couldn't find that site. Check the site address in Settings."
        case .timedOut:
            return "The integration didn't answer in time."
        case .rateLimited:
            return "The integration is rate limiting this account. Try again shortly."
        case .unavailable:
            return "The integration is unavailable right now."
        case .invalidResponse:
            return "The integration's answer couldn't be read."
        }
    }
}

extension SourceError {
    /// The fixed vocabulary the `sources` log category uses.
    ///
    /// Spelled out rather than derived from `String(describing:)`, whose output
    /// is a refactor away from changing — and which would print `retryAfter` and
    /// a status code into a field meant to be a label (D-137's rule).
    public var metricsLabel: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .invalidCredential: return "invalidCredential"
        case .credentialExpired: return "credentialExpired"
        case .notFound: return "notFound"
        case .network: return "network"
        case .siteNotFound: return "siteNotFound"
        case .timedOut: return "timedOut"
        case .rateLimited: return "rateLimited"
        case .unavailable: return "unavailable"
        case .invalidResponse: return "invalidResponse"
        }
    }
}
