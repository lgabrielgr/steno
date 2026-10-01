import Foundation

/// §5.2's token expiry rule, as a pure function of two dates.
///
/// **Token expiry is not an edge case, and this type exists to say so in code.**
/// §5.2: Atlassian Cloud API tokens created since December 2024 expire, with a
/// maximum lifetime of one year set at creation — "a scheduled, guaranteed
/// failure". The app therefore warns before it happens rather than explaining it
/// afterwards.
///
/// Clock-injected, like every other policy in this codebase, so "warns at 14 days
/// and not at 15" is a test rather than a wait.
public enum AtlassianTokenExpiry {
    /// §5.2's threshold, in days.
    public static let warningThreshold = 14

    private static let day: TimeInterval = 24 * 60 * 60

    /// Where the user creates a replacement (§5.2's "direct link").
    ///
    /// Confirmed reachable 2026-09-26. A constant rather than a string built at
    /// the call site: it is the one URL §5.2 requires, and `URL(string:)` returning
    /// `nil` at the moment the token expires would drop the link precisely when it
    /// is needed.
    public static let renewalURL = URL(
        string: "https://id.atlassian.com/manage-profile/security/api-tokens")!

    /// Whole days until `expiresAt`, **negative once it has passed**.
    ///
    /// Floored rather than rounded, and no `Calendar` involved: the sentence is a
    /// warning, not a date, and a calendar computation would make it depend on the
    /// machine's time zone. Floor is the honest direction — with eleven hours left
    /// it says "today", not "tomorrow".
    public static func daysRemaining(expiresAt: Date, now: Date) -> Int {
        Int(floor(expiresAt.timeIntervalSince(now) / day))
    }

    /// Whether §5.2's warning is due.
    ///
    /// **Gated on the interval, not on `daysRemaining`.** Flooring first would warn
    /// at 14.9 days, because `floor(14.9) == 14` — a day early, every day, which is
    /// how a warning becomes noise (FR-5). This asks the question §5.2 actually
    /// asks: is the token 14 days or less from expiring?
    public static func shouldWarn(expiresAt: Date, now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) <= Double(warningThreshold) * day
    }

    /// The warning for a connector holding this expiry date, or `nil` when there is
    /// nothing to say.
    ///
    /// `nil` for an absent date as well as a distant one: §5.2 asks the user to
    /// enter the expiry, and a user who has not cannot be warned about it — which
    /// is one reason the 401 path does not depend on this value (D-192).
    public static func warning(
        displayName: String, expiresAt: Date?, now: Date
    ) -> SourceCredentialWarning? {
        guard let expiresAt, shouldWarn(expiresAt: expiresAt, now: now) else { return nil }
        return SourceCredentialWarning(
            displayName: displayName,
            daysRemaining: daysRemaining(expiresAt: expiresAt, now: now),
            renewalURL: renewalURL)
    }
}
