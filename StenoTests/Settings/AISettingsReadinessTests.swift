import Foundation
import Testing

@testable import StenoKit

// The pane's headline claim: whether the AI will actually run. Split from
// AISettingsModelTests so both files stay under SwiftLint's 400-line limit.

/// **The line the pane leads with, and it must agree with what actually runs.**
/// `MainWindowModel.standupPolish` reads exactly these two things — a credential
/// in the Keychain and `aiSelectedModelID` — so a pane that said "on" from
/// different evidence would be telling the user their stand-ups are polished
/// while §7.4's raw path quietly produced them.
@Test("readiness tracks the two conditions the stand-up path actually reads")
@MainActor
func readinessTracksTheStandupPath() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: store, settings: settings)

    #expect(model.readiness == .noKey)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    // The save adopted element zero (D-159), so both conditions now hold — and
    // the line names what the picker shows, not the raw id.
    #expect(model.readiness == .ready(model: aiSonnet.displayName))

    model.removeKey()
    #expect(model.readiness == .noKey)
}

/// A key stored while offline leaves no selection (D-159), and that state has
/// its own sentence: the remedy is Refresh, not another key.
@Test("a stored key with no model selected is its own state")
@MainActor
func aStoredKeyWithNoModelIsItsOwnState() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .failure(.network))],
        credentials: store, settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    #expect(model.hasStoredKey)
    #expect(model.readiness == .noModel(remedy: .fetchTheList))
}

/// **A refresh that succeeds changes the remedy, not the state.** D-159 keeps
/// adoption on the save path only, so a successful refresh leaves a populated
/// picker with nothing selected — and a line still saying "press Refresh
/// Models" is a loop with no exit. Raised by Copilot on PR #41.
@Test("once a list arrives, the remedy becomes choosing rather than refreshing")
@MainActor
func theRemedyChangesOnceAListArrives() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    try store.store(.apiKey("sk-ant-already-here"), for: "stub")
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: store, settings: settings)

    #expect(model.readiness == .noModel(remedy: .fetchTheList))

    await model.refreshModels()

    #expect(model.models == [aiSonnet, aiHaiku])
    #expect(model.selectedModelID == nil, "a refresh must not adopt a default (D-159)")
    #expect(model.readiness == .noModel(remedy: .chooseOne))
}

/// Before any fetch there is no display name to show, and the id is what the
/// picker shows too — so the line says the same thing the row says.
@Test("readiness falls back to the model id when no list has been fetched")
@MainActor
func readinessFallsBackToTheID() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = "claude-sonnet-1-retired"
    let store = InMemoryCredentialStore()
    try store.store(.apiKey("sk-ant-already-here"), for: "stub")
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: store, settings: settings)

    #expect(model.readiness == .ready(model: "claude-sonnet-1-retired"))
}

/// **The third way "no model" happens, and Refresh cannot fix it.** §7.1 calls
/// an empty list legitimate — "a key with access to nothing" — so a successful
/// refresh can leave both the picker and `models` empty. Reading that state off
/// `models.isEmpty` gave the same advice as "never fetched", which sent the
/// user into a refresh loop that could never end. Raised by Copilot on PR #41.
@Test("a key that can use no models is told so, not told to refresh")
@MainActor
func aKeyWithNoModelsIsToldSo() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    try store.store(.apiKey("sk-ant-already-here"), for: "stub")
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([]))],
        credentials: store, settings: settings)

    // Before asking, the remedy is to ask.
    #expect(model.readiness == .noModel(remedy: .fetchTheList))

    await model.refreshModels()

    // After asking and being offered nothing, it is not.
    #expect(model.models.isEmpty)
    #expect(model.hasFetchedModels)
    #expect(model.readiness == .noModel(remedy: .noneOffered))
}
