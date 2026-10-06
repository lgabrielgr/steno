import AppKit
import Foundation
import Testing

@testable import StenoKit

/// What an unattended pass records, announces and catches up on — D-227, D-228, D-229.
///
/// **A second file because the first reached SwiftLint's 400-line limit**, and because this
/// is a different subject: `ScheduledRefreshControllerTests` is about when a pass runs, and
/// this is about what the pass leaves behind for a surface to read.

@MainActor
private final class PassCounter {
    var total = 0
}

/// See `ScheduledRefreshControllerTests` for why this is a deadline rather than a
/// continuation the code under test resumes: that version hangs under mutation instead of
/// failing.
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

// MARK: - D-227: what an unattended pass records about the credential

@Test("a refused credential is persisted by the pass that found it")
@MainActor
func aRefusedCredentialIsPersisted() async throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            RefreshOutcome(
                attempted: 1,
                failures: [
                    RefreshOutcome.Failure(
                        connectorID: "jira", displayName: "Jira", error: .credentialExpired)
                ])
        })

    #expect(subject.tick())

    #expect(await waitFor { settings.scheduledRefreshRejection != nil })
    let rejection = try #require(settings.scheduledRefreshRejection)
    #expect(rejection.displayName == "Jira")
    #expect(rejection.discoveredAt == moment)
}

@Test("a later pass that reaches the source clears the record")
@MainActor
func aLaterPassClearsTheRecord() async throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshRejection = CredentialRejection(displayName: "Jira", at: .distantPast)
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: { RefreshOutcome(attempted: 2, cached: 2) })

    #expect(subject.tick())

    #expect(await waitFor { settings.scheduledRefreshRejection == nil })
}

/// A pass with nothing due is the normal case, so clearing on one would erase the warning on
/// the next tick after recording it.
@Test("a pass that attempted nothing leaves the record standing")
@MainActor
func anEmptyPassLeavesTheRecord() async throws {
    let settings = try scratchSettings()
    let recorded = CredentialRejection(displayName: "Jira", at: .distantPast)
    settings.scheduledRefreshRejection = recorded
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
    #expect(await waitFor { passes.total == 1 })

    #expect(settings.scheduledRefreshRejection == recorded)
}

// MARK: - D-228: a wake is a launch, for an app that never closed

/// The gap D-224 argued did not exist. A Mac asleep from 02:00 to 13:00 with Steno still
/// running gets no launch pass — the app never relaunched — and the first resumed tick finds
/// the occurrence five hours past its grace window. Before the wake observation, nothing
/// refreshed until the user pressed Prepare.
@Test("a wake refreshes even when the occurrence is long past")
@MainActor
func aWakeRefreshesAfterTheWindow() async throws {
    let settings = try scratchSettings()
    let workspace = NotificationCenter()
    let calendar = try pacific()
    let afternoon = try instant("2026-10-06 13:00:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { afternoon }, calendar: { calendar },
        workspaceCenter: workspace, center: NotificationCenter(),
        refresh: {
            passes.total += 1
            return .idle
        })
    subject.start(interval: 3600)
    #expect(await waitFor { passes.total == 1 }, "the pass armed by start() never ran")

    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(await waitFor { passes.total == 2 }, "a wake must run a catch-up pass")
    // And it does not resurrect a morning that has gone: the occurrence stays unclaimed, so
    // tomorrow's is unaffected and nothing fires again today.
    #expect(settings.scheduledRefreshLastRun == nil)
}

@Test("a wake inside the window serves the occurrence")
@MainActor
func aWakeInsideTheWindowServesIt() async throws {
    let settings = try scratchSettings()
    let workspace = NotificationCenter()
    let calendar = try pacific()
    let morning = try instant("2026-10-06 09:00:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { morning }, calendar: { calendar },
        workspaceCenter: workspace, center: NotificationCenter(),
        refresh: {
            passes.total += 1
            return .idle
        })
    // Stopped, so only the wake drives this test — `start()` would claim the occurrence
    // itself and leave nothing for the wake to do.
    settings.scheduledRefreshLastRun = nil

    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    // No observation is armed until `start()`, so nothing happened.
    #expect(passes.total == 0)
    subject.start(interval: 3600)
    #expect(await waitFor { passes.total == 1 })
    #expect(settings.scheduledRefreshLastRun == morning)
    subject.stop()
}

/// A burst of wakes must not become a burst of fetches. The stamp stops the occurrence being
/// claimed twice; `refreshDue()`'s staleness rule and the gate are what stop the passes
/// themselves from costing anything, which is why dispatching on every wake is safe.
@Test("repeated wakes claim the occurrence once")
@MainActor
func repeatedWakesClaimOnce() async throws {
    let settings = try scratchSettings()
    let workspace = NotificationCenter()
    let calendar = try pacific()
    let morning = try instant("2026-10-06 09:00:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { morning }, calendar: { calendar },
        workspaceCenter: workspace, center: NotificationCenter(),
        refresh: {
            passes.total += 1
            return .idle
        })
    subject.start(interval: 3600)
    #expect(await waitFor { passes.total == 1 })

    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(await waitFor { passes.total == 3 })
    #expect(settings.scheduledRefreshLastRun == morning)
    subject.stop()
}

@Test("stop disarms the wake observation")
@MainActor
func stopDisarmsTheWake() async throws {
    let settings = try scratchSettings()
    let workspace = NotificationCenter()
    let calendar = try pacific()
    let morning = try instant("2026-10-06 06:00:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { morning }, calendar: { calendar },
        workspaceCenter: workspace, center: NotificationCenter(),
        refresh: {
            passes.total += 1
            return .idle
        })
    subject.start(interval: 3600)
    #expect(await waitFor { passes.total == 1 })

    subject.stop()
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(await waitFor(.milliseconds(300)) { passes.total > 1 } == false)
}

// MARK: - D-229: an open pane hears about a rejection

@Test("recording a rejection announces it")
@MainActor
func recordingARejectionAnnouncesIt() async throws {
    let settings = try scratchSettings()
    let center = NotificationCenter()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let announcements = PassCounter()
    let observation = center.addObserver(
        forName: .stenoScheduledRefreshDidChange, object: nil, queue: nil
    ) { _ in
        MainActor.assumeIsolated { announcements.total += 1 }
    }
    defer { center.removeObserver(observation) }
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        workspaceCenter: NotificationCenter(), center: center,
        refresh: {
            RefreshOutcome(
                attempted: 1,
                failures: [
                    RefreshOutcome.Failure(
                        connectorID: "jira", displayName: "Jira", error: .credentialExpired)
                ])
        })

    #expect(subject.tick())

    #expect(await waitFor { announcements.total == 1 }, "an open pane would never redraw")
}

/// **Only when it changed.** A pass that records the same nothing it found last time must not
/// redraw the pane: a notification that fires every five minutes is one readers learn to
/// ignore, and this one is read by a surface that is usually not even open.
@Test("a pass that changes nothing announces nothing")
@MainActor
func anUnchangedPassAnnouncesNothing() async throws {
    let settings = try scratchSettings()
    let center = NotificationCenter()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let announcements = PassCounter()
    let passes = PassCounter()
    let observation = center.addObserver(
        forName: .stenoScheduledRefreshDidChange, object: nil, queue: nil
    ) { _ in
        MainActor.assumeIsolated { announcements.total += 1 }
    }
    defer { center.removeObserver(observation) }
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        workspaceCenter: NotificationCenter(), center: center,
        refresh: {
            passes.total += 1
            return RefreshOutcome(attempted: 2, cached: 2)
        })

    #expect(subject.tick())

    #expect(await waitFor { passes.total == 1 })
    #expect(announcements.total == 0)
}
