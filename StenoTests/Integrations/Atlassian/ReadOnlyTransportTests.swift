import Foundation
import Testing

@testable import StenoKit

/// D5's second enforcement point (D-191).

@Test("GET is allowed")
func getIsAllowed() {
    #expect(ReadOnlyTransport.isAllowed(.get))
}

@Test("D5: POST is not allowed")
func postIsNotAllowed() {
    // **The predicate, not the trap.** `send` calls `preconditionFailure` on anything
    // but a GET, and a test cannot survive that — so the rule is asserted here and the
    // trap is one line that calls it. Asserting the rule is what keeps "every request
    // is a GET" verified without a test process that dies to prove it.
    #expect(ReadOnlyTransport.isAllowed(.post) == false)
}

@Test("an allowed request reaches the wrapped transport unchanged")
func anAllowedRequestPassesThrough() async throws {
    let inner = StubJiraTransport(routes: ["issue": [.ok(JiraFixture.issue())]])
    let transport = ReadOnlyTransport(wrapping: inner)
    let url = try #require(URL(string: "https://acme.atlassian.net/rest/api/3/issue/PAY-421"))

    let response = try await transport.send(
        HTTPRequest(method: .get, url: url, headers: ["authorization": "Basic xyz"]))

    #expect(response.status == 200)
    let received = await inner.received
    #expect(received.count == 1)
    #expect(received.first?.headers["authorization"] == "Basic xyz")
}
