import Foundation

/// §5.5's "scheduled background refresh at a user-set time", as arithmetic.
///
/// **Pure, and holds no clock** — `RefreshPolicy`'s posture, for `RefreshPolicy`'s
/// reason: the rule that decides when the app reaches the network is the part worth
/// a test table rather than a wait. `ScheduledRefreshController` owns the timer and
/// has no decisions of its own.
///
/// **This is a latency optimization, not a data-integrity mechanism** (§5.5). The
/// launch pass refreshes anything older than 30 minutes and "Prepare Stand-up"
/// refreshes the report window unconditionally, so correctness never depends on this
/// rule firing. That is what licenses every answer below to be "no".
public enum ScheduledRefreshDue {
    /// How late a missed occurrence may still be served.
    ///
    /// Four hours: long enough that a Mac opened at 11:00 still gets its morning
    /// warmed, short enough that an evening launch does not spend requests on a
    /// morning that has gone. Past it the day is skipped rather than queued —
    /// M4-05's acceptance criteria ask for "a catch-up on next launch rather than a
    /// skipped day **or a thundering herd of requests**", and the window is how both
    /// halves of that sentence hold at once.
    public static let grace: TimeInterval = 4 * 60 * 60

    /// Whether a scheduled pass is owed right now.
    ///
    /// - Parameters:
    ///   - now: the caller's clock, injected so every case below is a test rather
    ///     than a wait.
    ///   - time: the user's configured time of day.
    ///   - lastRun: when a scheduled pass was last *dispatched* — not when one last
    ///     succeeded (D-223). A failed pass is a non-event under §5.5, and measuring
    ///     from success would retry every tick until the grace window closed.
    ///   - calendar: passed in rather than read here, and read fresh by the caller on
    ///     every tick, which is what makes a time-zone change take effect without
    ///     anything being re-armed.
    public static func isDue(
        now: Date,
        at time: TimeOfDay,
        lastRun: Date?,
        grace: TimeInterval = ScheduledRefreshDue.grace,
        calendar: Calendar
    ) -> Bool {
        guard let occurrence = mostRecentOccurrence(of: time, notAfter: now, calendar: calendar)
        else {
            // Unreachable for any `TimeOfDay` — see `TimeOfDay.instant(on:calendar:)`,
            // which documents the probe. Logged rather than ignored, because the only
            // way to arrive here is a `Calendar` behaving in a way this code does not
            // model, and silence would make that look like "nothing was due".
            Log.sources.error("scheduled refresh: no occurrence could be formed for the set time")
            return false
        }

        // **Strictly less than, so exactly `grace` late is not due.** Which side the
        // boundary falls on matters less than a test holding it still — the posture
        // `RefreshPolicy.due` already takes for its own boundary.
        guard now.timeIntervalSince(occurrence) < grace else { return false }

        guard let lastRun else { return true }

        // A stamp in the future is treated as no stamp at all. A clock dragged
        // backwards — usually a stored `Date` read after a time-zone change — would
        // otherwise suppress the schedule until real time caught up, which for a
        // mis-set year means never. `AutoExportDue` takes the same position.
        if lastRun > now { return true }

        // The occurrence has already been served. This is the line that makes a
        // repeated hour on a fall-back day fire once, and the line that makes a
        // five-minute tick inside one window dispatch one pass.
        return lastRun < occurrence
    }

    /// The latest instant matching `time` that is at or before `now`.
    ///
    /// **Not "today's occurrence", which is the obvious reading and is wrong at the
    /// edge a laptop hits most.** With the time set to 23:00, a Mac asleep from 23:30
    /// until 01:00 computes *that day's* 23:00, finds it in the future, and concludes
    /// nothing is owed — silently dropping the one occurrence the grace window exists
    /// to catch. Walking back a day costs one branch and removes the whole class.
    ///
    /// `internal` rather than private so the walk-back can be asserted directly; the
    /// public rule's tests would only see it through two other comparisons.
    static func mostRecentOccurrence(
        of time: TimeOfDay, notAfter now: Date, calendar: Calendar
    ) -> Date? {
        guard let today = time.instant(on: now, calendar: calendar) else { return nil }
        if today <= now { return today }
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        return time.instant(on: dayBefore, calendar: calendar)
    }
}
