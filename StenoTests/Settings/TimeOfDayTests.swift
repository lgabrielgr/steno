import Foundation
import Testing

@testable import StenoKit

/// A fixed calendar, so nothing here depends on the machine's time zone.
private func pacific() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
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

@Test("minutes since midnight round-trip through hour and minute")
func minutesRoundTrip() throws {
    let time = try #require(TimeOfDay(minutesSinceMidnight: 8 * 60 + 35))

    #expect(time.hour == 8)
    #expect(time.minute == 35)
    #expect(time.minutesSinceMidnight == 8 * 60 + 35)
}

@Test("the default is 08:00")
func theDefaultIsEightAM() {
    #expect(TimeOfDay.eightAM.hour == 8)
    #expect(TimeOfDay.eightAM.minute == 0)
    #expect(TimeOfDay.eightAM.minutesSinceMidnight == 480)
}

/// The bound is what stops a hand-written `defaults write` from reaching
/// `Calendar`. Clamping was rejected: it would refresh at a time the user never
/// chose rather than at the default they can see in the pane.
@Test("a time outside the day is refused")
func aTimeOutsideTheDayIsRefused() {
    #expect(TimeOfDay(minutesSinceMidnight: -1) == nil)
    #expect(TimeOfDay(minutesSinceMidnight: 24 * 60) == nil)
    #expect(TimeOfDay(minutesSinceMidnight: 0) != nil)
    #expect(TimeOfDay(minutesSinceMidnight: 24 * 60 - 1) != nil)
    #expect(TimeOfDay(hour: 24, minute: 0) == nil)
    #expect(TimeOfDay(hour: 23, minute: 60) == nil)
    #expect(TimeOfDay(hour: -1, minute: 0) == nil)
}

/// **The conformance that was removed, pinned so its removal is falsifiable** (Copilot,
/// PR #46). A synthesized `init(from:)` assigns the stored property directly, so
/// `{"minutesSinceMidnight":1440}` decoded to an hour of 24 — a value the initializers
/// below refuse. Nothing serializes this type, so `Codable` cost the invariant and bought
/// nothing; without this test, re-adding it would contradict a comment and nothing else.
///
/// Through `Any`, so the compiler cannot decide the cast statically and warn about it.
@Test("TimeOfDay is not Codable, so no decoder can bypass its bounds")
func timeOfDayIsNotCodable() {
    let value: Any = TimeOfDay.eightAM

    #expect(!(value is any Decodable), "a synthesized init(from:) bypasses the bounds check")
    #expect(!(value is any Encodable))
}

@Test("a date's hour and minute become the setting, and its date is dropped")
func aDateBecomesATimeOfDay() throws {
    let calendar = try pacific()
    let afternoon = try instant("2026-10-06 14:45:30", in: calendar)

    let time = TimeOfDay(of: afternoon, calendar: calendar)

    #expect(time.hour == 14)
    #expect(time.minute == 45)
}

/// The probe this type's documentation records. `direction` defaults to `.forward`,
/// which reads as though this would answer *tomorrow's* 08:00 — it does not, and the
/// rule above it depends on which day is meant.
@Test("an occurrence is on the day it is asked about, even when already past")
func anOccurrenceStaysOnItsOwnDay() throws {
    let calendar = try pacific()
    let afternoon = try instant("2026-10-06 14:00:00", in: calendar)

    let morning = try #require(TimeOfDay.eightAM.instant(on: afternoon, calendar: calendar))

    #expect(morning == (try instant("2026-10-06 08:00:00", in: calendar)))
    #expect(morning < afternoon)
}

/// 02:30 does not exist on 2026-03-08 in this zone. Under the default
/// `matchingPolicy: .nextTime` the day still has an occurrence — 03:00 — so a skipped
/// hour costs thirty minutes rather than a whole day's refresh. `.strict` would answer
/// the *next day's* 02:30, which is why the default is load bearing.
@Test("a time inside a skipped hour moves forward, not to the next day")
func aSkippedHourMovesForward() throws {
    let calendar = try pacific()
    let springForward = try instant("2026-03-08 12:00:00", in: calendar)
    let halfPastTwo = try #require(TimeOfDay(hour: 2, minute: 30))

    let occurrence = try #require(halfPastTwo.instant(on: springForward, calendar: calendar))

    #expect(occurrence == (try instant("2026-03-08 03:00:00", in: calendar)))
}

@Test("a repeated hour answers its first instance")
func aRepeatedHourAnswersItsFirstInstance() throws {
    let calendar = try pacific()
    let fallBack = try instant("2026-11-01 12:00:00", in: calendar)
    let halfPastOne = try #require(TimeOfDay(hour: 1, minute: 30))

    let occurrence = try #require(halfPastOne.instant(on: fallBack, calendar: calendar))

    // The first 01:30 that day is still on daylight time, seven hours behind UTC.
    #expect(calendar.timeZone.secondsFromGMT(for: occurrence) == -7 * 60 * 60)
}
