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

    // A dyadic fraction, so the emitted digits are exact. Encoding truncates
    // at the millisecond rather than rounding, and most decimals are not
    // representable as a `Double` at this magnitude: `.481` is stored as
    // `.4809999…` and emits as `.480`.
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
    // The values are asserted as *distinct and ordered*, not as exact: both
    // truncate down a millisecond on the way out, which is within the
    // precision this format promises.
    #expect(decoded.events.map(\.body) == ["first", "second"])
    #expect(decoded.events[0].timestamp < decoded.events[1].timestamp)
}

@MainActor
@Test("a dyadic fraction of a second survives exactly")
func aDyadicFractionIsExact() throws {
    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    try fixture.event("on the quarter", on: task, at: ExportFixture.at(0.25))

    let data = try fixture.encoder().encode()
    let decoded = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    // This is why every fixture date is whole or dyadic: it is the only class
    // of value for which `ExportDocument ==` is a fair test.
    #expect(decoded.events.first?.timestamp == ExportFixture.at(0.25))
}

@MainActor
@Test("a date off the clock round-trips to within a millisecond, not exactly")
func aClockDateRoundTripsWithinAMillisecond() throws {
    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    // Sub-millisecond precision, as `Date.now` produces. The encoded string
    // **truncates** to three fractional digits — it does not round — so this is
    // the case `==` would fail, and it fails in one direction only.
    let imprecise = Date(timeIntervalSince1970: 1_700_000_000.4817263)
    try fixture.event("from the clock", on: task, at: imprecise)

    let data = try fixture.encoder().encode()
    let decoded = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    let timestamp = try #require(decoded.events.first?.timestamp)
    // Truncation, so the decoded value is never later than the original and is
    // short by less than a millisecond.
    #expect(timestamp <= imprecise)
    #expect(abs(timestamp.timeIntervalSince(imprecise)) < 0.001)
    // Stated as plainly as possible, because M2.5-02's "the object graph is
    // identical" criterion means identical at this precision, and an `==` on a
    // clock date there would fail in a way that looks like a merge bug.
    #expect(timestamp != imprecise)
}
