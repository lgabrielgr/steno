import Foundation

/// Jira's failures, mapped onto `SourceError` and nothing else (D-192).
///
/// **Pure functions over a status code and a header dictionary**, for the reason
/// `AnthropicErrors` is: no response body reaches this file, so §8's "never full
/// payloads" is a property of the shape rather than a rule each branch has to
/// remember. There is no parameter here that could carry a ticket title, a comment
/// body or an assignee's name.
enum JiraErrors {
    /// `nil` when the status is a success. Anything else is a `SourceError` the
    /// caller must throw.
    static func error(forStatus status: Int, headers: [String: String]) -> SourceError? {
        switch status {
        case 200..<300:
            return nil
        case 400:
            // **`.notFound`, not a generic failure.** Jira answers 400 for a
            // malformed issue key, and a malformed key is a mistyped reference in a
            // task title — which is exactly what `.notFound` tells the user, while
            // "the integration is unavailable" would send them to a status page over
            // a typo.
            return .notFound
        case 401:
            // §5.2: never a generic network error. D-192 maps every 401 here without
            // consulting the stored expiry date, because that date is hand-entered
            // and is precisely what is wrong when a token silently expires.
            return .credentialExpired
        case 403:
            // Not expiry: an authentication policy, a blocked account, or a captcha
            // challenge. The credential is being refused rather than being stale.
            return .invalidCredential
        case 404:
            // Jira returns 404 for an issue the account cannot see, which is the same
            // sentence the user needs either way.
            return .notFound
        case 429:
            return .rateLimited(retryAfter: retryAfter(in: headers))
        case 400..<500:
            // The least-wrong bucket for the rest, and the log carries the status.
            // `.invalidResponse` would be a lie — the response was perfectly
            // readable — and there is no case for "we sent something wrong".
            return .unavailable(status: status)
        default:
            // 5xx, and the redirects `RedirectBlocker` hands back as a status rather
            // than following with the credential attached.
            return .unavailable(status: status)
        }
    }

    /// Map an error thrown by the transport itself.
    ///
    /// `URLError.cancelled` is `.timedOut`, not `.network`: the only thing that
    /// cancels a fetch here is `SourceRefreshService`'s per-fetch deadline or its
    /// pass budget, and telling a user with a working connection that they are
    /// offline sends them to fix the wrong thing.
    static func error(forTransport error: any Error) -> SourceError {
        if let sourceError = error as? SourceError { return sourceError }
        if error is CancellationError { return .timedOut }
        if error is TransportError { return .network }

        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .timedOut : .network
        }

        // An unrecognised error is reported as `.network` because that is the reading
        // §5.5 degrades most usefully from: the draft falls back on cached data and
        // the banner tells the user to check their connection, which is wrong less
        // often than any other guess available here.
        return .network
    }

    /// `retry-after`, when it is the integer-seconds form.
    ///
    /// The HTTP-date form is ignored rather than parsed, for `AnthropicErrors`'
    /// reason: it would need a formatter and a clock, and the only consumer treats a
    /// missing value as "no interval was named".
    static func retryAfter(in headers: [String: String]) -> Duration? {
        guard let value = headers["retry-after"], let seconds = Int(value), seconds >= 0 else {
            return nil
        }
        return .seconds(seconds)
    }
}
