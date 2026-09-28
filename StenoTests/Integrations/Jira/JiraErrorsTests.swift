import Foundation
import Testing

@testable import StenoKit

/// D-192: every status Jira can answer with, mapped to the sentence §5.5 shows.

@Test(
    "the status table",
    arguments: [
        (200, SourceError?.none),
        (204, SourceError?.none),
        // A malformed key, which is a mistyped reference rather than an outage.
        (400, SourceError?.some(.notFound)),
        // §5.2: never a generic network error, and never `.invalidCredential` either —
        // the sentence has to say "expired" and carry a link.
        (401, SourceError?.some(.credentialExpired)),
        // Authentication policy or a blocked account: refused, not stale.
        (403, SourceError?.some(.invalidCredential)),
        (404, SourceError?.some(.notFound)),
        (409, SourceError?.some(.unavailable(status: 409))),
        (500, SourceError?.some(.unavailable(status: 500))),
        (503, SourceError?.some(.unavailable(status: 503))),
        // A redirect `RedirectBlocker` handed back rather than following with the
        // credential attached.
        (302, SourceError?.some(.unavailable(status: 302))),
    ])
func theStatusTable(status: Int, expected: SourceError?) {
    #expect(JiraErrors.error(forStatus: status, headers: [:]) == expected)
}

@Test("429 carries the interval the service named")
func rateLimitCarriesRetryAfter() {
    #expect(
        JiraErrors.error(forStatus: 429, headers: ["retry-after": "30"])
            == .rateLimited(retryAfter: .seconds(30)))
}

@Test(
    "a retry-after that is not integer seconds is no interval at all",
    arguments: ["", "soon", "-5", "Wed, 21 Oct 2026 07:28:00 GMT"])
func rateLimitWithoutAUsableInterval(value: String) {
    // The HTTP-date form is ignored rather than parsed: the only consumer treats a
    // missing value as "no interval was named", which is correct for a shape this API
    // does not use in practice.
    #expect(
        JiraErrors.error(forStatus: 429, headers: ["retry-after": value])
            == .rateLimited(retryAfter: nil))
}

@Test("the header lookup is case-insensitive in practice")
func retryAfterIsFoundWhateverTheCase() {
    // `HTTPResponse` lowercases its keys, so this is the shape that actually arrives —
    // and the reason that normalization is load-bearing rather than tidiness.
    let response = HTTPResponse(status: 429, headers: ["Retry-After": "12"])
    #expect(
        JiraErrors.error(forStatus: response.status, headers: response.headers)
            == .rateLimited(retryAfter: .seconds(12)))
}

@Test("a cancelled request is a timeout, not an offline machine")
func jiraCancellationIsATimeout() {
    // The only thing that cancels a fetch is the per-fetch deadline or the pass budget,
    // and telling a user with working wifi that they are offline sends them to fix the
    // wrong thing.
    #expect(JiraErrors.error(forTransport: CancellationError()) == .timedOut)
    #expect(JiraErrors.error(forTransport: URLError(.cancelled)) == .timedOut)
}

@Test(
    "the transport's own failures are network failures",
    arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .secureConnectionFailed])
func transportFailuresAreNetwork(code: URLError.Code) {
    #expect(JiraErrors.error(forTransport: URLError(code)) == .network)
}

@Test("a response that was not HTTP is a network failure")
func notHTTPIsNetwork() {
    // `TransportError` exists so `URLSessionTransport` could move to `Support/` without
    // dragging the AI layer's error type with it (D-189).
    #expect(JiraErrors.error(forTransport: TransportError.notHTTP) == .network)
}

@Test("a SourceError passes through unchanged")
func sourceErrorsPassThrough() {
    // The client throws these itself — an invalid key, a missing credential — and
    // re-mapping them would turn a precise sentence into "check your connection".
    #expect(JiraErrors.error(forTransport: SourceError.notFound) == .notFound)
    #expect(JiraErrors.error(forTransport: SourceError.notConfigured) == .notConfigured)
}

@Test("an unrecognised error degrades to network")
func unknownErrorsDegradeToNetwork() {
    struct Surprise: Error {}
    #expect(JiraErrors.error(forTransport: Surprise()) == .network)
}
