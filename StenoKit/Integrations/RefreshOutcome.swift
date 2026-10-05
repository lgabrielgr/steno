import Foundation

/// What one refresh pass did (§5.5).
///
/// **Counts, not collections.** D-163's lesson applies directly here: an empty
/// array is never evidence that nothing was fetched, so `attempted` is carried
/// explicitly rather than inferred from the size of anything. A caller asking
/// "did this pass do nothing, or did everything fail?" must be able to tell.
public struct RefreshOutcome: Sendable, Equatable {
    /// One ref's failure, with the connector that owns it.
    ///
    /// Carries `displayName` because a banner reading "a source couldn't be
    /// reached" is unactionable while "Jira couldn't be reached" points at the
    /// right Settings pane. Both fields are connector constants, never response
    /// content, which is what keeps `SourceError`'s logging property intact.
    public struct Failure: Sendable, Equatable {
        public let connectorID: String
        public let displayName: String
        public let error: SourceError

        /// When *this* ref was last observed, or `nil` if it never was.
        ///
        /// **Its own field rather than the outcome's `oldestFetch`**, which is the
        /// minimum across every ref in scope. Attributing that minimum to the
        /// connector that failed states something false as soon as two
        /// integrations are in play: an uncached Jira ref failing while an
        /// unrelated Confluence ref holds a two-day-old cache would tell the user
        /// Jira is using two-day-old data, when Jira has none at all. Raised by
        /// Copilot in review of PR #42.
        public let cachedAt: Date?

        /// Where the user renews this connector's credential, when it has such a
        /// page (D-193). §5.2 requires a 401 to carry a direct link, and this is
        /// how it reaches `SourceNotice` without the notice knowing what Atlassian
        /// is.
        public let renewalURL: URL?

        public init(
            connectorID: String, displayName: String, error: SourceError,
            cachedAt: Date? = nil, renewalURL: URL? = nil
        ) {
            self.connectorID = connectorID
            self.displayName = displayName
            self.error = error
            self.cachedAt = cachedAt
            self.renewalURL = renewalURL
        }
    }

    /// Refs handed to a configured connector.
    public let attempted: Int

    /// Refs whose `cachedSummary` and `lastFetchedAt` were written.
    public let cached: Int

    /// Refs that produced an `externalUpdate` event.
    public let changed: Int

    public let failures: [Failure]

    /// Refs a connector claimed but could not be fetched for want of a
    /// credential.
    public let notConfigured: Int

    /// Refs claimed only by connectors the user has switched off (D-216).
    ///
    /// **Counted, and deliberately never shown.** `SourceNotice` says nothing about
    /// this number: the user turned the integration off, so there is nothing to
    /// report, and a banner that complains about a setting the user chose is one
    /// they learn to ignore (FR-5's reasoning). It exists so the `sources` log can
    /// still explain a pass that attempted nothing.
    ///
    /// **Both loggers carry it, which this comment claimed before either did**
    /// (Copilot, PR #45): `applyAndSave`'s summary line omitted the field, and a pass
    /// of only disabled refs returns before that function runs — so the one case
    /// this count exists to explain was the one case nothing logged. The early
    /// return in `run` now logs too.
    public let disabled: Int

    /// Refs the pass budget ran out before reaching, plus in-flight fetches
    /// cancelled by it (D-178). Not failures: nothing went wrong with them.
    public let skipped: Int

    /// Changes dropped because the log says they were already reported (D-186).
    ///
    /// **Its own count, not folded into `superseded`.** D-163's rule: these are
    /// different facts — one is the deliberate overlap working as designed, the
    /// other is two passes racing — and a single number could not say which. This
    /// one is expected to be non-zero on a healthy pass, which is exactly why it
    /// must not share a counter with something that indicates contention.
    public let duplicates: Int

    /// What the user should know about a connector's credential before it breaks
    /// (§5.2's 14-day warning, D-194).
    ///
    /// **Collected once per pass from the registry, not per ref**, and stamped on
    /// every outcome this service returns — including the early exits, because a
    /// pass with no refs in scope must still be able to say the token expires on
    /// Friday.
    public let credentialWarnings: [SourceCredentialWarning]

    /// Results dropped because a concurrent pass had already applied a fetch for
    /// the same row.
    ///
    /// Its own count rather than folded into `skipped`, per D-163's rule: these
    /// two are different facts — the clock ran out on one, and the other arrived
    /// to find its work already done — and a single number could not say which.
    public let superseded: Int

    /// The oldest `lastFetchedAt` among the refs in scope after the pass, or
    /// `nil` when every ref in scope is freshly fetched or never was.
    ///
    /// Drives the stand-up sheet's staleness wording (D-176).
    public let oldestFetch: Date?

    /// The candidate query failed. Nothing was attempted, and the reason is a
    /// store read rather than a network.
    ///
    /// **Separate from `saveFailed`.** A read failure means the pass never ran;
    /// a write failure means it ran and was discarded. The two have different
    /// owners and one field could not say which — the same rule that keeps
    /// `StandupDraftModel.lastError` and `.notice` apart.
    public let readFailed: Bool

    /// The pass's single save failed and was rolled back (D-172).
    public let saveFailed: Bool

    public init(
        attempted: Int = 0,
        cached: Int = 0,
        changed: Int = 0,
        failures: [Failure] = [],
        notConfigured: Int = 0,
        disabled: Int = 0,
        skipped: Int = 0,
        superseded: Int = 0,
        duplicates: Int = 0,
        credentialWarnings: [SourceCredentialWarning] = [],
        oldestFetch: Date? = nil,
        readFailed: Bool = false,
        saveFailed: Bool = false
    ) {
        self.attempted = attempted
        self.cached = cached
        self.changed = changed
        self.failures = failures
        self.notConfigured = notConfigured
        self.disabled = disabled
        self.skipped = skipped
        self.superseded = superseded
        self.duplicates = duplicates
        self.credentialWarnings = credentialWarnings
        self.oldestFetch = oldestFetch
        self.readFailed = readFailed
        self.saveFailed = saveFailed
    }

    /// This outcome with `credentialWarnings` attached.
    ///
    /// **Exists because `.idle` is a constant and the warnings are not.** A pass
    /// that returns early — an empty task list, a store read that threw — still has
    /// to carry them, and the alternative is every early return spelling out a full
    /// initializer.
    func warning(about warnings: [SourceCredentialWarning]) -> RefreshOutcome {
        guard !warnings.isEmpty else { return self }
        return RefreshOutcome(
            attempted: attempted, cached: cached, changed: changed, failures: failures,
            notConfigured: notConfigured, disabled: disabled, skipped: skipped,
            superseded: superseded, duplicates: duplicates, credentialWarnings: warnings,
            oldestFetch: oldestFetch, readFailed: readFailed, saveFailed: saveFailed)
    }

    /// A pass that had nothing to do.
    ///
    /// Not named `.none`: `Optional.none` is in scope wherever this type is
    /// optional, and `outcome = .none` would then be two different values
    /// depending on the context it is read in.
    public static let idle = RefreshOutcome()

    /// Whether anything reached the store, and therefore whether the window is
    /// worth re-reading.
    public var didWrite: Bool { cached > 0 || changed > 0 }
}

/// A window and the pass that ran over it (D-175).
///
/// `window` is re-gathered when the pass appended events, and is the input
/// window otherwise — so a caller adopts it unconditionally rather than
/// branching on whether a refresh found anything.
public struct RefreshedWindow: Sendable, Equatable {
    public let window: GatheredWindow
    public let outcome: RefreshOutcome

    public init(window: GatheredWindow, outcome: RefreshOutcome) {
        self.window = window
        self.outcome = outcome
    }
}
