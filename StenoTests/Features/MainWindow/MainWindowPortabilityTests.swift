import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §10.5's File menu, end to end through the window's model.
///
/// The sheet is layout with no logic (D-010 puts it beyond this bundle), so
/// these are the tests that cover what pressing the menu items actually does.

private struct BackupRefused: Error {}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-portability-tests-\(UUID().uuidString)", isDirectory: true)
}

/// A window under test: the model, and the pieces a test needs to look behind
/// it.
///
/// A named type rather than a three-member tuple, which SwiftLint's
/// `large_tuple` rejects under `--strict`. `container` is held rather than
/// discarded because `mainContext` does not retain its container — a test whose
/// container is a local would dangle.
@MainActor
private struct Window {
    let model: MainWindowModel
    let container: ModelContainer
    let context: ModelContext
}

/// A store with one project and one task, plus the model over it.
@MainActor
private func window(
    panels: StubFilePanels,
    backupDirectory: URL? = nil,
    backupWrite: ((Data, URL) throws -> Void)? = nil
) throws -> Window {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let project = Project(
        id: UUID(), name: "Payments", colorHex: "#112233",
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    context.insert(project)
    let task = TaskItem(
        id: UUID(), title: "Fix the retry handler", projectID: project.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_010))
    context.insert(task)
    try context.save()

    let model = MainWindowModel(
        context: context,
        panels: panels,
        makeBackupWriter: { context in
            try BackupWriter(
                context: context,
                directory: backupDirectory ?? temporaryDirectory(),
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                write: backupWrite ?? { try $0.write(to: $1, options: .atomic) })
        })
    return Window(model: model, container: container, context: context)
}

@MainActor
@Test("export writes the file the panel chose and says where it went")
func exportWritesAndReports() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("out.json")

    let panels = StubFilePanels(
        exportDestination: ExportDestination(url: url, includesCachedExternalData: false))
    let harness = try window(panels: panels)

    harness.model.exportStore()

    #expect(FileManager.default.fileExists(atPath: url.path))
    let document = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try Data(contentsOf: url))
    #expect(document.tasks.count == 1)

    // The outcome is a notice, not an error: rendering a success in the error
    // banner's colours would misreport an operation that just wrote a file.
    #expect(harness.model.lastError == nil)
    #expect(harness.model.lastNotice?.contains(url.path) == true)
    // §10.2's default name, offered to the panel rather than invented by it.
    #expect(panels.lastDefaultName?.hasPrefix("steno-export-") == true)
}

@MainActor
@Test("the export panel's checkbox reaches the encoder")
func theCachedDataCheckboxIsHonoured() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("out.json")

    let panels = StubFilePanels(
        exportDestination: ExportDestination(url: url, includesCachedExternalData: true))
    let harness = try window(panels: panels)

    harness.model.exportStore()

    let document = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try Data(contentsOf: url))
    // Without this the §10.2 opt-in is unreachable from any surface the user
    // has until M2.5-04's CLI ships.
    #expect(document.includesCachedExternalData)
}

@MainActor
@Test("cancelling the export panel writes nothing and says nothing")
func cancellingTheExportPanelIsSilent() throws {
    let panels = StubFilePanels(exportDestination: nil)
    let harness = try window(panels: panels)

    harness.model.exportStore()

    #expect(panels.exportPrompts == 1)
    #expect(harness.model.lastNotice == nil)
    // Cancelling is not a failure, and reporting it as one would train the user
    // to ignore the banner.
    #expect(harness.model.lastError == nil)
}

@MainActor
@Test("import opens the preview and writes nothing until it is confirmed")
func importPreviewsBeforeItWrites() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let panels = StubFilePanels(importSource: url)
    let harness = try window(panels: panels)
    let counter = WriteCounter()

    harness.model.importStore()

    #expect(harness.model.activeSheet == .importPreview)
    #expect(harness.model.importPreview.mode == .merge)
    // §10.4: "cancel leaves the store untouched". The strongest form of that is
    // that nothing was ever written — not that a rollback worked.
    #expect(counter.posts == 0)
    #expect(try harness.context.fetch(FetchDescriptor<TaskItem>()).count == 1)

    harness.model.dismissImportPreview()
    #expect(harness.model.activeSheet == nil)
    #expect(counter.posts == 0)
    #expect(try harness.context.fetch(FetchDescriptor<TaskItem>()).count == 1)
}

@MainActor
@Test("confirming the import applies it")
func confirmingAppliesTheImport() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let panels = StubFilePanels(importSource: url)
    let harness = try window(panels: panels)

    harness.model.importStore()
    harness.model.applyImport()

    #expect(harness.model.importPreview.phase == .applied)
    #expect(try harness.context.fetch(FetchDescriptor<TaskItem>()).count == 2)
}

@MainActor
@Test("a malformed file never opens the sheet")
func aMalformedFileIsReportedInline() throws {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("junk.json")
    try Data("this is not an export".utf8).write(to: url)

    let panels = StubFilePanels(importSource: url)
    let harness = try window(panels: panels)

    harness.model.importStore()

    // A modal whose only content is an error asks the user to dismiss something
    // they did not summon — `prepareStandup()` makes the same call.
    #expect(harness.model.activeSheet == nil)
    #expect(harness.model.lastError?.isEmpty == false)
}

@MainActor
@Test("replace writes a backup before it deletes anything")
func replaceBacksUpFirst() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let backups = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: backups) }

    let panels = StubFilePanels(importSource: url)
    let harness = try window(panels: panels, backupDirectory: backups)

    harness.model.replaceStoreFromFile()
    #expect(harness.model.importPreview.mode == .replace)
    // The path is shown *before* the user commits: that there is a way back is
    // information they need while deciding.
    let planned = try #require(harness.model.importPreview.backupURL)
    #expect(!FileManager.default.fileExists(atPath: planned.path))

    harness.model.importPreview.confirmation = "REPLACE"
    harness.model.applyImport()

    #expect(FileManager.default.fileExists(atPath: planned.path))
    // The local task is gone and the file's task is here — a replace, not a
    // merge.
    let titles = try harness.context.fetch(FetchDescriptor<TaskItem>()).map(\.title)
    #expect(titles == ["From the other Mac"])

    // And the backup holds what was replaced, which is the only reason it
    // exists.
    let backup = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try Data(contentsOf: planned))
    #expect(backup.tasks.map(\.title) == ["Fix the retry handler"])
}

@MainActor
@Test("a replace whose backup fails changes nothing at all")
func replaceFailsSafeWhenTheBackupFails() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let panels = StubFilePanels(importSource: url)
    let harness = try window(
        panels: panels, backupWrite: { _, _ in throw BackupRefused() })
    let counter = WriteCounter()

    harness.model.replaceStoreFromFile()
    harness.model.importPreview.confirmation = "REPLACE"
    harness.model.applyImport()

    // §10.1 makes the backup mandatory and the acceptance criterion is that
    // Replace "fails safe if that backup cannot be written". Nothing was
    // deleted, nothing was inserted, and nothing was even attempted — the
    // deletion phase is downstream of the throw.
    #expect(counter.posts == 0)
    #expect(harness.model.importPreview.phase == .previewing)
    #expect(harness.model.importPreview.lastError?.isEmpty == false)
    let titles = try harness.context.fetch(FetchDescriptor<TaskItem>()).map(\.title)
    #expect(titles == ["Fix the retry handler"])
}

@MainActor
@Test("replace does nothing until the word is typed")
func replaceIgnoresAnUnconfirmedApply() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let backups = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: backups) }

    let panels = StubFilePanels(importSource: url)
    let harness = try window(panels: panels, backupDirectory: backups)

    harness.model.replaceStoreFromFile()
    harness.model.applyImport()

    // Not even the backup: `applyImport` gates on `canApply` before it does
    // anything, so an unconfirmed Replace leaves no trace whatsoever.
    #expect(harness.model.importPreview.phase == .previewing)
    #expect(try harness.context.fetch(FetchDescriptor<TaskItem>()).count == 1)
    #expect(
        (try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.isEmpty != false)
}

@MainActor
@Test("the File menu is closed while another sheet is up")
func dataExchangeIsGatedOnTheSheet() throws {
    let panels = StubFilePanels()
    let harness = try window(panels: panels)

    #expect(harness.model.canExchangeData)
    harness.model.activeSheet = .newProject
    #expect(!harness.model.canExchangeData)

    // And the gate is real, not decorative: the action refuses rather than
    // opening a file panel on top of an open sheet.
    harness.model.exportStore()
    harness.model.importStore()
    #expect(panels.exportPrompts == 0)
    #expect(panels.importPrompts == 0)
}

@MainActor
@Test("the default file panels cannot open anything")
func theDefaultPanelsAreUnavailable() throws {
    let container = try StenoStore.inMemory()
    let model = MainWindowModel(context: ModelContext(container))

    // The property that keeps this suite from hanging: a test that reached a
    // real `NSOpenPanel` would block with no window server, which stops CI with
    // no message rather than failing with one.
    #expect(model.panels is UnavailableFilePanels)
}
