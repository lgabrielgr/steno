import Foundation

/// Every vendor failure, mapped onto `AIError` and nothing else (D-144).
///
/// **Pure functions over a status code and a header dictionary.** No response
/// body reaches this file, which is what makes §8's "never full payloads" a
/// property of the shape rather than a rule each branch has to remember — there
/// is no parameter here that could carry a draft, a prompt, or the API's own
/// `error.message`.
enum AnthropicErrors {
    /// `nil` when the status is a success. Anything else is an `AIError` the
    /// caller must throw.
    static func error(forStatus status: Int, headers: [String: String]) -> AIError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            // §7.1's acceptance criterion: "Test connection" must distinguish a
            // rejected key from an unreachable network.
            return .invalidCredential
        case 429:
            return .rateLimited(retryAfter: retryAfter(in: headers))
        case 400..<500:
            // 404 belongs here rather than with `.providerUnavailable`: the two
            // 404s this app can provoke are a model id that was retired since
            // the user picked it and a typo'd path. Both are ours. Routing them
            // to "the provider is unavailable right now" would send the user to
            // a status page instead of the picker.
            return .invalidRequest
        default:
            // 5xx, 529, and anything else that is not a success — including the
            // redirects HTTPS to this API should never produce.
            return .providerUnavailable(status: status)
        }
    }

    /// Map an error thrown by the transport itself.
    ///
    /// `URLError.cancelled` is `.timedOut`, not `.network`: the only thing that
    /// cancels a request in this module is `withDeadline` (D-146), and telling
    /// a user with a working connection that they are offline sends them to fix
    /// the wrong thing.
    static func error(forTransport error: any Error) -> AIError {
        if let aiError = error as? AIError { return aiError }
        if error is CancellationError { return .timedOut }

        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .timedOut : .network
        }

        // An unrecognised error is reported as `.network` because that is the
        // reading §7.4 degrades most usefully from: it produces the raw-event
        // report and tells the user to check their connection, which is wrong
        // less often than any other guess available here.
        return .network
    }

    /// `retry-after`, when it is the integer-seconds form.
    ///
    /// The HTTP-date form is ignored rather than parsed. It would need a
    /// formatter and a clock to become a `Duration`, and this header's only
    /// consumer is D-145's retry gate, which treats a missing value as "use the
    /// default backoff" — a correct outcome for a header shape this API does
    /// not use in practice.
    static func retryAfter(in headers: [String: String]) -> Duration? {
        guard let value = headers["retry-after"], let seconds = Int(value), seconds >= 0 else {
            return nil
        }
        return .seconds(seconds)
    }
}
