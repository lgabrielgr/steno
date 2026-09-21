import Foundation
import Testing

@testable import StenoKit

@Test("the pane reads the shipped defaults")
@MainActor
func theDataPaneReadsTheDefaults() throws {
    let fixture = try autoExportFixture()

    let model = DataSettingsModel(settings: fixture.settings, service: fixture.service())

    #expect(model.isEnabled)
    #expect(model.exportsOnQuit)
    #expect(model.exportsDaily)
    #expect(model.folder.path == fixture.folder.path)
}

@Test("each toggle writes through to the settings store")
@MainActor
func togglesWriteThrough() throws {
    let fixture = try autoExportFixture()
    let model = DataSettingsModel(settings: fixture.settings, service: fixture.service())

    model.isEnabled = false
    model.exportsOnQuit = false
    model.exportsDaily = false

    #expect(fixture.settings.autoExportEnabled == false)
    #expect(fixture.settings.autoExportOnQuit == false)
    #expect(fixture.settings.autoExportDaily == false)
}

@Test("Back Up Now writes a file and refreshes what the pane shows")
@MainActor
func backUpNowWrites() throws {
    let fixture = try autoExportFixture()
    let model = DataSettingsModel(settings: fixture.settings, service: fixture.service())

    model.exportNow()

    let url = fixture.folder.appendingPathComponent(ExportFilename.forDate(fixture.stamp))
    #expect(fixture.recorder.written == [url])
    #expect(model.status.lastSuccess?.path == url.path)
}

/// Verifying the choice immediately is the point: a folder that cannot be
/// written to should say so while the user is in the pane that chose it, not at
/// the next quit.
@Test("choosing a folder exports into it straight away")
@MainActor
func choosingAFolderVerifiesIt() throws {
    let fixture = try autoExportFixture()
    let chosen = autoExportScratchDirectory()
    let model = DataSettingsModel(
        settings: fixture.settings, panels: StubFilePanels(exportFolder: chosen),
        service: fixture.service())

    model.chooseFolder()

    #expect(model.folder.path == chosen.path)
    #expect(fixture.recorder.written.first?.path.hasPrefix(chosen.path) == true)
}

/// Important finding, final review of M2.5-05: `statusObservation` is the
/// pane's live channel for a failure recorded by *another* trigger — the
/// hourly tick or the quit hook — while the pane sits open. Nothing else in
/// this file proves it works: the other four tests reach `refresh()` only
/// through `exportNow()`, or never post at all, so deleting the registration
/// left every one of them green. Mirrors
/// `AutoExportWindowModelTests.theBannerUpdatesOnNotification` and
/// `MenuBarAutoExportTests.thePopoverPicksUpALaterFailure`, which prove the
/// same property for the window banner and the popover.
///
/// **Confirmed by mutation**: with `statusObservation`'s registration deleted
/// from `DataSettingsModel.init`, this test alone goes red while the other
/// four in this file stay green — see the PR body / fix report.
@Test("the pane's status updates when an export fails in the background")
@MainActor
func theStatusUpdatesOnNotification() throws {
    let fixture = try autoExportFixture()
    let model = DataSettingsModel(settings: fixture.settings, service: fixture.service())
    fixture.recorder.writeFailure = AutoExportFailure(detail: "no space left on device")

    // A different `AutoExportService` instance, over the same settings and
    // recorder — the shape of a failure recorded by the hourly tick or the
    // quit hook while this pane is open, not by this model's own
    // `exportNow()`.
    fixture.service().run(trigger: .quit)

    #expect(model.status.lastFailure != nil)
}

/// Carried finding, final review of M2.5-05: a refusal from an earlier
/// attempt must not outlive a later cancel that touched no folder.
@Test("cancelling the folder panel clears a previously-set refusal")
@MainActor
func cancellingClearsAPriorRefusalInTheDataPane() throws {
    let fixture = try autoExportFixture()
    // In-memory containers report `/dev/null` as their configuration's URL
    // (`StenoStore.inMemory()`), so `/dev/anything` reads as inside the
    // store's own directory to `StoreFileGuard.isInsideStoreDirectory` and
    // `service.problem(withFolder:)` refuses it.
    let refused = URL(fileURLWithPath: "/dev/inside-the-store", isDirectory: true)
    let panels = StubFilePanels(exportFolder: refused)
    let model = DataSettingsModel(
        settings: fixture.settings, panels: panels, service: fixture.service())

    model.chooseFolder()
    #expect(model.folderProblem != nil)

    panels.exportFolder = nil
    model.chooseFolder()

    #expect(model.folderProblem == nil)
}

@Test("a store that failed to open disables the pane and says why")
@MainActor
func aFailedStoreDisablesThePane() throws {
    let fixture = try autoExportFixture()

    let model = DataSettingsModel(settings: fixture.settings, service: nil)

    #expect(model.storeFailureNote != nil)
    model.exportNow()
    #expect(fixture.recorder.written.isEmpty)
}

/// The pane's own half of the same fix. `DataSettingsPane` is SwiftUI in the
/// app target, which the unhosted test bundle cannot reach (D-010) — so the
/// button's enablement rule lives on the model, where it can be asserted, and
/// the view binds to it rather than re-deriving it.
@Test("Back Up Now stays available while auto-export is off")
@MainActor
func backUpNowStaysAvailableWhileDisabled() throws {
    let fixture = try autoExportFixture()
    let model = DataSettingsModel(settings: fixture.settings, service: fixture.service())

    model.isEnabled = false

    #expect(model.canBackUpNow)
}

@Test("Back Up Now is unavailable when the store could not be opened")
@MainActor
func backUpNowIsUnavailableWithoutAStore() {
    // The gate that must survive: there is nothing to export, and D-018's
    // posture is that the app runs on without one.
    let model = DataSettingsModel(service: nil)

    #expect(model.canBackUpNow == false)
}
