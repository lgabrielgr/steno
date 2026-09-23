import Foundation
import Testing

@testable import StenoKit

/// §7.4: "the user must never arrive at a stand-up empty-handed."

private let modelID = "claude-test-1"

/// A window with one task and something to say about it.
private func window(_ cadence: ReportCadence = .daily) -> GatheredWindow {
    DraftFixture.window(
        cadence,
        tasks: [
            DraftFixture.task(
                "Flaky auth test in CI", keys: ["STENO-12"],
                events: [DraftFixture.event("found the race in the token refresh")])
        ])
}

/// A draft the model could plausibly have returned for `window`.
private func draft(for window: GatheredWindow, text: String = "Fixed the flaky auth test")
    -> StandupDraft
{
    let ids = window.tasks.map(\.id)
    switch window.cadence {
    case .daily:
        return .daily(
            DailyDraft(
                sinceLastStandup: ids.map { DailyBullet(taskID: $0, text: text) },
                today: [], blockers: []))
    case .periodic:
        return .periodic(
            PeriodicDraft(
                completed: [ThemedBullet(taskIDs: ids, text: text)],
                inFlight: [], blockersAndRisks: []))
    }
}

private func summarizer(
    provider: (any AIProvider)?, modelID: String? = modelID
) -> StandupSummarizer {
    StandupSummarizer(
        provider: provider, modelID: modelID, timeout: .seconds(20),
        timeZone: .gmt)
}

// MARK: - The AI path

@Test("a validated draft becomes the report, and records the model that wrote it")
func aSuccessfulDraftIsRendered() async {
    let window = window()
    let provider = StubAIProvider(draft: .success(draft(for: window)))

    let result = await summarizer(provider: provider).summarize(window)

    #expect(result.modelUsed == modelID)
    #expect(result.markdown.contains("Fixed the flaky auth test (STENO-12)"))
    // **The load-bearing half of the degradation table below.** Without this,
    // a summarizer that ignored its provider and always returned the raw report
    // would pass every fallback row and the whole suite would be green.
    #expect(result.markdown != StandupSummarizer.rawMarkdown(for: window))
}

@Test("the request carries §7.3's prompt, schema, ids and budget")
func theRequestIsAssembledHere() async throws {
    let window = window(.periodic)
    let provider = StubAIProvider(draft: .success(draft(for: window)))

    _ = await summarizer(provider: provider).summarize(window)

    let request = try #require(await provider.received.first)
    #expect(request.modelID == modelID)
    #expect(request.cadence == .periodic)
    #expect(request.systemPrompt == StandupPrompt.system(for: .periodic))
    #expect(
        request.userPrompt
            == StandupPrompt.user(for: window, timeZone: .gmt))
    #expect(request.outputSchema == StandupSchema.schema(for: .periodic))
    // §7.3's hallucination check runs inside the provider, so the ids have to
    // ride on the request rather than stay with the caller.
    #expect(request.allowedTaskIDs == Set(window.tasks.map(\.id)))
    #expect(request.maxOutputTokens == StandupSummarizer.maxOutputTokens)
    #expect(request.timeout == .seconds(20))
}

// MARK: - §7.4, every way down

@Test(
    "every provider failure produces the raw report instead",
    arguments: [
        AIError.notConfigured,
        .invalidCredential,
        .invalidRequest,
        .network,
        .timedOut,
        .rateLimited(retryAfter: nil),
        .rateLimited(retryAfter: .seconds(3)),
        .providerUnavailable(status: 503),
        .invalidResponse(.undecodable),
        .invalidResponse(.schemaViolation),
        .invalidResponse(.emptyDraft),
        .invalidResponse(.refused),
        .invalidResponse(.truncated),
        .unknownTaskIDs(count: 2),
    ])
func everyFailureDegrades(_ error: AIError) async {
    let window = window()
    let provider = StubAIProvider(draft: .failure(error))

    let result = await summarizer(provider: provider).summarize(window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
}

/// A provider that breaks `AIProvider`'s error contract.
///
/// The protocol says an implementation throws `AIError` and nothing else, so
/// this cannot happen today — and the catch-all it exercises is what keeps a
/// future provider's leaked `URLError` from taking down the draft path instead
/// of roughening it.
private struct ContractBreakingProvider: AIProvider {
    let id = "contract-breaker"
    let displayName = "Contract Breaker"
    func availableModels() async throws -> [AIModel] { [] }
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        throw URLError(.badServerResponse)
    }
    func testConnection() async throws {}
}

@Test("an error the protocol forbids still degrades rather than escaping")
func aNonAIErrorDegrades() async {
    let window = window()

    let result = await summarizer(provider: ContractBreakingProvider()).summarize(window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
}

@Test("a draft of nothing but blank bullets is treated as no draft at all")
func aBlankDraftDegrades() async {
    let window = window()
    let blank = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: window.tasks.map { DailyBullet(taskID: $0.id, text: "  ") },
            today: [], blockers: []))
    let provider = StubAIProvider(draft: .success(blank))

    let result = await summarizer(provider: provider).summarize(window)

    // It passed `validated(against:)` — which counts bullets, not words — and
    // would otherwise render as three headings of empty bullets. §7.4's rough
    // report is strictly better (D-152).
    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
}

// MARK: - The rows that never reach the network

@Test("no provider, no selected model, or no tasks: no call is made at all")
func theUnconfiguredRowsMakeNoCall() async {
    let window = window()
    let raw = StandupSummarizer.rawMarkdown(for: window)

    let noModel = StubAIProvider(draft: .success(draft(for: window)))
    let withoutModel = await summarizer(provider: noModel, modelID: nil).summarize(window)
    #expect(withoutModel.markdown == raw)
    #expect(withoutModel.modelUsed == nil)
    #expect(await noModel.received.isEmpty)

    let withoutProvider = await summarizer(provider: nil).summarize(window)
    #expect(withoutProvider.markdown == raw)
    #expect(withoutProvider.modelUsed == nil)

    // An empty window is not an error — D-074 renders it as three headings that
    // each say `_None_` — and the only answer a call could return is an empty
    // draft, reached more slowly and for money.
    let empty = DraftFixture.window(tasks: [])
    let quiet = StubAIProvider(draft: .success(draft(for: window)))
    let result = await summarizer(provider: quiet).summarize(empty)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: empty))
    #expect(result.modelUsed == nil)
    #expect(await quiet.received.isEmpty)
}

@Test("the fallback is the same text M2-02 renders, byte for byte")
func theFallbackIsM2s() async {
    let window = window(.periodic)

    let result = await summarizer(provider: nil).summarize(window)

    // Not a paraphrase of the raw path and not a second renderer: §7.4's
    // "rougher content, same three headings" is literally M2-02's output.
    #expect(result.markdown == SlackMarkdown.render(RawReportSections.build(from: window)))
    #expect(result.markdown.contains(ReportHeadings.completed))
}
