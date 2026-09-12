import Foundation

/// `Project.lastStandupAt`, recomputed from the reports rather than merged.
///
/// **This replaces §10.1's "take the later timestamp", which M2-04 made unsafe.**
/// §10.1 was written before undo existed. `StandupService.commit` sets
/// `lastStandupAt` to the window's end; `StandupUndoService.undo` moves it
/// *backwards* to the report's `windowStart`, and stamps nothing — neither model
/// carries a clock that records the undo. So "later wins" lets any older export
/// from the other machine defeat an undo: the report merges back marked undone,
/// its `standupReported` events stay redacted, and `lastStandupAt` keeps the
/// pre-undo value. The window the user reclaimed is then never reported again,
/// which is the same class of failure §10.1's rule exists to prevent, pointing
/// the other way. Recorded as D-099; REQUIREMENTS §10.1 amended to match.
///
/// It is also the more faithful reading of §10.1's own principle — *"any mutable
/// field that can be recomputed from the log, should be"* — since a
/// `StandupReport` is part of the log.
///
/// **The `isUndone ? windowStart : windowEnd` shape is what makes undo
/// survive.** A simpler "newest report that is not undone" rule yields `nil` when
/// the only report is undone, and `nil` makes the next Prepare compute a
/// *sliding* 24-hour window — the loss D-067 and M2-04's step 5 went out of their
/// way to avoid. Taking the undone report's `windowStart` reproduces exactly
/// what undo restores.
///
/// `LastStandupClockTests` drives the real `StandupService` and
/// `StandupUndoService` through every sequence and asserts this function equals
/// the live value. That test is the point of the type existing separately: a
/// derivation that models two services will drift from them, and a comment
/// claiming otherwise would be the defect rather than the guard.
enum LastStandupClock {
    /// - Parameter reports: every report in the merged store. Filtering happens
    ///   here rather than at the call site so the rule and its input cannot be
    ///   paired up wrongly.
    /// - Note: `max` over raw `Date`s is only well-defined because both sides of
    ///   a merge are wire-normalized before they reach it (`ImportService.plan`),
    ///   so every value here is already at the format's precision. The
    ///   `wireInstant` comparison makes that independent of the caller rather
    ///   than a property of the one call site — two report sets that are equal on
    ///   the wire must derive the same clock, or two Macs disagree about a window
    ///   boundary `ReportGatherer` compares with a closed range.
    static func value(forProjectID projectID: UUID, in reports: [ExportedReport]) -> Date? {
        reports
            .filter { $0.projectID == projectID }
            .map { $0.isUndone ? $0.windowStart : $0.windowEnd }
            .max { ExportDocument.wireString($0) < ExportDocument.wireString($1) }
    }
}
