import Foundation

/// The only error an `AIProvider` may throw (§7.1, §7.4).
///
/// **No case carries a free-form `String`, and that is a security property
/// rather than a style preference.** The obvious shape for `invalidResponse` is
/// `(reason: String)`, and the obvious reason string is built out of the model's
/// own output — which puts a stand-up's contents inside a value that §8's
/// logging path then prints. Typed reasons make "an `AIError` is always safe to
/// log" true of the type, instead of a rule every future provider has to
/// remember.
///
/// `.network` and `.timedOut` are separate because §7.4's fallback tells the
/// user different things, and because a retry policy applies to one and not the
/// other. `.invalidCredential` is separate from both because M3-02's acceptance
/// criterion requires `testConnection()` to distinguish a rejected key from an
/// unreachable network — the user needs to know which.
public enum AIError: Error, Equatable, Sendable {
    /// No credential is stored for this provider (§7.4's "is not configured").
    case notConfigured

    /// The provider rejected the credential. Not retryable.
    case invalidCredential

    /// The provider rejected the *request* — a 400 it would not parse, or a 404
    /// for a model id that was retired since the user picked it (D-143).
    ///
    /// **Separate from `.providerUnavailable`, which is where the obvious
    /// mapping would put a 404.** These failures are ours, not Anthropic's, and
    /// "the provider is unavailable right now" would send a user whose selected
    /// model no longer exists to a status page instead of the picker. Carries
    /// nothing: the API's `error.message` can quote the request that provoked
    /// it, which on the draft path is the user's event log (§8).
    case invalidRequest

    /// Offline, DNS failure, TLS failure — the request never reached the provider.
    case network

    /// The request exceeded `StandupRequest.timeout`.
    case timedOut

    /// Rate limited. `retryAfter` is `nil` when the provider named no interval.
    case rateLimited(retryAfter: Duration?)

    /// The provider answered with a server-side failure.
    case providerUnavailable(status: Int)

    /// The response arrived and could not be turned into a `StandupDraft`.
    case invalidResponse(InvalidResponseReason)

    /// §7.3: the model referenced task ids the app never sent.
    ///
    /// **A count, not the ids.** What §8 permits logging is metadata; the ids
    /// are enough to reconstruct which of the user's tasks were in the window.
    case unknownTaskIDs(count: Int)
}

/// Why a response could not become a draft.
///
/// Three cases rather than one, because they mean different things about the
/// provider: `.undecodable` is not JSON at all, `.schemaViolation` is JSON that
/// does not match §7.3's schema, and `.emptyDraft` is a well-formed answer with
/// nothing in it — which is a failure, not a quiet success, because §7.4's raw
/// fallback is strictly better than an empty report.
public enum InvalidResponseReason: Equatable, Sendable {
    case undecodable
    case schemaViolation
    case emptyDraft

    /// The model declined the request (`stop_reason: "refusal"`).
    ///
    /// Distinct from `.undecodable`, which is where a refusal lands without
    /// this case — a well-formed answer that is not a draft would otherwise be
    /// reported as garbage from the provider, and §8's metrics would stop
    /// distinguishing a decline from a broken response.
    case refused

    /// The answer was cut off by `max_tokens`.
    ///
    /// Distinct from `.schemaViolation` for the same reason in the other
    /// direction: truncated JSON breaks §7.3's schema, but the cause is a
    /// budget the app set, not a model that invented a shape. Filing it under
    /// `.schemaViolation` would make a real hallucination indistinguishable
    /// from the app under-provisioning `maxOutputTokens`.
    case truncated
}

extension AIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No credential is set for this provider. Add an API key in Settings."
        case .invalidCredential:
            return "The provider rejected this credential."
        case .invalidRequest:
            return
                "The provider couldn't accept this request. The selected model may no longer exist."
        case .network:
            return "Couldn't reach the provider. Check your connection."
        case .timedOut:
            return "The provider didn't answer in time."
        case .rateLimited:
            return "The provider is rate limiting this key. Try again shortly."
        case .providerUnavailable:
            return "The provider is unavailable right now."
        case .invalidResponse:
            return "The provider's answer couldn't be read."
        case .unknownTaskIDs:
            return "The draft referred to work that isn't in this window."
        }
    }
}

extension AIError {
    /// The fixed vocabulary §8's metrics line uses for `outcome`.
    ///
    /// Spelled out rather than derived from `String(describing:)`, whose output
    /// is a refactor away from changing — and which would print associated
    /// values, putting `retryAfter` and a status code into a field that is
    /// supposed to be a label.
    public var metricsLabel: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .invalidCredential: return "invalidCredential"
        case .invalidRequest: return "invalidRequest"
        case .network: return "network"
        case .timedOut: return "timedOut"
        case .rateLimited: return "rateLimited"
        case .providerUnavailable: return "providerUnavailable"
        case .invalidResponse: return "invalidResponse"
        case .unknownTaskIDs: return "unknownTaskIDs"
        }
    }
}
