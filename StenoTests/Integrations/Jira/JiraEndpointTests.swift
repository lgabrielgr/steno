import Foundation
import Testing

@testable import StenoKit

/// D5 and D-191: the requests this connector can build, and the one method it may use.

private let base = URL(string: "https://acme.atlassian.net")

private func request(_ endpoint: JiraEndpoint) throws -> HTTPRequest {
    let base = try #require(base)
    return try #require(endpoint.request(base: base, authorization: "Basic xyz"))
}

@Test(
    "D5: every endpoint builds a GET",
    arguments: [
        JiraEndpoint.issue(key: "PAY-421"),
        .changelog(key: "PAY-421", startAt: 0, maxResults: 100),
        .comments(key: "PAY-421", startAt: 0, maxResults: 50),
        .remoteLinks(key: "PAY-421"),
        .currentUser,
    ])
func everyEndpointIsAGet(endpoint: JiraEndpoint) throws {
    // The acceptance criterion says to assert read-only rather than intend it. This is
    // the first of three: nothing here can construct a write, because `request` does
    // not take a method. Mutation: change one `case` to `.post` and this goes red.
    #expect(try request(endpoint).method == .get)
}

@Test("the paths are REST v3's, with the key in place")
func thePathsAreRestV3() throws {
    #expect(try request(.issue(key: "PAY-421")).url.path == "/rest/api/3/issue/PAY-421")
    #expect(
        try request(.changelog(key: "PAY-421", startAt: 0, maxResults: 100)).url.path
            == "/rest/api/3/issue/PAY-421/changelog")
    #expect(
        try request(.comments(key: "PAY-421", startAt: 0, maxResults: 50)).url.path
            == "/rest/api/3/issue/PAY-421/comment")
    #expect(
        try request(.remoteLinks(key: "PAY-421")).url.path == "/rest/api/3/issue/PAY-421/remotelink"
    )
    #expect(try request(.currentUser).url.path == "/rest/api/3/myself")
}

@Test("D-191: `updateHistory` is never sent, because it writes")
func updateHistoryIsNeverSent() throws {
    // `GET /issue/{key}` accepts `updateHistory`, which reorders the user's recent
    // projects — a read with a write side effect, which D5 forbids. It defaults to
    // false, so the assertion is that we never name it.
    let all = [
        try request(.issue(key: "PAY-421")),
        try request(.changelog(key: "PAY-421", startAt: 0, maxResults: 100)),
        try request(.comments(key: "PAY-421", startAt: 0, maxResults: 50)),
        try request(.remoteLinks(key: "PAY-421")),
        try request(.currentUser),
    ]
    for built in all {
        #expect(built.url.absoluteString.contains("updateHistory") == false)
    }
}

@Test("the issue request asks for four fields, not for everything")
func theIssueRequestNamesItsFields() throws {
    let url = try request(.issue(key: "PAY-421")).url.absoluteString
    // §8 is easier to keep when the response never carried the content: a bare issue
    // GET returns every custom field an org has ever defined.
    #expect(url.contains("fields=summary,status,assignee,updated"))
}

@Test("comments are ordered newest first, because there is no date filter")
func commentsAreOrderedNewestFirst() throws {
    let url = try request(.comments(key: "PAY-421", startAt: 50, maxResults: 50)).url.absoluteString
    // Verified against the API's OpenAPI document: `orderBy` accepts `-created`, and
    // neither this endpoint nor the changelog takes a `since` of any kind (D-196).
    #expect(url.contains("orderBy=-created"))
    #expect(url.contains("startAt=50"))
    #expect(url.contains("maxResults=50"))
}

@Test("the credential travels as a header, never in the URL")
func theCredentialIsAHeader() throws {
    let built = try request(.issue(key: "PAY-421"))
    #expect(built.headers["authorization"] == "Basic xyz")
    #expect(built.url.absoluteString.contains("xyz") == false)
}

@Test(
    "a key that is not a key yields nil rather than a wasted round trip",
    arguments: ["", "   ", "PAY 421", "PAY-421\n"])
func anInvalidKeyIsRefused(key: String) throws {
    let base = try #require(base)
    // `URLComponents` would encode all of these happily and Jira would answer 400, so
    // the check is local and the `nil` reaches `JiraClient` as `.notFound` — what a
    // mistyped reference in a task title deserves.
    #expect(JiraEndpoint.issue(key: key).request(base: base, authorization: "x") == nil)
}

@Test("an ordinary key is not refused")
func anOrdinaryKeyIsAccepted() throws {
    // The other direction, because a validator that rejected everything would pass the
    // test above and break the product (one-directional coverage is blind).
    #expect(JiraEndpoint.isValidKey("PAY-421"))
    #expect(JiraEndpoint.isValidKey("A1_2-99"))
    #expect(try request(.issue(key: "PAY-421")).url.path == "/rest/api/3/issue/PAY-421")
}
