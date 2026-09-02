import Foundation

/// FR-2's five-minute typo window, as a rule with no store and no clock.
public enum NoteCorrection {
    /// FR-2's grace period.
    public static let window: TimeInterval = 5 * 60

    /// Whether an event may still be corrected at `instant`.
    ///
    /// Takes the four facts it needs rather than an `Event`, so every branch is
    /// testable against literals — which matters because two of this task's
    /// acceptance criteria are statements about this function and nothing else.
    ///
    /// **There is deliberately no lower bound on the age.** An event stamped
    /// slightly in the future — clock jitter, or a §10 import from a Mac whose
    /// clock runs fast — yields a negative interval and stays correctable.
    /// Rejecting negative ages would make a note one second in the future
    /// permanently uncorrectable, which is both likelier and worse.
    public static func isCorrectable(
        kind: EventKind, timestamp: Date, isRedacted: Bool, at instant: Date
    ) -> Bool {
        guard kind.isUserAuthored, !isRedacted else { return false }
        return instant.timeIntervalSince(timestamp) < window
    }
}
