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

/// A skipped run must stay quiet. A regression that posted on
/// `.skipped(.notDue)` would wake all four `.stenoAutoExportDidChange`
/// observers — `MenuBarModel`, `AutoExportWindowModel`, `DataSettingsModel`
/// and (transitively) `MainWindowModel` — on every hourly tick, and
/// `everyRunPosts` above would stay green throughout, since it only ever
/// counts posts from runs that do write.
@Test("a skipped run posts nothing")
@MainActor
func aSkippedRunPostsNothing() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportEnabled = false
    var posts = 0
    let token = NotificationCenter.default.addObserver(
        forName: .stenoAutoExportDidChange, object: nil, queue: nil
    ) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    let outcome = fixture.service().run(trigger: .quit)

    #expect(outcome == .skipped(.disabled))
    #expect(posts == 0)
}

/// **Important 3, final review of M2.5-05.** `encode(at:)` used to build its
/// `ExportEncoder` with no seam into the two-reading stability check, so
/// nothing in this bundle could force `ExportError.storeChangedWhileReading`
/// through `AutoExportService.run` — the `catch let error as ExportError` arm
/// two lines above the generic fallback was unreachable, and swapping the two
/// messages (or deleting the typed catch entirely) would have left the suite
/// green. `AutoExportFixture.service(afterRead:)` closes that gap the same
/// way `ExportStableReadTests` does for `ExportEncoder` directly.
///
/// **Confirmed by mutation**: with the typed catch removed (`catch { ... }`
/// alone) or with the two failure strings swapped, this test goes red — see
/// the PR body / fix report for the exact diff exercised.
@Test("a store that changes during the read is reported with the read-specific message")
@MainActor
func aStoreChangeDuringReadIsReportedAndRecorded() throws {
    let fixture = try autoExportFixture()
    // Inserts on every gap between the encoder's two readings, so the store
    // never settles — matching `ExportStableReadTests.changingStoreIsRefused`.
    var inserted = 0
    let service = fixture.service(
        afterRead: {
            inserted += 1
            let project = Project(
                id: UUID(), name: "Added mid-read \(inserted)", colorHex: "#445566",
                modifiedAt: fixture.stamp)
            fixture.context.insert(project)
            try? fixture.context.save()
        })

    let outcome = service.run(trigger: .quit)

    guard case .failed(let message) = outcome else {
        Issue.record("a changing store was not reported as a failure: \(outcome)")
        return
    }
    // The read-specific sentence, not the generic "could not read its own
    // store" fallback — the distinction the two-sentence design draws.
    #expect(message == ExportError.storeChangedWhileReading.message)
    #expect(fixture.settings.autoExportStatus.problem == message)
    // Proof the seam actually fired, and that nothing reached disk.
    #expect(inserted > 0)
    #expect(fixture.recorder.written.isEmpty)
}
