import Foundation
import Testing

@testable import StenoKit

// D-141 through D-147, end to end over `StubHTTPTransport`. `make test` denies
// outbound IP (§9.4, D-012), so every assertion here is about what the provider
// sent and what it made of what came back.

// D-144 and D-142: what the provider sends, and what it makes of the answer.

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

// MARK: - The request body (D-142)

@Test("the body carries exactly five keys, and no tuning parameters")
func theBodyIsMinimal() async throws {
    // D-142: the model id comes from a runtime list, so a parameter that 400s
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

@Test("the body is serialized with its keys in sorted order")
func theBodyIsDeterministic() async throws {
    // **An exact byte sequence, not two serializations compared.** The earlier
    // version of this test ran `messagesBody` twice in one process and compared
    // the results — which cannot detect a missing `.sortedKeys` at all, because
    // unsorted dictionary iteration is stable *within* a process and both calls
    // produce the same order either way (PR #35 review). It was a test that
    // could not fail for the mutation its own comment named.
    //
    // §10.2 already pays for this lesson once: hash order differs between
    // processes, so a body that is not explicitly sorted is not reproducible.
    // Mutation: drop `.sortedKeys`. Red — the nested objects reorder too.
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    _ = try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())

    let body = try #require(await transport.received.first?.body)
    let expected = """
        {"max_tokens":1024,"messages":[{"content":"user","role":"user"}],\
        "model":"claude-sonnet-5",\
        "output_config":{"format":{"schema":{"type":"object"},"type":"json_schema"}},\
        "system":"system"}
        """

    // The failable initializer rather than `String(decoding:)`, per SwiftLint's
    // `optional_data_string_conversion` — which is the better assertion anyway:
    // a body that is not valid UTF-8 fails here rather than becoming replacement
    // characters that then compare unequal for an unrelated-looking reason.
    #expect(String(bytes: body, encoding: .utf8) == expected)
}

// MARK: - The draft path (D-144)

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

@Test("a periodic window decodes into the periodic draft, not the daily one")
func periodicCadenceRoundTrips() async throws {
    // §7.3: the two cadences "are not cosmetic variants of each other — the
    // sections differ, and so does the cardinality of the task reference." The
    // provider switches on cadence to pick the decode, and only `.daily` was
    // covered (PR #35 review). Mutation: decode `.daily` regardless of cadence.
    // Red — a periodic body has no `since_last_standup`.
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.periodicDraftResponse())])

    let draft = try await AnthropicFixture.provider(transport)
        .generateStandup(AnthropicFixture.request(cadence: .periodic))

    guard case .periodic(let periodic) = draft else {
        Issue.record("expected a periodic draft")
        return
    }
    #expect(periodic.completed.first?.text == "shipped the export encoder")
    #expect(periodic.completed.first?.taskIDs == [AnthropicFixture.taskID])
    #expect(periodic.inFlight.isEmpty)
}

@Test("a hallucinated id in a periodic bullet is rejected too")
func periodicDraftsAreValidated() async {
    // `task_ids` is plural here and `allTaskIDs` flattens it — a guard that
    // only walked the daily shape would let a themed bullet smuggle one in.
    let transport = StubHTTPTransport(answers: [
        .respond(
            AnthropicFixture.periodicDraftResponse(
                taskIDs: [AnthropicFixture.taskID, AnthropicFixture.otherID]))
    ])

    await #expect(throws: AIError.unknownTaskIDs(count: 1)) {
        try await AnthropicFixture.provider(transport)
            .generateStandup(AnthropicFixture.request(cadence: .periodic))
    }
}

// MARK: - The contract, and what §8 keeps when it breaks

@Test("cancelling a model-list fetch still surfaces an AIError")
func cancellationDoesNotEscapeTheContract() async {
    // M3-01's contract: an implementation throws `AIError` and nothing else,
    // because §7.4 "cannot switch on an error type it has never heard of".
    // Cancelling the caller cancels the deadline's child tasks, and `Task.sleep`
    // then throws a bare `CancellationError` past every mapping inside the
    // group — `generateStandup` caught that and `availableModels` did not
    // (PR #35 review). Mutation: drop the catch in `availableModels`. Red.
    let transport = StubHTTPTransport(
        answers: [.respond(AnthropicFixture.modelsResponse(ids: ["claude-sonnet-5"]))],
        delay: .seconds(60))
    let provider = AnthropicFixture.provider(transport)

    let task = Task { try await provider.availableModels() }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected the cancelled fetch to fail")
    } catch is AIError {
        // The contract held.
    } catch {
        Issue.record("escaped as \(type(of: error)), which §7.4 cannot classify")
    }
}

@Test("a refusal keeps the token counts it was billed for")
func failedDraftsKeepTheirUsage() throws {
    // D-147: the metrics line keeps the token counts whenever the response
    // carried them. A refusal, a truncation and a hallucinated id are all
    // billed calls — the API reports `usage` and *then* the draft fails — so
    // recording `nil` would lose the numbers for the one class of failure that
    // actually cost the user money (PR #35 review).
    //
    // Mutation: return `nil` for `usage` in `DraftFailure`. Red.
    let body = AnthropicFixture.draftResponse(stopReason: "refusal").body

    do {
        _ = try AnthropicProvider.draft(
            from: body, cadence: .daily, allowed: [AnthropicFixture.taskID])
        Issue.record("expected a refusal to fail")
    } catch let failure as AnthropicProvider.DraftFailure {
        #expect(failure.error == .invalidResponse(.refused))
        #expect(failure.usage?.inputTokens == 120)
        #expect(failure.usage?.outputTokens == 45)
    }
}

@Test("a hallucinated id keeps its usage too, not just a refusal")
func validationFailuresKeepTheirUsage() throws {
    // The `StandupDraft.decode` / `validated(against:)` pair throws a plain
    // `AIError`, so it needs its own wrap — a fix applied to the `stop_reason`
    // branches alone would leave this path recording nothing.
    let body = AnthropicFixture.draftResponse(taskID: AnthropicFixture.otherID).body

    do {
        _ = try AnthropicProvider.draft(
            from: body, cadence: .daily, allowed: [AnthropicFixture.taskID])
        Issue.record("expected a hallucinated id to fail")
    } catch let failure as AnthropicProvider.DraftFailure {
        #expect(failure.error == .unknownTaskIDs(count: 1))
        #expect(failure.usage?.inputTokens == 120)
    }
}
