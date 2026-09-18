import Foundation
import SwiftData

@testable import StenoKit

/// Records what an auto-export did to the filesystem, and makes either half of
/// it fail on demand.
///
/// A plain class rather than an actor: every call arrives on the main actor,
/// through closures a `@MainActor` service invokes, and an actor would force
/// `await` into injection points that are synchronous by design.
final class AutoExportRecorder {
    private(set) var written: [URL] = []
    private(set) var trashed: [URL] = []

    /// Set to make the next write throw — "the disk is full", without a full
    /// disk.
    var writeFailure: (any Error)?

    /// Set to make every trash throw, which must leave the export successful.
    var trashFailure: (any Error)?

    /// Names (`lastPathComponent`) of files whose trash must throw, leaving
    /// the rest to succeed.
    ///
    /// Separate from `trashFailure`: that one exists to prove a stuck sweep
    /// never fails the export; this one exists to prove the sweep does not
    /// abandon the rest of the folder over a single undeletable file — the
    /// property `AutoExportService.sweep`'s per-file `do`/`catch` documents.
    /// A single `Set<URL>` matched on `lastPathComponent` rather than on the
    /// full `URL`, because the folder in a fixture is a fresh temp directory
    /// each run and only the name is known ahead of time.
    var trashFailures: Set<String> = []

    func write(_ data: Data, to url: URL) throws {
        if let writeFailure { throw writeFailure }
        written.append(url)
        try data.write(to: url, options: .atomic)
    }

    func trash(_ url: URL) throws {
        if let trashFailure { throw trashFailure }
        if trashFailures.contains(url.lastPathComponent) {
            throw AutoExportFailure(detail: "could not trash \(url.lastPathComponent)")
        }
        trashed.append(url)
        // Removed rather than trashed: the suite must not put files in the
        // developer's Trash (§9.4). What `AutoExportService` does with the URL
        // it is handed is `trashed`'s business; that it hands over the right
        // ones is what these tests assert.
        try FileManager.default.removeItem(at: url)
    }
}

struct AutoExportFailure: Error, Equatable {
    let detail: String
}

/// A store, a scratch defaults suite, and a temp folder to export into.
@MainActor
struct AutoExportFixture {
    let container: ModelContainer
    let context: ModelContext
    let settings: AppSettings
    let defaults: UserDefaults
    let folder: URL
    let recorder: AutoExportRecorder
    let projectID: UUID
    let taskID: UUID
    let stamp: Date

    /// The service under test, over this fixture's injected everything.
    func service(now: (() -> Date)? = nil) -> AutoExportService {
        AutoExportService(
            context: context,
            settings: settings,
            now: now ?? { stamp },
            exportedBy: "steno/test (macOS)",
            write: { try recorder.write($0, to: $1) },
            trash: { try recorder.trash($0) }
        )
    }
}

@MainActor
func autoExportScratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-auto-export-\(UUID().uuidString)", isDirectory: true)
}

/// One project, one task, one fetched `SourceRef` — the last so D-122's
/// "cached external data is included" has something to be true about.
@MainActor
func autoExportFixture(
    stamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> AutoExportFixture {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)

    let project = Project(
        id: UUID(), name: "Payments", colorHex: "#112233", modifiedAt: stamp)
    context.insert(project)
    let task = TaskItem(
        id: UUID(), title: "Fix the retry handler", projectID: project.id, createdAt: stamp)
    context.insert(task)
    let ref = SourceRef(taskID: task.id, kind: .jiraIssue, identifier: "PAY-421")
    ref.recordFetch(summary: "Reopened after the rollback", at: stamp)
    context.insert(ref)
    try context.save()

    // A suite per fixture, so nothing here touches the developer's own
    // preferences and no two tests can see each other's settings (§9.4).
    guard let defaults = UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)") else {
        throw AutoExportFailure(detail: "could not open a scratch defaults suite")
    }
    let settings = AppSettings(defaults: defaults)
    let folder = autoExportScratchDirectory()
    settings.autoExportFolder = folder

    return AutoExportFixture(
        container: container,
        context: context,
        settings: settings,
        defaults: defaults,
        folder: folder,
        recorder: AutoExportRecorder(),
        projectID: project.id,
        taskID: task.id,
        stamp: stamp)
}
