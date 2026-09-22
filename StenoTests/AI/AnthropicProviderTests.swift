import Foundation
import Testing

@testable import StenoKit

// D-140 through D-146, end to end over `StubHTTPTransport`. `make test` denies
// outbound IP (§9.4, D-012), so every assertion here is about what the provider
// sent and what it made of what came back.

// D-143 and D-141: what the provider sends, and what it makes of the answer.

// MARK: - Credentials

@Test("no stored credential is .notConfigured, and nothing is sent")
func anEmptyStoreNeverReachesTheNetwork() async {
    // §7.4's "is not configured". Mutation: read the key after building the
    // request instead of before. Red on `received`.
    let transport = StubHTTPTransport()
    let provider = AnthropicFixture.provider(transport, credentials: AnthropicFixture.store(nil))

    await #expect(throws: AIError.notConfigured) {
        try await provider.generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.isEmpty)
}

@Test("an OAuth credential is .notConfigured — §7.2 ships the API key path only")
func oauthIsNotYetACredential() async {
    let store = AnthropicFixture.store(
        .oauth(TokenSet(accessToken: "token", refreshToken: nil, expiresAt: nil)))
    let provider = AnthropicFixture.provider(StubHTTPTransport(), credentials: store)

    await #expect(throws: AIError.notConfigured) { try await provider.testConnection() }
}

@Test("the key is sent as x-api-key, with the API version")
func requestsCarryTheirHeaders() async throws {
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.modelsResponse(ids: ["claude-sonnet-5"]))
    ])

    _ = try await AnthropicFixture.provider(transport).availableModels()

    let sent = try #require(await transport.received.first)
    #expect(sent.headers["x-api-key"] == AnthropicFixture.key)
    #expect(sent.headers["anthropic-version"] == "2023-06-01")
    #expect(sent.url.path.hasSuffix("/v1/models"))
}

// MARK: - The request body (D-141)

@Test("the body carries exactly five keys, and no tuning parameters")
func theBodyIsMinimal() async throws {
    // D-141: the model id comes from a runtime list, so a parameter that 400s
    // on one model would make that model unusable from a picker offering it.
    // Mutation: add `"temperature": 0` to the envelope. Red.
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    _ = try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())

    let body = try #require(await transport.received.first?.body)
    let json = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(
        Set(json.keys) == ["model", "max_tokens", "system", "messages", "output_config"])
    #expect(json["model"] as? String == "claude-sonnet-5")
    #expect(json["max_tokens"] as? Int == 1024)
}

@Test("the schema reaches the API as the value M3-03 authored")
func theSchemaIsTransmittedWhole() async throws {
    let schema = #"{"type":"object","properties":{"today":{"type":"array"}},"required":["today"]}"#
    var request = AnthropicFixture.request()
    request = StandupRequest(
        modelID: request.modelID,
        cadence: request.cadence,
        systemPrompt: request.systemPrompt,
        userPrompt: request.userPrompt,
        outputSchema: AIOutputSchema(name: "daily", json: Data(schema.utf8)),
        allowedTaskIDs: request.allowedTaskIDs,
        maxOutputTokens: request.maxOutputTokens,
        timeout: request.timeout
    )

    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    _ = try await AnthropicFixture.provider(transport).generateStandup(request)

    let body = try #require(await transport.received.first?.body)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let format = (json?["output_config"] as? [String: Any])?["format"] as? [String: Any]
    let sent = try #require(format?["schema"] as? [String: Any])

    #expect(format?["type"] as? String == "json_schema")
    #expect(sent["required"] as? [String] == ["today"])
    #expect((sent["properties"] as? [String: Any])?.keys.contains("today") == true)
}

@Test("a schema that is not a JSON object fails before any request is sent")
func aBrokenSchemaIsCaughtLocally() async {
    let request = StandupRequest(
        modelID: "claude-sonnet-5",
        cadence: .daily,
        systemPrompt: "system",
        userPrompt: "user",
        outputSchema: AIOutputSchema(name: "daily", json: Data("not a schema".utf8)),
        allowedTaskIDs: [AnthropicFixture.taskID],
        maxOutputTokens: 1024,
        timeout: .seconds(5)
    )
    let transport = StubHTTPTransport()

    await #expect(throws: AIError.invalidRequest) {
        try await AnthropicFixture.provider(transport).generateStandup(request)
    }
    #expect(await transport.received.isEmpty)
}

@Test("two calls with equal inputs produce equal bytes")
func theBodyIsDeterministic() async throws {
    // `JSONSerialization`'s unsorted key order is hash order, which differs
    // between processes. Mutation: drop `.sortedKeys`. Red only sometimes,
    // which is why the two bodies are compared within one run *and* the option
    // is asserted by this test's existence in review.
    let first = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    let second = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])

    _ = try await AnthropicFixture.provider(first).generateStandup(AnthropicFixture.request())
    _ = try await AnthropicFixture.provider(second).generateStandup(AnthropicFixture.request())

    #expect(await first.received.first?.body == second.received.first?.body)
}

// MARK: - The draft path (D-143)

@Test("a valid draft decodes and is returned")
func aGoodResponseBecomesADraft() async throws {
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    let draft = try await AnthropicFixture.provider(transport).generateStandup(
        AnthropicFixture.request())

    guard case .daily(let daily) = draft else {
        Issue.record("expected a daily draft")
        return
    }
    #expect(daily.sinceLastStandup.first?.text == "fixed the flaky auth test")
    #expect(daily.sinceLastStandup.first?.taskID == AnthropicFixture.taskID)
}

@Test("a task id the app never sent is rejected inside the provider")
func hallucinatedIDsFailLoudly() async {
    // §7.3: "a hallucinated ID is the clearest possible signal the model
    // invented a fact, and it should fail loudly into the §7.4 fallback rather
    // than render." Mutation: drop the `validated(against:)` call. Red.
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.draftResponse(taskID: AnthropicFixture.otherID))
    ])

    await #expect(throws: AIError.unknownTaskIDs(count: 1)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a refusal is its own reason, not undecodable")
func refusalsAreNamed() async {
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.draftResponse(stopReason: "refusal"))
    ])

    await #expect(throws: AIError.invalidResponse(.refused)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a truncated answer is its own reason, not a schema violation")
func truncationIsNamed() async {
    // Blaming `.schemaViolation` would make a real hallucination
    // indistinguishable from the app under-provisioning `maxOutputTokens`.
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.draftResponse(stopReason: "max_tokens"))
    ])

    await #expect(throws: AIError.invalidResponse(.truncated)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a response with no text block is an empty draft, not a silent success")
func emptyResponsesFail() async {
    let empty = HTTPResponse(
        status: 200, body: Data(#"{"content":[],"stop_reason":"end_turn"}"#.utf8))
    let transport = StubHTTPTransport(answers: [.respond(empty)])

    await #expect(throws: AIError.invalidResponse(.emptyDraft)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a body that is not JSON is undecodable")
func garbageIsUndecodable() async {
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 200, body: Data("<html>502</html>".utf8)))
    ])

    await #expect(throws: AIError.invalidResponse(.undecodable)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}
