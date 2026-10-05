import Foundation

/// Where a `SourceRef` goes (D-166).
///
/// Three cases rather than an optional, because `SourceRefreshService` accounts
/// for each differently: one is fetched, one is reported to the user as an
/// integration awaiting setup, and one is dropped without a trace.
public enum SourceDispatch: Sendable {
    /// A configured connector claims this ref.
    case ready(any SourceConnector)

    /// A connector claims this kind but has no credential yet. Counted, so the
    /// stand-up sheet can say the integration is not set up rather than
    /// implying the fetch failed.
    case notConfigured

    /// A connector claims this ref, and the user has switched it off (D-216).
    ///
    /// **Its own case because the user must not be told to set up something they
    /// deliberately turned off.** Folding this into `.notConfigured` makes the
    /// stand-up sheet say "some references have no integration set up yet" — false,
    /// and an instruction they have already declined. `SourceNotice` says nothing
    /// about this case; `RefreshOutcome` counts it so the log still can.
    case disabled

    /// Nothing claims it.
    ///
    /// **The normal case, not an error.** `SourceRefKind.url` has no connector
    /// in any planned milestone and FR-1.5's extractor creates one for every
    /// link the user pastes. Logging it, or counting it as a failure, would put
    /// a permanent warning in front of a user who did nothing wrong — and a
    /// warning that always fires is one they learn to ignore (FR-5's reasoning).
    case unhandled
}

/// Routes a `SourceRef` to the connector that handles it (§5.1).
///
/// Holds nothing but its connectors: no store, no network, no cache. That is
/// what lets the routing rule be tested without a container, and it is why
/// `canHandle` lives on the connector while "which connector wins" lives here.
///
/// **Empty in the shipping app this milestone** (D-179). No connector conforms
/// to `SourceConnector` until M4-02, so every ref dispatches `.unhandled` and
/// the launch pass is a no-op. The subsystem is exercised by test doubles —
/// the shape M3-01 shipped before M3-02 supplied a provider.
public struct SourceRegistry: Sendable {
    private let connectors: [any SourceConnector]

    /// Whether a connector id may fetch — FR-6's per-integration toggle (D-216).
    private let isEnabled: @Sendable (String) -> Bool

    /// - Parameter connectors: **registration order is priority.** M5's MCP
    ///   connector will claim kinds a native connector also claims, and ordering
    ///   decided by which Settings pane the user happened to open first is not a
    ///   routing rule anyone can reason about. There is deliberately no
    ///   `register()`: the order lives at the composition root, where it is one
    ///   readable array literal.
    /// - Parameter isEnabled: FR-6's toggle, read **per dispatch** rather than at
    ///   construction (D-216). `StenoApp` builds this registry once for the
    ///   process, so a registry filtered at construction time would honour a
    ///   toggle only after a relaunch — and nothing on screen would say so.
    ///   Defaulted to "everything is on", which is what keeps every M4-01 call
    ///   site and test behaving exactly as before.
    public init(
        connectors: [any SourceConnector] = [],
        isEnabled: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.connectors = connectors
        self.isEnabled = isEnabled
    }

    /// The first enabled, configured connector that claims `ref`, or why none did.
    ///
    /// Configuration is part of the routing decision rather than a check the
    /// service makes afterwards: with two connectors claiming one kind, an
    /// unconfigured first one must not shadow a configured second.
    ///
    /// **Precedence: `.ready` > `.notConfigured` > `.disabled` > `.unhandled`**
    /// (D-216). A sentence the user can act on outranks silence, so where two
    /// connectors claim one ref and one is enabled-but-unconfigured while the other
    /// is switched off, "this integration isn't set up yet" is the answer — the
    /// disabled one is reported only when nothing enabled claims the ref at all.
    public func dispatch(_ ref: SourceRefSnapshot) -> SourceDispatch {
        var claimedByEnabled = false
        var claimedByDisabled = false
        for connector in connectors where connector.canHandle(ref) {
            guard isEnabled(connector.id) else {
                claimedByDisabled = true
                continue
            }
            claimedByEnabled = true
            if connector.isConfigured { return .ready(connector) }
        }
        if claimedByEnabled { return .notConfigured }
        return claimedByDisabled ? .disabled : .unhandled
    }

    /// One named connector, for FR-6's per-integration "Test connection" button
    /// (M4-04), which acts on a connector rather than routing a ref.
    public func connector(withID id: String) -> (any SourceConnector)? {
        connectors.first { $0.id == id }
    }

    /// The connectors the user has not switched off (D-216).
    ///
    /// **What `credentialWarnings()` reads.** Both Atlassian connectors share one
    /// credential (§5.3), so a user who switches Confluence off to stop its noise
    /// would otherwise keep being warned about the token it is no longer using. Jira
    /// keeps warning while it is on, which is correct — the token still matters to it.
    public var enabled: [any SourceConnector] { connectors.filter { isEnabled($0.id) } }

    /// Every registered connector, **including the disabled ones**, for M4-04's list
    /// of integrations.
    ///
    /// The pane must list a disabled integration: one that vanished when switched off
    /// would offer no way to switch it back on.
    public var all: [any SourceConnector] { connectors }
}
