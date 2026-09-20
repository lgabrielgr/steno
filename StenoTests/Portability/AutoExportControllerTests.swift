import AppKit
import Foundation
import Testing

@testable import StenoKit

/// The controller was shipped untested on the grounds that it is "a timer plus
/// a notification observer" with nothing decidable in it. Copilot's review of
/// PR #32 pointed out what that leaves uncovered, and it is the wrong thing to
/// leave uncovered: **the quit trigger is the one that runs most often**, and
/// if its observer were never registered, nothing anywhere would fail. Every
/// test below would pass against a controller whose `start()` did nothing.
///
/// The timer itself is still not tested — an hourly `Timer` is Foundation's to
/// get right — so `start(interval:)` is given an interval far longer than any
/// test run, and the tick path is exercised through `runDaily()` directly.
@MainActor
private func controllerFixture() throws -> (AutoExportController, AutoExportFixture) {
    let fixture = try autoExportFixture()
    return (AutoExportController(service: fixture.service()), fixture)
}

@Test("start() takes the launch backup")
@MainActor
func startTakesTheLaunchBackup() throws {
    let (controller, fixture) = try controllerFixture()
    defer { controller.stop() }

    controller.start(interval: 3600)

    #expect(fixture.recorder.written.count == 1)
}

/// The acceptance criterion behind the whole quit trigger: terminating the app
/// writes a backup. `NSApplication.willTerminateNotification` is what the
/// controller observes, so posting it is the closest a headless test can stand
/// to a real ⌘Q — and it is close enough to prove the registration exists.
@Test("terminating the app takes a backup")
@MainActor
func terminatingTakesABackup() throws {
    let (controller, fixture) = try controllerFixture()
    defer { controller.stop() }
    controller.start(interval: 3600)
    #expect(fixture.recorder.written.count == 1)

    NotificationCenter.default.post(
        name: NSApplication.willTerminateNotification, object: nil)

    #expect(fixture.recorder.written.count == 2)
}

/// The quit export is unconditional (D-121), so it must fire even when a daily
/// one would be skipped as not due — which, right after `start()`, it is.
@Test("terminating backs up even though a daily export is not due")
@MainActor
func terminatingIgnoresDueness() throws {
    let (controller, fixture) = try controllerFixture()
    defer { controller.stop() }
    controller.start(interval: 3600)
    #expect(controller.runDaily() == .skipped(.notDue))

    NotificationCenter.default.post(
        name: NSApplication.willTerminateNotification, object: nil)

    #expect(fixture.recorder.written.count == 2)
}

/// `stop()` exists so a controller can be torn down; a stopped one that still
/// exported on termination would mean the observer outlived its owner.
@Test("a stopped controller does not back up on termination")
@MainActor
func stoppingUnregistersTheObserver() throws {
    let (controller, fixture) = try controllerFixture()
    controller.start(interval: 3600)
    let afterStart = fixture.recorder.written.count

    controller.stop()
    NotificationCenter.default.post(
        name: NSApplication.willTerminateNotification, object: nil)

    #expect(fixture.recorder.written.count == afterStart)
}
