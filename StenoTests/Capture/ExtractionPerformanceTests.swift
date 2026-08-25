import XCTest

@testable import StenoKit

/// Extraction runs on the capture path, which §1.1 and §13 make
/// latency-critical: if capture exceeds ~3 seconds the user reverts to paper
/// and the product dies. XCTest rather than Swift Testing per D-011 — this is
/// the `measure` exception, and there is no Swift Testing equivalent.
///
/// Each case asserts against the **worst** of `measure`'s ten iterations, not
/// the last one: assigning `elapsed` per iteration would leave the assertion
/// looking only at the final, warmest run. The ceilings sit well above the
/// worst measured value, so a real regression fails while a loaded machine
/// does not.
final class ExtractionPerformanceTests: XCTestCase {
    private static let realistic = """
        Debugged the retry handler for PAY-421, PR https://github.com/acme/api/pull/912, \
        notes in https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Retry
        """

    /// Measured at 180 µs, worst of ten, on this machine (the warmest run is
    /// 77 µs). A task title is the input that must never be felt.
    func testRealisticCaptureStringIsWellUnderBudget() {
        let text = Self.realistic
        var elapsed = 0.0

        measure {
            let start = Date()
            for _ in 0..<100 {
                _ = ReferenceExtractor.extract(from: text)
            }
            elapsed = max(elapsed, Date().timeIntervalSince(start) / 100)
        }

        XCTAssertLessThan(elapsed, 0.001, "extraction of a capture string exceeded 1 ms")
    }

    /// Measured at 3.9 ms for ~7 KB, worst of ten, on this machine. FR-1.5 runs
    /// extraction over note bodies too, so the longest realistic input gets its
    /// own ceiling.
    func testLongNoteBodyStaysFarInsideBudget() {
        let text = String(
            repeating:
                "Worked on PAY-421 and read "
                + "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook today. ",
            count: 70)
        var elapsed = 0.0

        measure {
            let start = Date()
            for _ in 0..<10 {
                _ = ReferenceExtractor.extract(from: text)
            }
            elapsed = max(elapsed, Date().timeIntervalSince(start) / 10)
        }

        XCTAssertLessThan(elapsed, 0.020, "extraction of a long note body exceeded 20 ms")
    }

    /// A 250 KB paste carrying 8,000 links and 8,000 keys: the shape that tells
    /// linear cost from quadratic, which the two cases above cannot. Measured at
    /// 180 ms, worst of ten. The ceiling is 1 s, five times that and still far
    /// inside §1.1's three seconds — while the O(keys × spans) membership test
    /// this replaced spent 3.6 s on this very input in its overlap phase alone,
    /// so a regression to it fails here rather than reaching a user's clipboard.
    func testLinkDensePasteScalesLinearly() {
        let text = String(repeating: "PAY-421 https://example.com/a/b ", count: 8000)
        var elapsed = 0.0

        measure {
            let start = Date()
            _ = ReferenceExtractor.extract(from: text)
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }

        XCTAssertLessThan(elapsed, 1.0, "extraction of a link-dense paste exceeded 1 s")
    }
}
