import Foundation
import Testing

@testable import StenoKit

@MainActor
private func scratch() throws -> (ScheduledRefreshSettingsModel, AppSettings) {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let model = ScheduledRefreshSettingsModel(settings: settings, calendar: { calendar })
    return (model, settings)
}

@Test("a fresh install is scheduled for 08:00")
@MainActor
func aFreshInstallIsScheduled() throws {
    let (model, _) = try scratch()

    #expect(model.isEnabled)
    #expect(model.time == .eightAM)
}

/// The mirror has to be written through, or the controller — which reads `AppSettings`
/// per tick — keeps the old schedule until the next launch.
@Test("switching the schedule off writes through to the settings")
@MainActor
func switchingOffWritesThrough() throws {
    let (model, settings) = try scratch()

    model.isEnabled = false

    #expect(settings.scheduledRefreshEnabled == false)
}

@Test("setting a time writes through to the settings")
@MainActor
func settingATimeWritesThrough() throws {
    let (model, settings) = try scratch()
    let halfPastSix = try #require(TimeOfDay(hour: 6, minute: 30))

    model.time = halfPastSix

    #expect(settings.scheduledRefreshTime == halfPastSix)
}

/// What the `DatePicker` binding does: the instant it hands back carries a date this
/// setting must not keep, because an instant drifts with the time zone it was set in
/// and a time of day does not.
@Test("the picker's date becomes an hour and a minute, and nothing else")
@MainActor
func thePickersDateBecomesATimeOfDay() throws {
    let (model, settings) = try scratch()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let components = DateComponents(
        calendar: calendar, year: 1999, month: 12, day: 31, hour: 7, minute: 15)
    let fromAnotherCentury = try #require(components.date)

    model.pickerDate = fromAnotherCentury

    #expect(settings.scheduledRefreshTime == (try #require(TimeOfDay(hour: 7, minute: 15))))
    // And reading it back shows the same clock time on today's date, not in 1999.
    #expect(calendar.component(.hour, from: model.pickerDate) == 7)
    #expect(calendar.component(.minute, from: model.pickerDate) == 15)
    #expect(calendar.component(.year, from: model.pickerDate) != 1999)
}

@Test("a stored schedule is read back at launch")
@MainActor
func aStoredScheduleIsReadBack() throws {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    settings.scheduledRefreshEnabled = false
    settings.scheduledRefreshTime = try #require(TimeOfDay(hour: 21, minute: 45))

    let model = ScheduledRefreshSettingsModel(settings: settings)

    #expect(model.isEnabled == false)
    #expect(model.time.hour == 21)
    #expect(model.time.minute == 45)
}
