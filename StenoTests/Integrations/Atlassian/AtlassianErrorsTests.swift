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
    #expect(
        AtlassianErrors.error(forStatus: status, headers: [:], badRequest: .notFound) == expected)
}

@Test("429 carries the interval the service named")
func rateLimitCarriesRetryAfter() {
    #expect(
        AtlassianErrors.error(
            forStatus: 429, headers: ["retry-after": "30"], badRequest: .notFound)
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
        AtlassianErrors.error(
            forStatus: 429, headers: ["retry-after": value], badRequest: .notFound)
            == .rateLimited(retryAfter: nil))
}

@Test("the header lookup is case-insensitive in practice")
func retryAfterIsFoundWhateverTheCase() {
    // `HTTPResponse` lowercases its keys, so this is the shape that actually arrives —
    // and the reason that normalization is load-bearing rather than tidiness.
    let response = HTTPResponse(status: 429, headers: ["Retry-After": "12"])
    #expect(
        AtlassianErrors.error(
            forStatus: response.status, headers: response.headers, badRequest: .notFound)
            == .rateLimited(retryAfter: .seconds(12)))
}

@Test("a cancelled request is a timeout, not an offline machine")
func jiraCancellationIsATimeout() {
    // The only thing that cancels a fetch is the per-fetch deadline or the pass budget,
    // and telling a user with working wifi that they are offline sends them to fix the
    // wrong thing.
    #expect(AtlassianErrors.error(forTransport: CancellationError()) == .timedOut)
    #expect(AtlassianErrors.error(forTransport: URLError(.cancelled)) == .timedOut)
}

@Test(
    "the transport's own failures are network failures",
    arguments: [
        URLError.Code.notConnectedToInternet, .secureConnectionFailed,
        // **`.cannotConnectToHost` belongs here, not with the two below** (D-217).
        // A host that resolves and then refuses the connection is a proxy, a
        // captive portal or a firewall — not a typo — so sending the user to edit
        // a site address that is correct would be the wrong instruction.
        .cannotConnectToHost, .timedOut, .networkConnectionLost,
    ])
func transportFailuresAreNetwork(code: URLError.Code) {
    #expect(AtlassianErrors.error(forTransport: URLError(code)) == .network)
}

@Test(
    "D-217: a host that does not resolve is a wrong site address, not a network failure",
    arguments: [URLError.Code.cannotFindHost, .dnsLookupFailed])
func unresolvableHostsAreSiteNotFound(code: URLError.Code) {
    // §5.2 forbids reporting a 401 as a generic network error, and the same
    // reasoning reaches every failure the user can fix. `acmee.atlassian.net` is
    // shaped correctly, passes `baseURL`'s validation, and fails here — so this
    // is the mapping that decides whether the user is sent to Settings or to
    // their router.
    //
    // **`.cannotFindHost` was asserted as `.network` by the test above until this
    // task**, which is what made the wrong sentence a documented behaviour rather
    // than an oversight.
    #expect(AtlassianErrors.error(forTransport: URLError(code)) == .siteNotFound)
}

@Test("D-217: the two site-shaped failures do not collapse into one another")
func siteAndNetworkStayDistinct() {
    // Mutation: map `.cannotConnectToHost` to `.siteNotFound` as well. Red —
    // which is the point, because the generous mapping is the tempting one.
    #expect(AtlassianErrors.error(forTransport: URLError(.cannotFindHost)) != .network)
    #expect(AtlassianErrors.error(forTransport: URLError(.cannotConnectToHost)) != .siteNotFound)
}

@Test("a response that was not HTTP is a network failure")
func notHTTPIsNetwork() {
    // `TransportError` exists so `URLSessionTransport` could move to `Support/` without
    // dragging the AI layer's error type with it (D-189).
    #expect(AtlassianErrors.error(forTransport: TransportError.notHTTP) == .network)
}

@Test("a SourceError passes through unchanged")
func sourceErrorsPassThrough() {
    // The client throws these itself — an invalid key, a missing credential — and
    // re-mapping them would turn a precise sentence into "check your connection".
    #expect(AtlassianErrors.error(forTransport: SourceError.notFound) == .notFound)
    #expect(AtlassianErrors.error(forTransport: SourceError.notConfigured) == .notConfigured)
}

@Test("an unrecognised error degrades to network")
func unknownErrorsDegradeToNetwork() {
    struct Surprise: Error {}
    #expect(AtlassianErrors.error(forTransport: Surprise()) == .network)
}

@Test("D-214: a 400 means what the calling API says it means, not one shared guess")
func badRequestIsPerAPI() {
    // Jira answers 400 for a malformed issue key — a mistyped reference, so `.notFound`.
    // Confluence cannot: `ConfluenceEndpoint` rejects a non-numeric page id locally, so a
    // 400 from Confluence is a bad cursor or another request-contract problem, and telling
    // the user a page they were just reading does not exist would be worse than saying the
    // integration is having trouble.
    #expect(
        AtlassianErrors.error(forStatus: 400, headers: [:], badRequest: .notFound) == .notFound)
    #expect(
        AtlassianErrors.error(
            forStatus: 400, headers: [:], badRequest: .unavailable(status: 400))
            == .unavailable(status: 400))

    // Every other status is genuinely shared, and stays shared.
    for status in [401, 403, 404, 429, 500] {
        let asJira = AtlassianErrors.error(forStatus: status, headers: [:], badRequest: .notFound)
        let asConfluence = AtlassianErrors.error(
            forStatus: status, headers: [:], badRequest: .unavailable(status: 400))
        #expect(asJira == asConfluence)
    }
}
