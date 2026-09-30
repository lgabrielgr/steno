import Foundation
import Testing

@testable import StenoKit

/// The version walk: how it resumes, where it stops, and what it says when it could not
/// read everything (§5.3, D-188, D-205, D-208).
///
/// Split from `ConfluenceClientTests` for the reason `JiraClientPagingTests` is split
/// from `JiraClientTests`: paging is most of the client's surface, and `make lint`
/// caps a file at 400 lines.

private typealias Answer = StubConfluenceTransport.Answer

private func client(_ transport: StubConfluenceTransport) -> ConfluenceClient {
    ConfluenceClient(transport: transport)
}

private func changeSet(
    _ transport: StubConfluenceTransport, since: Date? = ConfluenceFixture.windowStart
) async throws -> ConfluenceChangeSet {
    try await client(transport).changeSet(
        pageID: ConfluenceFixture.pageID, since: since, credential: ConfluenceFixture.credential())
}

private let knownUsers: [String: Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez")),
    ConfluenceFixture.priya: .ok(ConfluenceFixture.user(displayName: "Priya Anand")),
]

@Test("D-205: the walk resumes on the cursor the response carried")
func confluenceWalkResumesOnTheCursor() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [
                .ok(
                    ConfluenceFixture.versions(
                        [
                            ConfluenceFixture.version(
                                number: 9, createdAt: ConfluenceFixture.inWindow)
                        ],
                        next: ConfluenceFixture.next(cursor: "PAGE2"))),
                .ok(
                    ConfluenceFixture.versions([
                        ConfluenceFixture.version(
                            number: 8, createdAt: ConfluenceFixture.outOfWindow)
                    ])),
            ],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    let urls = await transport.urls.filter { $0.contains("/versions") }
    #expect(urls.count == 2)
    #expect(urls.first?.contains("cursor=") == false)
    #expect(urls.last?.contains("cursor=PAGE2") == true)
    // Both pages' versions are collected; only the one in the window is reported.
    #expect(set.changes.map(\.id) == ["12345#v9"])
    #expect(set.isWindowCapped == false)
}

@Test("the walk stops at the first page that predates the window")
func confluenceWalkStopsBelowTheWindow() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [
                .ok(
                    ConfluenceFixture.versions(
                        [
                            ConfluenceFixture.version(
                                number: 8, createdAt: ConfluenceFixture.outOfWindow)
                        ],
                        next: ConfluenceFixture.next(cursor: "PAGE2")))
            ],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    // A `next` was offered and deliberately not taken: everything below this page is
    // older still, and reading it would cost a request per pass forever.
    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == 1)
    #expect(set.isWindowCapped == false)
}

@Test("a cursor that does not move ends the walk rather than looping")
func confluenceRepeatedCursorEndsTheWalk() async throws {
    // A server that repeats a cursor would otherwise be paged until the cap, re-reading
    // the same versions and reporting a cap that never happened.
    let repeating = ConfluenceFixture.versions(
        [ConfluenceFixture.version(number: 9, createdAt: ConfluenceFixture.inWindow)],
        next: ConfluenceFixture.next(cursor: "SAME"))
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": Array(repeating: Answer.ok(repeating), count: 12),
        ], users: knownUsers)

    let set = try await changeSet(transport)

    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == 2)
    // **Capped, not complete.** `next` was still present, so older versions may remain
    // unread — a walk that could not continue is not a walk that reached the end of the
    // window, and claiming the latter would let the watermark advance over history
    // nothing ever read (Copilot, review of PR #44).
    #expect(set.isWindowCapped)
}

@Test("hitting the page cap is reported as a capped window, not as a complete one")
func confluenceWalkReportsItsCap() async throws {
    // Every page is inside the window and offers a new cursor, so the only thing that
    // stops this walk is the cap.
    let pages = (0..<12).map { index in
        Answer.ok(
            ConfluenceFixture.versions(
                [
                    ConfluenceFixture.version(
                        number: 100 - index, createdAt: ConfluenceFixture.inWindow)
                ],
                next: ConfluenceFixture.next(cursor: "PAGE\(index)")))
    }
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": pages], users: knownUsers)

    let set = try await changeSet(transport)

    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == ConfluenceClient.maxPages)
    #expect(set.isWindowCapped)
}

@Test("D-188: with no anchor, one page is enough to establish one")
func confluenceFirstObservationReadsOnePage() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [
                .ok(
                    ConfluenceFixture.versions(
                        [
                            ConfluenceFixture.version(
                                number: 9, createdAt: ConfluenceFixture.inWindow)
                        ],
                        next: ConfluenceFixture.next(cursor: "PAGE2")))
            ],
        ], users: knownUsers)

    let set = try await changeSet(transport, since: nil)

    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == 1)
    #expect(set.isWindowCapped == false)
    #expect(set.watermark != nil)
}

@Test("D-209: an empty page with a `next` is not the end of the walk")
func confluenceEmptyPageWithNextKeepsPaging() async throws {
    // `results` absent and `results: []` say nothing about whether more history exists —
    // only `_links.next` does. Stopping here and calling the walk complete was the same
    // defect as the repeated cursor, reached from the other side: it let the watermark
    // advance over history the server had just said was there.
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [
                .ok(#"{"_links":{"next":"/wiki/api/v2/pages/12345/versions?cursor=X"}}"#),
                .ok(
                    ConfluenceFixture.versions([
                        ConfluenceFixture.version(
                            number: 8, createdAt: ConfluenceFixture.outOfWindow)
                    ])),
            ],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == 2)
    #expect(versionRequests.last?.contains("cursor=X") == true)
    #expect(set.isWindowCapped == false)
}

@Test("D-209: an empty page with no `next` is the end of the walk")
func confluenceEmptyPageWithoutNextEndsTheWalk() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [.ok(#"{"results":[],"_links":{}}"#)],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == 1)
    #expect(set.isWindowCapped == false)
    #expect(set.changes.isEmpty)
}

@Test("a capped walk does not continue on the next pass — the cap is a bound, not a pause")
func confluenceCappedWalkDoesNotContinueNextPass() async throws {
    // **This pins a limitation, deliberately.** The code used to claim the gap "stays
    // inside the next window and fills itself once the page quiets down". It does not:
    // every walk restarts at `cursor == nil` and pages newest-first, while `since` is
    // only a client-side stopping condition — so lowering the watermark to the floor
    // makes the *next* pass re-read the same ten pages and stop in the same place.
    // Reaching page eleven needs a persisted cursor, which is out of scope (§10's
    // export, import and merge rules would all have to learn about it).
    //
    // The stub answers by **cursor** here rather than from a queue, because a queue
    // models a server that remembers where the last walk stopped — which is precisely
    // the thing that is not true, and which would make this test pass for the wrong
    // reason. Raised by Copilot in review of PR #44.
    var byCursor: [String: Answer] = [:]
    for index in 0..<12 {
        let asksFor = index == 0 ? "" : "PAGE\(index - 1)"
        byCursor[asksFor] = .ok(
            ConfluenceFixture.versions(
                [
                    ConfluenceFixture.version(
                        number: 100 - index, createdAt: ConfluenceFixture.inWindow)
                ],
                next: ConfluenceFixture.next(cursor: "PAGE\(index)")))
    }

    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page()), .ok(ConfluenceFixture.page())]],
        users: knownUsers, versionsByCursor: byCursor)
    let subject = client(transport)

    let first = try await subject.changeSet(
        pageID: ConfluenceFixture.pageID, since: ConfluenceFixture.windowStart,
        credential: ConfluenceFixture.credential())
    #expect(first.isWindowCapped)

    // The second pass asks from the floor the first one reported, exactly as
    // `ResumePoint.since(now:)` would.
    let second = try await subject.changeSet(
        pageID: ConfluenceFixture.pageID,
        since: first.watermark?.addingTimeInterval(-ResumePoint.overlap),
        credential: ConfluenceFixture.credential())

    // It caps again, having walked the same ten pages from the top...
    #expect(second.isWindowCapped)
    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == ConfluenceClient.maxPages * 2)
    #expect(versionRequests.filter { $0.contains("cursor=PAGE9") }.isEmpty)

    // ...so versions 90 and 89, which sit behind that cap, are reported by neither pass
    // even though the fixture is perfectly willing to serve them.
    let reported = Set(first.changes.map(\.id) + second.changes.map(\.id))
    #expect(reported.contains("12345#v90") == false)
    #expect(reported.contains("12345#v89") == false)
}
