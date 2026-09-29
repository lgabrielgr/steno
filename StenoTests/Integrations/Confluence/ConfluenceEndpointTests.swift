import Foundation
import Testing

@testable import StenoKit

/// D5, D-191 and D-205: the requests this connector can build, the one method it may
/// use, and the one thing it takes from a response that tells it where to go next.

private let site = URL(string: "https://acme.atlassian.net")

private func built(_ endpoint: ConfluenceEndpoint) throws -> HTTPRequest {
    let base = try #require(site)
    return try #require(endpoint.request(base: base, authorization: "Basic xyz"))
}

@Test(
    "D5: every Confluence endpoint builds a GET",
    arguments: [
        ConfluenceEndpoint.page(id: "12345"),
        .versions(pageID: "12345", cursor: nil, limit: 50),
        .versions(pageID: "12345", cursor: "eyJpZCI6NDJ9", limit: 50),
        .user(accountID: "557058:aa1b"),
        .spaces(limit: 1),
    ])
func everyConfluenceEndpointIsAGet(endpoint: ConfluenceEndpoint) throws {
    #expect(try built(endpoint).method == .get)
}

@Test("the content paths are v2's; the name lookup is the one v1 path (D-200, D-201)")
func confluencePathsAreV2ExceptTheUserLookup() throws {
    #expect(try built(.page(id: "12345")).url.path == "/wiki/api/v2/pages/12345")
    #expect(
        try built(.versions(pageID: "12345", cursor: nil, limit: 50)).url.path
            == "/wiki/api/v2/pages/12345/versions")
    #expect(try built(.spaces(limit: 1)).url.path == "/wiki/api/v2/spaces")
    #expect(try built(.user(accountID: "557058:aa1b")).url.path == "/wiki/rest/api/user")
}

@Test("§8: the page request never asks for a body")
func confluencePageRequestAsksForNoBody() throws {
    // `body-format` is what makes the API render a page's text into the response.
    // Not sending it is the whole of the §8 claim, so the assertion is that the
    // request carries no query at all — which also pins `include-version`'s default,
    // since the current version is what the summary is built from and nothing here
    // asks for it.
    #expect(try built(.page(id: "12345")).url.query == nil)
}

@Test("the version walk is sorted newest-first, and says so on every page")
func confluenceVersionsAreSortedNewestFirst() throws {
    let first = try built(.versions(pageID: "12345", cursor: nil, limit: 50))
    let items = try #require(URLComponents(url: first.url, resolvingAgainstBaseURL: false)?
        .queryItems)

    #expect(items.contains(URLQueryItem(name: "sort", value: "-modified-date")))
    #expect(items.contains(URLQueryItem(name: "limit", value: "50")))
    #expect(items.contains { $0.name == "cursor" } == false)

    // A resumed page keeps both: the cursor encodes position, not ordering, and a
    // walk that dropped `sort` would page the rest of the history ascending.
    let resumed = try built(.versions(pageID: "12345", cursor: "eyJpZCI6NDJ9", limit: 50))
    let resumedItems = try #require(
        URLComponents(url: resumed.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(resumedItems.contains(URLQueryItem(name: "sort", value: "-modified-date")))
    #expect(resumedItems.contains(URLQueryItem(name: "cursor", value: "eyJpZCI6NDJ9")))
}

@Test("the name lookup sends the account id")
func confluenceUserLookupSendsTheAccountID() throws {
    let request = try built(.user(accountID: "557058:aa1b"))
    let items = try #require(
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items == [URLQueryItem(name: "accountId", value: "557058:aa1b")])
}

@Test("D-205: only the cursor is taken out of `_links.next`")
func confluenceCursorIsExtractedFromNext() {
    let next = "/wiki/api/v2/pages/12345/versions?limit=50&sort=-modified-date&cursor=eyJpZCI6NDJ9"
    #expect(ConfluenceEndpoint.cursor(inNext: next) == "eyJpZCI6NDJ9")
}

@Test("D-205: a `next` pointing somewhere else cannot redirect the token")
func confluenceNextOnAnotherHostIsNotFollowed() throws {
    // The attack this rule exists for: every request carries HTTP Basic, so a `next`
    // naming another host would send the user's API token there. Only the cursor
    // survives parsing, and the rebuilt request goes to the configured site.
    let hostile = "https://evil.example.com/wiki/api/v2/pages/1/versions?cursor=stolen"
    let cursor = try #require(ConfluenceEndpoint.cursor(inNext: hostile))

    let request = try built(.versions(pageID: "12345", cursor: cursor, limit: 50))

    #expect(request.url.host() == "acme.atlassian.net")
    #expect(request.url.path == "/wiki/api/v2/pages/12345/versions")
    #expect(request.url.absoluteString.contains("evil.example.com") == false)
}

@Test(
    "a `next` with nothing to resume on ends the walk",
    arguments: [
        nil,
        "",
        "/wiki/api/v2/pages/12345/versions?limit=50",
        "/wiki/api/v2/pages/12345/versions?cursor=",
    ] as [String?])
func confluenceNextWithoutACursorEndsTheWalk(next: String?) {
    // Each of these would otherwise re-request the first page forever.
    #expect(ConfluenceEndpoint.cursor(inNext: next) == nil)
}

@Test(
    "a page id that is not a page id never reaches a URL",
    arguments: ["", "abc", "12 34", "12/34", "12345\u{200B}", "١٢٣", "-1", "12.0"])
func confluenceInvalidPageIDsAreRefusedLocally(id: String) throws {
    #expect(ConfluenceEndpoint.isValidPageID(id) == false)

    let base = try #require(site)
    #expect(ConfluenceEndpoint.page(id: id).request(base: base, authorization: "Basic xyz") == nil)
    #expect(
        ConfluenceEndpoint.versions(pageID: id, cursor: nil, limit: 50)
            .request(base: base, authorization: "Basic xyz") == nil)
}

@Test("a real page id is accepted")
func confluenceValidPageIDIsAccepted() throws {
    #expect(ConfluenceEndpoint.isValidPageID("12345"))
    #expect(ConfluenceEndpoint.isValidPageID("0"))
    #expect(try built(.page(id: "12345")).url.path.hasSuffix("/12345"))
}

@Test("the endpoints that address no page are built whatever the ids around them")
func confluenceEndpointsWithoutAPageIDAreAlwaysBuilt() throws {
    #expect(ConfluenceEndpoint.user(accountID: "557058:aa1b").pageID == nil)
    #expect(ConfluenceEndpoint.spaces(limit: 1).pageID == nil)
    #expect(try built(.spaces(limit: 1)).url.query == "limit=1")
}
