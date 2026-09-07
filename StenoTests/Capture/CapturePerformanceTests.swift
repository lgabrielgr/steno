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
/// **All three cases assert the mean of `measure`'s iterations.** The two
/// store-write cases gated on the worst of ten until they flaked in CI;
/// `testKeyScanOnALargePasteStaysInteractive` was moved to the mean by M1-07
/// for the same reason (D-053, then D-064). Each doc comment below carries its
/// own measurements.
///
/// The cause is the same in all three: **`measure`'s first iteration is
/// consistently 2–5x the other nine**, and worst-of-ten is the statistic that
/// selects for it. It is *not* a cold store, though the comment here used to
/// say so — an untimed warm-up capture before `measure` was implemented and
/// measured, and left the spike exactly where it was (9.5 ms → 9.6 ms). The
/// overhead is in XCTest's measurement harness, not in the code under test, so
/// the warm-up was reverted rather than shipped.
///
/// Nothing here assumes ten iterations: `XCTMeasureOptions` can change the
/// count, so the mean divides by the iterations actually run and the row-count
/// assertions compare against the same tally. The "did the block run at all"
/// question is a separate assertion, because a block that never ran leaves
/// every count at zero and every zero-against-zero comparison true.
///
/// **`make test` will not show you these numbers.** xcbeautify compresses
/// `measure`'s output to an average and an RSD, and the per-iteration values
/// that make the first-iteration spike visible never appear at all. To read
/// them, run the raw command:
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
    /// Measured on this machine: **32 ms average**, 50 ms worst-of-ten, in this
    /// unoptimised Debug test build; the same scan costs 21 ms built `-O`,
    /// which is what the shipped app pays.
    ///
    /// The assertion exists to catch the return of the per-iteration `Regex`
    /// construction, not to police milliseconds. It discriminates: reinstating
    /// `JiraKey.pattern` inside the loop takes this case to ~400 ms per
    /// iteration and fails the assertion. That was verified by breaking it on
    /// purpose, not reasoned about.
    ///
    /// **This case asserts the mean, unlike the rest of the file — M1-07.**
    /// It originally gated on worst-of-ten at 150 ms, which flaked on GitHub's
    /// runners in 2 of 7 runs: worst-of-ten came in at 150.1 ms once and
    /// **267 ms** once. Worst-of-ten is precisely the statistic shared CI
    /// hardware destabilises — both failing runs had a blown-out relative
    /// standard deviation (±20.7% and ±41.8%) where every passing run sat at
    /// ±2.9–11.4%. The *mean* was stable at 82–121 ms across every run,
    /// including both failures.
    ///
    /// So the ceiling is 250 ms on the mean: ~2x the noisiest mean observed on
    /// a runner, ~8x this machine's, and still far below the ~400 ms per
    /// iteration the regression costs — which drags the mean too, so nothing
    /// is given up. Widening the worst-of-ten ceiling instead was rejected:
    /// 267 ms was already seen on clean code, leaving no usable gap below the
    /// 400 ms defect signature.
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
        var total = 0.0
        var iterations = 0
        var matched = true

        measure {
            let start = Date()
            let hit = ProjectRouter.ticketKeyMatch(text: noisy, projects: projects)
            total += Date().timeIntervalSince(start)
            iterations += 1
            matched = matched && hit == nil
        }

        // None of those tokens carries a configured prefix, so the scan must
        // run to the end. If this ever returns a match the input stopped being
        // the worst case and the number below stops meaning anything.
        XCTAssertTrue(matched, "the adversarial paste unexpectedly resolved to a project")
        // Guard the divisor: a `measure` block that never ran would otherwise
        // divide by zero and report a NaN mean, which compares false against
        // any ceiling and passes silently — the same swallowed-block failure
        // the other two cases in this file guard against by other means.
        XCTAssertGreaterThan(iterations, 0, "the measure block never ran")
        let average = total / Double(iterations)
        // The ceiling is named so the failure message cannot drift from the
        // value actually asserted — found by mutation-testing this assertion,
        // where a hardcoded "250 ms" in the message survived a changed literal.
        let ceiling = 0.250
        XCTAssertLessThan(
            average, ceiling,
            """
            scanning a large paste for ticket keys averaged \(average * 1000) ms, \
            over the \(ceiling * 1000) ms ceiling
            """
        )
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
        var total = 0.0
        var iterations = 0
        var failures = 0

        measure {
            let start = Date()
            do {
                try service.capture(text: Self.realistic, preferred: nil)
            } catch {
                failures += 1
            }
            total += Date().timeIntervalSince(start)
            iterations += 1
        }

        // A swallowed error would otherwise measure a run of no-ops and pass.
        XCTAssertEqual(failures, 0)
        // Against `iterations`, not a hardcoded 10: `XCTMeasureOptions` can
        // change the count, and a literal would then fail for a reason that has
        // nothing to do with capture.
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, iterations)
        // Still needed alongside it, and not only for the divisor. A block that
        // never ran leaves `iterations` and the row count both at zero, which
        // satisfies the equality above — and would divide by zero here for a
        // NaN mean, which compares false against any ceiling and passes
        // silently. This is the assertion that makes "it ran" a claim.
        XCTAssertGreaterThan(iterations, 0, "the measure block never ran")
        let average = total / Double(iterations)
        // 50 ms is ~24x the noisiest mean measured here, and unchanged from
        // when this
        // gated on the worst of ten. Deliberately loose, and deliberately the
        // same figure as the at-scale case below so the two gates cannot drift
        // apart. With three orders of magnitude of headroom against §1.1's
        // budget, the regression worth catching is an order of magnitude, not
        // a factor of two.
        let ceiling = 0.050
        XCTAssertLessThan(
            average, ceiling,
            """
            a single capture averaged \(average * 1000) ms, \
            over the \(ceiling * 1000) ms ceiling
            """
        )
    }

    /// The same capture against D18's ceiling of live tasks, because the
    /// last-used derivation reads all of them (`CaptureService`'s comment
    /// explains why it cannot use `fetchLimit`).
    ///
    /// **This is the case that flaked, and the reason this file moved off
    /// worst-of-ten.** On the identical commit `f757b07` it failed at 63 ms,
    /// failed again at 72 ms, then passed — three outcomes from one commit, so
    /// the code was never the variable. The failing run reported a mean of 11 ms
    /// with an RSD of **±189%**: nine iterations near 3 ms and one pathological
    /// one, which is exactly what a worst-of-ten gate selects for.
    ///
    /// Measured on this machine over four runs: **mean 2.1–2.8 ms**, against a
    /// worst-of-ten of 5.3–9.6 ms. The runner's *mean* stayed at 5–11 ms even
    /// while failing, so the mean is the statistic that survives the hardware;
    /// 50 ms is ~4.5x the noisiest mean ever observed in CI and ~18x the
    /// noisiest here.
    ///
    /// **What this still catches, and what it gives up.** A regression that
    /// slows every capture — the kind worth catching — moves the mean with it.
    /// A regression that made one capture in ten slow would now pass, which is
    /// the trade M1-07 accepted for `testKeyScanOnALargePasteStaysInteractive`
    /// and is accepted here for the same reason: no ceiling on worst-of-ten
    /// separates that defect from the runner, because 72 ms has been seen on
    /// clean code.
    ///
    /// Twenty extra tasks cost roughly 0.4 ms over the empty-store case — the
    /// full-table read is not the bottleneck at D18's ceiling, the save is.
    @MainActor
    func testCaptureAtScaleIsWellUnderBudget() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, context) = try makeService(at: directory, tasks: 20)
        var total = 0.0
        var iterations = 0
        var failures = 0

        measure {
            let start = Date()
            do {
                try service.capture(text: Self.realistic, preferred: nil)
            } catch {
                failures += 1
            }
            total += Date().timeIntervalSince(start)
            iterations += 1
        }

        // As above: `capture` returning nil without throwing would leave
        // `failures` at zero and measure a run of no-ops. 20 seeded, plus one
        // row per iteration actually run.
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 20 + iterations)
        XCTAssertGreaterThan(iterations, 0, "the measure block never ran")
        let average = total / Double(iterations)
        let ceiling = 0.050
        XCTAssertLessThan(
            average, ceiling,
            """
            a capture at D18 scale averaged \(average * 1000) ms, \
            over the \(ceiling * 1000) ms ceiling
            """
        )
    }
}
