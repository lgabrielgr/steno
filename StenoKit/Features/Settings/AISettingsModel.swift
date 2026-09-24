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
    /// It is cleared after every successful save, and by `forgetEntry()`, which
    /// the pane calls as it appears and disappears — **this model is built once
    /// in `StenoApp.init` and held for the process**, so a key typed and not
    /// saved would otherwise still be in the field when the window reopened, and
    /// in memory until the app quit. The clearing is the pane's to trigger
    /// because only a view knows what an appearance is.
    /// Nothing in this type reads a credential's *value*; the only Keychain
    /// read it performs is the presence check behind `hasStoredKey`, whose
    /// result is a `Bool`. That is what makes "the key is never displayed in
    /// full after entry" a property of this code rather than of AppKit's
    /// secure-entry behaviour.
    public var keyEntry: String = ""

    /// Whether a credential exists for the selected provider.
    ///
    /// `false` when the Keychain *refused the read* as well as when nothing is
    /// stored — the two are indistinguishable to a caller — which is why that
    /// case also sets `keyProblem`. Reporting only "no key" would tell a user
    /// with a locked keychain to paste a new one, which cannot work.
    public internal(set) var hasStoredKey: Bool = false

    /// Why the last store or delete was refused, if it was.
    ///
    /// Carries a `KeychainError`'s own description — an `OSStatus` and a case
    /// name, never the credential — because a bare "could not save" leaves a
    /// user unable to tell a locked keychain from a bug.
    ///
    /// **Anything that is not a `KeychainError` is named by type only.** The
    /// `catch` binds `any Error`: `KeychainCredentialStore.store` encodes the
    /// `Credential` before it reaches `SecItem*`, and an `EncodingError`
    /// describes itself by quoting the value it choked on — which is the key
    /// (§8). `ModelsSelftest.describe` narrows for the same reason.
    public internal(set) var keyProblem: String?

    // MARK: - Models

    /// The last successfully fetched list, ordered by the provider (D-141).
    public internal(set) var models: [AIModel] = []

    public internal(set) var listState: ListState = .idle

    /// Whether a fetch has ever succeeded for the selected provider.
    ///
    /// **`models.isEmpty` cannot answer this.** §7.1 calls an empty result
    /// legitimate — "a key with access to nothing" — so an empty array is
    /// either "we never asked" or "we asked and there is nothing", and the pane
    /// says different things about those. Reset when the provider changes or
    /// the key is removed, because what a provider offered is an answer about a
    /// credential. Raised by Copilot on PR #38.
    public internal(set) var hasFetchedModels: Bool = false

    /// The user's choice, mirrored from `AppSettings` and written through.
    public internal(set) var selectedModelID: String?

    // MARK: - Connection

    public internal(set) var connection: ConnectionState = .untested

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
            hasFetchedModels = false
            listState = .idle
            connection = .untested
            keyEntry = ""
            switch Self.storedKey(in: credentials, for: selectedProviderID) {
            case .present:
                hasStoredKey = true
                keyProblem = nil
            case .absent:
                hasStoredKey = false
                keyProblem = nil
            case .unreadable(let detail):
                hasStoredKey = false
                keyProblem = "macOS could not read your stored key: \(detail)."
            }
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

    /// Where the selected model stands against the list that was fetched.
    ///
    /// **Three cases, because the pane has three different things to say.** An
    /// unlisted selection before any fetch is D-158's ordinary state ("we have
    /// not asked"); an unlisted selection *after* a fetch means the provider
    /// retired the model, and telling that user the list has not been fetched
    /// sends them to a Refresh button that cannot help them.
    public enum SelectionStatus: Equatable, Sendable {
        /// Nothing is selected.
        case none
        /// The fetched list contains it.
        case offered
        /// No list has been fetched yet (D-158).
        case notFetchedYet
        /// A list was fetched and does not contain it.
        case noLongerOffered
    }

    public var selectionStatus: SelectionStatus {
        guard let selectedModelID else { return .none }
        if models.contains(where: { $0.id == selectedModelID }) { return .offered }
        return hasFetchedModels ? .noLongerOffered : .notFetchedYet
    }

    /// Whether the selected model is a row the provider did not offer.
    public var selectionIsUnlisted: Bool {
        selectionStatus == .notFetchedYet || selectionStatus == .noLongerOffered
    }

    /// Whether the AI path will actually run, and why not when it will not.
    ///
    /// **The same two conditions `MainWindowModel.standupPolish` reads**, which
    /// is the point: it builds a provider over the Keychain and passes
    /// `settings.aiSelectedModelID`, and `StandupSummarizer` takes §7.4's raw
    /// path unless both are present. A pane that answered "configured?" from
    /// different evidence would drift from what the stand-up actually does.
    ///
    /// Lives here rather than in the pane's `if` statements because the
    /// unhosted test bundle cannot reach the app target (D-010) — the same
    /// reasoning `DataSettingsModel.canBackUpNow` records.
    public enum Readiness: Equatable, Sendable {
        /// A key is stored and a model is selected. Carries what the picker
        /// shows, so the line names the model rather than an opaque id.
        case ready(model: String)
        /// No credential for this provider.
        case noKey
        /// A credential, but the user has not chosen a model — the state a
        /// first key saved while offline leaves behind (D-159).
        case noModel
    }

    public var readiness: Readiness {
        guard hasStoredKey else { return .noKey }
        guard let selectedModelID else { return .noModel }
        // `modelRows` always contains the selection, synthesised from the id
        // when no list has been fetched, so this is a display name when one is
        // known and the id otherwise — never blank.
        return .ready(
            model: modelRows.first { $0.id == selectedModelID }?.displayName ?? selectedModelID)
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

    // Internal rather than private: `private` is file-scoped, and the
    // credential half of this type lives in `AISettingsModel+Credential.swift`.
    let providers: [any AIProvider]
    let credentials: any CredentialStore
    let settings: AppSettings

    /// The provider the picker names, or `nil` only if this was built with an
    /// empty list — which production never does, and which a guard here turns
    /// into an inert pane rather than a crash.
    var provider: (any AIProvider)? {
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

        switch Self.storedKey(in: credentials, for: providers.first?.id ?? "") {
        case .present:
            self.hasStoredKey = true
        case .absent:
            self.hasStoredKey = false
        case .unreadable(let detail):
            self.hasStoredKey = false
            self.keyProblem = "macOS could not read your stored key: \(detail)."
        }
    }

    // MARK: - Actions

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

    /// Record the user's choice (FR-6, §7.1).
    public func select(modelID: String) {
        selectedModelID = modelID
        settings.aiSelectedModelID = modelID
    }

    // MARK: - Plumbing

    func fetchModels(adoptingRecommendedDefault adoptsDefault: Bool) async {
        guard let provider else { return }
        listState = .loading
        do {
            let fetched = try await provider.availableModels()
            models = fetched
            hasFetchedModels = true
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

    /// `AIProvider`'s contract is that an implementation throws `AIError` and
    /// nothing else. Anything else is a defect in that provider, so it is
    /// logged as a fault — by type name only, because an arbitrary error's
    /// description can quote a payload (§8) — and presented as `.network`,
    /// which is the reading §7.4 degrades most usefully from.
    static func presentable(_ error: any Error) -> AIError {
        if let aiError = error as? AIError { return aiError }
        Log.app.fault(
            "AI provider threw a non-AIError: \(String(describing: type(of: error)), privacy: .public)"
        )
        return .network
    }
}
