import Foundation

/// FR-4 step 2's window, as a rule with no store and no clock.
///
/// Extracted from `ReportGatherer` for the reason `NoteCorrection` is extracted
/// from `NoteService`: two of M2-01's acceptance criteria are statements about
/// window arithmetic and nothing else, and a rule that takes plain values is
/// testable against literals rather than against a store fixture.
public enum ReportWindow {
    /// FR-4 step 2, and §3.5 as corrected in v1.7: a project's first report
    /// looks back 24 hours.
    ///
    /// `TimeInterval` arithmetic, deliberately, not `Calendar` arithmetic. FR-4
    /// says "24h before now" — not "yesterday", and not "since the start of the
    /// previous day". `Calendar.date(byAdding: .day, value: -1)` expresses a
    /// different sentence, one that shifts by an hour across a DST boundary and
    /// hands the user a 23- or 25-hour window twice a year.
    public static let firstRunLookback: TimeInterval = 24 * 60 * 60

    /// D8's window for one project: since that project's last stand-up.
    ///
    /// Takes the two facts it needs rather than a `Project`, so every branch is
    /// reachable from literals and neither a store nor a clock is required to
    /// test it.
    ///
    /// **`start` is clamped to `end`.** A `lastStandupAt` in the future is
    /// reachable through a supported path, not a hypothetical: §10.1 merges the
    /// field by "take the later timestamp", so reporting on a Mac whose clock
    /// runs fast and importing onto one whose clock does not leaves the second
    /// machine holding a timestamp ahead of its own `now`. Clamping yields an
    /// empty window — a thin report — where the alternatives are worse: falling
    /// back to 24h silently re-reports work already said aloud, and throwing
    /// takes out the app's core feature over a ninety-second clock disagreement
    /// (§7.4). It also keeps `windowStart <= windowEnd` true for every
    /// `StandupReport` M2-03 persists, which M2-04's undo reads back.
    ///
    /// The clamp is not logged here — `ReportGatherer` does that, so this stays
    /// a pure function of its arguments.
    public static func bounds(lastStandupAt: Date?, now: Date) -> (start: Date, end: Date) {
        let requested = lastStandupAt ?? now.addingTimeInterval(-firstRunLookback)
        return (min(requested, now), now)
    }
}
