import Foundation
import Testing

@testable import StenoKit

/// §10.2's timestamps as a **fixed point**, which is the property M2.5-02's
/// idempotency criterion rests on and the one M2.5-01 did not have.
///
/// D-091 measured `Date → string → Date` and recorded it honestly: lossy, exact
/// only for eighths. The direction that decides whether a merge converges is the
/// other one — `string → Date → string` — and under the format style's own
/// truncation it was unstable for 496 of 1000 millisecond values, walking a
/// timestamp backwards up to 2 ms across at most two export/import hops.
/// `ExportDocument.wireString` rounds instead, and these tests are that
/// measurement kept where a regression has to argue with it.

private struct WireDecodeFailure: Error {
    let text: String
}

/// Epochs spanning 2020 to 2033, because the representable gap between decimals
/// widens with magnitude and a single epoch would prove nothing about the others.
private let wireEpochs: [TimeInterval] = [
    1_600_000_000, 1_700_000_000, 1_800_000_000, 2_000_000_000,
]

private func decodeWire(_ text: String, using decoder: JSONDecoder) throws -> Date {
    let decoded = try decoder.decode([Date].self, from: Data("[\"\(text)\"]".utf8))
    guard let date = decoded.first else { throw WireDecodeFailure(text: text) }
    return date
}

/// The whole second at `epoch`, with its fractional part replaced.
private func wireText(epoch: TimeInterval, millisecond: Int) -> String {
    ExportDocument.wireString(Date(timeIntervalSince1970: epoch))
        .replacingOccurrences(of: ".000Z", with: String(format: ".%03dZ", millisecond))
}

@Test("every millisecond value is a fixed point: string → Date → string")
func everyMillisecondValueIsAFixedPoint() throws {
    let decoder = ExportDocument.decoder()
    var unstable: [(String, String)] = []

    for epoch in wireEpochs {
        for millisecond in 0..<1000 {
            let text = wireText(epoch: epoch, millisecond: millisecond)
            let emitted = ExportDocument.wireString(try decodeWire(text, using: decoder))
            if emitted != text { unstable.append((text, emitted)) }
        }
    }

    // Falsify by deleting the half-millisecond from `wireString`: measured, this
    // goes to 1984 of 4000, the first being `…20.002Z → …20.001Z`. The count and
    // the first pair ride in the message so a failure names the scale of the
    // regression and one concrete instance of it.
    #expect(
        unstable.isEmpty,
        "\(unstable.count) of 4000 unstable, first: \(unstable.first as Any)")
}

@Test("a clock-shaped date survives re-emission unchanged")
func aClockShapedDateSurvivesReEmission() throws {
    let decoder = ExportDocument.decoder()
    var unstable = 0
    var worstError: TimeInterval = 0

    // Deliberately off the millisecond and off any eighth — the shape `Date.now`
    // produces, and the shape that moved under truncation.
    for step in 0..<5000 {
        let original = Date(
            timeIntervalSince1970: 1_700_000_000 + Double(step) * 0.000_137_4 + 0.480_999_9)
        let text = ExportDocument.wireString(original)
        let decoded = try decodeWire(text, using: decoder)
        if ExportDocument.wireString(decoded) != text { unstable += 1 }
        worstError = max(worstError, abs(decoded.timeIntervalSince(original)))
    }

    #expect(unstable == 0)
    // Half a millisecond, plus the representation slack at this magnitude. Under
    // truncation the same sweep moved 9919 of 20000 and the error was one-sided.
    #expect(worstError < 0.000_51)
}

@Test("the encoder's date strategy and the sort key are the same implementation")
func theEncoderAndTheSortKeyAgree() throws {
    // D-092 records the last time these were two implementations: an arithmetic
    // sort key disagreed with the formatter at `.999`. Rounding makes that
    // boundary live again — `…20.9995` carries into the next whole second — so
    // the two must be the same function, not two functions that agree today.
    let awkward: [TimeInterval] = [0, 0.000_1, 0.480_999_9, 0.499_5, 0.999_4, 0.999_5, 0.999_99]

    for offset in awkward {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + offset)
        let text = try ExportJSON.text(of: ExportDocument.encoder().encode([date]))

        #expect(text.contains(ExportDocument.wireString(date)), "offset \(offset)")
    }
}

@Test("rounding carries across a whole-second boundary")
func roundingCarriesAcrossASecondBoundary() {
    // The `.999` boundary, stated as a behaviour rather than left implicit:
    // truncation clamped everything here to `…20.999`, which is why the two
    // implementations D-092 found could disagree without either being obviously
    // wrong. `.9994` stays; `.9995` and above carry.
    let base = 1_700_000_000.0

    #expect(
        ExportDocument.wireString(Date(timeIntervalSince1970: base + 0.999_4))
            .hasSuffix("20.999Z"))
    #expect(
        ExportDocument.wireString(Date(timeIntervalSince1970: base + 0.999_5))
            .hasSuffix("21.000Z"))
    #expect(
        ExportDocument.wireString(Date(timeIntervalSince1970: base + 0.999_99))
            .hasSuffix("21.000Z"))
}

@Test("every eighth of a second is still exact")
func everyEighthIsStillExact() throws {
    let decoder = ExportDocument.decoder()
    // The set `ExportFixture` documents, and the reason its `==` assertions are
    // fair. Rounding must not have cost this.
    let eighths: [TimeInterval] = [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875]

    for eighth in eighths {
        let original = Date(timeIntervalSince1970: 1_700_000_000 + eighth)
        let decoded = try decodeWire(ExportDocument.wireString(original), using: decoder)

        #expect(decoded == original, "eighth \(eighth)")
    }
}
