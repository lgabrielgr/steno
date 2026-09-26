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

    /// - Parameter connectors: **registration order is priority.** M5's MCP
    ///   connector will claim kinds a native connector also claims, and ordering
    ///   decided by which Settings pane the user happened to open first is not a
    ///   routing rule anyone can reason about. There is deliberately no
    ///   `register()`: the order lives at the composition root, where it is one
    ///   readable array literal.
    public init(connectors: [any SourceConnector] = []) {
        self.connectors = connectors
    }

    /// The first configured connector that claims `ref`, or why none did.
    ///
    /// Configuration is part of the routing decision rather than a check the
    /// service makes afterwards: with two connectors claiming one kind, an
    /// unconfigured first one must not shadow a configured second.
    public func dispatch(_ ref: SourceRefSnapshot) -> SourceDispatch {
        var claimed = false
        for connector in connectors where connector.canHandle(ref) {
            claimed = true
            if connector.isConfigured { return .ready(connector) }
        }
        return claimed ? .notConfigured : .unhandled
    }

    /// One named connector, for FR-6's per-integration "Test connection" button
    /// (M4-04), which acts on a connector rather than routing a ref.
    public func connector(withID id: String) -> (any SourceConnector)? {
        connectors.first { $0.id == id }
    }

    /// Every registered connector, for M4-04's list of integrations.
    public var all: [any SourceConnector] { connectors }
}
