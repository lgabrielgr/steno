import Foundation
import SwiftData
import XCTest

@testable import StenoKit

/// What one popover open costs.
///
/// The status item, the popover and its hosting controller are resident, so
/// `prepareForShow()` is the whole per-open price: two fetches and a chip
/// refresh. §1.1 makes capture latency P0 and §13 requires it measured;
/// `CapturePerformanceTests` covers the write, this covers the open.
///
/// XCTest rather than Swift Testing per D-011's `measure` exception. Asserts
/// against the **worst** of `measure`'s ten iterations, not the last —
/// `CapturePerformanceTests`' convention, and for its reason.
///
/// **`make test` will not show you the number.** xcbeautify compresses
/// `measure` output to an average and an RSD. To read it:
///
///     sandbox-exec -f Scripts/test-sandbox.sb xcodebuild -project \
///       Steno.xcodeproj -scheme Steno -derivedDataPath .build \
///       -configuration Debug -destination 'platform=macOS' \
///       -only-testing:StenoTests/MenuBarPerformanceTests \
///       test-without-building 2>&1 | grep measured
///
/// The class is not `@MainActor`, matching `CapturePerformanceTests`: that
/// would make the XCTest overrides main-actor-isolated and conflict with their
/// nonisolated declarations.
final class MenuBarPerformanceTests: XCTestCase {
    private static let origin = Date(timeIntervalSince1970: 1_000_000)

    /// A store on disk in a fresh temp directory, not `StenoStore.inMemory()`:
    /// the fetch this measures is the one the shipped app pays for.
    @MainActor
    private func makeModel(at directory: URL, tasks: Int) throws -> MenuBarModel {
        let container = try StenoStore.live(at: directory.appendingPathComponent("Steno.store"))
        let context = ModelContext(container)
        let project = Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: Self.origin)
        context.insert(project)
        for index in 0..<tasks {
            let task = TaskItem(
                title: "existing \(index)", projectID: project.id, createdAt: Self.origin)
            task.setStatus(.inProgress, at: Self.origin)
            context.insert(task)
        }
        try context.save()
        return MenuBarModel(context: context, now: { Self.origin })
    }

    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-menubar-perf-\(UUID().uuidString)", isDirectory: true)
    }

    /// One open at D18's ceiling: 20 live tasks, all of them in progress,
    /// which is the largest list the popover can be asked to build.
    ///
    /// The ceiling below is deliberately loose. It exists to catch a fetch
    /// moving into a loop or a predicate turning into a full scan per row —
    /// not to police milliseconds on a machine already under test load.
    ///
    /// Observed, not fixed, for `prepareForShow()` against 1 project and 20
    /// in-progress tasks: on the order of a few milliseconds per open.
    /// Worst-of-ten across four runs on this machine — three in this session
    /// (1.275 ms, 2.509 ms, 3.077 ms) plus one independent rerun during
    /// review (3.56 ms) — with each run's own average, computed from its raw
    /// ten values rather than xcodebuild's 3-decimal rounding, landing
    /// between roughly 0.7 ms and 1.5 ms. Every run sits an order of
    /// magnitude under the 50 ms ceiling below and three under §1.1's
    /// ~3-second budget. Read this as the range one machine's noise
    /// produced, not a constant — a single figure quoted as fixed is what
    /// D-025 got wrong by 16x.
    @MainActor
    func testPreparingForShowAtD18ScaleIsInstant() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(at: directory, tasks: 20)
        var elapsed = 0.0

        measure {
            let start = Date()
            model.prepareForShow()
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }

        // A swallowed failure would otherwise measure ten no-ops and pass.
        XCTAssertEqual(model.rows.count, 20)
        XCTAssertLessThan(elapsed, 0.050, "one popover open exceeded 50 ms")
    }
}
