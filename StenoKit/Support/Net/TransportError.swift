import Foundation

/// A transport failure that is not an HTTP response at all.
///
/// **Exists so `URLSessionTransport` can live in `Support/`** (D-189). It used to
/// throw `AIError.network` for a response that was not `HTTPURLResponse`, which
/// made the one adapter every layer needs a member of the AI layer. Each
/// consumer maps this onto its own error vocabulary instead:
/// `AnthropicErrors.error(forTransport:)` already reports an unrecognised error
/// as `AIError.network`, and `AtlassianErrors` maps it to `SourceError.network`, so
/// nothing about either layer's behaviour changes.
///
/// One case, because one case is all that is reachable: every other failure
/// `URLSession` produces is a `URLError`, which both consumers already map.
public enum TransportError: Error, Equatable, Sendable {
    /// The response arrived over something other than HTTP.
    case notHTTP
}
