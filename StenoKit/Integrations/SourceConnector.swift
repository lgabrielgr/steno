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
    /// Human-readable current state. Stored as `SourceRef.cachedSummary`.
    ///
    /// **Nothing displays it yet, and this comment used to say otherwise** (D-219).
    /// It claimed "§7.4 reads when the network is gone"; no code does. Its only
    /// readers are `ExportRecords` and the import/merge rules — the staleness
    /// wording a user actually sees is built from `lastFetchedAt` via
    /// `RefreshOutcome.Failure.cachedAt`. §5.2 does describe it as "what the app
    /// shows when it tells the user their integration data is stale", so the surface
    /// is owed; until one exists this is a durable record for export, import and the
    /// baseline a later fetch is described against, and nothing more.
    public let summary: String

    /// Discrete changes since `since`, each carrying a stable id (D-186).
    /// **Empty is a valid answer** — the resource has not moved — and is what
    /// makes `externalUpdate` appear only when there is news (§3.3, D-169).
    ///
    /// A connector reports everything in its window, including items it has
    /// already reported and including on a first observation: the window overlaps
    /// deliberately (D-185) and `SourceRefreshService` is what drops the repeats and
    /// what keeps a first observation's items out of the event body (D-188). A
    /// connector that filtered here too would leave those ids unrecorded, and the
    /// next pass would find them again and call them news.
    public let changes: [SourceChange]

    /// The **complete** set of state items observed now, not a delta (D-187).
    ///
    /// A member absent from the previous fetch's set is news; the rest are the
    /// status quo. For Jira this is remote links — PR references — which carry no
    /// timestamp of any kind, so no `since` can window them and set difference is
    /// the only thing that can decide what is new. A connector with nothing of
    /// this shape leaves it empty.
    ///
    /// **Known gap: a removal is silent, so remove-then-re-add can be missed.** The set is
    /// recorded only when an event is written (D-184), and D-187 deliberately reports no
    /// event for a link that disappears — so if a link is removed and re-added with no other
    /// reportable change in between, the recorded set still contains it and the re-addition
    /// reads as the status quo. Closing it needs either an event D-187 declined ("unlinked
    /// acme/api#421" is Jira's bookkeeping, not the user's work) or state on the row that
    /// D-184 declined. Raised by Copilot in review round 3 of PR #43;
    /// `aremovedAndReaddedLinkIsMissed` pins today's behaviour so the trade is revisitable
    /// rather than rediscovered.
    public let present: [SourceChange]

    public let url: URL?

    /// The connector's own timestamp. Diagnostic only: `lastFetchedAt` is
    /// stamped from the app's clock (D-171).
    public let fetchedAt: Date

    /// The newest item timestamp this update is reporting — **the watermark the
    /// next `since` is computed from** (D-184).
    ///
    /// The connector's own clock is not involved: this is a timestamp the *source*
    /// assigned to something it served, which is the whole point. `nil` when the
    /// connector has no notion of one, or found nothing timestamped, which leaves
    /// the next window open rather than closing it around a guess.
    ///
    /// **It must be set even when `changes` is empty after filtering**, and even on
    /// a first observation that reports nothing (D-188): a watermark that only
    /// moves when something is said would send the next pass back to the beginning
    /// of the ticket's history.
    public let watermark: Date?

    /// Whether the connector stopped short of the whole window — a page cap, a budget, anything
    /// that leaves part of `since…now` unread.
    ///
    /// **Has no default, deliberately.** It had one — `false`, which reads as the obvious answer
    /// for a connector with no paging — and the Jira adapter then forgot to forward it, so every
    /// capped walk reported a complete window and the continuation fix was dead code in the
    /// shipping app for a review round. A required argument makes that a compile error instead of
    /// a silent lie.
    ///
    /// **It changes what the watermark means, so the log has to record it.** A connector that
    /// stopped short reports a watermark that is a *floor* ("coverage is complete above here")
    /// rather than a high-water mark, and `SourceRefreshService` resolves several payloads'
    /// watermarks with `max` — which would throw that floor away in favour of an earlier,
    /// higher one and leave the unread band unreachable. Defaulted to `false` for connectors
    /// that always read their whole window.
    public let isWindowCapped: Bool

    /// - Parameters:
    ///   - present: defaulted for connectors with no state stream, and for the
    ///     test doubles that predate one.
    ///   - watermark: defaulted to `nil`, which means "I have no anchor" and keeps
    ///     the window open. A connector reading a timestamped source should always
    ///     pass one.
    public init(
        summary: String,
        changes: [SourceChange],
        url: URL?,
        fetchedAt: Date,
        present: [SourceChange] = [],
        watermark: Date? = nil,
        isWindowCapped: Bool
    ) {
        self.summary = summary
        self.changes = changes
        self.url = url
        self.fetchedAt = fetchedAt
        self.present = present
        self.watermark = watermark
        self.isWindowCapped = isWindowCapped
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

    /// Something about this connector's credential the user should know before it
    /// breaks — §5.2's "warn in-app 14 days before expiry" (D-194).
    ///
    /// **Synchronous and cheap by contract, like `isConfigured`**, and read *once
    /// per pass* rather than once per ref: `SourceRefreshService` collects these
    /// from the registry before it dispatches anything. An implementation may read
    /// its credential here — one Keychain read per pass is the measured cost — but
    /// must not cross the network. `testConnection()` is the call that does that.
    ///
    /// Defaulted to `nil` in an extension, so no existing connector and no test
    /// double has to answer it.
    var credentialWarning: SourceCredentialWarning? { get }

    /// Where the user renews this connector's credential — §5.2's "with a direct
    /// link" (D-193).
    ///
    /// **Separate from `credentialWarning`, and not derived from it.** The warning
    /// exists only when an expiry date was recorded, and a 401 arrives precisely
    /// when that date is wrong or was never entered — so a link that came from the
    /// warning would be missing at the one moment §5.2 requires it. Defaulted to
    /// `nil` for connectors whose credential cannot be renewed on a web page.
    var credentialRenewalURL: URL? { get }

    /// Fetch the current state, and the changes since `since`.
    ///
    /// **Must be cancellation-aware, and that is a requirement rather than a
    /// nicety.** `SourceRefreshService` enforces its per-fetch deadline and its
    /// pass budget with `withDeadline`, whose task group awaits this call before
    /// returning — Swift cancellation is cooperative, so an implementation that
    /// performs non-cancellable I/O holds the whole pass past both limits, and
    /// §5.5's never-block guarantee degrades from "the report is never delayed" to
    /// "the report is delayed by however long this takes". `Deadline.swift` records
    /// the same limit for the same reason, and `HTTPTransport.send` states the same
    /// requirement on the AI side.
    ///
    /// In practice: build on `URLSession`, which honours cancellation, and check
    /// `Task.isCancelled` around any loop of your own. Raised by Copilot in review
    /// of PR #42.
    ///
    /// The alternative — returning without awaiting an uncooperative fetch — was
    /// rejected for D-146's reason: it means abandoning a live task, trading a late
    /// answer for a leaked request. So this is a contract, enforced by review and
    /// by the fact that every connector in this codebase is written against it.
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

extension SourceConnector {
    /// No page to send the user to.
    public var credentialRenewalURL: URL? { nil }

    /// Nothing to warn about. **Defaulted rather than required** so a connector
    /// whose credential cannot expire — M5's MCP connectors, every test double —
    /// says nothing by construction instead of returning `nil` in a stub.
    public var credentialWarning: SourceCredentialWarning? { nil }
}
