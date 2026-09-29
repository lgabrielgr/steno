import Foundation
import Testing

@testable import StenoKit

/// The pure core: what counts as news, what the summary says, and where the next
/// window starts (§5.3, D-203, D-184, D-188).

private let names = ConfluenceFixture.names

/// A version, built directly rather than decoded — these are table tests about
/// judgment, not about the wire.
private func aVersion(
    _ number: Int?,
    at createdAt: String?,
    message: String? = nil,
    minorEdit: Bool = false,
    by authorID: String? = ConfluenceFixture.leo
) -> ConfluenceVersion {
    ConfluenceVersion(
        number: number, createdAt: createdAt, message: message, minorEdit: minorEdit,
        authorId: authorID)
}

private func aPage(
    title: String? = "Payments Migration Plan",
    version: ConfluenceVersion? = nil,
    webui: String? = ConfluenceFixture.webui
) -> ConfluencePage {
    ConfluencePage(
        id: ConfluenceFixture.pageID, title: title, version: version,
        links: ConfluencePage.Links(webui: webui))
}

private func make(
    page: ConfluencePage = aPage(),
    versions: [ConfluenceVersion] = [],
    since: Date? = ConfluenceFixture.windowStart,
    isCapped: Bool = false
) -> ConfluenceChangeSet {
    ConfluenceChangeSet.make(
        page: page, versions: versions, names: names, since: since, isCapped: isCapped)
}

// MARK: - Summary

@Test("§5.3: the summary is title, current version, and last editor")
func confluenceSummaryNamesTheVersionAndEditor() {
    let set = make(page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)))

    #expect(set.summary == "Payments Migration Plan — v9, edited by Leo Gutierrez")
}

@Test("D-176: no timestamp is baked into the stored summary")
func confluenceSummaryCarriesNoTimestamp() {
    // The cached summary outlives the fetch that wrote it. "edited 2h ago" would be
    // wrong one second later, and the staleness banner is what says how old the data
    // is.
    let set = make(page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)))

    #expect(set.summary.contains("2026") == false)
    #expect(set.summary.contains("ago") == false)
}

/// One row of the summary table. A struct rather than a 4-tuple because
/// `make lint --strict` caps a tuple at two members — and it reads better besides.
private struct SummaryCase {
    let title: String?
    let number: Int?
    let authorID: String?
    let expected: String
}

@Test(
    "a missing part is omitted, never rendered as the word unknown",
    arguments: [
        SummaryCase(
            title: nil, number: 9, authorID: ConfluenceFixture.leo,
            expected: "v9, edited by Leo Gutierrez"),
        SummaryCase(
            title: "Payments Migration Plan", number: nil, authorID: ConfluenceFixture.leo,
            expected: "Payments Migration Plan"),
        SummaryCase(
            title: "Payments Migration Plan", number: 9, authorID: "557058:nobody",
            expected: "Payments Migration Plan — v9"),
        SummaryCase(
            title: "Payments Migration Plan", number: nil, authorID: nil,
            expected: "Payments Migration Plan"),
    ])
private func confluenceSummaryOmitsWhatItCannotSay(testCase: SummaryCase) {
    let version = testCase.number.map {
        aVersion($0, at: ConfluenceFixture.inWindow, by: testCase.authorID)
    }
    let set = make(page: aPage(title: testCase.title, version: version))

    #expect(set.summary == testCase.expected)
}

@Test("a page with no title and no readable version still produces a string")
func confluenceSummaryIsEmptyRatherThanWrong() {
    let set = make(page: aPage(title: nil, version: nil))

    #expect(set.summary.isEmpty)
}

// MARK: - The delta

@Test("D-203: one line per version, keyed by page and version number")
func confluenceReportsOneChangePerVersion() {
    // **Input order disagrees with the expected order on purpose.** Versions arrive
    // newest-first, and a test whose input already matched its expectation would pass
    // against an implementation that sorted, reversed, or did nothing at all.
    let set = make(versions: [
        aVersion(9, at: "2026-09-25T18:04:11.000Z", message: "final pass"),
        aVersion(8, at: "2026-09-24T10:00:00.000Z", by: ConfluenceFixture.priya),
        aVersion(7, at: "2026-09-23T09:00:00.000Z", minorEdit: true),
    ])

    #expect(set.changes.map(\.id) == ["12345#v9", "12345#v8", "12345#v7"])
    #expect(
        set.changes.map(\.text) == [
            "v9 by Leo Gutierrez: final pass",
            "v8 by Priya Anand",
            "v7 by Leo Gutierrez (minor)",
        ])
}

@Test("D-201: an editor who could not be named is \"someone\", not an account id")
func confluenceUnresolvedEditorReadsAsSomeone() {
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow, by: "557058:nobody")])

    #expect(set.changes.first?.text == "v9 by someone")
    #expect(set.changes.first?.text.contains("557058") == false)
}

@Test("a deactivated account's blank name is not a name")
func confluenceBlankDisplayNameReadsAsSomeone() {
    // Confluence answers a deactivated account with an empty `displayName`, and
    // "edited by " is not a sentence.
    let set = ConfluenceChangeSet.make(
        page: aPage(), versions: [aVersion(9, at: ConfluenceFixture.inWindow)],
        names: [ConfluenceFixture.leo: "   "], since: ConfluenceFixture.windowStart)

    #expect(set.changes.first?.text == "v9 by someone")
}

@Test("D-203: a minor edit is labelled, never dropped")
func confluenceMinorEditIsLabelledNotDropped() {
    let set = make(versions: [
        aVersion(9, at: ConfluenceFixture.inWindow, message: "typo", minorEdit: true)
    ])

    #expect(set.changes.count == 1)
    #expect(set.changes.first?.text == "v9 by Leo Gutierrez (minor): typo")
}

@Test("a version with no number has no stable key, so it is not reported")
func confluenceVersionWithoutANumberIsSkipped() {
    // Reported, it would arrive under a key that cannot de-duplicate, and every pass
    // would say it again.
    let set = make(versions: [aVersion(nil, at: ConfluenceFixture.inWindow)])

    #expect(set.changes.isEmpty)
}

// MARK: - The window

@Test("a version at exactly `since` is inside the window; a second earlier is not")
func confluenceWindowIncludesItsOwnBoundary() {
    let boundary = "2026-09-22T00:00:00.000Z"
    let justBefore = "2026-09-21T23:59:59.000Z"

    let set = make(versions: [aVersion(9, at: boundary), aVersion(8, at: justBefore)])

    #expect(set.changes.map(\.id) == ["12345#v9"])
}

@Test("D-188: with no anchor, everything read is reported and the service suppresses")
func confluenceFirstObservationReportsWhatItSaw() {
    // Filtering here as well would leave the ids unrecorded, and the next pass — whose
    // window deliberately overlaps — would find them again and call them news.
    let set = make(
        versions: [aVersion(9, at: ConfluenceFixture.inWindow), aVersion(1, at: "2019-01-01T00:00:00.000Z")],
        since: nil)

    #expect(set.changes.count == 2)
}

@Test("a version whose timestamp will not parse is reported rather than lost")
func confluenceUnparseableTimestampIsReported() {
    let set = make(versions: [aVersion(9, at: "last Tuesday"), aVersion(8, at: nil)])

    // It cannot be placed in the window, and the safe direction is to say it: dedup
    // stops it being said twice, while dropping it would lose a real edit to a
    // date-format change.
    #expect(set.changes.map(\.id) == ["12345#v9", "12345#v8"])
}

// MARK: - Watermark

@Test("D-184: the watermark is the newest thing seen, not the newest thing said")
func confluenceWatermarkCoversWhatWasNotReported() {
    let newest = "2026-09-25T18:04:11.000Z"
    let set = make(
        versions: [aVersion(9, at: newest), aVersion(8, at: ConfluenceFixture.outOfWindow)])

    // v8 is outside the window and goes unreported; the watermark still moves past it,
    // or the next pass would re-read the same history forever.
    #expect(set.changes.count == 1)
    #expect(set.watermark == AtlassianDate.parse(newest))
}

@Test("the page's own version anchors a walk that came back empty")
func confluenceWatermarkFallsBackToTheCurrentVersion() {
    let set = make(page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)), versions: [])

    #expect(set.watermark == AtlassianDate.parse(ConfluenceFixture.inWindow))
}

@Test("with nothing timestamped anywhere, the window stays open")
func confluenceWatermarkIsNilWhenNothingIsTimestamped() {
    let set = make(page: aPage(version: nil), versions: [aVersion(9, at: nil)])

    #expect(set.watermark == nil)
}

@Test("a capped walk reports the floor it reached, not the newest it saw")
func confluenceCappedWalkHoldsTheWatermarkAtItsFloor() {
    let newest = "2026-09-25T18:04:11.000Z"
    let floor = "2026-09-24T10:00:00.000Z"
    let set = make(
        page: aPage(version: aVersion(9, at: newest)),
        versions: [aVersion(9, at: newest), aVersion(8, at: floor)],
        isCapped: true)

    // Coverage is complete only above `floor`; claiming `newest` would close over the
    // versions the cap left unread, and the next pass starts from the watermark.
    #expect(set.watermark == AtlassianDate.parse(floor))
    #expect(set.isWindowCapped)
}

@Test("the capped floor never rises above the newest thing actually seen")
func confluenceCappedFloorCannotExceedWhatWasSeen() {
    // A floor above the newest observation would mean claiming coverage of a region
    // nothing was read from.
    let set = make(
        page: aPage(version: aVersion(9, at: "2030-01-01T00:00:00.000Z")),
        versions: [aVersion(8, at: "2026-09-24T10:00:00.000Z")],
        isCapped: true)

    #expect(set.watermark == AtlassianDate.parse("2026-09-24T10:00:00.000Z"))
}

@Test("a capped walk that read nothing has no anchor to offer")
func confluenceCappedWalkWithNothingReadHasNoWatermark() {
    let set = make(
        page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)), versions: [],
        isCapped: true)

    #expect(set.watermark == nil)
}

@Test("an uncapped set says so, which is what the payload records")
func confluenceUncappedSetIsNotFlagged() {
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow)])

    #expect(set.isWindowCapped == false)
}

// MARK: - Free text from a box the editor can type anything into

@Test("a version message with newlines stays one line of a stand-up")
func confluenceMessageNewlinesAreCollapsed() {
    // The change text becomes one line of a report the user reads aloud. A newline in
    // it silently becomes two lines, the second having lost its subject.
    let set = make(versions: [
        aVersion(
            9, at: ConfluenceFixture.inWindow,
            message: "rewrote the rollback steps\n\n- drain the queue\n- flip the flag")
    ])

    let text = try? #require(set.changes.first?.text)
    #expect(text?.contains("\n") == false)
    #expect(
        text
            == "v9 by Leo Gutierrez: rewrote the rollback steps - drain the queue - flip the flag")
}

@Test("D-195's limit applies to a version message too, not only to a Jira comment")
func confluenceLongMessageIsTruncated() {
    // Without this a stand-up line is whatever length somebody's release notes were.
    let long = String(repeating: "migration ", count: 60)
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow, message: long)])

    let text = try? #require(set.changes.first?.text)
    #expect((text?.count ?? 0) <= AtlassianText.limit + "v9 by Leo Gutierrez: ".count)
    #expect(text?.hasSuffix("…") == true)
}

@Test("a message of nothing but whitespace is no message at all")
func confluenceWhitespaceOnlyMessageIsOmitted() {
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow, message: "  \n\t ")])

    #expect(set.changes.first?.text == "v9 by Leo Gutierrez")
}
