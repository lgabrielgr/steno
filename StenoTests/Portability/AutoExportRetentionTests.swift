import Foundation
import Testing

@testable import StenoKit

private func exportURLs(_ days: [String]) -> [URL] {
    days.map { URL(fileURLWithPath: "/backups/steno-export-\($0).json") }
}

@Test("the newest 14 are kept and the rest are returned")
@MainActor
func theNewestFourteenAreKept() {
    let days = (1...20).map { String(format: "2026-09-%02d", $0) }

    let prunable = AutoExportRetention.prunable(from: exportURLs(days.shuffled()))

    #expect(prunable.count == 6)
    #expect(
        Set(prunable.map(\.lastPathComponent))
            == Set(days.prefix(6).map { "steno-export-\($0).json" }))
}

@Test("fewer than the limit prunes nothing")
@MainActor
func fewerThanTheLimitPrunesNothing() {
    let days = (1...14).map { String(format: "2026-09-%02d", $0) }

    #expect(AutoExportRetention.prunable(from: exportURLs(days)).isEmpty)
}

/// D-124: only Steno's own dated names are ever candidates, so nothing the user
/// put in the folder can be deleted by retention.
@Test("only exact steno-export-YYYY-MM-DD.json names are candidates")
@MainActor
func onlyExactNamesAreCandidates() {
    let foreign = [
        "notes.txt",
        "steno-export.json",
        "steno-export-2026-09.json",
        "steno-export-2026-9-01.json",
        "steno-export-2026-09-01.json.bak",
        "steno-export-2026-09-01-copy.json",
        "steno-backup-2026-09-01-142205.json",
        "Steno-Export-2026-09-01.json",
    ].map { URL(fileURLWithPath: "/backups/\($0)") }
    let mine = exportURLs((1...20).map { String(format: "2026-09-%02d", $0) })

    let prunable = AutoExportRetention.prunable(from: foreign + mine)

    #expect(prunable.allSatisfy { $0.lastPathComponent.hasPrefix("steno-export-2026-09-") })
    #expect(prunable.count == 6)
}

/// A name whose digits are not ASCII sorts unpredictably against one whose are,
/// so it is not a candidate at all.
@Test("non-ASCII digits are not a date")
@MainActor
func nonASCIIDigitsAreNotADate() {
    #expect(AutoExportRetention.day(inFilename: "steno-export-٢٠٢٦-٠٩-٠١.json") == nil)
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-09-01.json") == "2026-09-01")
}

@Test("keeping zero prunes everything that matches")
@MainActor
func keepingZeroPrunesEverything() {
    let urls = exportURLs(["2026-09-01", "2026-09-02"])

    #expect(AutoExportRetention.prunable(from: urls, keeping: 0).count == 2)
}

/// Ten digits in the right shape are not a date. `2026-99-99` passed every
/// structural check and then sorted *newer* than any genuine export, so it
/// held one of the fourteen kept slots forever and evicted a real backup
/// early. Raised by Copilot in review of PR #32.
@Test("a filename whose date cannot exist is not a candidate")
@MainActor
func animpossibleDateIsNotACandidate() {
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-99-99.json") == nil)
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-13-01.json") == nil)
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-00-10.json") == nil)
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-01-00.json") == nil)
    // `Calendar.date(from:)` answers this one with March 2nd rather than nil,
    // which is why the implementation reads the components back out.
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-02-30.json") == nil)
}

/// The other half: every date Steno itself writes must still parse, including
/// the leap day that the round-trip check is most likely to get wrong.
@Test("real dates, leap day included, are still candidates")
@MainActor
func realDatesAreStillCandidates() {
    #expect(AutoExportRetention.day(inFilename: "steno-export-2024-02-29.json") == "2024-02-29")
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-12-31.json") == "2026-12-31")
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-01-01.json") == "2026-01-01")
    // 2026 is not a leap year, so this one must go.
    #expect(AutoExportRetention.day(inFilename: "steno-export-2026-02-29.json") == nil)
}

/// A name Steno wrote must always survive its own validator — the round trip
/// through `ExportFilename` is the only claim that matters here.
@Test("every filename ExportFilename produces parses back")
@MainActor
func exportFilenamesAlwaysParse() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for dayOffset in 0..<400 {
        let date = start.addingTimeInterval(TimeInterval(dayOffset * 24 * 60 * 60))
        let name = ExportFilename.forDate(date, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
        #expect(AutoExportRetention.day(inFilename: name) != nil, "\(name) did not parse")
    }
}
