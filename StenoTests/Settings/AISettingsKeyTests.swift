import Foundation
import Testing

@testable import StenoKit

// §8's half of FR-6's AI pane: what happens to the credential.
//
// Every test drives the model directly — the pane holds no rule (D-010) — and
// awaits each action rather than starting it, because a `Task` has not run
// when the function that created it returns.

// MARK: - The key

@Test("a saved key is trimmed, stored, and never kept in the field")
@MainActor
func savingAKeyStoresItAndClearsTheField() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet]))],
        credentials: store, settings: settings)

    // The shape a paste from a web page actually has.
    model.keyEntry = "  sk-ant-test-key\n"
    await model.saveKey()

    #expect(store.contents["stub"] == .apiKey("sk-ant-test-key"))
    #expect(model.keyEntry.isEmpty)
    #expect(model.hasStoredKey)
    #expect(model.keyProblem == nil)
}

/// **The blank entry is the one that must change nothing.** A Save that
/// reported success for an empty field would leave a user believing the AI is
/// configured until the next stand-up quietly came back raw.
@Test("a blank key stores nothing and configures nothing")
@MainActor
func aBlankKeyStoresNothing() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet]))],
        credentials: store, settings: settings)

    model.keyEntry = "   \n "
    await model.saveKey()

    #expect(store.contents.isEmpty)
    #expect(model.hasStoredKey == false)
    #expect(settings.aiSelectedModelID == nil)
    #expect(model.listState == .idle)
}

@Test("a Keychain that refuses the write says so and configures nothing")
@MainActor
func aRefusedWriteIsReported() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore(failing: KeychainError.interactionNotAllowed)
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet]))],
        credentials: store, settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    #expect(model.hasStoredKey == false)
    #expect(model.keyProblem?.contains("interactionNotAllowed") == true)
    // No fetch followed the failed write: the list was never asked for.
    #expect(model.listState == .idle)
    #expect(settings.aiSelectedModelID == nil)
}

/// §8: the key is never displayed after entry. The pane has no path to the
/// stored value at all — `hasStoredKey` is a `Bool` — so this asserts the
/// property the type is built on rather than a string on screen.
@Test("an existing key is reported as present and never read back")
@MainActor
func anExistingKeyIsPresentButNotLoaded() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    try store.store(.apiKey("sk-ant-already-here"), for: "stub")

    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: store, settings: settings)

    #expect(model.hasStoredKey)
    #expect(model.keyEntry.isEmpty)
}

/// A Keychain read that throws reads as "nothing stored", the posture
/// `AnthropicProvider.apiKey()` already takes: the remedy is the one an absent
/// key already asks for.
@Test("a Keychain that cannot be read reports no key rather than trapping")
@MainActor
func anUnreadableKeychainReportsNoKey() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore(failing: KeychainError.interactionNotAllowed)

    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: store, settings: settings)

    #expect(model.hasStoredKey == false)
}

@Test("removing a key deletes it and keeps the selected model")
@MainActor
func removingAKeyKeepsTheModel() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: store, settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()
    #expect(settings.aiSelectedModelID == aiSonnet.id)

    model.removeKey()

    #expect(store.contents.isEmpty)
    #expect(model.hasStoredKey == false)
    #expect(model.models.isEmpty)
    // D-157: a model id is not a secret, and re-entering a key must restore the
    // previous behaviour with nothing to redo.
    #expect(settings.aiSelectedModelID == aiSonnet.id)
    #expect(model.selectedModelID == aiSonnet.id)
}

/// Deleting what is not there is success, not failure — the caller asked for an
/// end state, and that end state holds.
@Test("removing a key that was never stored is not an error")
@MainActor
func removingAnAbsentKeyIsFine() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: InMemoryCredentialStore(), settings: settings)

    model.removeKey()

    #expect(model.keyProblem == nil)
    #expect(model.hasStoredKey == false)
}
