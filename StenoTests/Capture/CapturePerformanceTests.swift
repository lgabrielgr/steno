import Foundation
import SwiftData
import XCTest

@testable import StenoKit

/// §1.1 makes capture latency a P0 functional requirement: if capture exceeds
/// ~3 seconds the user reverts to paper and the product dies. §13 requires it
/// measured, not assumed. **M1-03 and M1-04 diff against this file.**
///
/// XCTest rather than Swift Testing per D-011 — the `measure` exception.
///
/// Each case asserts against the **worst** of `measure`'s ten iterations, not
/// the last, so the assertion does not look only at the warmest run.
///
/// **`make test` will not show you that number.** xcbeautify compresses
/// `measure`'s output to an average and an RSD, so the worst-of-ten the
/// assertions actually gate on is invisible unless one fails. To read it, run
/// the raw command:
///
///     sandbox-exec -f Scripts/test-sandbox.sb xcodebuild -project \
///       Steno.xcodeproj -scheme Steno -derivedDataPath .build \
///       -configuration Debug -destination 'platform=macOS' \
///       -only-testing:StenoTests/CapturePerformanceTests \
///       test-without-building 2>&1 | grep measured
///
/// The class is not `@MainActor` — that would make the XCTest overrides
/// main-actor-isolated and conflict with their nonisolated declarations. The
/// test methods carry the isolation instead, which is where `CaptureService`
/// needs it.
final class CapturePerformanceTests: XCTestCase {
    private static let realistic =
        "PAY-421 debugged the retry handler, PR https://github.com/acme/api/pull/912"

    /// A store on disk in a fresh temp directory.
    ///
    /// **Not `StenoStore.inMemory()`.** The in-memory store skips the fsync,
    /// which is the entire question this file asks.
    @MainActor
    private func makeService(at directory: URL, tasks: Int = 0) throws -> (
        CaptureService, ModelContext
    ) {
        let container = try StenoStore.live(at: directory.appendingPathComponent("Steno.store"))
        let context = ModelContext(container)
        let project = Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: Date())
        context.insert(project)
        for index in 0..<tasks {
            context.insert(
                TaskItem(title: "existing \(index)", projectID: project.id, createdAt: Date()))
        }
        try context.save()
        return (CaptureService(context: context), context)
    }

    /// A 250 KB paste dense in the false positives `JiraKey` documents
    /// (`UTF-8`, `ISO-8601`, `COVID-19`, `M1-01`) and containing no key that
    /// resolves to a project — the worst input for `ticketKeyMatch`, because
    /// it defeats the early exit *and* maximises the match loop.
    ///
    /// **This case exists because the claim it tests was once asserted rather
    /// than measured.** `ticketKeyMatch` runs on `text.didSet`, synchronously
    /// on the main actor, on every keystroke — it is more latency-sensitive
    /// than `capture` itself, which runs once per task. `ProjectRouter`'s
    /// comment used to say a regex scan "has no such cliff"; it has one, and
    /// reading the computed `JiraKey.pattern` inside the loop made it 342 ms.
    ///
    /// Measured worst-of-ten on this machine: **50 ms** in this unoptimised
    /// Debug test build (32 ms average); the same scan costs 21 ms built `-O`,
    /// which is what the shipped app pays.
    ///
    /// The ceiling is 150 ms, well above both — this is an adversarial input
    /// on a machine already under test load, and the assertion exists to catch
    /// the return of the per-iteration `Regex` construction, not to police
    /// milliseconds. It discriminates: reinstating `JiraKey.pattern` inside
    /// the loop takes this case to ~400 ms per iteration and fails the
    /// assertion. That was verified by breaking it on purpose, not reasoned
    /// about.
    @MainActor
    func testKeyScanOnALargePasteStaysInteractive() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, context) = try makeService(at: directory)
        let projects = try context.fetch(FetchDescriptor<Project>())
        var noisy = ""
        while noisy.utf8.count < 250_000 {
            noisy += "UTF-8 encodes ISO-8601 stamps and COVID-19 counts beside M1-01 notes. "
        }
        var elapsed = 0.0
        var matched = true

        measure {
            let start = Date()
            let hit = ProjectRouter.ticketKeyMatch(text: noisy, projects: projects)
            elapsed = max(elapsed, Date().timeIntervalSince(start))
            matched = matched && hit == nil
        }

        // None of those tokens carries a configured prefix, so the scan must
        // run to the end. If this ever returns a match the input stopped being
        // the worst case and the number below stops meaning anything.
        XCTAssertTrue(matched, "the adversarial paste unexpectedly resolved to a project")
        XCTAssertLessThan(elapsed, 0.150, "scanning a large paste for ticket keys exceeded 150 ms")
    }

    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-capture-perf-\(UUID().uuidString)", isDirectory: true)
    }

    /// One realistic capture — routing, extraction, three inserts, one save —
    /// on an empty store. Measured at 3.6 ms, worst of ten across three runs
    /// on this machine (the average across the ten was 1.6 ms). The worst is
    /// always the first iteration, against a cold store; the other nine sit
    /// near 1.4 ms.
    @MainActor
    func testSingleCaptureIsWellUnderBudget() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, context) = try makeService(at: directory)
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
        // otherwise measure ten no-ops and pass.
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 10)
        // 50 ms is ~14x the worst measured value, where the plan asked for
        // ~5x. Deliberately loose, and deliberately the same figure as the
        // at-scale case below so the two gates cannot drift apart: the first
        // iteration runs against a cold store and the ten-run spread is wide
        // (RSD ~35%). That a 5x gate would fail under load is risk-aversion,
        // not something observed — three runs under concurrent load stayed
        // well inside 5x. With three orders of magnitude of headroom against
        // §1.1's budget, the regression worth catching is an order of
        // magnitude, not a factor of two.
        XCTAssertLessThan(elapsed, 0.050, "a single capture exceeded 50 ms")
    }

    /// The same capture against D18's ceiling of live tasks, because the
    /// last-used derivation reads all of them (`CaptureService`'s comment
    /// explains why it cannot use `fetchLimit`). Measured at 8.1 ms, worst of
    /// ten across three runs on this machine (the average across the ten was
    /// 2.2 ms) — so here the shared 50 ms ceiling is ~6x, close to the ~5x
    /// the plan asked for.
    ///
    /// Twenty extra tasks cost roughly 0.8 ms over the empty-store case — the
    /// full-table read is not the bottleneck at D18's ceiling, the save is.
    @MainActor
    func testCaptureAtScaleIsWellUnderBudget() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, context) = try makeService(at: directory, tasks: 20)
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

        // As above: `capture` returning nil without throwing would leave
        // `failures` at zero and measure ten no-ops. 20 seeded + 10 captured.
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 30)
        XCTAssertLessThan(elapsed, 0.050, "a capture at D18 scale exceeded 50 ms")
    }
}
