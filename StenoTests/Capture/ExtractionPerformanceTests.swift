import XCTest

@testable import StenoKit

/// Extraction runs on the capture path, which §1.1 and §13 make
/// latency-critical: if capture exceeds ~3 seconds the user reverts to paper
/// and the product dies. XCTest rather than Swift Testing per D-011 — this is
/// the `measure` exception, and there is no Swift Testing equivalent.
///
/// The ceilings sit roughly an order of magnitude above measured values, so a
/// real regression fails while a loaded machine does not.
final class ExtractionPerformanceTests: XCTestCase {
    private static let realistic = """
        Debugged the retry handler for PAY-421, PR https://github.com/acme/api/pull/912, \
        notes in https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Retry
        """

    /// Measured at 75 µs on this machine. A task title is the input that must never be felt.
    func testRealisticCaptureStringIsWellUnderBudget() {
        let text = Self.realistic
        var elapsed = 0.0

        measure {
            let start = Date()
            for _ in 0..<100 {
                _ = ReferenceExtractor.extract(from: text)
            }
            elapsed = Date().timeIntervalSince(start) / 100
        }

        XCTAssertLessThan(elapsed, 0.001, "extraction of a capture string exceeded 1 ms")
    }

    /// Measured at 2.2 ms for ~7 KB on this machine. FR-1.5 runs extraction over
    /// note bodies too, so the longest realistic input gets its own ceiling.
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
            elapsed = Date().timeIntervalSince(start) / 10
        }

        XCTAssertLessThan(elapsed, 0.020, "extraction of a long note body exceeded 20 ms")
    }
}
