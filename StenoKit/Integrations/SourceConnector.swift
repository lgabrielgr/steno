import Foundation

/// A `SourceRef` as a connector sees it (D-164).
///
/// **§5.1 prints `fetch(_ ref: SourceRef, since:)`, and that signature does not
/// compile here.** `SourceRef` is an `@Model` class and therefore not
/// `Sendable`; `fetch` is `async`, so the argument crosses an isolation
/// boundary; `SWIFT_VERSION` is 6.0, which makes that an error rather than a
/// warning. This is the same wall `GatheredWindow` exists for — `TaskItem` and
/// `Event` cannot cross into an `AIProvider` either — and the deviation is
/// declared in the PR body rather than absorbed silently, per CLAUDE.md.
///
/// Carries `refID` rather than the row so `SourceRefreshService` can key the
/// result back to the object it snapshotted, without the connector ever
/// holding a store reference.
public struct SourceRefSnapshot: Sendable, Equatable {
    public let refID: UUID
    public let kind: SourceRefKind

    /// §3.4's identifier: `PAY-421`, a Confluence page id, `acme/api#421`.
    public let identifier: String

    public let url: String?
    public let lastFetchedAt: Date?

    public init(
        refID: UUID,
        kind: SourceRefKind,
        identifier: String,
        url: String? = nil,
        lastFetchedAt: Date? = nil
    ) {
        self.refID = refID
        self.kind = kind
        self.identifier = identifier
        self.url = url
        self.lastFetchedAt = lastFetchedAt
    }
}

/// What one fetch learned (§5.1).
public struct SourceUpdate: Sendable, Equatable {
    /// Human-readable current state. Stored as `SourceRef.cachedSummary`, which
    /// §7.4 reads when the network is gone.
    public let summary: String

    /// Discrete changes since `since`. **Empty is a valid answer** — the
    /// resource has not moved — and is what makes `externalUpdate` appear only
    /// when there is news (§3.3, D-169).
    public let changes: [String]

    public let url: URL?

    /// The connector's own timestamp. Diagnostic only: `lastFetchedAt` is
    /// stamped from the app's clock (D-171).
    public let fetchedAt: Date

    public init(summary: String, changes: [String], url: URL?, fetchedAt: Date) {
        self.summary = summary
        self.changes = changes
        self.url = url
        self.fetchedAt = fetchedAt
    }
}

/// §5.1's protocol: every external fetch in this app goes through it.
///
/// **`Sendable` is added to §5.1's printed signature**, for the reason D-131
/// added it to `AIProvider`: `fetch` is awaited across an isolation boundary, so
/// a non-`Sendable` connector cannot be held by the caller that awaits it.
///
/// **The error contract: an implementation throws `SourceError` and nothing
/// else.** A `URLError` or a `DecodingError` escaping a connector is a defect in
/// that connector — §5.5 must degrade on any failure, and it cannot switch on an
/// error type it has never heard of. `SourceRefreshService` catches the
/// violation rather than trusting it, the way `StandupSummarizer` does for
/// `AIProvider`.
///
/// **A connector reads. It never writes.** No cache, no `Event`, no store:
/// `SourceRefreshService` is the only writer (D-172), so §3.3's append-only
/// invariant and §5.5's never-block rule are enforced once instead of once per
/// connector.
///
/// §13: this layer and `AIProvider` are independent. Nothing here may reference
/// the AI layer, and nothing there may reference this.
public protocol SourceConnector: Sendable {
    /// Stable across launches — it keys `RefreshOutcome.Failure` and M4-04's
    /// per-integration settings.
    var id: String { get }

    /// What Settings and the stand-up sheet's staleness banner show.
    var displayName: String { get }

    /// Whether a credential is present. **Synchronous and cheap**: the registry
    /// reads it per ref while routing, so an implementation must not do I/O
    /// here. `testConnection()` is the call that crosses the network.
    var isConfigured: Bool { get }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool

    /// Fetch the current state, and the changes since `since`.
    ///
    /// - Parameter since: `nil` on the first observation of a ref. Passed
    ///   explicitly even though the snapshot carries `lastFetchedAt`, so refresh
    ///   *policy* stays in the service: a connector reading the snapshot's
    ///   timestamp would be deciding what "since" means, and M4-05's catch-up
    ///   pass needs to pass something else.
    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate

    /// Verify the stored credential (FR-6's per-integration connection test).
    ///
    /// Must distinguish a rejected credential (`.invalidCredential`) from an
    /// unreachable network (`.network`): a test that says only "failed" tells
    /// the user nothing actionable.
    func testConnection() async throws
}
