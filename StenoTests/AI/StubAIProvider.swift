import Foundation

@testable import StenoKit

/// The §9.4 test double: an `AIProvider` that answers from a script.
///
/// **Scripting failure is its main job, not an afterthought.** M3-02 needs a
/// provider that hangs in order to test its timeout budget, and M3-03 needs one
/// that throws each `AIError` case in order to test §7.4's fallback — which is
/// the requirement that must never arrive at a stand-up empty-handed. A double
/// that could only succeed would leave both untested.
///
/// An `actor` rather than a lock-guarded class: `AIProvider` is `Sendable`, its
/// methods are `async`, and `Mutex` needs macOS 15 where this project's floor is
/// 14 (D2).
actor StubAIProvider: AIProvider {
    nonisolated let id: String
    nonisolated let displayName: String

    private let models: Result<[AIModel], AIError>
    private let draft: Result<StandupDraft, AIError>
    private let connection: Result<Void, AIError>

    /// Held before answering, so a caller's timeout can be exercised.
    private let delay: Duration?

    /// Every request this provider was asked to answer, in order.
    private(set) var received: [StandupRequest] = []

    init(
        id: String = "stub",
        displayName: String = "Stub Provider",
        models: Result<[AIModel], AIError> = .success([]),
        draft: Result<StandupDraft, AIError> = .failure(.notConfigured),
        connection: Result<Void, AIError> = .success(()),
        delay: Duration? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.draft = draft
        self.connection = connection
        self.delay = delay
    }

    func availableModels() async throws -> [AIModel] {
        try await hold()
        return try models.get()
    }

    /// Records the request **before** it can fail, so a test of a failing
    /// provider can still assert what was sent to it.
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        received.append(request)
        try await hold()
        return try draft.get()
    }

    func testConnection() async throws {
        try await hold()
        try connection.get()
    }

    private func hold() async throws {
        guard let delay else { return }
        try await Task.sleep(for: delay)
    }
}
