import Foundation
import Testing

@testable import StenoKit

/// Shared by the AI pane's two test files.
///
/// They are split because one file covering key handling *and* the model list
/// runs past SwiftLint's 400-line limit — and the two halves are separate
/// subjects anyway: §8's credential rules, and D-158/D-159's list behaviour.

@MainActor
func scratchAISettings() throws -> (AppSettings, UserDefaults) {
    // `try #require`, never `!` — `force_unwrapping` is an enabled opt-in rule
    // and `--strict` promotes it to a build failure.
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return (AppSettings(defaults: defaults), defaults)
}

let aiSonnet = AIModel(id: "claude-sonnet-9", displayName: "Claude Sonnet 9")
let aiHaiku = AIModel(id: "claude-haiku-9", displayName: "Claude Haiku 9")

/// A provider that breaks `AIProvider`'s contract by throwing something other
/// than an `AIError`.
///
/// It exists so the model's catch-all is executed rather than asserted: the
/// contract says only `AIError` escapes, and what this pane does when a future
/// provider gets that wrong should be a tested answer rather than a hope.
struct DefectiveAIProvider: AIProvider {
    struct Defect: Error {}

    let id = "defective"
    let displayName = "Defective"

    func availableModels() async throws -> [AIModel] { throw Defect() }
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft { throw Defect() }
    func testConnection() async throws { throw Defect() }
}
