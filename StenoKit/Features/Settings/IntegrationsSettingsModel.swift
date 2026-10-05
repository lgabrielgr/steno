import Foundation
import OSLog

/// What the Settings window's Integrations pane binds to (FR-6, §5.2, §5.3, §8).
///
/// **This is the type that makes M4 reachable from the app.** M4-01 shipped the
/// protocol and the registry, M4-02 and M4-03 filled it with two connectors on one
/// credential — and all three ship in a build whose only way to store that
/// credential is `make atlassian-login`, the harness D-197 introduced precisely
/// because this pane was two tasks away.
///
/// Built once in `StenoApp.init` and held for the process, the posture all three
/// sibling models take: the `Settings` scene's content is rebuilt freely by SwiftUI
/// and the state behind it must not be.
///
/// **Every rule lives here rather than in the pane.** The unhosted test bundle
/// cannot reach the app target (D-010), so a rule only a view knows is a rule no
/// test can hold.
@Observable
@MainActor
public final class IntegrationsSettingsModel {
    /// What the Keychain says about the Atlassian credential.
    ///
    /// **A refused read is its own case, not "absent"**, for `StoredKeyState`'s
    /// reason: telling a user with a locked keychain that no credential is stored
    /// sends them to retype a token that is already there.
    ///
    /// The present case carries the site, the email and the expiry — none of which
    /// is a secret — and **never the token** (D-218).
    public enum StoredCredentialState: Equatable, Sendable {
        case absent
        case present(site: String, email: String, expiresAt: Date?)
        /// The read itself was refused. Carries what is safe to show, never the
        /// credential.
        case unreadable(String)
    }

    /// Where one integration's connection test stands.
    public enum TestState: Equatable, Sendable {
        case untested
        case testing
        case passed
        case failed(SourceError)
    }

    /// One row in the Integrations list.
    ///
    /// A value rather than a reference, so the pane cannot write to it: enablement
    /// goes through `setIntegration(_:enabled:)`, which is what puts it in
    /// `AppSettings` where `SourceRegistry` reads it.
    public struct Row: Identifiable, Sendable {
        public let id: String
        public let displayName: String
        public let isEnabled: Bool

        /// Whether a usable credential is present for this connector.
        public let isConfigured: Bool

        public let test: TestState
    }

    // MARK: - The credential being edited

    /// The site, as the user is typing it. Prefilled from the stored credential:
    /// a user who cannot see which site is configured cannot fix a typo in it.
    public var site: String = ""

    public var email: String = ""

    /// **The only secret here, and it is write-only** (D-218, §8).
    ///
    /// Cleared after every successful save and by `forgetEntry()`, which the pane
    /// calls as it appears and disappears — this model outlives every appearance,
    /// so a token typed and not saved would otherwise sit in the field when the
    /// window reopened, and in memory until the app quit.
    ///
    /// Nothing in this type ever holds the *stored* token: `saveCredential()` reads
    /// it as a function-local when a partial edit needs it, and no property of this
    /// class can hold it. That is what makes "never displayed in full after entry"
    /// a property of this code rather than of `SecureField`'s drawing behaviour.
    public var tokenEntry: String = ""

    /// §5.2's user-entered expiry date.
    public var expiresAt: Date = Date()

    /// Whether the user recorded an expiry date at all.
    ///
    /// **Its own flag because the date is genuinely optional.** `AtlassianLogin`
    /// accepts a blank date and §5.2's warning then cannot fire (D-192), so a date
    /// picker with no off switch would invent a date the user never recorded — and
    /// a warning derived from an invented date is worse than no warning.
    public var recordsExpiry: Bool = false

    public internal(set) var storedCredential: StoredCredentialState = .absent

    /// Why the last store, read or delete was refused, if it was.
    public internal(set) var credentialProblem: String?

    /// Whether a credential is definitely there.
    ///
    /// Derived, so it cannot disagree with `storedCredential` — and so "the read was
    /// refused" keeps its own identity for the surfaces that tell the two apart.
    public var hasStoredCredential: Bool {
        if case .present = storedCredential { return true }
        return false
    }

    // MARK: - The integrations

    /// Per-connector test results. Keyed by `SourceConnector.id`, which is stable
    /// across launches by contract.
    ///
    /// Internal rather than `private`: `private` is file-scoped, and the credential
    /// half of this type lives in `IntegrationsSettingsModel+Credential.swift`.
    var testStates: [String: TestState] = [:]

    /// Bumped per connector by every change to what *that* connector's test would be
    /// testing (Copilot, PR #45, twice).
    ///
    /// **Because a verdict is committed after a suspension point.** `testConnection`
    /// awaits the network, and the toggle, Save and Remove all stay usable while it
    /// does — each of them clears the verdicts, and then the in-flight result landed
    /// and *resurrected* one for a credential or a setting that no longer exists. A
    /// result is applied only if the generation it started in is still current.
    ///
    /// **Per connector, not one counter for the pane.** The first version was global,
    /// and toggling Confluence while Jira was testing therefore invalidated Jira's
    /// result while clearing only Confluence's state — so Jira stayed `.testing`
    /// forever, `isBusy` stayed true, and every Test button in the pane was disabled
    /// until relaunch. Toggling one integration says nothing about what another's
    /// test would find; replacing the shared credential says it about all of them,
    /// which is why `forgetTestResults()` bumps every id.
    ///
    /// A counter rather than cancellation: `SourceConnector.testConnection` has no
    /// cancellation contract — only `fetch` does — so abandoning the task is not
    /// something this layer may assume works.
    var generations: [String: Int] = [:]

    /// Every registered connector, **including the ones switched off** (D-216).
    ///
    /// A row that vanished when switched off would offer no way to switch it back
    /// on.
    public var rows: [Row] {
        registry.all.map { connector in
            Row(
                id: connector.id,
                displayName: connector.displayName,
                isEnabled: settings.isIntegrationEnabled(connector.id),
                isConfigured: connector.isConfigured,
                test: testStates[connector.id] ?? .untested)
        }
    }

    /// Whether any test is in flight, which is what disables the buttons.
    public var isBusy: Bool {
        testStates.values.contains(.testing)
    }

    /// The host a connection verdict should name — **the stored credential's, not
    /// the one being typed.**
    ///
    /// **Normalized.** `AtlassianCredential.cloudHost(in:)` accepts a pasted URL,
    /// which is deliberate — a URL is what people have in their clipboard — so a
    /// site value can be
    /// `https://acme.atlassian.net/jira/software/projects/PAY/boards/1`, and a
    /// verdict reading "Reached https://…/boards/1" is exactly the defect PR #44
    /// fixed in `ConfluenceSelftest`, which interpolated `site` where `baseURL` was
    /// meant.
    ///
    /// **Read from `storedCredential` first** (Copilot, PR #45). Every verdict
    /// describes the saved credential, so sourcing this from the editable field made
    /// an existing "Reached acme.atlassian.net" silently become "Reached
    /// corrected.atlassian.net" the moment the user typed — naming a host no request
    /// was ever sent to. `hasUnsavedChanges` tells the user the verdict is about the
    /// saved credential; this is what stops the verdict from contradicting that.
    ///
    /// Falls back to the edited value when nothing is stored, so the pane can still
    /// name what the user typed, and to the raw value when it is not a usable host,
    /// so an unusable site is shown back to whoever typed it.
    public var siteHost: String {
        if case .present(let storedSite, _, _) = storedCredential {
            return AtlassianCredential.cloudHost(in: storedSite) ?? storedSite
        }
        return AtlassianCredential.cloudHost(in: site) ?? site
    }

    /// Whether the fields differ from the stored credential.
    ///
    /// **Because "Test" verifies what is *stored*, not what is typed.** A user who
    /// corrects the site and presses Test without saving would otherwise get a
    /// verdict about the old credential, displayed beside the new fields, with
    /// nothing saying so — and would reasonably conclude their correction did not
    /// work.
    public var hasUnsavedChanges: Bool {
        if !tokenEntry.isEmpty { return true }
        guard case .present(let storedSite, let storedEmail, let storedExpiry) = storedCredential
        else {
            // With nothing stored, anything typed is unsaved.
            return !site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if site.trimmingCharacters(in: .whitespacesAndNewlines) != storedSite { return true }
        if email.trimmingCharacters(in: .whitespacesAndNewlines) != storedEmail { return true }
        // The date only counts when the user says they recorded one, so toggling the
        // switch off and on without touching the picker is not a change.
        let typedExpiry = recordsExpiry ? expiresAt : nil
        return typedExpiry != storedExpiry
    }

    // MARK: - §5.2's expiry warning

    /// §5.2's 14-day warning, derived from the **stored** expiry rather than the
    /// one being edited.
    ///
    /// A date half-typed into the picker is not a fact about the token in the
    /// Keychain, and warning about it would fire on every keystroke.
    public var expiryWarning: SourceCredentialWarning? {
        guard case .present(_, _, let stored) = storedCredential else { return nil }
        return AtlassianTokenExpiry.warning(
            displayName: "Atlassian", expiresAt: stored, now: now())
    }

    // MARK: - Purge

    /// Where "Purge cached external data" stands.
    public enum PurgeState: Equatable, Sendable {
        case idle
        case purged(cleared: Int)
        case failed(String)
    }

    public private(set) var purgeState: PurgeState = .idle

    /// Set when the store could not be opened, in which case there is no cache to
    /// purge. Mirrors `DataSettingsModel.storeFailureNote` — §13 requires a
    /// feature's degradation to ship with it.
    ///
    /// **The credential half of this pane is unaffected.** A credential lives in the
    /// Keychain, so site, email, token, the toggles and the connection tests all
    /// work in a build whose store will not open.
    public var storeFailureNote: String? {
        purge == nil
            ? "Steno could not open its data store, so there is no cached data to purge."
            : nil
    }

    public var canPurge: Bool { purge != nil }

    // MARK: - Dependencies

    // Internal rather than `private`, for `testStates`' reason: the credential half
    // of this type is another file.
    let credentials: any AtlassianCredentialStore
    private let registry: SourceRegistry
    private let settings: AppSettings
    private let purge: SourceCachePurge?
    private let now: () -> Date

    /// - Parameters:
    ///   - credentials: injected so `make test` never writes into the developer's
    ///     login keychain (D-134). The real store's round trip is verified by
    ///     `make verify-integrations` against the signed binary (D-220).
    ///   - registry: the same instance the refresh service routes through, so the
    ///     rows are the connectors that actually ship.
    ///   - settings: injected so tests use a scratch suite rather than the
    ///     developer's own preferences (§9.4).
    ///   - purge: `nil` when the store failed to open, because `StenoApp` builds no
    ///     purge in that case (D-018's posture).
    ///   - now: injected so §5.2's 14-day boundary is a test rather than a wait.
    public init(
        credentials: any AtlassianCredentialStore = AtlassianKeychainStore(),
        registry: SourceRegistry,
        settings: AppSettings = AppSettings(),
        purge: SourceCachePurge? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.registry = registry
        self.settings = settings
        self.purge = purge
        self.now = now
        load()
    }

    // MARK: - Actions

    /// Switch one integration on or off (FR-6).
    ///
    /// **Writes `AppSettings`, which is where `SourceRegistry` reads it per
    /// dispatch** (D-216) — so the change takes effect on the next refresh with no
    /// relaunch. It does not touch the credential: the fourth acceptance criterion
    /// is that disabling stops fetches *without* deleting it.
    public func setIntegration(_ id: String, enabled: Bool) {
        settings.setIntegration(id, enabled: enabled)
        // A result that described the previous state is worse than none: the test
        // was run against a configuration that is no longer the one in force. The
        // generation bump is what also discards a result still in flight.
        testStates[id] = .untested
        invalidate(id)
    }

    /// FR-6's per-integration connection test.
    ///
    /// **Calls the connector's own `testConnection()`** rather than fetching a ref:
    /// how a connector verifies a credential is its business, and §5.2 requires the
    /// result to tell a rejected credential, an expired token, a wrong site and an
    /// unreachable network apart — which `SourceError` already does.
    public func testConnection(id: String) async {
        guard let connector = registry.connector(withID: id) else { return }
        guard testStates[id] != .testing else { return }

        // **Refused before any request when the site is unusable** (D-190, D19).
        // This credential travels as HTTP Basic, so a site that is not an Atlassian
        // Cloud host must not receive the user's work token in an `Authorization`
        // header — and `isConfigured` is exactly that check.
        guard connector.isConfigured else {
            testStates[id] = .failed(.notConfigured)
            return
        }

        let generation = generations[id, default: 0]
        testStates[id] = .testing

        let result: TestState
        do {
            try await connector.testConnection()
            result = .passed
        } catch {
            result = .failed(Self.presentable(error))
        }

        // **Only if nothing changed while this was in flight** (Copilot, PR #45).
        // The toggle, Save and Remove all remain usable during a test and all clear
        // the verdicts; without this, the late result wrote one back and the pane
        // showed a tick for a credential that had just been replaced.
        guard generation == generations[id, default: 0] else {
            // **Never leave the row `.testing`** — that is what made `isBusy` stick
            // and disabled every button in the pane (Copilot, PR #45). Whoever
            // invalidated this row already set it to `.untested`; this makes that a
            // property of the code rather than of each caller remembering.
            if testStates[id] == .testing { testStates[id] = .untested }
            return
        }
        testStates[id] = result
    }

    /// FR-6's "purge cached external data" (D-219).
    public func purgeCache() {
        guard let purge else { return }
        switch purge.purge() {
        case .purged(let cleared):
            purgeState = .purged(cleared: cleared)
        case .failed(let detail):
            purgeState = .failed(detail)
        }
    }

    /// Drop every connection verdict.
    ///
    /// **Called whenever the credential changes**, because a verdict describes the
    /// credential it was obtained with: a green tick beside Jira after the token was
    /// replaced is a claim about a credential that no longer exists.
    func forgetTestResults() {
        // Every id, because the credential these verdicts describe is shared by all
        // of them (§5.3) — unlike a toggle, which concerns one row.
        for id in testStates.keys { invalidate(id) }
        testStates.removeAll()
    }

    /// Discard whatever `id`'s in-flight test is about to report.
    func invalidate(_ id: String) {
        generations[id, default: 0] += 1
    }

    /// `SourceConnector`'s contract is that an implementation throws `SourceError`
    /// and nothing else. Anything else is a defect in that connector, so it is
    /// logged as a fault — **by type name only**, because an arbitrary error's
    /// description can quote a response payload (§8) — and presented as `.network`,
    /// which is the reading §5.5 degrades most usefully from.
    static func presentable(_ error: any Error) -> SourceError {
        if let sourceError = error as? SourceError { return sourceError }
        Log.sources.fault(
            "a connector threw a non-SourceError: \(String(describing: type(of: error)), privacy: .public)"
        )
        return .network
    }
}
