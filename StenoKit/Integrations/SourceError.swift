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
    /// M4-02 adds a `credentialExpired` sibling for §5.2's 401 handling: an
    /// Atlassian token that expired needs "create a new one" with a link, not
    /// "check your password". Adding it is a compile error at every exhaustive
    /// switch, which is the intent.
    case invalidCredential

    /// The resource does not exist, or this credential cannot see it.
    ///
    /// **Its own case because it is permanent.** A mistyped ticket key in a task
    /// title will never resolve, and reporting it as `.network` sends the user
    /// to check their wifi over a typo. Nothing suppresses the retry — that
    /// would need a persisted per-ref failure record, and therefore export,
    /// import and merge rules for it, to save one request per pass on a ref the
    /// user will notice and fix.
    case notFound

    /// Offline, DNS failure, TLS failure — the request never arrived.
    case network

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
        case .notFound:
            return "That reference doesn't exist, or this account can't see it."
        case .network:
            return "Couldn't reach the integration. Check your connection."
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
        case .notFound: return "notFound"
        case .network: return "network"
        case .timedOut: return "timedOut"
        case .rateLimited: return "rateLimited"
        case .unavailable: return "unavailable"
        case .invalidResponse: return "invalidResponse"
        }
    }
}
