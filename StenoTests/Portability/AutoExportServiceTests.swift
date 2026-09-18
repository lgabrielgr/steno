import Foundation
import Testing

@testable import StenoKit

/// §10.5's unattended write: what it puts on disk, and what it does when it
/// cannot.
///
/// The file assertions matter more here than on the manual path, not less —
/// nobody is watching this one (task file, acceptance criteria).
@Test("a quit export writes the dated file into the configured folder")
@MainActor
func quitExportWritesTheDatedFile() throws {
    let fixture = try autoExportFixture()

    let outcome = fixture.service().run(trigger: .quit)

    let url = fixture.folder.appendingPathComponent(ExportFilename.forDate(fixture.stamp))
    #expect(outcome == .written(url))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(fixture.recorder.written == [url])
}

@Test("the written file is one an import accepts")
@MainActor
func theWrittenFileImports() throws {
    let fixture = try autoExportFixture()
    guard case .written(let url) = fixture.service().run(trigger: .quit) else {
        Issue.record("the export did not report a written file")
        return
    }

    let document = try ImportReader.read(try Data(contentsOf: url))

    #expect(document.projects.map(\.id) == [fixture.projectID])
    #expect(document.tasks.map(\.id) == [fixture.taskID])
}

/// §10.3, on the path that writes without being asked.
@Test("the written file carries no credential markers")
@MainActor
func theWrittenFileCarriesNoSecrets() throws {
    let fixture = try autoExportFixture()
    guard case .written(let url) = fixture.service().run(trigger: .quit) else {
        Issue.record("the export did not report a written file")
        return
    }

    let text = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))

    #expect(CredentialPatterns.matches(in: text).isEmpty)
}

/// D-122: this file is the backup, so it carries what a restore needs.
@Test("the written file carries cached external data")
@MainActor
func theWrittenFileCarriesCachedExternalData() throws {
    let fixture = try autoExportFixture()
    guard case .written(let url) = fixture.service().run(trigger: .quit) else {
        Issue.record("the export did not report a written file")
        return
    }

    let document = try ImportReader.read(try Data(contentsOf: url))

    #expect(document.sourceRefs.first?.cachedSummary == "Reopened after the rollback")
    #expect(document.sourceRefs.first?.lastFetchedAt != nil)
}

@Test("quit exports even when a daily export would not be due")
@MainActor
func quitIgnoresDueness() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastSuccess: .init(
            writtenAt: fixture.stamp, path: "/somewhere/steno-export-2023-11-14.json"))

    let outcome = fixture.service().run(trigger: .quit)

    guard case .written = outcome else {
        Issue.record("quit was skipped: \(outcome)")
        return
    }
}

/// The Data pane's "Back Up Now" — the one gesture where the user is
/// watching and expecting a file, so it must never go quiet just because a
/// backup already ran within the day.
@Test("manual exports even when a daily export would not be due")
@MainActor
func manualIgnoresDueness() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastSuccess: .init(
            writtenAt: fixture.stamp.addingTimeInterval(-60 * 60),
            path: "/somewhere/an-hour-ago.json"))

    let outcome = fixture.service().run(trigger: .manual)

    guard case .written = outcome else {
        Issue.record("manual was skipped: \(outcome)")
        return
    }
}

@Test("a daily export inside 24h is skipped")
@MainActor
func dailyInsideTheDayIsSkipped() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastSuccess: .init(
            writtenAt: fixture.stamp.addingTimeInterval(-60 * 60), path: "/somewhere/yesterday.json"
        ))

    #expect(fixture.service().run(trigger: .daily) == .skipped(.notDue))
    #expect(fixture.recorder.written.isEmpty)
}

@Test("a daily export past 24h runs")
@MainActor
func dailyPastTheDayRuns() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastSuccess: .init(
            writtenAt: fixture.stamp.addingTimeInterval(-25 * 60 * 60), path: "/somewhere/old.json")
    )

    guard case .written = fixture.service().run(trigger: .daily) else {
        Issue.record("a daily export past 24h did not run")
        return
    }
}

@Test("auto-export turned off writes nothing, on any trigger")
@MainActor
func disabledWritesNothing() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportEnabled = false

    #expect(fixture.service().run(trigger: .quit) == .skipped(.disabled))
    #expect(fixture.service().run(trigger: .daily) == .skipped(.disabled))
    #expect(fixture.service().run(trigger: .manual) == .skipped(.disabled))
    #expect(fixture.recorder.written.isEmpty)
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

@Test("a successful export records where it went and clears the last failure")
@MainActor
func successRecordsTheStatus() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastFailure: .init(failedAt: fixture.stamp, message: "the folder went missing"))

    fixture.service().run(trigger: .quit)

    let status = fixture.settings.autoExportStatus
    #expect(status.lastFailure == nil)
    #expect(status.problem == nil)
    #expect(status.lastSuccess?.writtenAt == fixture.stamp)
    #expect(
        status.lastSuccess?.path
            == fixture.folder.appendingPathComponent(ExportFilename.forDate(fixture.stamp)).path)
}

/// The acceptance criterion this whole design exists for: a failure is visible,
/// and it survives the process that suffered it.
@Test("a write failure is recorded, and the last good backup survives it")
@MainActor
func aWriteFailureIsRecorded() throws {
    let fixture = try autoExportFixture()
    let earlier = fixture.stamp.addingTimeInterval(-48 * 60 * 60)
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastSuccess: .init(writtenAt: earlier, path: "/somewhere/steno-export-2023-11-12.json"))
    fixture.recorder.writeFailure = AutoExportFailure(detail: "no space left on device")

    let outcome = fixture.service().run(trigger: .quit)

    guard case .failed(let message) = outcome else {
        Issue.record("a failed write was not reported as a failure: \(outcome)")
        return
    }
    #expect(message.contains("Nothing on this Mac was changed"))
    let status = fixture.settings.autoExportStatus
    #expect(status.problem == message)
    #expect(status.lastSuccess?.writtenAt == earlier)
}

@Test("a folder that cannot be created is reported, not retried silently")
@MainActor
func anUncreatableFolderIsReported() throws {
    let fixture = try autoExportFixture()
    // A path whose parent is a *file*, so `createDirectory` cannot succeed.
    let blocker = autoExportScratchDirectory()
    try FileManager.default.createDirectory(
        at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: blocker)
    fixture.settings.autoExportFolder = blocker.appendingPathComponent("inside", isDirectory: true)

    let outcome = fixture.service().run(trigger: .quit)

    guard case .failed(let message) = outcome else {
        Issue.record("an uncreatable folder was not reported: \(outcome)")
        return
    }
    #expect(message.contains("no backup was written"))
    #expect(fixture.settings.autoExportStatus.problem == message)
}

@Test("every run posts, so the surfaces refresh")
@MainActor
func everyRunPosts() throws {
    let fixture = try autoExportFixture()
    var posts = 0
    let token = NotificationCenter.default.addObserver(
        forName: .stenoAutoExportDidChange, object: nil, queue: nil
    ) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    fixture.service().run(trigger: .quit)
    fixture.recorder.writeFailure = AutoExportFailure(detail: "gone")
    fixture.service().run(trigger: .quit)

    #expect(posts == 2)
}
