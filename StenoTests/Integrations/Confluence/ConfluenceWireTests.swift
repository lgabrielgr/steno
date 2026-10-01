import Foundation
import Testing

@testable import StenoKit

/// The wire contract, asserted against the recorded shapes (D-197).

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Test("a page carries its title, its current version, and a relative web URL")
func confluencePageDecodesItsCurrentVersion() throws {
    let page = try decode(ConfluencePage.self, ConfluenceFixture.page())

    #expect(page.id == "12345")
    #expect(page.title == "Payments Migration Plan")
    #expect(page.version?.number == 9)
    #expect(page.version?.authorId == ConfluenceFixture.leo)
    #expect(page.links?.webui == ConfluenceFixture.webui)
}

@Test("§8: a body in the response is not decoded, because nothing models it")
func confluencePageIgnoresABodyItNeverAskedFor() throws {
    // `body-format` is never sent, so this should not arrive — but a decoder that
    // choked on an unmodelled field would turn a surprise into a failed fetch, and a
    // mirror that modelled it would put the page's text in memory. Both are wrong;
    // this pins the middle.
    let withBody = """
        {"id":"12345","title":"T","body":{"storage":{"value":"<p>secret</p>","representation":"storage"}}}
        """
    let page = try decode(ConfluencePage.self, withBody)

    #expect(page.title == "T")
    #expect(Mirror(reflecting: page).children.contains { $0.label == "body" } == false)
}

@Test("every field is optional, so one missing value costs only itself")
func confluencePageSurvivesMissingFields() throws {
    let page = try decode(ConfluencePage.self, "{}")

    #expect(page.id == nil)
    #expect(page.title == nil)
    #expect(page.version == nil)
    #expect(page.links == nil)
}

@Test("a version carries the five fields the schema documents")
func confluenceVersionDecodesItsFiveFields() throws {
    let raw = ConfluenceFixture.version(
        number: 7, createdAt: "2026-09-25T18:04:11.123Z", message: "tightened the migration steps",
        minorEdit: true, authorID: ConfluenceFixture.priya)
    let version = try decode(ConfluenceVersion.self, raw)

    #expect(version.number == 7)
    #expect(version.message == "tightened the migration steps")
    #expect(version.minorEdit == true)
    #expect(version.authorId == ConfluenceFixture.priya)
    #expect(version.stamp == AtlassianDate.parse("2026-09-25T18:04:11.123Z"))
}

@Test("a version with an unreadable timestamp decodes, and says so with nil")
func confluenceVersionWithBadTimestampStillDecodes() throws {
    let version = try decode(
        ConfluenceVersion.self, #"{"number":7,"createdAt":"last Tuesday"}"#)

    // It must decode — §5.5 degrades rather than failing a fetch over one field — and
    // `stamp` must be nil rather than some default date, because a default would place
    // an unplaceable version inside or outside the window by accident.
    #expect(version.number == 7)
    #expect(version.stamp == nil)
}

@Test("Z and +0000 are the same instant, so both forms window identically")
func confluenceVersionAcceptsBothOffsetForms() throws {
    // Confluence documents `YYYY-MM-DDTHH:mm:ss.sssZ` while Jira sends `+0000`. They
    // share a parser now (D-202), and this is what says the sharing is sound.
    let zulu = try decode(ConfluenceVersion.self, #"{"createdAt":"2026-09-25T18:04:11.000Z"}"#)
    let offset = try decode(
        ConfluenceVersion.self, #"{"createdAt":"2026-09-25T18:04:11.000+0000"}"#)

    #expect(zulu.stamp != nil)
    #expect(zulu.stamp == offset.stamp)
}

@Test("a versions page carries its results and the cursor to resume on")
func confluenceVersionPageDecodesResultsAndNext() throws {
    let body = ConfluenceFixture.versions(
        [ConfluenceFixture.version(number: 9), ConfluenceFixture.version(number: 8)],
        next: ConfluenceFixture.next(cursor: "eyJpZCI6NDJ9"))
    let page = try decode(ConfluenceVersionPage.self, body)

    #expect(page.results?.count == 2)
    #expect(page.results?.first?.number == 9)
    #expect(ConfluenceEndpoint.cursor(inNext: page.links?.next) == "eyJpZCI6NDJ9")
}

@Test("an absent `next` is how the API says the walk is over")
func confluenceVersionPageWithoutNextEndsTheWalk() throws {
    let page = try decode(
        ConfluenceVersionPage.self, ConfluenceFixture.versions([ConfluenceFixture.version()]))

    #expect(page.links?.next == nil)
    #expect(ConfluenceEndpoint.cursor(inNext: page.links?.next) == nil)
}

@Test("the user lookup reads a display name and nothing else")
func confluenceUserDecodesOnlyTheDisplayName() throws {
    // The real response also carries an email address, a time zone, a personal space
    // and a permissions block. §8 is kept by not modelling them: whatever arrives,
    // only this one field is decoded.
    let rich = """
        {"accountId":"557058:aa1b","displayName":"Leo Gutierrez","email":"leo@example.com",
         "timeZone":"America/Denver","personalSpace":{"key":"~leo"}}
        """
    let user = try decode(ConfluenceUser.self, rich)

    #expect(user.displayName == "Leo Gutierrez")
    #expect(Mirror(reflecting: user).children.map(\.label) == ["displayName"])
}

@Test("an account with no visible space is still a working credential")
func confluenceSpacesDecodesAnEmptyResult() throws {
    let page = try decode(ConfluenceSpacePage.self, ConfluenceFixture.spaces(count: 0))

    #expect(page.results?.isEmpty == true)
}
