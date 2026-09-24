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
