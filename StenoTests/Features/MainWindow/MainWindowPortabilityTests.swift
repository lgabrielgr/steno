import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §10.5's File menu, end to end through the window's model.
///
/// The sheet is layout with no logic (D-010 puts it beyond this bundle), so
/// these are the tests that cover what pressing the menu items actually does.

@MainActor
@Test("export writes the file the panel chose and says where it went")
func exportWritesAndReports() throws {
    let directory = portabilityScratchDirectory()
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
    let directory = portabilityScratchDirectory()
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

    let directory = portabilityScratchDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let panels = StubFilePanels(importSource: url)
    let harness = try window(panels: panels)
    let counter = WriteCounter()

    // **All five record types, not just the task count.** Comparing one type
    // leaves a preview that quietly mutated a project, event, ref or report
    // indistinguishable from one that touched nothing — and §10.4's guarantee
    // is about the store, not about tasks. Raised in review of PR #30.
    let before = try wholeStore(harness.context)

    harness.model.importStore()

    #expect(harness.model.activeSheet == .importPreview)
    #expect(harness.model.importPreview.mode == .merge)
    // §10.4: "cancel leaves the store untouched". The strongest form of that is
    // that nothing was ever written — not that a rollback worked. The snapshot
    // comparison is what catches a silent save; `counter` catches a post.
    #expect(counter.posts == 0)
    #expect(try wholeStore(harness.context) == before)

    harness.model.dismissImportPreview()
    #expect(harness.model.activeSheet == nil)
    #expect(counter.posts == 0)
    #expect(try wholeStore(harness.context) == before)
}

@MainActor
@Test("confirming the import applies it")
func confirmingAppliesTheImport() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = portabilityScratchDirectory()
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
    let directory = portabilityScratchDirectory()
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
