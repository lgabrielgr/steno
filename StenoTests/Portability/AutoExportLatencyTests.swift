import Foundation
import SwiftData
import XCTest

@testable import StenoKit

/// What an auto-export costs, because the quit trigger pays it synchronously
/// while the user is waiting for the app to go away.
///
/// §13's latency rule is written about capture, and the reasoning carries: a
/// quit that visibly hangs teaches the user to force-quit, and force-quit is
/// the one path that skips the export entirely — so a slow backup is a backup
/// that stops happening.
///
/// **Measured on `AutoExportService.run` itself**, not on a wrapper around it.
/// D-025 is the standing example of what happens otherwise: a performance claim
/// about the wrong scope, asserted rather than measured, wrong by an order of
/// magnitude.
///
/// Asserts the **mean** of `measure`'s ten iterations, per D-064: the worst-of-
/// ten shape flaked on GitHub's runners for the store-write cases, and this one
/// does a superset of their work.
///
/// XCTest rather than Swift Testing per D-011's `measure` exception. The class
/// is not `@MainActor` — that would make the XCTest overrides main-actor-
/// isolated and conflict with their nonisolated declarations.
final class AutoExportLatencyTests: XCTestCase {
    /// A store on disk, not `StenoStore.inMemory()`: the read this measures is
    /// the one the shipped app pays for.
    @MainActor
    private func makeService(in directory: URL) throws -> AutoExportService {
        // The store and the backup folder are siblings, not nested: an export
        // folder inside the store's own directory is refused by
        // `StoreFileGuard`, which this harness discovered by being written the
        // other way round first.
        let storeDirectory = directory.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: true)
        let container = try StenoStore.live(
            at: storeDirectory.appendingPathComponent("Steno.store"))
        let context = ModelContext(container)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        // D18 caps the live dataset under 20 tasks; the event log is what grows
        // without bound, so the store is sized by events rather than by tasks.
        for projectIndex in 0..<5 {
            let project = Project(
                name: "Project \(projectIndex)", colorHex: "#3B82F6", sortOrder: projectIndex,
                modifiedAt: stamp)
            context.insert(project)
            for taskIndex in 0..<4 {
                let task = TaskItem(
                    title: "Task \(projectIndex)-\(taskIndex)", projectID: project.id,
                    createdAt: stamp)
                context.insert(task)
                for eventIndex in 0..<25 {
                    context.insert(
                        Event(
                            taskID: task.id,
                            timestamp: stamp.addingTimeInterval(TimeInterval(eventIndex)),
                            kind: .note,
                            body: "A progress note, number \(eventIndex), of realistic length."))
                }
            }
        }
        try context.save()

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.autoExportFolder = directory.appendingPathComponent(
            "Backups", isDirectory: true)
        return AutoExportService(
            context: context, settings: settings, now: { stamp },
            exportedBy: "steno/test (macOS)")
    }

    /// 500 events, 20 tasks, 5 projects — a year of use at the volume D18
    /// describes. Measured at ~23 ms mean (10 iterations, RSD 23.6%) in this
    /// unoptimised Debug test build on this machine; the ceiling is 500 ms,
    /// which is where a quit would start to be *felt* rather than where the
    /// current implementation sits.
    ///
    /// The assertion exists to catch a change of shape — an export that starts
    /// walking relationships per event, or writing non-atomically — not to
    /// police milliseconds.
    @MainActor
    func testAnExportAtQuitIsNotFelt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-auto-export-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = try makeService(in: directory)
        var total = 0.0
        var runs = 0

        measure {
            let start = Date()
            let outcome = service.run(trigger: .quit)
            total += Date().timeIntervalSince(start)
            runs += 1
            // A run that skipped or failed would measure nothing and pass.
            guard case .written = outcome else {
                return XCTFail("the measured export did not write: \(outcome)")
            }
        }

        XCTAssertGreaterThan(runs, 0, "the measured block never ran")
        XCTAssertLessThan(total / Double(runs), 0.5, "an export at quit exceeded 500 ms")
    }
}
