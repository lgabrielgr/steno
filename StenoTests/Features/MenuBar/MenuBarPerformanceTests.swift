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
/// It also covers what M1-04 adds to that write. The model is resident too,
/// and it reloads on every `.stenoDidWrite` — which `CaptureService` posts
/// synchronously before `capture()` returns — so every capture from every
/// surface now pays a `reload()` that `CapturePerformanceTests` cannot see,
/// because nothing there observes. The last two cases measure it both ways.
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

    /// The same realistic line `CapturePerformanceTests` captures, so the
    /// capture cases below differ from its numbers only in what is observing.
    private static let realistic =
        "PAY-421 debugged the retry handler, PR https://github.com/acme/api/pull/912"

    /// A store on disk in a fresh temp directory, not `StenoStore.inMemory()`:
    /// the fetch this measures is the one the shipped app pays for.
    @MainActor
    private func makeStore(at directory: URL, inProgress: Int, todo: Int = 0) throws -> ModelContext
    {
        let container = try StenoStore.live(at: directory.appendingPathComponent("Steno.store"))
        let context = ModelContext(container)
        let project = Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: Self.origin)
        context.insert(project)
        for index in 0..<inProgress {
            let task = TaskItem(
                title: "existing \(index)", projectID: project.id, createdAt: Self.origin)
            task.setStatus(.inProgress, at: Self.origin)
            context.insert(task)
        }
        for index in 0..<todo {
            context.insert(
                TaskItem(title: "waiting \(index)", projectID: project.id, createdAt: Self.origin))
        }
        try context.save()
        return context
    }

    @MainActor
    private func makeModel(at directory: URL, tasks: Int) throws -> MenuBarModel {
        MenuBarModel(context: try makeStore(at: directory, inProgress: tasks), now: { Self.origin })
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

    /// The baseline for the case below: one capture at D18's ceiling with no
    /// `MenuBarModel` in the process at all.
    ///
    /// A pair of cases rather than one, because the cost M1-04 adds to capture
    /// is a *difference* and the two halves have to share a fixture to be
    /// subtracted. `CapturePerformanceTests.testCaptureAtScaleIsWellUnderBudget`
    /// is close but not identical — its twenty seeded tasks are `.todo`, and the
    /// observer's work scales with the in-progress list — so it cannot serve as
    /// this half.
    ///
    /// Run the pair in isolation to read the numbers. Swift Testing runs its
    /// suites in parallel in the same process, and any other live
    /// `MenuBarModel` observes `.stenoDidWrite` too, which would put part of
    /// the "with observer" cost into this baseline:
    ///
    ///     sandbox-exec -f Scripts/test-sandbox.sb xcodebuild -project \
    ///       Steno.xcodeproj -scheme Steno -derivedDataPath .build \
    ///       -configuration Debug -destination 'platform=macOS' \
    ///       -only-testing:StenoTests/MenuBarPerformanceTests \
    ///       test-without-building 2>&1 | grep measured
    @MainActor
    func testCaptureWithNoMenuBarModelObserving() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try makeStore(at: directory, inProgress: 20)
        let service = CaptureService(context: context, now: { Self.origin })
        var elapsed = 0.0
        var failures = 0

        measure {
            let start = Date()
            do {
                try service.capture(text: Self.realistic, preferred: nil)
            } catch {
                failures += 1
            }
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }

        // `measure` runs the block ten times, so a swallowed error would
        // otherwise measure ten no-ops and pass. 20 seeded + 10 captured.
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 30)
        // The same 50 ms `CapturePerformanceTests` gates on, so the three
        // capture ceilings cannot drift apart. The worst iteration observed
        // here is 14.5 ms — the cold first one — so the margin is ~3.4x rather
        // than that file's ~6x. It is the cold-store fsync being measured, not
        // this branch's work; see the case below.
        XCTAssertLessThan(elapsed, 0.050, "a capture with nothing observing exceeded 50 ms")
    }

    /// The same capture with a live `MenuBarModel` observing — which is the
    /// shipped configuration, since `MenuBarController` builds one at launch
    /// and keeps it for the process.
    ///
    /// **This is a P0 path measured rather than reasoned about.** `CaptureService`
    /// posts `.stenoDidWrite` synchronously on the main actor before `capture()`
    /// returns, and the model's observer answers it with a full `reload()` —
    /// two fetches, a sort and a project join — whether or not the popover has
    /// ever been opened. §13 and CLAUDE.md's fourth non-negotiable require that
    /// cost measured, not assumed.
    ///
    /// Observed, not fixed, over five isolated runs of this file on this
    /// machine — fifty captures each way, at D18's ceiling:
    ///
    /// - **No observer:** first iteration 9.9–14.5 ms; the other nine
    ///   1.8–3.6 ms, per-run medians 2.0–2.2 ms.
    /// - **With the observer:** first iteration 4.8–8.1 ms; the other nine
    ///   1.9–5.6 ms, per-run medians 2.4–3.3 ms.
    ///
    /// So the observer costs roughly **0.2–1.4 ms per capture**, near 0.9 ms
    /// at the median — one `reload()` at D18's ceiling, the same order as the
    /// `prepareForShow()` case above (0.8–2.0 ms after its own first
    /// iteration). Against §1.1's ~3-second budget that is three orders of
    /// magnitude of headroom, which is what lets M1-04 claim capture latency
    /// has not regressed.
    ///
    /// **The two worst-of-ten figures do not compare, and inverting them is
    /// not evidence the observer is free.** Building the `MenuBarModel` runs a
    /// fetch before the measure starts, warming a store the no-observer case
    /// meets cold on its first iteration; that first iteration is the worst in
    /// every run of both cases. The delta above rests on the warm iterations.
    ///
    /// Read every figure as the range one machine's noise produced, not a
    /// constant — D-025 wrote one sample down as fixed and was wrong by 16x.
    @MainActor
    func testCaptureWithTheMenuBarModelObserving() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try makeStore(at: directory, inProgress: 19, todo: 1)
        let model = MenuBarModel(context: context, now: { Self.origin })
        XCTAssertEqual(model.rows.count, 19)

        // Flipped behind the model's back and saved without posting
        // `.stenoDidWrite`, so a twentieth row can appear only if the
        // observer actually fired. Without this the assertion after the
        // measure would hold over ten captures that reloaded nothing.
        let waiting = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.status == .todo }
        try XCTUnwrap(waiting.first).setStatus(.inProgress, at: Self.origin)
        try context.save()
        XCTAssertEqual(model.rows.count, 19, "no reload should have happened yet")

        let service = CaptureService(context: context, now: { Self.origin })
        var elapsed = 0.0
        var failures = 0

        measure {
            let start = Date()
            do {
                try service.capture(text: Self.realistic, preferred: nil)
            } catch {
                failures += 1
            }
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }

        XCTAssertEqual(failures, 0)
        // Captured tasks arrive `.todo`, so the list is the twenty in-progress
        // — and the twentieth is the one only a reload can find.
        XCTAssertEqual(model.rows.count, 20, "the .stenoDidWrite observer never reloaded")
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 30)
        XCTAssertLessThan(elapsed, 0.050, "a capture with the menu bar observing exceeded 50 ms")
    }
}
