import Foundation
import Testing

@testable import StenoKit

/// §10.2's `steno-export-YYYY-MM-DD.json`.

@Test("§10.2: the filename carries the date, zero-padded")
func theFilenameCarriesTheDate() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))

    // 2023-11-14 22:13:20 UTC.
    #expect(
        ExportFilename.forDate(ExportFixture.origin, timeZone: utc)
            == "steno-export-2023-11-14.json")
}

@Test("the date is the user's local day, not UTC's")
func theDateIsLocal() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let denver = try #require(TimeZone(identifier: "America/Denver"))
    let utc = try #require(TimeZone(identifier: "UTC"))

    // 22:13 UTC on the 14th is already 07:13 on the 15th in Tokyo. A user who
    // exports in the evening should see the day they remember, not UTC's.
    #expect(
        ExportFilename.forDate(ExportFixture.origin, timeZone: tokyo)
            == "steno-export-2023-11-15.json")

    // And the other direction: 00:13 UTC on the 15th is still the 14th in
    // Denver. Both cases, because a test in one time zone passes either way.
    let justAfterMidnightUTC = ExportFixture.at(7200)
    #expect(
        ExportFilename.forDate(justAfterMidnightUTC, timeZone: utc)
            == "steno-export-2023-11-15.json")
    #expect(
        ExportFilename.forDate(justAfterMidnightUTC, timeZone: denver)
            == "steno-export-2023-11-14.json")
}
