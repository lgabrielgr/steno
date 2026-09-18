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

@Test("a store that failed to open disables the pane and says why")
@MainActor
func aFailedStoreDisablesThePane() throws {
    let fixture = try autoExportFixture()

    let model = DataSettingsModel(settings: fixture.settings, service: nil)

    #expect(model.storeFailureNote != nil)
    model.exportNow()
    #expect(fixture.recorder.written.isEmpty)
}
