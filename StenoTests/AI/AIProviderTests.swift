import Foundation
import Testing

@testable import StenoKit

/// §9.4's acceptance criterion: a double satisfies the protocol and the suite
/// passes with networking disabled.
///
/// These tests are also the double's own coverage. `StubAIProvider` has no
/// production caller until M3-02, and an unexercised double is one that fails
/// the task it was built for at the moment that task starts.

private func aRequest(allowing allowed: Set<UUID> = []) -> StandupRequest {
    StandupRequest(
        modelID: "a-model-id",
        cadence: .daily,
        systemPrompt: "system",
        userPrompt: "user",
        outputSchema: AIOutputSchema(name: "standup_daily", json: Data("{}".utf8)),
        allowedTaskIDs: allowed,
        maxOutputTokens: 1024,
        timeout: .seconds(20))
}

@Test("a scripted provider answers through the protocol, with no network")
func theDoubleAnswersThroughTheProtocol() async throws {
    let taskID = UUID()
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: taskID, text: "shipped the encoder")],
            today: [], blockers: []))
    // Held as the existential, not the concrete type: what M3-03 will hold.
    let provider: any AIProvider = StubAIProvider(
        models: .success([AIModel(id: "a-model-id", displayName: "A Model")]),
        draft: .success(draft))

    #expect(
        try await provider.availableModels() == [AIModel(id: "a-model-id", displayName: "A Model")])
    #expect(try await provider.generateStandup(aRequest(allowing: [taskID])) == draft)
    try await provider.testConnection()
}

@Test("the double can throw each error §7.4 has to degrade from", arguments: AIError.everyCase)
func theDoubleCanFailEveryWay(error: AIError) async {
    let provider = StubAIProvider(draft: .failure(error))

    await #expect(throws: error) {
        try await provider.generateStandup(aRequest())
    }
}

@Test("a request is recorded even when the provider fails")
func requestsAreRecordedBeforeFailing() async throws {
    // M3-03 will need to assert what it sent to a provider that refused —
    // a double that recorded only on success would make the failure paths,
    // which are the ones §7.4 exists for, the ones it could not inspect.
    let provider = StubAIProvider(draft: .failure(.timedOut))

    _ = try? await provider.generateStandup(aRequest())

    let received = await provider.received
    #expect(received.count == 1)
    #expect(received.first?.modelID == "a-model-id")
}

@Test("a provider can be made to hang, so a caller's timeout has something to time")
func theDoubleCanHang() async throws {
    // M3-02's timeout budget is untestable without this. The delay is tiny
    // here — what is being checked is that the seam exists and is honoured,
    // not how long it waits.
    let provider = StubAIProvider(connection: .success(()), delay: .milliseconds(50))
    let started = ContinuousClock.now

    try await provider.testConnection()

    #expect(ContinuousClock.now - started >= .milliseconds(50))
}
