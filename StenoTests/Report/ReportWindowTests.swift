import Foundation
import Testing

@testable import StenoKit

private let noon = Date(timeIntervalSince1970: 1_700_000_000)

@Test("FR-4 step 2: a project's first report looks back 24 hours")
func firstRunProducesATwentyFourHourWindow() {
    let (start, end) = ReportWindow.bounds(lastStandupAt: nil, now: noon)

    #expect(end == noon)
    #expect(start == noon.addingTimeInterval(-86_400))
    #expect(end.timeIntervalSince(start) == 86_400)
}

@Test("D8: a subsequent report starts from that project's own lastStandupAt")
func aSubsequentRunStartsFromLastStandupAt() {
    let last = noon.addingTimeInterval(-3_600)

    let (start, end) = ReportWindow.bounds(lastStandupAt: last, now: noon)

    #expect(start == last)
    #expect(end == noon)
}

/// One row of the gap table. Private, so the `@Test` function taking it must be
/// private too — a non-private function with a private parameter type does not
/// compile.
private struct GapCase: Sendable {
    let label: String
    let days: Double
}

/// D8's whole claim, as one parameterized test rather than two hand-written
/// ones.
///
/// The point is that a weekend and a vacation traverse **the same code with no
/// branch between them**. Two separate tests would pass just as well against an
/// implementation that special-cased one of them, which is exactly what D8 says
/// must not exist — so the shared body is the assertion, not a convenience.
@Test(
    "D8: weekend and vacation gaps need no special-casing",
    arguments: [
        GapCase(label: "three-day weekend", days: 3),
        GapCase(label: "two-week vacation", days: 14),
        GapCase(label: "sick day", days: 1),
        GapCase(label: "same morning", days: 0.25),
    ])
private func gapsOfAnyLengthProduceTheirOwnWindow(gap: GapCase) {
    let seconds = gap.days * 86_400
    let last = noon.addingTimeInterval(-seconds)

    let (start, end) = ReportWindow.bounds(lastStandupAt: last, now: noon)

    #expect(start == last, "\(gap.label): window must start at the last stand-up")
    #expect(end.timeIntervalSince(start) == seconds, "\(gap.label): no clamping, no rounding")
}

@Test("§10.1 clock skew: a future lastStandupAt clamps to an empty window")
func aFutureLastStandupClampsToEmpty() {
    let ahead = noon.addingTimeInterval(90)

    let (start, end) = ReportWindow.bounds(lastStandupAt: ahead, now: noon)

    #expect(start == noon)
    #expect(end == noon)
    #expect(start <= end, "M2-03 persists this pair; M2-04 restores lastStandupAt from it")
}

@Test("the 24h fallback is not used to paper over a future lastStandupAt")
func clampingDoesNotFallBackToTwentyFourHours() {
    let ahead = noon.addingTimeInterval(90)

    let (start, _) = ReportWindow.bounds(lastStandupAt: ahead, now: noon)

    // Falling back to 24h here would silently re-report a day of work the user
    // already said out loud on the other Mac.
    #expect(start != noon.addingTimeInterval(-86_400))
}
