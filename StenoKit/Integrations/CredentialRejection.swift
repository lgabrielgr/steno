import Foundation

/// A credential an **unattended** pass found broken, and when it found out (D-227).
///
/// **Why this exists at all.** M4-05's task file requires that "an expired Atlassian token
/// discovered here should set the warning state that M4-04 displays, not interrupt", and
/// before this type the scheduled pass discarded the only evidence it had.
/// `IntegrationsSettingsModel.expiryWarning` is derived from the *user-entered expiry
/// date* — by design, since D-192 made a blank date mean the warning cannot fire — so a
/// token that was **revoked**, or that expired with no date recorded, left the pane
/// showing nothing at all until the next "Prepare Stand-up". Raised by Copilot in review
/// of PR #46, against a claim in this task's own spec that said no plumbing was needed.
///
/// **A timestamped fact, not a current state.** "The background refresh at 08:03 could not
/// sign in" stays true however the credential is fixed afterwards, which is what keeps this
/// from needing to be invalidated from four places — the credential save, the connection
/// test, the toggle and a manual Prepare. A later pass that actually reaches the source
/// clears it, and until then the sentence it produces is still a fact.
///
/// `Codable` here is not the hole it was on `TimeOfDay`: this type has no invariant beyond
/// its fields, and it is genuinely serialized — it is stored as JSON in `UserDefaults`, the
/// shape `AutoExportStatus` already uses.
public struct CredentialRejection: Sendable, Equatable, Codable {
    /// The connector's `displayName`, so the sentence names what to fix. A connector
    /// constant, never response content — the property that keeps `SourceError`'s logging
    /// rule intact.
    public let displayName: String

    /// When the unattended pass was rejected, on the app's clock.
    public let discoveredAt: Date

    public init(displayName: String, at discoveredAt: Date) {
        self.displayName = displayName
        self.discoveredAt = discoveredAt
    }

    /// The rejection in `outcome`, if a connector refused this pass's credential.
    ///
    /// **Only `.credentialExpired` and `.invalidCredential`.** A network failure, a
    /// timeout, a mistyped site (`.siteNotFound`) and an unconfigured connector say nothing
    /// about whether the stored token is still good, and a warning that fires on an
    /// unreachable network is one the user learns to ignore — FR-5's reasoning, applied to
    /// the credential.
    ///
    /// The first such failure wins. Both Atlassian connectors share one credential (§5.3),
    /// so a pass that fails Jira and Confluence has found one broken token, not two.
    public static func from(_ outcome: RefreshOutcome, at moment: Date) -> CredentialRejection? {
        let rejected = outcome.failures.first { failure in
            failure.error == .credentialExpired || failure.error == .invalidCredential
        }
        guard let rejected else { return nil }
        return CredentialRejection(displayName: rejected.displayName, at: moment)
    }

    /// Whether `outcome` is evidence that a recorded rejection is over.
    ///
    /// **A fetch that succeeded, not merely a pass without a credential error.** `cached` is
    /// the count of refs whose `cachedSummary` and `lastFetchedAt` were written, so it is
    /// non-zero only if a connector actually authenticated and answered. Two weaker readings
    /// were tried and are both wrong:
    ///
    /// - `attempted > 0 && no credential failure` clears on a pass whose every ref failed
    ///   with `.network`. An unreachable source says nothing about whether the token is
    ///   valid, so that would erase a true warning the first time the user's wifi dropped.
    ///   Caught by `a network failure leaves an existing record exactly as it was`.
    /// - "no credential failure" alone clears on a pass that attempted nothing, which is the
    ///   *normal* case — most ticks have nothing due — so the warning would vanish within
    ///   five minutes of being recorded. D-163's rule: an empty failure list is not evidence
    ///   of success.
    ///
    /// A pass whose fetches succeeded but whose save was rolled back (D-172) leaves the
    /// record standing for one more pass. That is the safe direction: the warning is stale by
    /// a few hours rather than absent while a token is broken.
    public static func isCleared(by outcome: RefreshOutcome) -> Bool {
        outcome.cached > 0 && from(outcome, at: .distantPast) == nil
    }
}
