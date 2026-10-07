import Foundation

/// A wall-clock time with no date attached — FR-6's "refresh at 08:00", as a value.
///
/// **Not a `Date`, which is the whole reason this type exists.** SwiftUI's
/// `DatePicker(displayedComponents: .hourAndMinute)` binds a `Date`, so a setting
/// stored straight from the picker is an instant whose date component is noise every
/// reader has to know to ignore — and whose *meaning* moves with the time zone it
/// was written in, because 08:00 in Berlin and 08:00 in San Francisco are different
/// instants but the same setting. Minutes since midnight has no second meaning.
///
/// Stored as that one integer rather than as two, so `defaults read
/// com.lgabrielgr.steno` prints something legible and there is only one value to
/// validate on the way in.
/// **Deliberately not `Codable`** (Copilot, PR #46). A synthesized `init(from:)` assigns
/// the stored property directly, so it bypasses both validating initializers below:
/// `{"minutesSinceMidnight":1440}` decodes to an hour of 24, a value this type's own
/// initializer refuses. Nothing serializes a `TimeOfDay` — the setting is stored as an
/// `Int` in `UserDefaults`, and §10's export deliberately does not carry settings (D-024)
/// — so the conformance bought nothing and cost the invariant. If serialization is ever
/// needed, write `init(from:)` through `init?(minutesSinceMidnight:)` rather than letting
/// it be synthesized. `TimeOfDayTests` pins this, so re-adding it turns a test red rather
/// than only contradicting this comment.
public struct TimeOfDay: Sendable, Equatable {
    /// §5.5's default: "a user-set time (default 08:00)".
    ///
    /// **A static rather than `TimeOfDay(hour: 8, minute: 0)` at every call site.**
    /// The public initializers are failable — an out-of-range stored value must not
    /// be able to produce a `TimeOfDay` — and `force_unwrapping` is an enabled lint
    /// rule, so a literal default spelled at a call site would need an unwrap this
    /// repository does not allow. Built through the private unchecked initializer,
    /// whose argument is a literal the compiler can see.
    public static let eightAM = TimeOfDay(unchecked: 8 * 60)

    /// Minutes in a day, and the exclusive upper bound on `minutesSinceMidnight`.
    public static let minutesPerDay = 24 * 60

    /// The only stored property. `hour` and `minute` are views of it, so the two can
    /// never disagree.
    public let minutesSinceMidnight: Int

    public var hour: Int { minutesSinceMidnight / 60 }
    public var minute: Int { minutesSinceMidnight % 60 }

    /// `nil` for a time outside the day.
    ///
    /// **Failable rather than clamping**, because the caller is either a settings
    /// read — where the right answer to a nonsense stored value is "use the default",
    /// which only the caller knows — or a test. Clamping would turn `25:00` into
    /// 23:59 and refresh at a time the user never chose.
    public init?(minutesSinceMidnight minutes: Int) {
        guard (0..<Self.minutesPerDay).contains(minutes) else { return nil }
        self.minutesSinceMidnight = minutes
    }

    /// `nil` unless both components are in range.
    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.minutesSinceMidnight = hour * 60 + minute
    }

    /// The hour and minute `date` falls on, in `calendar`.
    ///
    /// Not failable: `Calendar.component(_:from:)` answers an hour in `0..<24` and a
    /// minute in `0..<60` for every date and every calendar, so there is no
    /// out-of-range case for a caller to handle. This is how the Settings picker's
    /// `Date` becomes a setting.
    public init(of date: Date, calendar: Calendar) {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        self.init(unchecked: hour * 60 + minute)
    }

    /// Trusted construction, for values the compiler or `Calendar` has already
    /// bounded. Private, so "trusted" cannot be claimed from another file.
    private init(unchecked minutes: Int) {
        self.minutesSinceMidnight = minutes
    }

    /// This time of day on `day`'s calendar date, or `nil` if the calendar cannot
    /// form one.
    ///
    /// **The one place `date(bySettingHour:minute:second:of:)` is called**, so its
    /// behaviour is documented once. Probed on 2026-10-06, `America/Los_Angeles`:
    ///
    /// - It does **not** search forward across days, despite `direction` defaulting
    ///   to `.forward`: 08:00 applied to a 14:00 date answers that same day's 08:00,
    ///   already in the past. The `startOfDay` anchor below is kept regardless, so
    ///   that which day is meant does not depend on reading that subtlety correctly.
    /// - On a spring-forward day, a time inside the skipped hour answers the next
    ///   valid instant that day — 02:30 becomes 03:00 — under the default
    ///   `matchingPolicy: .nextTime`. `.strict` instead answers *the next day's*
    ///   02:30, which would skip a day's refresh outright, so the default is load
    ///   bearing and not merely inherited.
    /// - On a fall-back day, a repeated time answers its first instance.
    ///
    /// The `nil` return is unreachable for a `TimeOfDay`, every value of which names
    /// an hour and minute `Calendar` can match. It is still propagated rather than
    /// forced, because the only honest alternative is a crash in a background timer.
    public func instant(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
    }
}
