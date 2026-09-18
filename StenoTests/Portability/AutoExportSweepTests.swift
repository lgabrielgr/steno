import Foundation
import Testing

@testable import StenoKit

/// Retention as the service actually applies it, against real files.
///
/// `AutoExportRetentionTests` proves the policy over names; this proves the
/// service hands that policy the right directory and acts on its answer.
@Test("the sweep keeps the newest 14 by filename date, not by modification time")
@MainActor
func theSweepIgnoresModificationTime() throws {
    let fixture = try autoExportFixture()
    try FileManager.default.createDirectory(
        at: fixture.folder, withIntermediateDirectories: true)

    // Twenty older exports, **with modification times in the opposite order to
    // their names**. An implementation that sorted by mtime would keep the
    // oldest fourteen and delete the newest six — the exact inversion a cloud
    // drive produces when it re-downloads a file and restamps it.
    let days = (1...20).map { String(format: "2023-10-%02d", $0) }
    for (index, day) in days.enumerated() {
        let url = fixture.folder.appendingPathComponent("steno-export-\(day).json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.stamp.addingTimeInterval(TimeInterval(-index * 3600))],
            ofItemAtPath: url.path)
    }
    // Two files retention must never touch.
    let foreign = fixture.folder.appendingPathComponent("notes.txt")
    let manual = fixture.folder.appendingPathComponent("steno-export-before-the-trip.json")
    try Data("mine".utf8).write(to: foreign)
    try Data("{}".utf8).write(to: manual)

    fixture.service().run(trigger: .quit)

    // 20 old + today's new one = 21 matching names; the oldest seven go.
    #expect(
        Set(fixture.recorder.trashed.map(\.lastPathComponent))
            == Set(days.prefix(7).map { "steno-export-\($0).json" }))
    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(FileManager.default.fileExists(atPath: manual.path))
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.folder.appendingPathComponent(
                ExportFilename.forDate(fixture.stamp)
            ).path))
}

/// D-124: the export succeeded, so a stuck sweep must not be reported as a
/// failed backup. The failure channel has to stay trustworthy.
@Test("a sweep that cannot delete leaves the export successful")
@MainActor
func aFailedSweepDoesNotFailTheExport() throws {
    let fixture = try autoExportFixture()
    try FileManager.default.createDirectory(
        at: fixture.folder, withIntermediateDirectories: true)
    for day in (1...20).map({ String(format: "2023-10-%02d", $0) }) {
        try Data("{}".utf8).write(
            to: fixture.folder.appendingPathComponent("steno-export-\(day).json"))
    }
    fixture.recorder.trashFailure = AutoExportFailure(detail: "the Trash is unavailable")

    let outcome = fixture.service().run(trigger: .quit)

    guard case .written = outcome else {
        Issue.record("a retention failure was reported as an export failure: \(outcome)")
        return
    }
    #expect(fixture.settings.autoExportStatus.problem == nil)
    #expect(fixture.settings.autoExportStatus.lastSuccess != nil)
}
