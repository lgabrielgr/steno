import XCTest

@testable import StenoKit

/// Extraction runs on the capture path, which §1.1 and §13 make
/// latency-critical: if capture exceeds ~3 seconds the user reverts to paper
/// and the product dies. XCTest rather than Swift Testing per D-011 — this is
/// the `measure` exception, and there is no Swift Testing equivalent.
///
/// Each case asserts the **mean** of `measure`'s ten iterations, per D-064 and
/// D-162 — never the last one, which would look only at the warmest run, and no
/// longer the worst, which is the statistic shared-runner noise destroys. The
/// ceilings are unchanged: they were already loose enough that the mean clears
/// them by 7-10x, and a regression that slows extraction drags the mean with it.
///
/// **`make test` will not show you the number.** xcbeautify compresses
/// `measure` output to an average and an RSD. To read it:
///
///     sandbox-exec -f Scripts/test-sandbox.sb xcodebuild -project \
///       Steno.xcodeproj -scheme Steno -derivedDataPath .build \
///       -configuration Debug -destination 'platform=macOS' \
///       -only-testing:StenoTests/ExtractionPerformanceTests \
///       test-without-building 2>&1 | grep measured
final class ExtractionPerformanceTests: XCTestCase {
    private static let realistic = """
        Debugged the retry handler for PAY-421, PR https://github.com/acme/api/pull/912, \
        notes in https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Retry
        """

    /// Measured at **100 µs per extraction, mean of ten**, across three runs on
    /// this machine (block average 0.010 s for 100 extractions, RSD 22-34%). A
    /// task title is the input that must never be felt.
    func testRealisticCaptureStringIsWellUnderBudget() {
        let text = Self.realistic
        var total = 0.0
        var runs = 0

        measure {
            let start = Date()
            for _ in 0..<100 {
                _ = ReferenceExtractor.extract(from: text)
            }
            total += Date().timeIntervalSince(start) / 100
            runs += 1
        }

        XCTAssertGreaterThan(runs, 0, "the measured block never ran")
        XCTAssertLessThan(
            total / Double(runs), 0.001, "extraction of a capture string exceeded 1 ms")
    }

    /// Measured at **2.2-2.3 ms per extraction for ~7 KB, mean of ten**, across
    /// three runs on this machine (RSD 18-26%). FR-1.5 runs extraction over note
    /// bodies too, so the longest realistic input gets its own ceiling.
    ///
    /// **This is the case that flaked**, on PR #38: 20.286 ms against the 20 ms
    /// ceiling, worst of ten, on a branch that touched no capture code — one
    /// pathological iteration roughly 9x the other nine. See D-162.
    func testLongNoteBodyStaysFarInsideBudget() {
        let text = String(
            repeating:
                "Worked on PAY-421 and read "
                + "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook today. ",
            count: 70)
        var total = 0.0
        var runs = 0

        measure {
            let start = Date()
            for _ in 0..<10 {
                _ = ReferenceExtractor.extract(from: text)
            }
            total += Date().timeIntervalSince(start) / 10
            runs += 1
        }

        XCTAssertGreaterThan(runs, 0, "the measured block never ran")
        XCTAssertLessThan(
            total / Double(runs), 0.020, "extraction of a long note body exceeded 20 ms")
    }

    /// A 250 KB paste carrying 8,000 links and 8,000 keys: the shape that tells
    /// linear cost from quadratic, which the two cases above cannot. Measured at
    /// 180 ms, worst of ten. The ceiling is 1 s, five times that and still far
    /// inside §1.1's three seconds — while the O(keys × spans) membership test
    /// this replaced spent 3.6 s on this very input in its overlap phase alone,
    /// so a regression to it fails here rather than reaching a user's clipboard.
    func testLinkDensePasteScalesLinearly() {
        let text = String(repeating: "PAY-421 https://example.com/a/b ", count: 8000)
        var total = 0.0
        var runs = 0

        measure {
            let start = Date()
            _ = ReferenceExtractor.extract(from: text)
            total += Date().timeIntervalSince(start)
            runs += 1
        }

        XCTAssertGreaterThan(runs, 0, "the measured block never ran")
        XCTAssertLessThan(
            total / Double(runs), 1.0, "extraction of a link-dense paste exceeded 1 s")
    }
}
