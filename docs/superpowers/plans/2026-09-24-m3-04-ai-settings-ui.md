# M3-04 — AI Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship FR-6's AI pane — provider picker, Keychain-backed key field, runtime model picker, "Test connection", and §8's data-transmission disclosure — plus `make verify-models`, so M3's AI path becomes reachable in a running build.

**Architecture:** One `@Observable @MainActor` view model in `StenoKit` holds every rule; the SwiftUI pane in `Steno/` arranges controls and owns none, because the unhosted test bundle cannot reach the app target (D-010). The model takes an injected `[any AIProvider]`, `CredentialStore` and `AppSettings`, so `make test` never touches the login Keychain, the network, or the developer's preferences. A hidden `steno models-selftest` subcommand exercises the real `URLSessionTransport` against the live API on a human's command.

**Tech Stack:** Swift 6, SwiftUI (`Settings` scene, `Form`), Swift Testing (`@Test`/`#expect`), SwiftData (untouched here), `Security.framework` via the existing `KeychainCredentialStore`, xcodegen + make.

**Spec:** [`docs/superpowers/specs/2026-09-24-m3-04-ai-settings-ui-design.md`](../specs/2026-09-24-m3-04-ai-settings-ui-design.md)

## Global Constraints

- **Branch `feat/ai-settings-ui`; never commit to `main`; open a PR and stop** (CLAUDE.md, §9.5).
- **`make build && make test && make lint` must all pass before the PR** (§9.5 step 4, §13).
- **`make test` runs with outbound networking denied** (§9.4, D-012) and must never touch the real Keychain (D-134) or `UserDefaults.standard` (§9.4) — inject `InMemoryCredentialStore` and a scratch suite.
- **The key is never displayed after entry and never logged** (§8). The pane reads no credential *value*: `hasStoredKey` is a `Bool` (D-157).
- **`AppSettings.allKeys` does not change.** `aiSelectedModelIDKey` already exists; adding a key would change the count `AISecretsTests` asserts.
- **SwiftLint `--strict`:** no identifier shorter than 3 characters (`case ai` is rejected — use `aiProvider`), files ≤ 400 lines, no orphaned `///` doc comments, no force unwrapping (`try #require`, never `!`).
- **`make format` runs before committing**; CI fails on a formatting diff (D-075).
- **New decisions are D-157 … D-161.** `DECISIONS.md`'s current maximum is D-156 — check it, never infer it from a sibling spec.
- **Every new test is mutation-verified**: break the line it covers, watch that test go red, restore. A test that cannot fail is not a test.

## Review Focus

The five inputs the spec implies but that no acceptance criterion names. Each has a test in the task that owns the code.

1. **A key pasted with a trailing newline** — the common case, since keys are copied from a web page. Trim before storing, or the API rejects a key the user can see is correct. (Task 1, `a saved key is trimmed…`)
2. **A locked or refusing Keychain** — `errSecInteractionNotAllowed` is reachable on a real Mac. The pane must say so and must not report a key as stored. (Task 1, `a Keychain that refuses the write…`)
3. **A model list that comes back empty** — legitimate per §7.1 ("a key with access to nothing") and must not clear a working selection. (Task 1, `a key whose list comes back empty…`)
4. **A provider that throws something other than an `AIError`** — a contract violation by a future provider must degrade, not crash the pane. (Task 1, `a provider that throws the wrong error type…`)
5. **An error whose description quotes a response body** — the selftest prints failures to a terminal and its scrollback, so an arbitrary error must be reported by type, never by description (§8). (Task 3, `an unexpected error is reported by type…`)

---

### Task 1: `AISettingsModel` — every rule the pane obeys

**Files:**
- Create: `StenoKit/Features/Settings/AISettingsModel.swift`
- Create: `StenoTests/Settings/AISettingsFixtures.swift`
- Create: `StenoTests/Settings/AISettingsKeyTests.swift`
- Create: `StenoTests/Settings/AISettingsModelTests.swift`

**Interfaces:**
- Consumes: `AIProvider`, `AIModel`, `AIError`, `Credential`, `CredentialKind`, `CredentialStore`, `KeychainCredentialStore`, `AppSettings.aiSelectedModelID`, `Log.app` — all already in `StenoKit`. Tests consume `StubAIProvider` and `InMemoryCredentialStore` from `StenoTests/AI/`.
- Produces: `AISettingsModel(providers:credentials:settings:)`; properties `keyEntry`, `hasStoredKey`, `keyProblem`, `models`, `listState`, `selectedModelID`, `connection`, `selectedProviderID`, `providerChoices`, `credentialKinds`, `modelRows`, `selectionIsUnlisted`, `isBusy`, `listAdvice`, `connectionAdvice`; methods `saveKey() async`, `refreshModels() async`, `testConnection() async`, `removeKey()`, `select(modelID:)`; nested `ListState`, `ConnectionState`, `Advice`. Task 2's pane binds to all of it.

- [ ] **Step 1: Write the shared fixtures**

These are `internal`, not `private`, because two test files share them — and the two files exist because one file covering both halves runs past SwiftLint's 400-line limit.

```swift
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
```

- [ ] **Step 2: Write the failing key tests**

```swift
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
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'AISettingsModel' in scope`. (`make test` regenerates `Steno.xcodeproj`, so new files are picked up automatically; it also prints no line at all for parameterized cases, so absence is not failure.)

- [ ] **Step 4: Write the failing list, connection and provider tests**

```swift
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
```

- [ ] **Step 5: Write the model**

```swift
import Foundation

/// What the Settings window's AI pane binds to (FR-6, §7.1, §7.2, §7.4, §8).
///
/// **This is the type that makes M3 reachable.** M3-01 built the seam, M3-02
/// the transport, M3-03 the prompt and §7.4's fallback — and all three shipped
/// into a build where the AI path could never run, because nothing wrote a key
/// into the Keychain and nothing wrote `AppSettings.aiSelectedModelID`. Those
/// two writes are this type; `MainWindowModel.standupPolish` already reads both
/// per call, so a key saved here is live without a relaunch.
///
/// Built once in `StenoApp.init` and held for the process, the posture
/// `SettingsModel` and `DataSettingsModel` already take: the `Settings` scene's
/// content is rebuilt freely by SwiftUI and the state behind it must not be.
///
/// **It has no store dependency and therefore no `storeFailureNote`.** Both
/// sibling panes carry one because a failed store takes their subject away; a
/// credential lives in the Keychain and a model id in `UserDefaults`, so this
/// pane is fully functional in a build whose store will not open. The absence
/// is deliberate, not an omission against two siblings that have one.
@Observable
@MainActor
public final class AISettingsModel {
    /// Where the model list stands. `models` is what was fetched; this is
    /// whether asking worked.
    public enum ListState: Equatable, Sendable {
        case idle
        case loading
        case failed(AIError)
    }

    /// Where "Test connection" stands.
    public enum ConnectionState: Equatable, Sendable {
        case untested
        case testing
        case passed
        case failed(AIError)
    }

    /// What the user can do about a failure.
    ///
    /// **Lives here rather than in the pane's `if` statements** for
    /// `DataSettingsModel.canBackUpNow`'s reason: the unhosted test bundle
    /// cannot reach the app target (D-010), so a rule only a view knows is a
    /// rule no test can hold. The third acceptance criterion — "Test
    /// connection" distinguishes an invalid key from a network failure — is
    /// exactly such a rule.
    public enum Advice: Equatable, Sendable {
        /// The key is wrong or missing. The field above is the fix.
        case fixTheKey
        /// Nothing here is wrong. Try again later.
        case tryAgainLater
    }

    // MARK: - Key entry

    /// The `SecureField`'s binding — **what the user is typing, never what is
    /// stored** (D-157).
    ///
    /// It starts empty on every appearance, including when a key is already in
    /// the Keychain, and `saveKey()` clears it the instant the write succeeds.
    /// Nothing in this type reads a credential's *value*; the only Keychain
    /// read it performs is the presence check behind `hasStoredKey`, whose
    /// result is a `Bool`. That is what makes "the key is never displayed in
    /// full after entry" a property of this code rather than of AppKit's
    /// secure-entry behaviour.
    public var keyEntry: String = ""

    /// Whether a credential exists for the selected provider.
    public private(set) var hasStoredKey: Bool = false

    /// Why the last store or delete was refused, if it was.
    ///
    /// Carries the `KeychainError`'s own description: it is an `OSStatus` and a
    /// case name, never the credential, so §8 is not engaged — and a bare
    /// "could not save" would leave a user with no way to tell a locked
    /// keychain from a bug.
    public private(set) var keyProblem: String?

    // MARK: - Models

    /// The last successfully fetched list, ordered by the provider (D-141).
    public private(set) var models: [AIModel] = []

    public private(set) var listState: ListState = .idle

    /// The user's choice, mirrored from `AppSettings` and written through.
    public private(set) var selectedModelID: String?

    // MARK: - Connection

    public private(set) var connection: ConnectionState = .untested

    // MARK: - Providers

    /// Which provider the pane is configuring (D-160).
    ///
    /// **Held in memory and persisted nowhere.** Only Anthropic ships, and a
    /// setting with one possible value is the field D-141 already refused: it
    /// would grow `AppSettings.allKeys`, which `AISecretsTests` counts, and
    /// hand a future task a stored value to honour or migrate. Switching
    /// clears everything that belonged to the previous provider, because a
    /// model list and a connection result are answers to a question about one
    /// vendor.
    public var selectedProviderID: String {
        didSet {
            guard oldValue != selectedProviderID else { return }
            models = []
            listState = .idle
            connection = .untested
            keyProblem = nil
            keyEntry = ""
            hasStoredKey = storedKeyExists()
        }
    }

    /// The picker's rows: every provider that ships, in order.
    public var providerChoices: [(id: String, name: String)] {
        providers.map { (id: $0.id, name: $0.displayName) }
    }

    /// §7.2: "surface API key as the **only enabled option** in Settings v1."
    ///
    /// Read from `CredentialKind.userSelectable` rather than `allCases`, which
    /// is what D-136 built it for. With one selectable kind the pane renders a
    /// label rather than a picker — a picker of one is a label — and the day
    /// `.oauth` becomes selectable this list grows without the pane changing.
    public var credentialKinds: [CredentialKind] { CredentialKind.userSelectable }

    // MARK: - Derived

    /// What the model picker shows.
    ///
    /// **The stored selection is always a row, even when the list does not
    /// contain it** — because it has not been fetched yet (D-158), because the
    /// network is unreachable, or because the vendor retired the model. This is
    /// the second acceptance criterion: an unreachable model list must not
    /// block using a previously selected model. The selection is never
    /// reassigned by a fetch that fails to mention it; `saveKey()` is the only
    /// path that re-points it, and only onto element zero (D-159).
    public var modelRows: [AIModel] {
        guard let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) else {
            return models
        }
        return [AIModel(id: selectedModelID, displayName: selectedModelID)] + models
    }

    /// Whether the selected model is a row the provider did not offer.
    ///
    /// Drives the pane's caption. `true` before the first fetch is the ordinary
    /// state under D-158, not an anomaly — which is why the caption says the
    /// list has not been fetched rather than that the model is gone.
    public var selectionIsUnlisted: Bool {
        guard let selectedModelID else { return false }
        return !models.contains { $0.id == selectedModelID }
    }

    /// Whether a network call is in flight. The pane disables its buttons on it.
    public var isBusy: Bool { listState == .loading || connection == .testing }

    /// What the user should do about the last failed fetch, if it failed.
    public var listAdvice: Advice? {
        guard case .failed(let error) = listState else { return nil }
        return Self.advice(for: error)
    }

    /// What the user should do about the last connection test, if it failed.
    public var connectionAdvice: Advice? {
        guard case .failed(let error) = connection else { return nil }
        return Self.advice(for: error)
    }

    /// The third acceptance criterion, as a function.
    ///
    /// `.invalidCredential` and `.notConfigured` point at the field above;
    /// everything else is not something this pane can fix. The *sentence* the
    /// user reads stays `AIError.errorDescription` — a second vocabulary here
    /// would be a second place for "the provider rejected this credential" to
    /// be worded, free to drift from the one M3-02 already ships.
    static func advice(for error: AIError) -> Advice {
        switch error {
        case .notConfigured, .invalidCredential:
            return .fixTheKey
        case .invalidRequest, .network, .timedOut, .rateLimited, .providerUnavailable,
            .invalidResponse, .unknownTaskIDs:
            return .tryAgainLater
        }
    }

    private let providers: [any AIProvider]
    private let credentials: any CredentialStore
    private let settings: AppSettings

    /// The provider the picker names, or `nil` only if this was built with an
    /// empty list — which production never does, and which a guard here turns
    /// into an inert pane rather than a crash.
    private var provider: (any AIProvider)? {
        providers.first { $0.id == selectedProviderID } ?? providers.first
    }

    /// - Parameters:
    ///   - providers: every provider that ships. One in production; the tests
    ///     pass two, which is what exercises §7.1's abstraction rather than
    ///     asserting it in a comment (D-160).
    ///   - credentials: injected so `make test` never writes into the
    ///     developer's login keychain (D-134).
    ///   - settings: injected so tests use a scratch suite rather than the
    ///     developer's own preferences (§9.4).
    public init(
        providers: [any AIProvider],
        credentials: any CredentialStore = KeychainCredentialStore(),
        settings: AppSettings = AppSettings()
    ) {
        self.providers = providers
        self.credentials = credentials
        self.settings = settings
        self.selectedProviderID = providers.first?.id ?? ""
        self.selectedModelID = settings.aiSelectedModelID
        self.hasStoredKey = Self.storedKeyExists(
            in: credentials, for: providers.first?.id ?? "")
    }

    // MARK: - Actions

    /// Store what the user typed, then fetch the list and adopt a default.
    ///
    /// **`async`, and awaited by the pane inside a `Task`** — not a method that
    /// starts a detached task of its own. A `Task` has not started when the
    /// function that created it returns, so a test of the second shape can only
    /// poll; awaiting this directly removes the question.
    ///
    /// Whitespace is trimmed because the common way to produce a key is a paste
    /// from a web page, which brings a trailing newline with it; an all-blank
    /// entry stores nothing, since `UserDefaults`-shaped "it saved!" feedback
    /// for an empty key would be a lie the user only discovers at a stand-up.
    public func saveKey() async {
        guard let provider else { return }
        let trimmed = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try credentials.store(.apiKey(trimmed), for: provider.id)
        } catch {
            // The error, not a generic sentence: a `KeychainError` is an
            // `OSStatus` and a case name — never the credential — and
            // `errSecInteractionNotAllowed` (a locked keychain) needs a
            // different action from a bug in this app.
            keyProblem = "macOS refused to store the key: \(error)."
            return
        }

        keyProblem = nil
        keyEntry = ""
        hasStoredKey = true
        connection = .untested
        await fetchModels(adoptingRecommendedDefault: true)
    }

    /// Fetch the list on the user's explicit request (D-158).
    ///
    /// **Does not re-point the selection.** A refresh that no longer offers the
    /// selected model leaves it selected and unlisted — the pane says so — because
    /// silently moving a user onto a different model is the one thing a picker
    /// must never do on its own.
    public func refreshModels() async {
        await fetchModels(adoptingRecommendedDefault: false)
    }

    /// §7.1's "Test connection".
    ///
    /// Calls the provider's own `testConnection()` rather than
    /// `availableModels()`: how a provider verifies a credential is its
    /// business, and a second provider may answer this question a cheaper way.
    /// It therefore populates no rows — "Refresh models" is what fills the
    /// picker.
    public func testConnection() async {
        guard let provider else { return }
        connection = .testing
        do {
            try await provider.testConnection()
            connection = .passed
        } catch {
            connection = .failed(Self.presentable(error))
        }
    }

    /// Delete the stored credential (§8's only removal path in the UI).
    ///
    /// **`aiSelectedModelID` is left alone.** A model id is not a secret, the
    /// picker should not lose its place because a key was rotated, and
    /// re-entering a key restores the previous behaviour with nothing to redo.
    /// §7.4 covers the interval: the provider throws `.notConfigured` and the
    /// stand-up is M2-02's raw report.
    public func removeKey() {
        guard let provider else { return }
        do {
            try credentials.delete(for: provider.id)
        } catch {
            keyProblem = "macOS refused to remove the key: \(error)."
            return
        }
        keyProblem = nil
        keyEntry = ""
        hasStoredKey = false
        models = []
        listState = .idle
        connection = .untested
    }

    /// Record the user's choice (FR-6, §7.1).
    public func select(modelID: String) {
        selectedModelID = modelID
        settings.aiSelectedModelID = modelID
    }

    // MARK: - Plumbing

    private func fetchModels(adoptingRecommendedDefault adoptsDefault: Bool) async {
        guard let provider else { return }
        listState = .loading
        do {
            let fetched = try await provider.availableModels()
            models = fetched
            listState = .idle
            if adoptsDefault { adoptRecommendedModel(from: fetched) }
        } catch {
            // The list is left as it was. A failed fetch must not empty a
            // picker the user was about to use — and with no cache (D-158)
            // what it holds is either the previous fetch or nothing.
            listState = .failed(Self.presentable(error))
        }
    }

    /// D-159: element zero, and only when there is nothing usable selected.
    ///
    /// An empty list is not an error — §7.1 calls it "a key with access to
    /// nothing" — and it leaves the selection alone rather than clearing it.
    private func adoptRecommendedModel(from fetched: [AIModel]) {
        guard let recommended = fetched.first else { return }
        if let selectedModelID, fetched.contains(where: { $0.id == selectedModelID }) { return }
        select(modelID: recommended.id)
    }

    private func storedKeyExists() -> Bool {
        Self.storedKeyExists(in: credentials, for: selectedProviderID)
    }

    /// **A presence check whose answer is a `Bool`.** The `Credential` it reads
    /// is compared against `nil` and goes no further; nothing assigns it, and
    /// no property of this type can hold it (D-157).
    ///
    /// A Keychain read that throws reads as "nothing stored", the posture
    /// `AnthropicProvider.apiKey()` already takes: every remedy the user has is
    /// the one an absent key already asks for.
    private static func storedKeyExists(in store: any CredentialStore, for providerID: String)
        -> Bool
    {
        guard !providerID.isEmpty else { return false }
        return ((try? store.credential(for: providerID)) ?? nil) != nil
    }

    /// `AIProvider`'s contract is that an implementation throws `AIError` and
    /// nothing else. Anything else is a defect in that provider, so it is
    /// logged as a fault — by type name only, because an arbitrary error's
    /// description can quote a payload (§8) — and presented as `.network`,
    /// which is the reading §7.4 degrades most usefully from.
    private static func presentable(_ error: any Error) -> AIError {
        if let aiError = error as? AIError { return aiError }
        Log.app.fault(
            "AI provider threw a non-AIError: \(String(describing: type(of: error)), privacy: .public)"
        )
        return .network
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make test`
Expected: PASS. Confirm by name — `grep '✔' ` the output for "a saved key is trimmed", "before any fetch the stored model is the only row", "switching provider routes the next fetch and clears the old answers".

- [ ] **Step 7: Mutation-verify the new tests**

Apply each mutation, run `make test`, confirm the named test goes red (the runner reports failures as `⚠️ Test "<name>" recorded an issue`, not with a ✘), then restore. These seven were run against this code and each caught what it claims:

| Mutation in `AISettingsModel.swift` | Test that must go red |
|---|---|
| Drop `.trimmingCharacters(...)` and the `guard !trimmed.isEmpty` in `saveKey` | `a saved key is trimmed…`, `a blank key stores nothing…` |
| Delete the "already selected and still offered" early return in `adoptRecommendedModel` | `saving a key leaves a selection the provider still offers` |
| Delete `if adoptsDefault { adoptRecommendedModel(from: fetched) }` | `saving a key adopts the provider's recommended model` |
| Make `modelRows` `return models` unconditionally | `before any fetch the stored model is the only row`, `a failed fetch keeps the key…` |
| `listState = .idle` instead of `.failed(...)` in `fetchModels`'s catch | `a failed fetch keeps the key, the selection, and the previous rows` |
| Clear `settings.aiSelectedModelID` in `removeKey` | `removing a key deletes it and keeps the selected model` |
| Map `.invalidCredential` to `.tryAgainLater` in `advice(for:)` | `a rejected key and an unreachable network are told apart` |
| `storedKeyExists` returns `true` (then `false`) unconditionally | `a Keychain that cannot be read…` / `an existing key is reported as present…` |
| Strip the clearing block from `selectedProviderID`'s `didSet` | `switching provider routes the next fetch and clears the old answers` |
| `credentialKinds` returns `CredentialKind.allCases` | `only the API key is offered as a credential kind` |
| Drop `settings.aiSelectedModelID = modelID` from `select(modelID:)` | `choosing a model writes it where the stand-up path reads it` |
| `presentable` returns `.timedOut` for a non-`AIError` | `a provider that throws the wrong error type degrades rather than crashing` |
| `detail(for:)` returns `String(describing: error)` for a non-`KeychainError` | `a store failure that quotes the credential is not rendered` |
| The `.unreadable` arm of `init` sets no `keyProblem` | `a Keychain that cannot be read says so rather than claiming no key` |
| `selectionStatus` returns `.notFetchedYet` for every unlisted selection | `the reason a selection is unlisted is distinguishable` |
| `forgetEntry()` is a no-op | `forgetting the entry clears a typed but unsaved key` |
| `removeKey` deletes for `providers.last?.id` | `removing an absent key is not an error, and touches no other provider` |
| Clear the selection on an empty fetch in `adoptRecommendedModel` | `a key whose list comes back empty changes no selection` |

- [ ] **Step 8: Format, lint, commit**

```bash
make format && make lint
git add StenoKit/Features/Settings/AISettingsModel.swift StenoTests/Settings/AISettingsFixtures.swift \
        StenoTests/Settings/AISettingsKeyTests.swift StenoTests/Settings/AISettingsModelTests.swift
git commit -m "feat: the AI pane's model, where the key and the model id are written"
```


---

### Task 2: The pane, the tab, and the composition root

**Files:**
- Create: `Steno/Features/Settings/AISettingsPane.swift`
- Modify: `StenoKit/Features/Settings/SettingsPane.swift` (the commented `// case ai` line)
- Modify: `Steno/Features/Settings/SettingsView.swift` (one switch arm, one stored property)
- Modify: `Steno/App/StenoApp.swift` (build the model once)

**Interfaces:**
- Consumes: every public member of `AISettingsModel` from Task 1; `AnthropicProvider(credentials:)` and `KeychainCredentialStore()` from M3-01/M3-02.
- Produces: `SettingsPane.aiProvider` (a third tab), and `SettingsView(model:dataModel:aiModel:)` — a changed initializer, so `StenoApp` must pass the new argument.

**No tests.** This target is unreachable from the unhosted bundle (D-010); the gate is `make build` plus the manual checklist in Task 5. Everything testable was put on the model in Task 1 for exactly this reason.

- [ ] **Step 1: Add the pane case**

`case ai` does not compile under `--strict`: SwiftLint's `identifier_name` rejects a two-character name, the same rule that produced `Log.aiLayer`. Replace the commented sketch line in `SettingsPane.swift`:

```swift
    /// FR-6's AI area: the provider, the Keychain-backed key, the model picker
    /// and "Test connection" (§7.1, §7.2, §8).
    ///
    /// Last of the three that ship today, because it is the one the product
    /// works without: §7.4 produces a stand-up with no key configured at all,
    /// and the tab order should not imply otherwise.
    ///
    /// Named `aiProvider` rather than `ai` because SwiftLint's
    /// `identifier_name` rejects a two-character name — the same rule that
    /// named `Log.aiLayer`. The *tab* still reads "AI".
    case aiProvider
```

and add its two arms:

```swift
        case .aiProvider: return "AI"        // in `title`
        case .aiProvider: return "sparkles"  // in `systemImage`
```

- [ ] **Step 2: Run the build to watch the exhaustive switch fail**

Run: `make build`
Expected: FAIL — `switch must be exhaustive` in `SettingsView.content(for:)`. That failure is the point of the registry: a pane case cannot be added without a view (see `SettingsView`'s doc comment).

- [ ] **Step 3: Write the pane**

```swift
import StenoKit
import SwiftUI

/// FR-6's AI area: provider, key, model, and "Test connection" (§7.1, §7.2, §8).
///
/// Kept as small as its two siblings, and for the same reason — this is a
/// recall tool, and time spent in configuration is time not spent capturing.
/// Every decision below lives on `AISettingsModel`; this file arranges controls
/// and owns no rule, because the unhosted test bundle cannot reach this target
/// (D-010).
struct AISettingsPane: View {
    @Bindable var model: AISettingsModel

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $model.selectedProviderID) {
                    ForEach(model.providerChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .disabled(model.providerChoices.count < 2 || model.isBusy)

                // §7.2: the API key is the only enabled option in Settings v1,
                // so one selectable kind renders as a label rather than as a
                // picker of one.
                if model.credentialKinds.count == 1 {
                    LabeledContent("Sign in with") { Text("An API key") }
                }

                disclosure
            }

            Section("API key") {
                // Entry only (D-157): this field never receives the stored key,
                // so what is on screen is what the user just typed.
                SecureField("Paste your API key", text: $model.keyEntry)
                    .textContentType(.password)

                HStack {
                    Button(model.hasStoredKey ? "Replace Key" : "Save Key") {
                        Task { await model.saveKey() }
                    }
                    .disabled(model.keyEntry.isEmpty || model.isBusy)

                    Button("Remove Key") { model.removeKey() }
                        .disabled(!model.hasStoredKey || model.isBusy)
                }

                Text(
                    model.hasStoredKey
                        ? "A key is stored in your login Keychain. Steno never shows it again."
                        : "Without a key, Steno still writes your stand-up — from your log alone, "
                            + "a little rougher."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if let problem = model.keyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                Picker("Model", selection: modelSelection) {
                    ForEach(model.modelRows) { row in
                        Text(row.displayName).tag(row.id)
                    }
                    if model.modelRows.isEmpty {
                        Text("No model selected").tag("")
                    }
                }
                .disabled(model.isBusy)

                Button("Refresh Models") { Task { await model.refreshModels() } }
                    .disabled(model.isBusy)

                if model.selectionIsUnlisted && model.selectedModelID != nil {
                    Text(
                        "Steno hasn't fetched the model list yet — it only asks when you save a "
                            + "key or press Refresh. Your stand-ups use the model above until then."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if case .failed(let error) = model.listState {
                    note(error, advice: model.listAdvice)
                }
            }

            Section("Connection") {
                Button("Test Connection") { Task { await model.testConnection() } }
                    .disabled(model.isBusy)

                switch model.connection {
                case .untested:
                    EmptyView()
                case .testing:
                    Text("Asking the provider…").font(.callout).foregroundStyle(.secondary)
                case .passed:
                    Label("The key works.", systemImage: "checkmark.circle")
                        .font(.callout)
                case .failed(let error):
                    note(error, advice: model.connectionAdvice)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// §8: "onboarding must state plainly which content is transmitted to the
    /// AI provider, so the user can re-evaluate if their employer's policy
    /// changes."
    ///
    /// **Inline and always visible, rather than a first-run sheet.** A modal
    /// shown once is exactly the surface a policy change cannot bring back.
    ///
    /// Every clause is checked against `StandupPrompt.user`,
    /// `ReportGatherer.gather` and `EventQueries.inWindow` — it describes what
    /// this build sends, not what a future one will: M4-02 and M4-03 add
    /// fetched Jira and Confluence text, which D4 permits, and this paragraph
    /// must grow a clause when they land.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What Steno sends to Anthropic").font(.callout.bold())
            Text(
                "When a stand-up is polished, Steno sends one project's report window: its start "
                    + "and end, and for every task in it — the title, the status, any ticket keys, "
                    + "the blocked reason, and every event inside that window (your notes, status "
                    + "changes, blocked reasons, and when the task was created) with its timestamp, "
                    + "in the words you typed. Notes are sent whole; nothing is shortened first. "
                    + "Each task also carries a random identifier so the model can refer to it."
            )
            Text(
                "Not sent: other projects, tasks outside the window, and notes you have redacted. "
                    + "Your API key travels as the request's authorization header and is stored "
                    + "only in your login Keychain — never in Steno's data file, its preferences, "
                    + "or its logs."
            )
            Text(
                "With no key set, or no model selected, Steno never contacts Anthropic and builds "
                    + "your stand-up from your log alone."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// One failure, worded by `AIError` and pointed by the model's advice.
    @ViewBuilder
    private func note(_ error: AIError, advice: AISettingsModel.Advice?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                error.errorDescription ?? "The provider could not be reached.",
                systemImage: advice == .fixTheKey
                    ? "key.slash" : "exclamationmark.triangle")
            if advice == .fixTheKey {
                Text("Check the key above, then try again.")
            } else {
                Text("Nothing here is wrong — try again in a moment.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// The picker's binding.
    ///
    /// Written by hand rather than with `$model.selectedModelID` because the
    /// setter is not a property write: it goes through `select(modelID:)`,
    /// which is what puts the choice in `AppSettings` where
    /// `MainWindowModel.standupPolish` reads it.
    private var modelSelection: Binding<String> {
        Binding(
            get: { model.selectedModelID ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                model.select(modelID: newValue)
            })
    }
}
```

- [ ] **Step 4: Wire it into the shell and the composition root**

In `SettingsView.swift`: add the stored property and the arm, and correct the stale doc comment that promised a one-segment toolbar until M3-04.

```swift
/// Three panes as of M3-04; two more are sketched in `SettingsPane`.
struct SettingsView: View {
    let model: SettingsModel
    let dataModel: DataSettingsModel
    let aiModel: AISettingsModel
```

```swift
        case .aiProvider:
            AISettingsPane(model: aiModel)
```

In `StenoApp.swift`: the stored property, its construction **before** the `store` switch, and the new argument.

```swift
    /// FR-6's AI pane, built here for the reason above — and built outside the
    /// `store` switch below, unlike its two siblings: a credential lives in the
    /// Keychain and a model id in `UserDefaults`, so this pane is fully
    /// functional in a build whose store will not open (§13).
    private let aiSettingsModel: AISettingsModel
```

```swift
        // §7.1's list, with the one provider that ships. The two
        // `KeychainCredentialStore` values are separate instances of a
        // stateless struct, the posture D-109 records for `AppKitFilePanels`.
        aiSettingsModel = AISettingsModel(
            providers: [AnthropicProvider(credentials: KeychainCredentialStore())],
            credentials: KeychainCredentialStore())
```

```swift
            SettingsView(
                model: settingsModel, dataModel: dataSettingsModel, aiModel: aiSettingsModel)
```

- [ ] **Step 5: Build, test, lint, commit**

```bash
make build && make test && make lint && make format
git add Steno/Features/Settings/AISettingsPane.swift Steno/Features/Settings/SettingsView.swift \
        Steno/App/StenoApp.swift StenoKit/Features/Settings/SettingsPane.swift
git commit -m "feat: FR-6's AI pane, with §8's disclosure stated concretely"
```


---

### Task 3: `models-selftest` and `make verify-models`

**Files:**
- Create: `StenoKit/AI/ModelsSelftest.swift`
- Create: `StenoTests/AI/ModelsSelftestTests.swift`
- Modify: `StenoKit/CLI/CLICommand.swift`, `StenoKit/CLI/CLIParser.swift`, `StenoKit/CLI/CLIEntry.swift`, `StenoKit/CLI/CLIRunner.swift`
- Modify: `StenoTests/CLI/CLIParserTests.swift`, `StenoTests/CLI/CLIEntryTests.swift`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `AIProvider`, `AIError`, `AIModel`, `CLIOutput.standardOut`, `AnthropicProvider`, `KeychainCredentialStore`.
- Produces: `ModelsSelftest.run(provider:out:) async -> Int32`, `ModelsSelftest.runSynchronously(provider:out:) -> Int32`, `CLICommand.modelsSelftest`, and the `verify-models` make target.

- [ ] **Step 1: Write the failing harness tests**

```swift
import Foundation
import Testing

@testable import StenoKit

/// The harness's *sequence and its reporting*, tested against the double.
///
/// `make verify-models` runs this same logic against the live API on a signed
/// build; what a unit test can settle is that it reports honestly — a harness
/// that printed PASS for an empty list, or that leaked a payload while
/// reporting a failure, would be worse than no harness at all.

/// Collects `out` lines from whatever executor the harness runs on.
///
/// A lock rather than a plain array: `run` is `nonisolated async`, so its
/// closure is `@Sendable` and a captured `var` would not compile under Swift 6.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var contents: [String] { lock.withLock { lines } }
    var joined: String { contents.joined(separator: "\n") }
}

/// An error that describes itself with something that must never be printed.
///
/// `AIProvider`'s contract is that only `AIError` escapes — which carries no
/// free-form string by construction (D-132) — so anything else could be a
/// `DecodingError` quoting a response body. This is that case, made concrete.
private struct LeakyDefect: Error, CustomStringConvertible {
    var description = #"response body: {"api_key":"sk-ant-secret-value"}"#
}

private struct DefectiveProvider: AIProvider {
    let id = "defective"
    let displayName = "Defective"

    func availableModels() async throws -> [AIModel] { throw LeakyDefect() }
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        throw LeakyDefect()
    }
    func testConnection() async throws { throw LeakyDefect() }
}

private let sonnet = AIModel(id: "claude-sonnet-9", displayName: "Claude Sonnet 9")
private let haiku = AIModel(id: "claude-haiku-9", displayName: "Claude Haiku 9")

@Test("a ranked list passes, and element zero is marked as the default")
func aRankedListPasses() async throws {
    let lines = LineCollector()
    let provider = StubAIProvider(models: .success([sonnet, haiku]))

    let code = await ModelsSelftest.run(provider: provider, out: { lines.append($0) })

    #expect(code == 0)
    #expect(lines.joined.contains("PASS"))
    #expect(lines.joined.contains(sonnet.id))
    #expect(lines.joined.contains(haiku.id))
    // The whole point of printing the list is reading D-141's ordering against
    // the live API, and an unmarked list makes the reader count rows.
    let defaultLine = try #require(lines.contents.first { $0.contains("[default]") })
    #expect(defaultLine.contains(sonnet.id))
    #expect(lines.contents.filter { $0.contains("[default]") }.count == 1)
}

/// An empty list is legitimate for the *protocol* (§7.1: "a key with access to
/// nothing") and useless for this harness: nothing about the wire shape was
/// verified, so it must not print PASS.
@Test("an empty list is reported as a failure, not as a pass")
func anEmptyListFails() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(
        provider: StubAIProvider(models: .success([])), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("PASS") == false)
    #expect(lines.joined.contains("no models"))
}

/// The ordinary state of a machine where nobody has set a key. The message is
/// the instruction — and it is still exit 1, because nothing was verified.
@Test("a missing key prints what to do about it")
func aMissingKeyIsExplained() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(
        provider: StubAIProvider(models: .failure(.notConfigured)), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("no key is stored"))
    #expect(lines.joined.contains("Settings"))
    #expect(lines.joined.contains("FAIL") == false)
}

@Test("a rejected key fails with the reason and its metrics label")
func aRejectedKeyFails() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(
        provider: StubAIProvider(models: .failure(.invalidCredential)), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("FAIL"))
    #expect(lines.joined.contains("invalidCredential"))
}

/// §8: a harness that dumped an arbitrary error's description would write a
/// response body — and, on the wrong day, a credential — to a terminal and its
/// scrollback.
@Test("an unexpected error is reported by type, never by description")
func anUnexpectedErrorIsNotQuoted() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(provider: DefectiveProvider(), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("sk-ant-secret-value") == false)
    #expect(lines.joined.contains("api_key") == false)
    #expect(lines.joined.contains("LeakyDefect"))
}

/// The bridge `CLIEntry` uses: a synchronous, `@MainActor` caller blocking on
/// work that runs on the cooperative pool. If `run` ever hops to the main
/// actor this test deadlocks rather than failing — which is the loudest
/// available signal for that mistake.
@Test("the synchronous bridge returns the same code as the async run")
func theSynchronousBridgeAgrees() {
    let lines = LineCollector()

    let code = ModelsSelftest.runSynchronously(
        provider: StubAIProvider(models: .success([sonnet])), out: { lines.append($0) })

    #expect(code == 0)
    #expect(lines.joined.contains(sonnet.id))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ModelsSelftest' in scope`.

- [ ] **Step 3: Write the harness**

```swift
import Foundation

/// The only way `URLSessionTransport` and the live `/v1/models` shape get
/// executed by anything but a user in a Settings pane (D-161).
///
/// **D-138's answer, applied to the network.** `make verify-keychain` exists
/// because §9.4 keeps `make test` out of the real Keychain, which left
/// `KeychainCredentialStore` unexecuted for two milestones. The same two gaps
/// were open here after M3-02:
///
/// - `URLSessionTransport` has no automated test at all (D-143). Its only
///   untested behaviour is "Foundation does what Foundation does", so a
///   `URLProtocol` harness was judged not worth its cost — but that left the
///   real adapter first executed by a human, in the pane they were trying to
///   configure.
/// - `/v1/models`'s shape was confirmed by hand once, on 2026-09-22. A renamed
///   field a year from now fails *silently*: the paging guards turn it into a
///   short list rather than an error, and `ModelRanking` dedupes by id, so
///   nothing complains. Printing the ranked list is also how D-141's ordering
///   gets checked against what the API actually returns rather than against
///   what `ModelRanking`'s unit tests assume.
///
/// Run by `make verify-models`, which invokes the signed binary. Hidden from
/// `CLIUsage.text`: it is a verification harness, not a feature.
///
/// **It never prints the credential, on any path.** `AIError` carries no
/// free-form string by construction (D-132), so its own description is safe to
/// print; anything else is reported by type name only.
///
/// Unlike `KeychainSelftest`, this reads the **real** provider id: there is no
/// way to ask Anthropic a question with a sentinel key, and every call this
/// makes is a read.
public enum ModelsSelftest {
    /// Fetch the ranked list and print it.
    ///
    /// - Returns: `0` when models came back, `1` for every other outcome —
    ///   including an empty list, which is legitimate for the *protocol*
    ///   (§7.1: "a key with access to nothing") but means this harness verified
    ///   nothing.
    ///
    /// **`nonisolated` and it must stay that way.** `runSynchronously` blocks
    /// the calling thread — which for `steno models-selftest` is the main
    /// thread — while this runs on the cooperative pool. An actor-isolated
    /// hop to `@MainActor` inside here would deadlock that bridge.
    public static func run(
        provider: any AIProvider,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let models: [AIModel]
        do {
            models = try await provider.availableModels()
        } catch AIError.notConfigured {
            // Not a failure of the network path: it is the ordinary state of a
            // machine where nobody has set a key, and the message is the
            // instruction. Still exit 1 — nothing was verified.
            out(
                "models-selftest: no key is stored for \(provider.id). "
                    + "Add one in Settings › AI, then run this again.")
            return 1
        } catch {
            out("models-selftest: FAIL — \(describe(error))")
            return 1
        }

        guard !models.isEmpty else {
            out("models-selftest: FAIL — \(provider.displayName) returned no models.")
            return 1
        }

        out(
            "models-selftest: PASS — \(models.count) model(s) from \(provider.displayName), "
                + "in the order the picker shows them.")
        for (index, model) in models.enumerated() {
            // Element zero is what M3-04's picker preselects (D-141, D-159), so
            // it is marked: the point of this list is to check that ordering
            // against the live API, and an unmarked list makes the reader count
            // rows.
            out("  \(model.id)  —  \(model.displayName)" + (index == 0 ? "   [default]" : ""))
        }
        return 0
    }

    /// The same run, for a caller that cannot `await`.
    ///
    /// `CLIEntry.run` is synchronous and `@MainActor`, because `StenoMain.main`
    /// must `exit()` with the code rather than return into SwiftUI's generated
    /// `main`. Making that path `async` would mean an `NSApplication`-free way
    /// to drive a run loop from `main()`, which is a far larger change than one
    /// verification harness justifies.
    public static func runSynchronously(
        provider: any AIProvider,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        let box = ExitCode()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await run(provider: provider, out: out)
            finished.signal()
        }
        finished.wait()
        return box.value
    }

    /// What is safe to print about a thrown error.
    ///
    /// An `AIError` describes itself without quoting a payload — no case of it
    /// carries a free-form `String` (D-132) — so its own sentence is printed.
    /// Anything else is a provider defect (`AIProvider`'s contract is that only
    /// `AIError` escapes) and could be a `DecodingError` quoting a response
    /// body, so only its type name is printed (§8).
    private static func describe(_ error: any Error) -> String {
        guard let aiError = error as? AIError else {
            return "the provider threw \(String(describing: type(of: error))), which is a defect"
        }
        return "\(aiError.localizedDescription) [\(aiError.metricsLabel)]"
    }

    /// A box the detached task writes and the waiting thread reads.
    ///
    /// `@unchecked Sendable` with no lock: the semaphore is the ordering. The
    /// write happens before `signal()` and the read after `wait()`, which is
    /// the same happens-before a lock would establish.
    private final class ExitCode: @unchecked Sendable {
        var value: Int32 = 1
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, including `the synchronous bridge returns the same code as the async run`. If that test **hangs** rather than failing, `run` has acquired a `@MainActor` hop and the bridge is deadlocked — that is the loudest signal available for the mistake.

- [ ] **Step 5: Add the subcommand**

`CLICommand.swift` — a second hidden case:

```swift
    /// `steno models-selftest` — hidden, and absent from `CLIUsage.text`.
    ///
    /// **Carries no store either**, for `keychainSelftest`'s reason: fetching a
    /// provider's model list has nothing to do with the event log. It reads the
    /// stored credential and makes one `GET`, so it is the network twin of the
    /// Keychain harness. See `ModelsSelftest`.
    case modelsSelftest
```

`CLIParser.swift` — one arm beside `keychain-selftest`:

```swift
        case "models-selftest":
            // Takes no flags, for `keychain-selftest`'s reason: accepting and
            // ignoring them would let `models-selftest --replace` look like it
            // did something.
            guard rest.count == 1 else {
                throw unexpected(rest[1], of: "models-selftest")
            }
            return .modelsSelftest
```

`CLIEntry.swift` — handled **before** the store is opened, beside the Keychain harness:

```swift
        // Before the store for the same reason, and with the same shape: this
        // one reads the stored credential and asks the provider for its model
        // list (D-161). `runSynchronously` blocks this thread while the call
        // runs on the cooperative pool — see `ModelsSelftest`.
        if case .modelsSelftest = command {
            return ModelsSelftest.runSynchronously(
                provider: AnthropicProvider(credentials: KeychainCredentialStore()))
        }
```

`CLIRunner.swift` — the exhaustive switch now needs a second arm, and the misroute message must name which subcommand arrived, because two harnesses share it:

```swift
        case .keychainSelftest:
            misroutedSelftest("keychain-selftest")
        case .modelsSelftest:
            misroutedSelftest("models-selftest")
```

```swift
    /// `CLIEntry` answers both selftests before a store is ever opened, so a
    /// runner — which exists to act on the store — should never be handed one.
    ///
    /// **Reported, not trapped.** `preconditionFailure` would turn a wiring
    /// mistake into a crash report; a message names the mistake and exits.
    ///
    /// The subcommand is a parameter rather than a fixed string: with two
    /// harnesses sharing this arm, a message naming only the first would send
    /// whoever hit it looking at the wrong code.
    private func misroutedSelftest(_ subcommand: String) -> Int32 {
        err("steno: \(subcommand) is handled before the store opens.")
        return ExitCode.failure
    }
```

- [ ] **Step 6: Write the CLI tests**

Append to `CLIParserTests.swift`'s `CLIParserTests` suite:

```swift
    // MARK: - The hidden harnesses

    @Test(
        "each selftest parses on its own",
        arguments: [
            (["keychain-selftest"], CLICommand.keychainSelftest),
            (["models-selftest"], CLICommand.modelsSelftest),
        ])
    func selftestParses(_ arguments: [String], _ expected: CLICommand) throws {
        #expect(try parse(arguments) == expected)
    }

    /// Accepting and ignoring a flag would let `models-selftest --replace` look
    /// like it did something.
    @Test(
        "a selftest takes no flags",
        arguments: [["keychain-selftest", "--replace"], ["models-selftest", "--output", "/tmp/a"]])
    func selftestTakesNoFlags(_ arguments: [String]) throws {
        let error = try #require(throws: CLIUsageError.self) { try parse(arguments) }
        #expect(error.message.contains("unexpected argument"))
    }

    /// **Both harnesses are hidden.** They are verification tools, not
    /// features: `steno --help` describes what §10.5 shipped for a user to run,
    /// and a list that advertised a live API call against their key would be
    /// inviting one.
    @Test("neither selftest appears in the usage text")
    func selftestsAreHidden() {
        #expect(CLIUsage.text.contains("selftest") == false)
    }
```

Append to `CLIEntryTests.swift`, as its own suite:

```swift
/// The other half of the selftest routing rule.
///
/// `CLIEntry` answers both harnesses before a `ModelContainer` is ever opened,
/// so a runner — which exists to act on the store — should never be handed one.
/// That claim is asserted here rather than assumed: the arm reports the
/// misrouting and exits, and it names the subcommand that got there, because
/// with two harnesses sharing it a message naming only the first would send
/// whoever hit it to the wrong code.
///
/// `CLIEntry.run`'s own selftest branches are deliberately not exercised: they
/// build the real `KeychainCredentialStore` and the real `AnthropicProvider`,
/// which would write into the developer's login keychain and reach the network
/// that §9.4 denies. That is what `make verify-keychain` and `make
/// verify-models` are for.
@Suite @MainActor struct CLISelftestRoutingTests {
    @Test(
        "a selftest handed to the runner is refused, and says which one",
        arguments: ["keychain-selftest", "models-selftest"])
    func misroutedSelftestIsRefused(_ subcommand: String) throws {
        let harness = try CLIHarness()

        let result = try harness.run([subcommand])

        #expect(result.code == 1)
        #expect(result.err.joined().contains("\(subcommand) is handled before the store opens"))
        #expect(result.out.isEmpty)
    }
}
```

- [ ] **Step 7: Add the make target**

After `verify-keychain` in the `Makefile`:

```make
# §7.1's network path, run against the live API with the key you actually use.
#
# `make test` denies outbound networking (§9.4, D-012), so `URLSessionTransport`
# has no automated execution at all (D-143) and `/v1/models`'s shape — paging,
# field names, the `structured_outputs` nesting — was confirmed by hand exactly
# once, on 2026-09-22. A renamed field a year from now fails silently: the
# paging guards turn it into a short list rather than an error. This target is
# the repeatable check, and it prints the ranked list so D-141's ordering can be
# read against what the API actually returns.
#
# It spends one GET against your key, and it never prints the key. Run it after
# any change to AnthropicWire, ModelRanking, HTTPTransport or URLSessionTransport.
verify-models: build ## Fetch the live model list with the stored key (signed build; §7.1, D-161)
	@"$(BIN)" models-selftest
```

- [ ] **Step 8: Run everything, then mutation-verify**

Run: `make build && make test && make lint`
Expected: all pass.

Then, each in turn — run `make test`, confirm the named test goes red, restore:

| Mutation | Test that must go red |
|---|---|
| Mark every row `[default]` in `ModelsSelftest.run` | `a ranked list passes, and element zero is marked as the default` |
| Delete the `guard !models.isEmpty` block | `an empty list is reported as a failure, not as a pass` |
| Change `catch AIError.notConfigured` to another case | `a missing key prints what to do about it` |
| `describe` returns `String(describing: error)` for a non-`AIError` | `an unexpected error is reported by type, never by description` |
| `describe` drops `[\(aiError.metricsLabel)]` | `a rejected key fails with the reason and its metrics label` |
| `runSynchronously` returns `0` without running the task | `the synchronous bridge returns the same code as the async run` |
| Delete the `guard rest.count == 1` in the parser arm | `a selftest takes no flags` |
| Rename the parser's `case "models-selftest"` | `each selftest parses on its own` |
| Hard-code `"keychain-selftest"` in `misroutedSelftest`'s call | `a selftest handed to the runner is refused, and says which one` |
| Add a `models-selftest` line to `CLIUsage.text` | `neither selftest appears in the usage text` |

- [ ] **Step 9: Commit**

```bash
make format
git add StenoKit/AI/ModelsSelftest.swift StenoTests/AI/ModelsSelftestTests.swift StenoKit/CLI/ \
        StenoTests/CLI/CLIParserTests.swift StenoTests/CLI/CLIEntryTests.swift Makefile
git commit -m "feat: make verify-models, so the real transport stops being first run by a user"
```


---

### Task 4: The decision log, the task index, and the spec's one correction

**Files:**
- Modify: `docs/DECISIONS.md` (append D-157 … D-161)
- Modify: `docs/tasks/README.md` (tick M3-04's row with the PR number once it is open)
- Modify: `docs/superpowers/specs/2026-09-24-m3-04-ai-settings-ui-design.md` (one factual correction)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Check the decision log's maximum before writing a number**

Run: `grep -o '^### D-[0-9]*' docs/DECISIONS.md | sort -t- -k2 -n | tail -3`
Expected: `D-154`, `D-155`, `D-156`. Inferring the next number from a sibling spec is how a duplicate D-140 shipped once already; a diff cannot see a collision.

- [ ] **Step 2: Append the five decisions**

Each is argued in full in the spec; the log entries carry the same reasoning in `DECISIONS.md`'s house format:

- **D-157 — The key field is entry-only.** `keyEntry` starts empty on every appearance and is cleared on save; the pane's only Keychain read is a presence check returning `Bool`. Makes §8's "never displayed in full" a property of this code rather than of `NSSecureTextField`. Removing a key leaves `aiSelectedModelID` in place.
- **D-158 — `/v1/models` is called only on an explicit act.** Save, Refresh, and nothing else — opening a settings tab is not a network event. The consequence is the offline rendering: a picker with the stored model as its only row, which is also the second acceptance criterion. No cache, because it would cost an `AppSettings` key and grow `AISecretsTests`' count.
- **D-159 — Saving a key adopts element zero.** Consumes D-141's ordering when the selection is `nil` or no longer offered, and never otherwise. Entering a key *is* the on switch; a second toggle could disagree with it.
- **D-160 — The provider picker renders a list and stores nothing.** `providers: [any AIProvider]`, selection in memory, no setting with one possible value. Tests drive it with two `StubAIProvider`s, which is what exercises §7.1 rather than asserting it.
- **D-161 — `models-selftest` and `make verify-models`.** D-138's shape applied to the network: the first execution of `URLSessionTransport` by anything but a user, and a repeatable check on `/v1/models`'s shape and D-141's ordering.

- [ ] **Step 3: Correct the spec**

The spec's D-158 section lists "Test connection" among the calls that fetch the list. It does reach the API, but `AIProvider.testConnection()` returns nothing, so it populates no rows — how a provider verifies a credential is its own business, and a second provider may answer it a cheaper way. Replace that parenthetical with: *Test connection reaches the provider too, but returns no rows: "Refresh models" is what fills the picker.*

Do not silently deviate elsewhere: any other place implementation contradicted the spec goes in the PR body (CLAUDE.md, §9.5).

- [ ] **Step 4: Commit**

```bash
git add docs/DECISIONS.md docs/superpowers/specs/2026-09-24-m3-04-ai-settings-ui-design.md
git commit -m "docs: record D-157..D-161 and correct what Test connection fetches"
```

- [ ] **Step 5: Open the PR, then stop**

```bash
git push -u origin feat/ai-settings-ui
gh pr create --fill   # then rewrite the body against .github/pull_request_template.md
```

Read the template before writing the body — `gh pr create` bypasses it silently. The body must carry:

- `make build && make test && make lint` output, not a claim that they pass.
- The **manual checklist**, which is what covers everything an agent cannot click:
  1. `make verify-models` on a signed build prints a ranked list, sonnet-family first, and never the key.
  2. A wrong key → "Test connection" says the credential was rejected.
  3. Wi-Fi off → "Test connection" says the provider could not be reached; "Refresh models" leaves the stored model selected and usable.
  4. A real key → the picker preselects a sonnet model; a prepared stand-up is marked AI-generated.
  5. `make verify-keychain` still passes (the Keychain path is shared).
- The note that §8's disclosure describes only what this build sends, and that M4-02/M4-03 must amend it when Jira and Confluence text starts travelling.

Then **stop**. The user reviews and merges; ticking M3-04's row in `docs/tasks/README.md` happens in the next task's PR, per CLAUDE.md step 4.

