import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// D-125: the folder must never be Steno's own store directory, and the guard
/// runs both when the folder is chosen and before every write.
///
/// A store on disk, not `StenoStore.inMemory()`: the question is about a
/// directory the store's files live in.
@MainActor
private func storeOnDisk() throws -> (ModelContext, URL) {
    let directory = autoExportScratchDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let container = try StenoStore.live(at: directory.appendingPathComponent("Steno.store"))
    return (ModelContext(container), directory)
}

/// A settings facade over a scratch `UserDefaults` suite, never the shared
/// one `AppSettings()` defaults to.
///
/// `problem(withFolder:)` never reads settings today, so the default was
/// harmless here — but a test that builds a real `AutoExportService` is one
/// `run()` away from writing into the developer's actual
/// `~/Steno Backups` (§9.4). Every construction in this file goes through
/// this rather than relying on that default.
@MainActor
private func scratchSettings() throws -> AppSettings {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return AppSettings(defaults: defaults)
}

@Test("the store's own directory is refused as an export folder")
@MainActor
func theStoreDirectoryIsRefused() throws {
    let (context, directory) = try storeOnDisk()
    let service = AutoExportService(context: context, settings: try scratchSettings())

    #expect(service.problem(withFolder: directory) != nil)
}

@Test("a folder inside the store's directory is refused")
@MainActor
func aFolderInsideTheStoreIsRefused() throws {
    let (context, directory) = try storeOnDisk()
    let service = AutoExportService(context: context, settings: try scratchSettings())

    #expect(
        service.problem(
            withFolder: directory.appendingPathComponent("Backups", isDirectory: true)) != nil)
}

/// The separator matters: `…/Steno-backups` is not inside `…/Steno`.
@Test("a sibling folder whose name merely starts the same is allowed")
@MainActor
func aSiblingWithASharedPrefixIsAllowed() throws {
    let (context, directory) = try storeOnDisk()
    let sibling = directory.deletingLastPathComponent()
        .appendingPathComponent(directory.lastPathComponent + "-backups", isDirectory: true)
    let service = AutoExportService(context: context, settings: try scratchSettings())

    #expect(service.problem(withFolder: sibling) == nil)
}

@Test("a run into the store's directory writes nothing and says why")
@MainActor
func aRunIntoTheStoreDirectoryIsRefused() throws {
    let (context, directory) = try storeOnDisk()
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    settings.autoExportFolder = directory
    let recorder = AutoExportRecorder()
    let service = AutoExportService(
        context: context, settings: settings, exportedBy: "steno/test (macOS)",
        write: { try recorder.write($0, to: $1) }, trash: { try recorder.trash($0) })

    let outcome = service.run(trigger: .quit)

    guard case .failed(let message) = outcome else {
        Issue.record("an export into the store directory was not refused: \(outcome)")
        return
    }
    #expect(message.contains("Steno's own data store"))
    #expect(recorder.written.isEmpty)
    #expect(settings.autoExportStatus.problem == message)
}
