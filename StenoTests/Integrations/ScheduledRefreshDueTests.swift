import Foundation
import Testing

@testable import StenoKit

/// A fixed calendar. Every case below is a date arithmetic question, so inheriting the
/// machine's time zone would make the suite pass or fail by geography.
private func calendar(in zone: String = "America/Los_Angeles") throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
}

private func instant(_ text: String, in calendar: Calendar) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return try #require(formatter.date(from: text))
}

private func isDue(
    _ nowText: String, time: TimeOfDay = .eightAM, lastRun: String? = nil,
    zone: String = "America/Los_Angeles"
) throws -> Bool {
    let calendar = try calendar(in: zone)
    return ScheduledRefreshDue.isDue(
        now: try instant(nowText, in: calendar), at: time,
        lastRun: try lastRun.map { try instant($0, in: calendar) },
        calendar: calendar)
}

// MARK: - The window

@Test("nothing is due before the configured time")
func nothingIsDueBeforeTheTime() throws {
    #expect(try isDue("2026-10-06 07:59:59") == false)
}

/// The lower boundary, pinned: exactly at the configured time *is* due. Mutating the
/// comparison in `mostRecentOccurrence` from `<=` to `<` makes this red.
@Test("the configured minute itself is due")
func theConfiguredMinuteIsDue() throws {
    #expect(try isDue("2026-10-06 08:00:00"))
}

@Test("a pass is due inside the grace window")
func aPassIsDueInsideTheWindow() throws {
    #expect(try isDue("2026-10-06 11:59:59"))
}

/// The upper boundary, pinned in the other direction: exactly `grace` late is *not*
/// due. Mutating `<` to `<=` in `isDue` makes this red.
@Test("exactly four hours late is too late")
func exactlyFourHoursLateIsTooLate() throws {
    #expect(try isDue("2026-10-06 12:00:00") == false)
}

@Test("an afternoon launch does not refresh for a morning that has gone")
func anAfternoonLaunchSkipsTheDay() throws {
    #expect(try isDue("2026-10-06 16:30:00") == false)
}

// MARK: - The stamp

@Test("an occurrence already served is not served again")
func anOccurrenceIsServedOnce() throws {
    #expect(try isDue("2026-10-06 09:00:00", lastRun: "2026-10-06 08:02:00") == false)
}

@Test("yesterday's pass does not serve today's occurrence")
func yesterdaysPassDoesNotCount() throws {
    #expect(try isDue("2026-10-06 09:00:00", lastRun: "2026-10-05 08:02:00"))
}

/// A clock dragged backwards — a stored `Date` read after a time-zone change is the
/// usual cause — must not disable the schedule until real time catches up, which for a
/// mis-set year means never. `AutoExportDue` takes the same position.
@Test("a stamp in the future is treated as no stamp")
func aFutureStampIsIgnored() throws {
    #expect(try isDue("2026-10-06 09:00:00", lastRun: "2027-01-01 08:00:00"))
}

// MARK: - Midnight, and the walk-back

/// The edge a laptop hits most, and the reason the rule asks for the most recent
/// occurrence rather than today's: computing *this* day's 23:00 at 01:00 finds it in the
/// future and concludes nothing is owed, silently dropping the occurrence the grace
/// window exists to catch.
@Test("a late-evening schedule is still served after midnight")
func aLateEveningScheduleSurvivesMidnight() throws {
    let elevenAtNight = try #require(TimeOfDay(hour: 23, minute: 0))

    #expect(try isDue("2026-10-07 01:00:00", time: elevenAtNight))
}

@Test("a late-evening schedule expires after midnight like any other")
func aLateEveningScheduleStillExpires() throws {
    let elevenAtNight = try #require(TimeOfDay(hour: 23, minute: 0))

    #expect(try isDue("2026-10-07 03:30:00", time: elevenAtNight) == false)
}

/// **An app left running past midnight must not re-serve yesterday's occurrence.** The
/// walk-back makes the most recent occurrence yesterday's 08:00 at 00:30, and the stamp
/// from yesterday morning is what keeps it served — without that comparison a machine
/// left on overnight would fetch again every night at midnight.
@Test("a tick after midnight does not re-serve yesterday's morning")
func aTickAfterMidnightDoesNotRepeatYesterday() throws {
    #expect(try isDue("2026-10-07 00:30:00", lastRun: "2026-10-06 08:02:00") == false)
}

@Test("the walk-back finds the previous day's occurrence")
func theWalkBackFindsYesterday() throws {
    let pacific = try calendar()
    let elevenAtNight = try #require(TimeOfDay(hour: 23, minute: 0))
    let afterMidnight = try instant("2026-10-07 01:00:00", in: pacific)

    let occurrence = ScheduledRefreshDue.mostRecentOccurrence(
        of: elevenAtNight, notAfter: afterMidnight, calendar: pacific)

    #expect(occurrence == (try instant("2026-10-06 23:00:00", in: pacific)))
}

// MARK: - Daylight saving

/// 02:30 does not exist on 2026-03-08 in this zone; the occurrence lands at 03:00. The
/// day is not skipped, which is what `matchingPolicy: .nextTime` buys — `.strict` would
/// answer the next day's 02:30 and drop a day's refresh.
@Test("a schedule inside a skipped hour still runs that day")
func aSkippedHourStillRuns() throws {
    let halfPastTwo = try #require(TimeOfDay(hour: 2, minute: 30))

    #expect(try isDue("2026-03-08 03:05:00", time: halfPastTwo))
}

@Test("a repeated hour fires once, not twice")
func aRepeatedHourFiresOnce() throws {
    let pacific = try calendar()
    let halfPastOne = try #require(TimeOfDay(hour: 1, minute: 30))
    let firstInstance = try instant("2026-11-01 01:30:00", in: pacific)

    // 01:45 on the first pass through the hour: due, and nothing has run yet.
    #expect(
        ScheduledRefreshDue.isDue(
            now: firstInstance.addingTimeInterval(15 * 60), at: halfPastOne, lastRun: nil,
            calendar: pacific))

    // 01:45 again an hour later, on standard time. The stamp from the first instance
    // covers it: the day gets one pass, not two.
    #expect(
        ScheduledRefreshDue.isDue(
            now: firstInstance.addingTimeInterval(75 * 60), at: halfPastOne,
            lastRun: firstInstance, calendar: pacific) == false)
}

/// The same instant, two calendars. This is what the controller's per-tick
/// `calendar()` read buys: a user who flies from California to Berlin gets 08:00 in
/// Berlin on the next tick, with nothing re-armed and no relaunch.
@Test("the verdict follows the calendar it is given")
func theVerdictFollowsTheCalendar() throws {
    let pacific = try calendar()
    let moment = try instant("2026-10-06 08:00:00", in: pacific)
    let berlin = try calendar(in: "Europe/Berlin")

    #expect(
        ScheduledRefreshDue.isDue(
            now: moment, at: .eightAM, lastRun: nil, calendar: pacific))
    // 08:00 Pacific is 17:00 in Berlin — nine hours past the window.
    #expect(
        ScheduledRefreshDue.isDue(
            now: moment, at: .eightAM, lastRun: nil, calendar: berlin) == false)
}
