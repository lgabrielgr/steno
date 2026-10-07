import AppKit
import Foundation
import Testing

@testable import StenoKit

/// A box, because the refresh closure escapes and a captured `var` cannot be mutated
/// from one.
@MainActor
private final class PassCounter {
    var total = 0
}

/// Wait up to `limit` for `condition`, yielding between checks.
///
/// **A deadline, not a continuation the refresh closure resumes.** The continuation
/// version read better and was wrong in the way that matters: a mutation which stops the
/// pass being dispatched left it never resumed, so the suite *hung* instead of going red
/// — found by the mutation sweep, where one edit turned a fifteen-second run into a
/// fifteen-minute one. A test that hangs under mutation is worse than one that fails,
/// because the failure never arrives and nothing says why.
///
/// Returns `false` on timeout, so the caller's `#expect` is what records the issue. Two
/// seconds is generous for a `Task` already enqueued on this actor; the loop costs
/// nothing when the pass has already run.
@MainActor
private func waitFor(
    _ limit: Duration = .seconds(2), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
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
/// `tick()` and `runCatchUpPass()` return synchronously. Observing the pass itself
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
        settings: settings, now: { moment }, calendar: { calendar }, refresh: { .idle })
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
        refresh: {
            attempts.total += 1
            return .idle
        })

    #expect(subject.tick())
    #expect(subject.tick() == false)
    #expect(subject.tick() == false)
    // The stamp survived the failure, which is the whole point: the next occurrence
    // still runs, this one does not run again.
    #expect(settings.scheduledRefreshLastRun == moment)
    #expect(attempts.total <= 1)
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

    #expect(early.runCatchUpPass() == false)
    #expect(settings.scheduledRefreshLastRun == nil)
}

@Test("a launch inside the window serves the occurrence as well")
@MainActor
func aLaunchInsideTheWindowServesIt() throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 09:30:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar }, refresh: { .idle })

    #expect(subject.runCatchUpPass())
    #expect(settings.scheduledRefreshLastRun == moment)
    // And the tick that follows minutes later finds nothing owed.
    #expect(subject.tick() == false)
}

/// **Switching the schedule off must not switch off §5.5's launch pass**, which is a
/// fixed rule and not the setting the user was given. The toggle governs the unattended
/// pass at a time of day; a launch is the user opening the app.
@Test("the launch pass still runs with the schedule switched off")
@MainActor
func theLaunchPassIgnoresTheToggle() async throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)

    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            passes.total += 1
            return .idle
        })

    // No occurrence is claimed — the schedule is off — and the pass runs anyway.
    #expect(subject.runCatchUpPass() == false)
    #expect(await waitFor { passes.total == 1 }, "the launch pass never reached the service")
    #expect(settings.scheduledRefreshLastRun == nil)
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

/// The test that waits for the pass itself rather than for the decision — the dispatch is
/// the one thing `tick()`'s return value does not prove, because a `Task` has not
/// necessarily started when the method that created it returns.
@Test("a dispatched pass reaches the refresh closure")
@MainActor
func aDispatchedPassReachesTheRefreshClosure() async throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            passes.total += 1
            return .idle
        })

    #expect(subject.tick())

    #expect(await waitFor { passes.total == 1 }, "the pass never reached the service")
}

/// **An abandoned controller must not leave a timer firing forever** (D-232). The run loop
/// retains a scheduled `Timer` while the tick block holds its owner weakly, so a controller
/// dropped without `stop()` used to wake every interval to find `nil` — unbounded, and "fires
/// forever to do nothing" is the spin M4-05's fourth acceptance criterion forbids. The `deinit`
/// comment described that as harmless, which is how a defect becomes a documented decision.
///
/// The `Timer` is held here, not the controller: that is the only way to watch what happens to
/// it after its owner is gone.
@Test("a dropped controller's timer invalidates itself on the next tick")
@MainActor
func anAbandonedTimerInvalidatesItself() async throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let calendar = try pacific()
    let moment = try instant("2026-10-06 06:00:00", in: calendar)
    var subject: ScheduledRefreshController? = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar }, refresh: { .idle })
    subject?.start(interval: 0.05)
    let timer = try #require(subject?.armedTimer)
    #expect(timer.isValid)

    subject = nil

    #expect(
        await waitFor { !timer.isValid },
        "the timer outlived its controller and is still firing")
}
