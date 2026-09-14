import Foundation
import Testing

@testable import StenoKit

/// §10.1's mandatory pre-Replace backup.
///
/// Replace is the only destructive operation in the product and, with sync
/// cancelled (§10, D1), there is no remote copy. These are the assertions that
/// stand between a mistaken Replace and an unrecoverable one.

private struct WriteRefused: Error {}

/// A directory under the scratch area that this test owns and removes.
private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-backup-tests-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
@Test("the backup filename carries the time, not only the day")
func backupFilenameCarriesSeconds() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let name = BackupWriter.filename(
        for: Date(timeIntervalSince1970: 1_700_000_000), timeZone: utc)

    // 2023-11-14T22:13:20Z. Seconds, where `ExportFilename` stops at the day:
    // two Replaces in one afternoon are entirely plausible — the first restored
    // the wrong snapshot — and a day-resolution name would overwrite the backup
    // taken before the mistake.
    #expect(name == "steno-backup-2023-11-14-221320.json")
}

@MainActor
@Test("the backup includes cached external data, whatever the export panel says")
func theBackupIsFullFidelity() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try fixture.task(
        "Fix the retry handler", in: project, createdAt: ExportFixture.at(20))
    try fixture.ref(
        "PAY-421", on: task, cachedSummary: "In review, 2 comments",
        lastFetchedAt: ExportFixture.at(30))

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = try BackupWriter(
        context: fixture.context, directory: directory, now: { ExportFixture.at(0) })
    let url = try writer.write(userAgent: "steno/test (macOS)")

    let document = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try Data(contentsOf: url))

    // **The assertion that catches `includesCachedExternalData` defaulting to
    // false on this path.** That default is silent data loss with no symptom
    // until someone restores the backup and finds every cached summary gone —
    // and §10.1's "nil loses to any value" would then hand those fields away on
    // the way back in.
    #expect(document.includesCachedExternalData)
    let ref = try #require(document.sourceRefs.first)
    #expect(ref.cachedSummary == "In review, 2 comments")
    #expect(ref.lastFetchedAt != nil)
}

@MainActor
@Test("writing the backup creates the directory")
func theBackupDirectoryIsCreated() throws {
    let fixture = try ExportFixture()
    try fixture.project("Payments", modifiedAt: ExportFixture.at(10))

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    let writer = try BackupWriter(
        context: fixture.context, directory: directory, now: { ExportFixture.at(0) })
    let url = try writer.write(userAgent: "steno/test (macOS)")

    #expect(FileManager.default.fileExists(atPath: url.path))
    // The planned path and the written path must agree, because the sheet shows
    // the planned one *before* the user commits. Two different answers would
    // make that promise false at the moment it matters most.
    #expect(url == writer.plannedURL())
}

@MainActor
@Test("a backup that cannot be written throws rather than returning nil")
func aFailedBackupThrows() throws {
    let fixture = try ExportFixture()
    try fixture.project("Payments", modifiedAt: ExportFixture.at(10))

    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = try BackupWriter(
        context: fixture.context, directory: directory, now: { ExportFixture.at(0) },
        write: { _, _ in throw WriteRefused() })

    // A throw is what makes "fails safe if that backup cannot be written"
    // enforceable: an optional return invites a caller to carry on with `nil`,
    // and the thing they would carry on to is a wipe.
    #expect(throws: WriteRefused.self) { try writer.write(userAgent: "steno/test (macOS)") }
}

@MainActor
@Test("an empty store still produces a readable backup")
func anEmptyStoreBacksUp() throws {
    let fixture = try ExportFixture()
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Replacing into a fresh machine is a real path — it is most of the point
    // of Replace — and a backup step that threw on an empty store would block
    // it for no reason.
    let writer = try BackupWriter(
        context: fixture.context, directory: directory, now: { ExportFixture.at(0) })
    let url = try writer.write(userAgent: "steno/test (macOS)")
    let document = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try Data(contentsOf: url))
    #expect(document.projects.isEmpty)
}
