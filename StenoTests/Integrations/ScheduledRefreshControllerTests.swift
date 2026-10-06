import Foundation
import Testing

@testable import StenoKit

/// A box, because the refresh closure escapes and a captured `var` cannot be mutated
/// from one.
@MainActor
private final class PassCounter {
    var count = 0
}

@MainActor
private func scratchSettings() throws -> AppSettings {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return AppSettings(defaults: defaults)
}

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

/// A controller whose clock stands still at `nowText` and whose pass does nothing.
///
/// The pass is a no-op because every test here asserts the *decision*, which
/// `tick()` and `runLaunchPass()` return synchronously. Observing the pass itself
/// through the closure would mean waiting on a `Task` that has not necessarily started
/// when they return — `aDispatchedPassReachesTheRefreshClosure` below is the one test
/// that waits for it, and it waits deterministically.
@MainActor
private func controller(
    settings: AppSettings, at nowText: String
) throws -> ScheduledRefreshController {
    let calendar = try pacific()
    let moment = try instant(nowText, in: calendar)
    return ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar }, refresh: {})
}

@Test("a tick inside the window dispatches and stamps")
@MainActor
func aTickInsideTheWindowDispatches() throws {
    let settings = try scratchSettings()
    let subject = try controller(settings: settings, at: "2026-10-06 08:03:00")

    #expect(subject.tick())
    #expect(settings.scheduledRefreshLastRun != nil)
}

@Test("a tick before the window neither dispatches nor stamps")
@MainActor
func aTickBeforeTheWindowDoesNothing() throws {
    let settings = try scratchSettings()
    let subject = try controller(settings: settings, at: "2026-10-06 07:30:00")

    #expect(subject.tick() == false)
    #expect(settings.scheduledRefreshLastRun == nil)
}

/// Five-minute ticks mean a four-hour window contains forty-eight of them. One
/// occurrence, one pass: the stamp written at dispatch is what makes the rest not-due,
/// which is also why the controller needs no in-flight flag.
@Test("two ticks inside one occurrence dispatch one pass")
@MainActor
func twoTicksDispatchOnePass() throws {
    let settings = try scratchSettings()
    let subject = try controller(settings: settings, at: "2026-10-06 08:03:00")

    #expect(subject.tick())
    #expect(subject.tick() == false)
}

/// The stamp is written at dispatch, not at success (D-223), so a pass that fails is
/// not retried every five minutes until noon. The failure is modelled the way §5.5
/// makes it available: the refresh closure returns having done nothing useful.
@Test("a failed pass is not retried inside the same occurrence")
@MainActor
func aFailedPassIsNotRetried() throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let attempts = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: { attempts.count += 1 })

    #expect(subject.tick())
    #expect(subject.tick() == false)
    #expect(subject.tick() == false)
    // The stamp survived the failure, which is the whole point: the next occurrence
    // still runs, this one does not run again.
    #expect(settings.scheduledRefreshLastRun == moment)
    #expect(attempts.count <= 1)
}

@Test("the toggle switches the schedule off entirely")
@MainActor
func theToggleSwitchesItOff() throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let subject = try controller(settings: settings, at: "2026-10-06 08:03:00")

    #expect(subject.tick() == false)
    // Nothing was claimed, so switching the schedule back on later still serves the
    // occurrence rather than finding it already stamped.
    #expect(settings.scheduledRefreshLastRun == nil)
}

/// §5.5's launch pass runs whether or not an occurrence is owed; the schedule decides
/// only whether this pass also serves one (D-224). Two passes at launch is the defect
/// this pins.
@Test("the launch pass runs even when no occurrence is owed")
@MainActor
func theLaunchPassAlwaysRuns() throws {
    let settings = try scratchSettings()
    let early = try controller(settings: settings, at: "2026-10-06 06:00:00")

    #expect(early.runLaunchPass() == false)
    #expect(settings.scheduledRefreshLastRun == nil)
}

@Test("a launch inside the window serves the occurrence as well")
@MainActor
func aLaunchInsideTheWindowServesIt() throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 09:30:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar }, refresh: {})

    #expect(subject.runLaunchPass())
    #expect(settings.scheduledRefreshLastRun == moment)
    // And the tick that follows minutes later finds nothing owed.
    #expect(subject.tick() == false)
}

/// A scheduled `Timer` is retained by the run loop, so reassigning the property does
/// not stop the old one. Found by Copilot in PR #32 against `AutoExportController`; the
/// assertion here is that a second `start()` leaves exactly one armed timer, observed
/// through the controller's own handle.
@Test("start is idempotent and leaves one armed timer")
@MainActor
func startIsIdempotent() throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let subject = try controller(settings: settings, at: "2026-10-06 06:00:00")

    subject.start(interval: 3600)
    let first = try #require(subject.armedTimer)
    subject.start(interval: 3600)
    let second = try #require(subject.armedTimer)

    #expect(first !== second)
    #expect(first.isValid == false, "the first timer must have been invalidated")
    #expect(second.isValid)

    subject.stop()
    #expect(subject.armedTimer == nil)
    #expect(second.isValid == false)
}

/// The one test that waits for the pass itself. `withCheckedContinuation`'s body runs
/// synchronously, so the dispatch happens before the await — and the await ends only
/// when the closure has actually run, rather than when a `Task` has been created.
@Test("a dispatched pass reaches the refresh closure")
@MainActor
func aDispatchedPassReachesTheRefreshClosure() async throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let subject = ScheduledRefreshController(
            settings: settings, now: { moment }, calendar: { calendar },
            refresh: { continuation.resume() })
        #expect(subject.tick())
    }
}
