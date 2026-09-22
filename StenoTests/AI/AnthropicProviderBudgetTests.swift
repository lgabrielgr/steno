import Foundation
import Testing

@testable import StenoKit

// D-144, D-145 and D-140: the budget §7.4 waits on, the retry that is worth
// one attempt, and the runtime model list §7.1 forbids compiling in.

// MARK: - Budget and retries (D-144, D-145)

@Test("a transport that hangs loses the deadline, and it is not a network error")
func aHangIsATimeout() async {
    // The row that matters most to §7.4: the fallback must engage promptly,
    // and it must not tell a user with a working connection that they are
    // offline. Mutation: map `URLError.cancelled` to `.network`. Red.
    let transport = StubHTTPTransport(
        answers: [.respond(AnthropicFixture.draftResponse())], delay: .seconds(60))

    await #expect(throws: AIError.timedOut) {
        try await AnthropicFixture.provider(transport).generateStandup(
            AnthropicFixture.request(timeout: .milliseconds(20)))
    }
}

@Test("a 529 is retried once and then succeeds")
func overloadIsRetried() async throws {
    // A 529 is Anthropic briefly overloaded; dropping to raw events for
    // something a one-second wait would fix is a worse stand-up than the user
    // could have had. Mutation: return `nil` from `backoff(for:)` for
    // `.providerUnavailable`. Red.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 529)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    _ = try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    #expect(await transport.received.count == 2)
}

@Test("the retry happens once, not until the budget runs out")
func retriesAreNotALoop() async {
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 529)),
        .respond(HTTPResponse(status: 529)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.providerUnavailable(status: 529)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 2)
}

@Test("a redirect is not retried, though it lands in the same error case")
func onlyServerFailuresAreRetried() async {
    // `AnthropicErrors` files every non-2xx, non-4xx status under
    // `.providerUnavailable`, so gating the retry on the *case* retried 3xx
    // too — sending the same POST twice for a response no retry can change
    // (PR #35 review, found in code that had not changed since the first
    // round). D-144's list is 429, 529 and 5xx.
    //
    // Mutation: gate on `case .providerUnavailable` without the status range.
    // Red on the request count.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 302)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.providerUnavailable(status: 302)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 1)
}

@Test("a 400 is never retried")
func ourOwnMistakesAreNotRetried() async {
    // Mutation: add `.invalidRequest` to `backoff(for:)`. Red on the count.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 400)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.invalidRequest) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 1)
}

@Test("a retry-after longer than the budget fails immediately")
func futileWaitsAreNotTaken() async {
    // Waiting out a 60-second `retry-after` inside a 5-second budget is a
    // slower failure, not a second chance — and M3-03 can say something
    // specific with the interval in hand.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 429, headers: ["retry-after": "60"])),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.rateLimited(retryAfter: .seconds(60))) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 1)
}

@Test("a transport failure arrives as an AIError, never as a URLError")
func transportErrorsAreMapped() async {
    // §7.4 "cannot switch on an error type it has never heard of" — the
    // contract M3-01 wrote into `AIProvider`'s doc comment.
    let transport = StubHTTPTransport(answers: [.fail(URLError(.notConnectedToInternet))])

    await #expect(throws: AIError.network) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

// MARK: - The model list (D-140)

@Test("the list is fetched, ranked, and returned with the default first")
func theListIsOrdered() async throws {
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.modelsResponse(ids: ["claude-opus-5", "claude-sonnet-5"]))
    ])

    let models = try await AnthropicFixture.provider(transport).availableModels()
    #expect(models.map(\.id) == ["claude-sonnet-5", "claude-opus-5"])
}

@Test("paging accumulates across pages, and the cursor is sent")
func pagingFollowsTheCursor() async throws {
    let transport = StubHTTPTransport(answers: [
        .respond(
            AnthropicFixture.modelsResponse(
                ids: ["claude-opus-5"], hasMore: true, lastID: "claude-opus-5")),
        .respond(AnthropicFixture.modelsResponse(ids: ["claude-sonnet-5"])),
    ])

    let models = try await AnthropicFixture.provider(transport).availableModels()

    #expect(models.map(\.id) == ["claude-sonnet-5", "claude-opus-5"])
    let second = try #require(await transport.received.last)
    #expect(second.url.query?.contains("after_id=claude-opus-5") == true)
}

@Test("a page that repeats its cursor ends the loop and offers no duplicate")
func aRepeatedCursorTerminates() async throws {
    // Two separate properties, and the first version of this test asserted the
    // defect as if it were the second. Every termination condition depends on a
    // field the vendor controls, so a page reporting `has_more` forever would
    // burn the user's budget instead of answering — the cursor guard stops that
    // after two requests. But the loop appends each page *before* it can know
    // the page repeats, so stopping the loop does not un-append: this asserted
    // `models.count == 2` and pinned a duplicated picker entry as intended
    // behaviour (PR #35 review). `ModelRanking.ordered` now dedupes by id.
    //
    // Mutations: drop the `last != cursor` guard (the run then pages until the
    // settings deadline expires — see `endlessPagingIsATimeout` for why that
    // is the right outcome); drop the `seen.insert` filter (red on the model
    // list).
    let repeated = AnthropicFixture.modelsResponse(
        ids: ["claude-sonnet-5"], hasMore: true, lastID: "cursor")
    let transport = StubHTTPTransport(
        answers: [.respond(repeated), .respond(repeated), .respond(repeated)],
        fallback: .respond(repeated))

    let models = try await AnthropicFixture.provider(transport).availableModels()

    #expect(models.map(\.id) == ["claude-sonnet-5"])
    #expect(await transport.received.count == 2)
}

@Test("an invalid key is distinguishable from an unreachable network")
func testConnectionSeparatesItsFailures() async {
    // §7.1's acceptance criterion, and the reason `.invalidCredential` exists
    // separately from `.network` at all.
    let rejected = StubHTTPTransport(answers: [.respond(HTTPResponse(status: 401))])
    await #expect(throws: AIError.invalidCredential) {
        try await AnthropicFixture.provider(rejected).testConnection()
    }

    let offline = StubHTTPTransport(answers: [.fail(URLError(.notConnectedToInternet))])
    await #expect(throws: AIError.network) {
        try await AnthropicFixture.provider(offline).testConnection()
    }
}

@Test("a key with access to nothing is an empty list, not an error")
func anEmptyListIsLegitimate() async throws {
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.modelsResponse(ids: []))])
    #expect(try await AnthropicFixture.provider(transport).availableModels().isEmpty)
}

// MARK: - §8

@Test("the metrics line for a draft carries metadata and no payload")
func theMetricsLineIsMetadataOnly() {
    // D-146 emits one line per draft. `AIMetricsLog.line(for:)` is the string
    // `record` writes, and `AISecretsTests` pins it character for character;
    // this asserts the values M3-02 supplies reach it.
    let metrics = AIRequestMetrics(
        providerID: "anthropic",
        modelID: "claude-sonnet-5",
        latency: .milliseconds(1234),
        inputTokens: 120,
        outputTokens: 45,
        outcome: .failed(label: AIError.invalidRequest.metricsLabel)
    )

    let line = AIMetricsLog.line(for: metrics)
    #expect(
        line
            == "ai provider=anthropic model=claude-sonnet-5 ms=1234 in=120 out=45 outcome=invalidRequest"
    )
    #expect(CredentialPatterns.matches(in: line).isEmpty)
}

@Test("a vendor that pages forever times out rather than truncating")
func endlessPagingIsATimeout() async {
    // Every page carries a *different* cursor, so the repeat guard never
    // fires. The twenty-page cap this replaced would have returned whatever it
    // had collected and called it the model list — a picker missing the user's
    // model, reported as success. The deadline reports the truth instead
    // (PR #35 review).
    let provider = AnthropicProvider(
        transport: EndlessPagingTransport(),
        credentials: AnthropicFixture.store(),
        configuration: AnthropicProvider.Configuration(
            baseURL: URL(fileURLWithPath: "/api.example.test"),
            settingsTimeout: .milliseconds(50),
            retryBackoff: .milliseconds(1),
            retryHeadroom: .milliseconds(1)))

    await #expect(throws: AIError.timedOut) { _ = try await provider.availableModels() }
}

/// Answers every request with a page whose cursor has never been seen before.
private actor EndlessPagingTransport: HTTPTransport {
    private var page = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        page += 1
        return AnthropicFixture.modelsResponse(
            ids: ["claude-sonnet-\(page)"], hasMore: true, lastID: "cursor-\(page)")
    }
}
