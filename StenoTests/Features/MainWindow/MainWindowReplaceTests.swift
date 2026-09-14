import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §10.1's Replace, driven through the window's model.
///
/// Split from `MainWindowPortabilityTests` on the 400-line limit; the
/// destructive path earning a file of its own is a fair division anyway.
/// The harness lives in `PortabilityHarness.swift`.

@MainActor
@Test("the backup lands at exactly the path the sheet promised")
func theBackupGoesWhereTheSheetSaid() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = portabilityScratchDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let backups = portabilityScratchDirectory()
    defer { try? FileManager.default.removeItem(at: backups) }

    // **A clock that moves between the preview and the confirmation.** Each
    // `BackupWriter` this factory builds reads a later second, so a `write()`
    // that recomputed its own filename would write somewhere other than the
    // path the safety prompt displayed — making the promised recovery path
    // point at nothing. Raised in review of PR #30.
    var tick = 0.0
    let panels = StubFilePanels(importSource: url)
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let seeded = Project(
        id: UUID(), name: "Payments", colorHex: "#112233",
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    context.insert(seeded)
    try context.save()

    let model = MainWindowModel(
        context: context,
        panels: panels,
        makeBackupWriter: { context in
            tick += 5
            return try BackupWriter(
                context: context, directory: backups,
                now: { Date(timeIntervalSince1970: 1_700_000_000 + tick) })
        })

    model.replaceStoreFromFile()
    let promised = try #require(model.importPreview.backupURL)
    model.importPreview.confirmation = "REPLACE"
    model.applyImport()

    #expect(FileManager.default.fileExists(atPath: promised.path))
    // And exactly one backup exists — not one at the promised path and another
    // at whatever the clock said a moment later.
    let written = try FileManager.default.contentsOfDirectory(atPath: backups.path)
    #expect(written == [promised.lastPathComponent])
    #expect(model.importPreview.notice?.contains(promised.path) == true)
}

@MainActor
@Test("replace writes a backup before it deletes anything")
func replaceBacksUpFirst() throws {
    let file = try ExportFixture()
    let project = try file.project("Other", modifiedAt: ExportFixture.at(10))
    try file.task("From the other Mac", in: project, createdAt: ExportFixture.at(20))

    let directory = portabilityScratchDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let backups = portabilityScratchDirectory()
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

    let directory = portabilityScratchDirectory()
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

    let directory = portabilityScratchDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("in.json")
    try file.encoder(includingCachedData: true).encode().write(to: url)

    let backups = portabilityScratchDirectory()
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
