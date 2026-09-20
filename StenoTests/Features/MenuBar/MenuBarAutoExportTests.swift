import Foundation
import Testing

@testable import StenoKit

/// The popover is the surface a user with no main window open actually sees,
/// which is why §10.5's failure has to reach it (D-123).
@Test("the popover reports a failure recorded by a previous process")
@MainActor
func thePopoverReportsAPersistedFailure() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastFailure: .init(failedAt: fixture.stamp, message: "the folder went missing"))

    let model = MenuBarModel(context: fixture.context, settings: fixture.settings)

    #expect(model.autoExportProblem == "the folder went missing")
}

@Test("the popover picks up a failure that happens while it is resident")
@MainActor
func thePopoverPicksUpALaterFailure() throws {
    let fixture = try autoExportFixture()
    let model = MenuBarModel(context: fixture.context, settings: fixture.settings)
    #expect(model.autoExportProblem == nil)

    fixture.recorder.writeFailure = AutoExportFailure(detail: "no space left on device")
    fixture.service().run(trigger: .quit)

    #expect(model.autoExportProblem?.contains("Nothing on this Mac was changed") == true)
}

/// There is no dismissal gesture here, and reopening the popover must not
/// become one: `prepareForShow()` clears `writeError`, and clearing this too
/// would let a user close the one message telling them they have no backup.
@Test("reopening the popover does not clear the backup failure")
@MainActor
func reopeningDoesNotClearTheFailure() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastFailure: .init(failedAt: fixture.stamp, message: "the folder went missing"))
    let model = MenuBarModel(context: fixture.context, settings: fixture.settings)

    model.prepareForShow()

    #expect(model.autoExportProblem == "the folder went missing")
}

@Test("a successful export clears it")
@MainActor
func aSuccessClearsIt() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastFailure: .init(failedAt: fixture.stamp, message: "the folder went missing"))
    let model = MenuBarModel(context: fixture.context, settings: fixture.settings)

    fixture.service().run(trigger: .quit)

    #expect(model.autoExportProblem == nil)
}
