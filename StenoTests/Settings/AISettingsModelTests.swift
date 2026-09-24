import Foundation
import Testing

@testable import StenoKit

// D-158 and D-159's half of FR-6's AI pane: the model list, the connection
// test, and the provider picker.

// MARK: - The model list

@Test("saving a key adopts the provider's recommended model")
@MainActor
func savingAKeyAdoptsElementZero() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    // D-141: element zero is the provider's recommended default, and D-159
    // makes saving a key the act that consumes it.
    #expect(settings.aiSelectedModelID == aiSonnet.id)
    #expect(model.selectedModelID == aiSonnet.id)
    #expect(model.models == [aiSonnet, aiHaiku])
}

@Test("saving a key leaves a selection the provider still offers")
@MainActor
func savingAKeyKeepsAStillOfferedSelection() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = aiHaiku.id
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    #expect(settings.aiSelectedModelID == aiHaiku.id)
}

@Test("saving a key re-points a selection the provider no longer offers")
@MainActor
func savingAKeyRepointsARetiredSelection() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = "claude-sonnet-1-retired"
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    #expect(settings.aiSelectedModelID == aiSonnet.id)
}

/// An empty list is legitimate — §7.1 calls it "a key with access to nothing" —
/// and must not clear a selection that already works.
@Test("a key whose list comes back empty changes no selection")
@MainActor
func anEmptyListChangesNothing() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = aiHaiku.id
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    #expect(settings.aiSelectedModelID == aiHaiku.id)
    #expect(model.modelRows.map(\.id) == [aiHaiku.id])
}

/// The second acceptance criterion: an unreachable model list must not block
/// using a previously selected model.
@Test("a failed fetch keeps the key, the selection, and the previous rows")
@MainActor
func aFailedFetchKeepsEverything() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = aiHaiku.id
    let store = InMemoryCredentialStore()
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .failure(.network))],
        credentials: store, settings: settings)

    model.keyEntry = "sk-ant-test-key"
    await model.saveKey()

    #expect(store.contents["stub"] == .apiKey("sk-ant-test-key"))
    #expect(model.hasStoredKey)
    #expect(model.listState == .failed(.network))
    #expect(model.listAdvice == .tryAgainLater)
    #expect(settings.aiSelectedModelID == aiHaiku.id)
    #expect(model.modelRows.map(\.id) == [aiHaiku.id])
    #expect(model.selectionIsUnlisted)
}

/// D-158's visible consequence: with no fetch yet, the picker still offers the
/// stored model, so the user can keep using it.
@Test("before any fetch the stored model is the only row")
@MainActor
func theStoredModelIsARowBeforeAnyFetch() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = aiSonnet.id
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiHaiku]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    #expect(model.listState == .idle)
    #expect(model.modelRows.map(\.id) == [aiSonnet.id])
    #expect(model.selectionIsUnlisted)
}

/// **A refresh never re-points the selection**, which is the boundary between
/// D-158 and D-159: only saving a key adopts a default, because silently moving
/// a user onto a different model is the one thing a picker must not do alone.
@Test("a refresh that no longer offers the selection keeps it, unlisted")
@MainActor
func aRefreshKeepsAnUnofferedSelection() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = "claude-sonnet-1-retired"
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    await model.refreshModels()

    #expect(settings.aiSelectedModelID == "claude-sonnet-1-retired")
    #expect(model.selectionIsUnlisted)
    #expect(model.modelRows.map(\.id) == ["claude-sonnet-1-retired", aiSonnet.id, aiHaiku.id])
}

/// **`selectionIsUnlisted` is true in three different situations and only one
/// of them means "we have not asked yet".** The pane's caption said so
/// unconditionally, which contradicted this file's own retired-model test: a
/// refresh that succeeds and no longer offers the selection was told the list
/// had not been fetched, and pressing Refresh again changed nothing.
@Test("the reason a selection is unlisted is distinguishable")
@MainActor
func theReasonASelectionIsUnlistedIsDistinguishable() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = "claude-sonnet-1-retired"
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([aiSonnet, aiHaiku]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    // Nothing fetched yet: D-158's ordinary state.
    #expect(model.selectionStatus == .notFetchedYet)

    await model.refreshModels()

    // The list arrived and does not contain it: the model is gone, and saying
    // "not fetched yet" here sends the user to a button that cannot help.
    #expect(model.selectionStatus == .noLongerOffered)

    model.select(modelID: aiSonnet.id)
    #expect(model.selectionStatus == .offered)
}

/// **An empty list that arrived is not the same as no list.** §7.1 calls an
/// empty result legitimate — "a key with access to nothing" — and it leaves
/// `models` empty, which is indistinguishable from "never fetched" if the only
/// evidence is the array. The pane would then tell a user whose key has access
/// to nothing to press Refresh, forever. Raised by Copilot on PR #38.
@Test("a successful fetch that returns nothing is not reported as never fetched")
@MainActor
func anEmptySuccessfulFetchIsNotNeverFetched() async throws {
    let (settings, _) = try scratchAISettings()
    settings.aiSelectedModelID = aiHaiku.id
    let model = AISettingsModel(
        providers: [StubAIProvider(models: .success([]))],
        credentials: InMemoryCredentialStore(), settings: settings)

    #expect(model.selectionStatus == .notFetchedYet)

    await model.refreshModels()

    #expect(model.selectionStatus == .noLongerOffered)

    // Removing the key takes the answer away again: what a provider offered is
    // an answer about a credential that no longer exists.
    model.removeKey()
    #expect(model.selectionStatus == .notFetchedYet)
}

@Test("a selection is not reported as unlisted when there is none")
@MainActor
func noSelectionIsNotUnlisted() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: InMemoryCredentialStore(), settings: settings)

    #expect(model.selectionStatus == .none)
    #expect(model.selectionIsUnlisted == false)
}

@Test("choosing a model writes it where the stand-up path reads it")
@MainActor
func choosingAModelWritesThrough() async throws {
    let (settings, defaults) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: InMemoryCredentialStore(), settings: settings)

    model.select(modelID: aiHaiku.id)

    #expect(model.selectedModelID == aiHaiku.id)
    #expect(defaults.string(forKey: AppSettings.aiSelectedModelIDKey) == aiHaiku.id)
}

// MARK: - Readiness

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
    #expect(model.readiness == .noModel)
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

// MARK: - Test connection

/// The third acceptance criterion, and the reason `AIError` separates these two
/// cases at all: the user needs to know which.
@Test("a rejected key and an unreachable network are told apart")
@MainActor
func testConnectionDistinguishesTheTwoFailures() async throws {
    let (settings, _) = try scratchAISettings()

    let rejected = AISettingsModel(
        providers: [StubAIProvider(connection: .failure(.invalidCredential))],
        credentials: InMemoryCredentialStore(), settings: settings)
    await rejected.testConnection()

    let offline = AISettingsModel(
        providers: [StubAIProvider(connection: .failure(.network))],
        credentials: InMemoryCredentialStore(), settings: settings)
    await offline.testConnection()

    #expect(rejected.connection == .failed(.invalidCredential))
    #expect(rejected.connectionAdvice == .fixTheKey)
    #expect(offline.connection == .failed(.network))
    #expect(offline.connectionAdvice == .tryAgainLater)
}

@Test("a working key passes and offers no advice")
@MainActor
func testConnectionPasses() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider(connection: .success(()))],
        credentials: InMemoryCredentialStore(), settings: settings)

    await model.testConnection()

    #expect(model.connection == .passed)
    #expect(model.connectionAdvice == nil)
    #expect(model.isBusy == false)
}

/// `AIProvider`'s contract is that only `AIError` escapes. A provider that
/// breaks it must not take the pane with it.
@Test("a provider that throws the wrong error type degrades rather than crashing")
@MainActor
func aDefectiveProviderDegrades() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [DefectiveAIProvider()], credentials: InMemoryCredentialStore(),
        settings: settings)

    await model.refreshModels()
    await model.testConnection()

    #expect(model.listState == .failed(.network))
    #expect(model.connection == .failed(.network))
}

// MARK: - Providers

/// D-160: the abstraction is exercised rather than asserted. With two providers
/// the picker's selection has to actually route the next call.
@Test("switching provider routes the next fetch and clears the old answers")
@MainActor
func switchingProviderRoutesAndClears() async throws {
    let (settings, _) = try scratchAISettings()
    let store = InMemoryCredentialStore()
    try store.store(.apiKey("sk-ant-first"), for: "first")

    let model = AISettingsModel(
        providers: [
            StubAIProvider(id: "first", displayName: "First", models: .success([aiSonnet])),
            StubAIProvider(id: "second", displayName: "Second", models: .success([aiHaiku])),
        ],
        credentials: store, settings: settings)

    #expect(model.selectedProviderID == "first")
    #expect(model.hasStoredKey)
    await model.refreshModels()
    #expect(model.models == [aiSonnet])

    model.selectedProviderID = "second"

    // Everything that belonged to the first provider is gone: a model list and
    // a stored key are answers about one vendor.
    #expect(model.models.isEmpty)
    #expect(model.hasStoredKey == false)
    #expect(model.connection == .untested)

    await model.refreshModels()
    #expect(model.models == [aiHaiku])
    #expect(model.providerChoices.map(\.name) == ["First", "Second"])
}

/// §7.2 ships the API key path only, and D-136 made that rule readable from
/// code rather than from a doc comment a future UI author has to find.
@Test("only the API key is offered as a credential kind")
@MainActor
func onlyTheAPIKeyIsOffered() async throws {
    let (settings, _) = try scratchAISettings()
    let model = AISettingsModel(
        providers: [StubAIProvider()], credentials: InMemoryCredentialStore(), settings: settings)

    #expect(model.credentialKinds == [.apiKey])
}
