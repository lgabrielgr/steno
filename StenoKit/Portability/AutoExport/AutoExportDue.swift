import Foundation

/// §10.5's "daily", as a pure function of two dates.
///
/// Separate from `AutoExportService` because it is the only part of the daily
/// trigger that can be wrong in an interesting way, and because a rule about
/// clocks deserves a test table rather than a timer.
public enum AutoExportDue {
    /// Twenty-four hours. Not a calendar day: a rule that fired at local
    /// midnight would fire twice on the day the clocks go back and not at all
    /// on the day they go forward, for a backup whose value is "recent", not
    /// "aligned to a date".
    public static let interval: TimeInterval = 24 * 60 * 60

    /// **Measured from the last success, never from the last attempt.** A
    /// folder that has gone missing therefore retries on the next tick instead
    /// of going quiet for a day, so the failure keeps re-announcing itself.
    ///
    /// A `lastSuccess` in the *future* is due. A clock that moved backwards —
    /// a timezone change carried into a stored `Date` is the usual cause —
    /// would otherwise disable backups until real time caught up, which for a
    /// mis-set year means never.
    public static func isDue(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        if lastSuccess > now { return true }
        return now.timeIntervalSince(lastSuccess) >= interval
    }
}
