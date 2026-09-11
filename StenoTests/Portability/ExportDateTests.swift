import Foundation
import Testing

@testable import StenoKit

/// §10.2's timestamps at millisecond precision, and what a round-trip can and
/// cannot promise.

@MainActor
@Test("timestamps carry milliseconds, not whole seconds")
func timestampsCarryMilliseconds() throws {
    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    try fixture.event("precise", on: task, at: ExportFixture.at(0.5))

    let text = try ExportJSON.text(of: try fixture.encoder().encode())

    // An eighth of a second, so the emitted digits are exact. Encoding rounds
    // to the nearest millisecond, which most decimals need: `.481` is stored as
    // `.4809999…` at this magnitude, and truncating it — which the format style
    // does on its own — would emit `.480` and make the format lose a
    // millisecond every time a value crossed a file (D-101).
    #expect(text.contains("2023-11-14T22:13:20.500Z"))
}

@MainActor
@Test("§10.1: two events a millisecond apart stay distinct and ordered")
func aMillisecondApartSurvivesTheRoundTrip() throws {
    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    try fixture.event("second", on: task, at: ExportFixture.at(0.482))
    try fixture.event("first", on: task, at: ExportFixture.at(0.481))

    let data = try fixture.encoder().encode()
    let decoded = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    // Whole-second encoding collapses these two into one instant: the order
    // becomes unrecoverable and §10.1's three timestamp-comparison merge rules
    // get a tie they cannot break. This is the assertion that would go red.
    //
    // The values are asserted as *distinct and ordered*, not as exact. They
    // happen to be exact now that encoding rounds, but the property this test
    // exists for is that a millisecond of separation survives at all — asserting
    // equality here would tie the test to the rounding rule it is not about.
    #expect(decoded.events.map(\.body) == ["first", "second"])
    #expect(decoded.events[0].timestamp < decoded.events[1].timestamp)
}

@MainActor
@Test("an eighth of a second survives exactly")
func anEighthOfASecondIsExact() throws {
    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    try fixture.event("on the quarter", on: task, at: ExportFixture.at(0.25))

    let data = try fixture.encoder().encode()
    let decoded = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    // This is why every fixture date **used in a direct `==` assertion** is a
    // whole second or an eighth. Other tests deliberately use values that do
    // not survive — `.5001`, `.5002`, a clock-shaped date — because that is the
    // behaviour they exist to pin; they assert order or tolerance, never
    // equality. "Dyadic" would be too broad for the exact set: `.0625` is
    // dyadic and still emits `.062`, because the half-millisecond rounding adds
    // lands just below `.063` at this magnitude — measured, not derived. The eighths — 0, .125, .25, .375, .5, .625, .75, .875 —
    // are the only values both exactly representable as a `Double` and exactly
    // expressible in three decimals.
    #expect(decoded.events.first?.timestamp == ExportFixture.at(0.25))
}

@MainActor
@Test("a date off the clock round-trips to within half a millisecond, not exactly")
func aClockDateRoundTripsWithinHalfAMillisecond() throws {
    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    // Sub-millisecond precision, as `Date.now` produces. Three fractional
    // digits cannot hold it, so this is the case `==` would fail.
    let imprecise = Date(timeIntervalSince1970: 1_700_000_000.4817263)
    try fixture.event("from the clock", on: task, at: imprecise)

    let data = try fixture.encoder().encode()
    let decoded = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    let timestamp = try #require(decoded.events.first?.timestamp)
    // **Rounding, so the error goes in either direction** — this value moves
    // *up*, to `.482`. That is the assertion that changed in M2.5-02: it read
    // `timestamp <= imprecise` while the format truncated. Half a millisecond
    // plus the representation slack measured at this magnitude (0.5002 ms).
    #expect(abs(timestamp.timeIntervalSince(imprecise)) < 0.000_51)
    // Stated as plainly as possible, because M2.5-02's "the object graph is
    // identical" criterion means identical at this precision, and an `==` on a
    // clock date there would fail in a way that looks like a merge bug.
    #expect(timestamp != imprecise)
}
