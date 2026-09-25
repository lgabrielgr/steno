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

/// **A read that throws is not the same as no key, and the pane must not claim
/// it is.** A locked keychain's remedy is to unlock it, not to paste a new key
/// — so the no-key caption ("Steno still writes your stand-up from your log
/// alone") would be an affirmative falsehood about a key that exists.
@Test("a Keychain that cannot be read says so rather than claiming no key")
@MainActor
func anUnreadableKeychainSaysSo() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore(failing: KeychainError.interactionNotAllowed)

    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: store, settings: settings)

    #expect(model.hasStoredKey == false)
    #expect(model.keyProblem?.contains("interactionNotAllowed") == true)
    #expect(model.keyProblem?.contains("could not read") == true)
    // **Not `.absent`, and not `.noKey`.** Both the readiness line and the row
    // under the field would otherwise tell a user whose keychain is merely
    // locked that no key exists, and send them to paste another one — the one
    // remedy that cannot work. Raised by Copilot on PR #41.
    #expect(model.storedKey == .unreadable("interactionNotAllowed"))
    #expect(model.readiness == .keyUnreadable)
}

/// §8, and the narrowing `ModelsSelftest.describe` already does: the `catch`
/// binds `any Error`, not `KeychainError`, and an arbitrary error's description
/// can quote the value it was handed — which here is the credential.
@Test("a store failure that quotes the credential is not rendered")
@MainActor
func aLeakyStoreFailureIsNotRendered() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore(failing: LeakyStoreFailure())
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: store, settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    let problem = try #require(model.keyProblem)
    #expect(problem.contains("sk-ant-leaked-value") == false)
    #expect(problem.contains("LeakyStoreFailure"))
    #expect(model.hasStoredKey == false)
}

/// D-157 promises the field is empty on every *appearance*, not merely on
/// construction — and this model is built once in `StenoApp.init` and held for
/// the process, so a typed-but-unsaved key would still be in the field when the
/// window reopened.
@Test("forgetting the entry clears a typed but unsaved key")
@MainActor
func forgettingTheEntryClearsIt() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: InMemoryCredentialStore(), settings: settings)

    model.keyEntry = "sk-ant-typed-never-saved"
    model.forgetEntry()

    #expect(model.keyEntry.isEmpty)
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

/// **The flag has to be true while the work is in flight, which is the only
/// part worth testing.** A test that awaited `saveKey()` and then asserted
/// `isSavingKey == false` would pass against a flag that was never set at all —
/// and the pane would show no spinner for the one button here that waits on the
/// network.
///
/// The stub holds for 200 ms so there is a window to observe, and the loop
/// yields until the flag flips rather than sleeping a fixed time: a `Task` has
/// not started when the function that created it returns.
@Test("a save reports itself as in flight, and stops when it finishes")
@MainActor
func aSaveReportsItselfInFlight() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet]), delay: .milliseconds(200))],
        credentials: InMemoryCredentialStore(), settings: settings)

    model.keyEntry = "sk-ant-test-key"
    #expect(model.isSavingKey == false)
    #expect(model.isBusy == false)

    let save = Task { await model.saveKey() }

    var spins = 0
    while !model.isSavingKey && spins < 10_000 {
        await Task.yield()
        spins += 1
    }

    #expect(model.isSavingKey, "the save never reported itself in flight")
    #expect(model.isBusy, "isBusy must cover a save, or the buttons stay live during one")

    await save.value

    #expect(model.isSavingKey == false)
    #expect(model.isBusy == false)
    #expect(settings.aiSelectedModelID == aiSonnet.id)
}

/// **Return in the key field is reachable while another call is in flight**, so
/// the guard cannot live only on the buttons: a keystroke could otherwise start
/// a save whose fetch raced a refresh, leaving `models` set by whichever
/// finished last. Raised by Copilot on PR #41.
@Test("a save refuses to start while another call is in flight")
@MainActor
func aSaveRefusesWhileBusy() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet]), delay: .milliseconds(200))],
        credentials: store, settings: settings)

    let refresh = Task { await model.refreshModels() }
    var spins = 0
    while model.listState != .loading && spins < 10_000 {
        await Task.yield()
        spins += 1
    }
    #expect(model.listState == .loading, "the refresh never started")

    // What Return does while that is in flight.
    model.keyEntry = "sk-ant-typed-during-a-refresh"
    await model.saveKey()

    #expect(store.contents.isEmpty, "the save started underneath a refresh")
    #expect(model.isSavingKey == false)
    #expect(model.keyEntry == "sk-ant-typed-during-a-refresh", "the entry must survive a refusal")

    await refresh.value
    #expect(model.models == [aiSonnet])
}

/// Deleting what is not there is success, not failure — the caller asked for an
/// end state, and that end state holds.
///
/// **The second provider's credential is what makes this test able to fail.**
/// Both assertions about *this* provider already hold before `removeKey()` runs,
/// so a `removeKey` that did nothing at all would pass them; what cannot pass is
/// a delete routed to the wrong provider id.
@Test("removing an absent key is not an error, and touches no other provider")
@MainActor
func removingAnAbsentKeyIsFine() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    try store.store(.apiKey("sk-ant-other-provider"), for: "second")
    let model = AISettingsModel(
        providers: [
            StubAIProvider(id: "first"), StubAIProvider(id: "second"),
        ], credentials: store, settings: settings)

    model.removeKey()

    #expect(model.keyProblem == nil)
    #expect(model.hasStoredKey == false)
    #expect(store.contents["second"] == .apiKey("sk-ant-other-provider"))
}
