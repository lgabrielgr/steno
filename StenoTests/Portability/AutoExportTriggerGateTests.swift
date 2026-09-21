import Foundation
import Testing

@testable import StenoKit

// Which triggers are allowed to run, and which the settings stop.
//
// Split from `AutoExportServiceTests` when that file reached SwiftLint's
// 400-line cap — the same cap that put `AutoExportWindowModel` in its own type
// (D-123). These four belong together anyway: they are all about the gate, and
// none of them is about what a run writes.

@Test("auto-export turned off stops the automatic triggers")
@MainActor
func disabledStopsTheAutomaticTriggers() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportEnabled = false

    #expect(fixture.service().run(trigger: .quit) == .skipped(.disabled))
    #expect(fixture.service().run(trigger: .daily) == .skipped(.disabled))
    #expect(fixture.recorder.written.isEmpty)
}

/// **The setting governs *automatic* backup, not backup.** `.manual` is what
/// the Data pane's "Back Up Now" runs, and it used to be refused here too —
/// which is how a standing failure became unclearable: D-123 clears status only
/// on a success, the button was gated on the same toggle, and turning
/// auto-export off therefore removed the only way to produce one. The warning
/// then sat in the popover and the Data pane with nothing the user could do
/// about it.
///
/// Un-gating is not "the feature working while it is off". A manual export
/// already works with this toggle off, from File > Export and from `steno
/// export`; the Data pane's button was the one manual surface that did not.
/// `AutoExportTrigger.isEnabled(by:)` already said `case .manual: return true`
/// — the blanket guard simply ran first.
@Test("a manual backup still runs while auto-export is off")
@MainActor
func aManualBackupRunsWhileDisabled() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportEnabled = false

    guard case .written = fixture.service().run(trigger: .manual) else {
        Issue.record("a manual backup was refused while auto-export was off")
        return
    }
    #expect(fixture.recorder.written.count == 1)
}

/// The bug in one test: the state a user was stuck in, and the way out.
@Test("a manual backup clears a standing failure while auto-export is off")
@MainActor
func aManualBackupClearsAStandingFailureWhileDisabled() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastSuccess: nil,
        lastFailure: AutoExportStatus.Failure(
            failedAt: Date(timeIntervalSince1970: 1_000_000),
            message: "the backup folder could not be written to"))
    fixture.settings.autoExportEnabled = false

    guard case .written = fixture.service().run(trigger: .manual) else {
        Issue.record("a manual backup was refused while auto-export was off")
        return
    }

    #expect(fixture.settings.autoExportStatus.lastFailure == nil)
    #expect(fixture.settings.autoExportStatus.lastSuccess != nil)
}

@Test("each trigger's own toggle gates only that trigger")
@MainActor
func aTriggerTogglesIndependently() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportOnQuit = false

    #expect(fixture.service().run(trigger: .quit) == .skipped(.triggerOff))
    guard case .written = fixture.service().run(trigger: .daily) else {
        Issue.record("the daily trigger was disabled by the quit toggle")
        return
    }
}
