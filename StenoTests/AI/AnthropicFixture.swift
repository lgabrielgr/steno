import Foundation

@testable import StenoKit

/// The fixtures `AnthropicProviderTests` and `AnthropicProviderBudgetTests`
/// share.
///
/// Its own file because both suites need it and neither owns it — the same
/// reason `AIError.everyCase` lives in `AIErrorTests` rather than being copied
/// into `AISecretsTests`.
enum AnthropicFixture {
    static let key = "sk-ant-test-key"

    /// Fixed ids so a failure message names the same value twice in a row.
    /// Generated rather than parsed from a literal: `UUID(uuidString:)` returns
    /// an optional, and unwrapping it is a force-unwrap SwiftLint rejects for a
    /// value that has no meaning beyond "not the other one".
    static let taskID = UUID()
    static let otherID = UUID()

    /// A configuration whose waits are short enough for a test to sit through.
    static let configuration = AnthropicProvider.Configuration(
        baseURL: URL(fileURLWithPath: "/api.example.test"),
        settingsTimeout: .seconds(5),
        retryBackoff: .milliseconds(1),
        retryHeadroom: .milliseconds(1)
    )

    static func store(_ credential: Credential? = .apiKey(key)) -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        if let credential {
            try? store.store(credential, for: "anthropic")
        }
        return store
    }

    static func provider(
        _ transport: StubHTTPTransport,
        credentials: InMemoryCredentialStore = store()
    ) -> AnthropicProvider {
        AnthropicProvider(
            transport: transport, credentials: credentials, configuration: configuration)
    }

    static func request(
        timeout: Duration = .seconds(5),
        allowed: Set<UUID> = [taskID],
        schema: String = #"{"type":"object"}"#,
        cadence: ReportCadence = .daily
    ) -> StandupRequest {
        StandupRequest(
            modelID: "claude-sonnet-5",
            cadence: cadence,
            systemPrompt: "system",
            userPrompt: "user",
            outputSchema: AIOutputSchema(name: "daily", json: Data(schema.utf8)),
            allowedTaskIDs: allowed,
            maxOutputTokens: 1024,
            timeout: timeout
        )
    }

    /// A `/v1/messages` response whose text block is §7.3's `daily` JSON.
    static func draftResponse(
        taskID: UUID = taskID,
        stopReason: String = "end_turn",
        status: Int = 200
    ) -> HTTPResponse {
        let draft = """
            {"since_last_standup":[{"task_id":"\(taskID.uuidString)",\
            "text":"fixed the flaky auth test"}],"today":[],"blockers":[]}
            """
        // The text block holds §7.3's JSON *as a string*, so the envelope is
        // serialized rather than hand-written: escaping it by hand is one
        // backslash away from a fixture that tests the decoder's error path
        // while claiming to test its success path.
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": draft]],
            "stop_reason": stopReason,
            "usage": ["input_tokens": 120, "output_tokens": 45],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return HTTPResponse(status: status, body: body)
    }

    /// A `/v1/messages` response whose text block is §7.3's `periodic` JSON.
    ///
    /// D17's two cadences "are not cosmetic variants of each other" (§7.3):
    /// the sections differ and so does the cardinality of the task reference,
    /// so the provider's cadence switch needs both sides exercised.
    static func periodicDraftResponse(taskIDs: [UUID] = [taskID]) -> HTTPResponse {
        let ids = taskIDs.map { "\"\($0.uuidString)\"" }.joined(separator: ",")
        let draft = """
            {"completed":[{"task_ids":[\(ids)],"text":"shipped the export encoder"}],\
            "in_flight":[],"blockers_and_risks":[]}
            """
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": draft]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 900, "output_tokens": 120],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return HTTPResponse(status: 200, body: body)
    }

    /// One page of `/v1/models`.
    static func modelsResponse(
        ids: [String],
        hasMore: Bool = false,
        lastID: String? = nil
    ) -> HTTPResponse {
        let models = ids.map { identifier in
            [
                "id": identifier,
                "display_name": identifier,
                "created_at": "2026-01-01T00:00:00Z",
            ]
        }
        var page: [String: Any] = ["data": models, "has_more": hasMore]
        if let lastID { page["last_id"] = lastID }

        let body = (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
        return HTTPResponse(status: 200, body: body)
    }
}
