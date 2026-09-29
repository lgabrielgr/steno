import Foundation
import Testing

@testable import StenoKit

/// The walk, the names, and the failures (§5.3, §5.5, D-201, D-205, D-206).

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

/// The two names every fixture editor resolves to, answered by account id.
private let knownUsers: [String: Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez")),
    ConfluenceFixture.priya: .ok(ConfluenceFixture.user(displayName: "Priya Anand")),
]

// MARK: - Read-only

@Test("D5: a whole Confluence fetch issues only GETs")
func confluenceFetchIssuesOnlyGets() async throws {
    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(), users: knownUsers)

    _ = try await changeSet(transport)

    let methods = await transport.methods
    #expect(methods.isEmpty == false)
    #expect(methods.allSatisfy { $0 == .get })
}

// MARK: - Paging

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
    #expect(set.isWindowCapped == false)
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

// MARK: - Names

@Test("D-201: one lookup per distinct account, however many versions they wrote")
func confluenceResolvesEachAccountOnce() async throws {
    let versions = ConfluenceFixture.versions([
        ConfluenceFixture.version(
            number: 9, createdAt: ConfluenceFixture.inWindow, authorID: ConfluenceFixture.leo),
        ConfluenceFixture.version(
            number: 8, createdAt: ConfluenceFixture.inWindow, authorID: ConfluenceFixture.priya),
        ConfluenceFixture.version(
            number: 7, createdAt: ConfluenceFixture.inWindow, authorID: ConfluenceFixture.leo),
    ])
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": [.ok(versions)]],
        users: knownUsers)

    let set = try await changeSet(transport)

    let counts = await transport.callCounts
    #expect(counts["user"] == 2)
    #expect(
        set.changes.map(\.text) == [
            "v9 by Leo Gutierrez", "v8 by Priya Anand", "v7 by Leo Gutierrez",
        ])
}

@Test("D-201: the lookups are bounded, and the newest editors are the ones named")
func confluenceNameLookupsAreBounded() async throws {
    // Twelve distinct editors inside one window is not the ordinary case — it is the
    // pathological one the bound exists for, so that one page cannot spend a refresh
    // pass's budget on name lookups.
    let editors = (0..<12).map { "557058:editor-\($0)" }
    let versions = ConfluenceFixture.versions(
        editors.enumerated().map { index, id in
            ConfluenceFixture.version(
                number: 100 - index, createdAt: ConfluenceFixture.inWindow, authorID: id)
        })
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": [.ok(versions)]],
        users: Dictionary(
            uniqueKeysWithValues: editors.map { id in
                (id, Answer.ok(ConfluenceFixture.user(displayName: "Editor \(id.suffix(1))")))
            }))

    let set = try await changeSet(transport)

    let counts = await transport.callCounts
    #expect(counts["user"] == ConfluenceClient.maxNameLookups)

    // The ids are walked newest-first, so the versions that keep their editor are the
    // most recent ones — not whichever the hasher happened to favour.
    #expect(set.changes.first?.text == "v100 by Editor 0")
    #expect(set.changes.last?.text == "v89 by someone")
}

@Test("D-201: a name lookup that fails costs a name, not the fetch")
func confluenceFailedNameLookupDoesNotFailTheFetch() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [
                .ok(
                    ConfluenceFixture.versions([
                        ConfluenceFixture.version(
                            number: 9, createdAt: ConfluenceFixture.inWindow)
                    ]))
            ],
        ],
        users: [ConfluenceFixture.leo: .status(404)])

    let set = try await changeSet(transport)

    #expect(set.changes.first?.text == "v9 by someone")
}

@Test("the page's own editor is named too, not only the versions'")
func confluencePageEditorIsResolved() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [
                .ok(
                    ConfluenceFixture.page(
                        currentVersion: ConfluenceFixture.version(
                            number: 9, createdAt: ConfluenceFixture.inWindow,
                            authorID: ConfluenceFixture.priya)))
            ],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    #expect(set.summary == "Payments Migration Plan — v9, edited by Priya Anand")
}

// MARK: - Failures

@Test("D-206: a failed version walk fails the ref rather than reporting no changes")
func confluenceFailedVersionWalkThrows() async throws {
    // Reported as an empty delta, this would advance the watermark past changes that
    // were never read — and the next pass would start after them. The news would not be
    // delayed; it would be gone.
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": [.status(503)]],
        users: knownUsers)

    await #expect(throws: SourceError.unavailable(status: 503)) {
        _ = try await changeSet(transport)
    }
}

@Test("a failed page read fails the ref, and its error is the one that escapes")
func confluenceFailedPageReadThrowsItsOwnError() async throws {
    // Both requests fail; the page's error is the one that describes the ref.
    let transport = StubConfluenceTransport(
        routes: ["page": [.status(404)], "versions": [.status(503)]], users: knownUsers)

    await #expect(throws: SourceError.notFound) {
        _ = try await changeSet(transport)
    }
}

@Test(
    "§5.2's status vocabulary reaches Confluence unchanged",
    arguments: [
        (401, SourceError.credentialExpired),
        (403, SourceError.invalidCredential),
        (404, SourceError.notFound),
        (500, SourceError.unavailable(status: 500)),
    ])
func confluenceStatusesMapToSourceErrors(status: Int, expected: SourceError) async throws {
    let transport = StubConfluenceTransport(routes: ["page": [.status(status)]])

    await #expect(throws: expected) {
        _ = try await changeSet(transport)
    }
}

@Test("a body that will not decode is an invalid response, not a network failure")
func confluenceUndecodableBodyIsInvalidResponse() async throws {
    let transport = StubConfluenceTransport(routes: ["page": [.ok("not json at all")]])

    await #expect(throws: SourceError.invalidResponse) {
        _ = try await changeSet(transport)
    }
}

@Test("a page id that is not a page id never leaves the process")
func confluenceInvalidPageIDNeverReachesTheNetwork() async throws {
    let transport = StubConfluenceTransport(routes: ConfluenceFixture.quietRoutes())

    await #expect(throws: SourceError.notFound) {
        _ = try await client(transport).changeSet(
            pageID: "not-a-page", since: nil, credential: ConfluenceFixture.credential())
    }

    let received = await transport.received
    #expect(received.isEmpty)
}

// MARK: - testConnection

@Test("FR-6: the connection test reads spaces, and an empty result still passes")
func confluenceVerifyPassesOnAnEmptySpaceList() async throws {
    let transport = StubConfluenceTransport(routes: [
        "spaces": [.ok(ConfluenceFixture.spaces(count: 0))]
    ])

    try await client(transport).verify(credential: ConfluenceFixture.credential())

    let urls = await transport.urls
    #expect(urls.count == 1)
    #expect(urls.first?.contains("/wiki/api/v2/spaces") == true)
}

@Test("FR-6: an account without Confluence access fails the test specifically")
func confluenceVerifyDistinguishesARefusedCredential() async throws {
    // 403 is the answer for a credential that works for Jira and has no Confluence
    // access — which is the sentence FR-6 exists to produce, and not "the network".
    let transport = StubConfluenceTransport(routes: ["spaces": [.status(403)]])

    await #expect(throws: SourceError.invalidCredential) {
        try await client(transport).verify(credential: ConfluenceFixture.credential())
    }
}

@Test("a versions response with no results at all ends the walk")
func confluenceVersionsWithoutResultsEndsTheWalk() async throws {
    // `{"results": …}` absent is not the same shape as `[]`, and a walk that treated
    // "no key" as "keep going" would page to the cap against a server saying nothing.
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [.ok(#"{"_links":{"next":"/wiki/api/v2/pages/12345/versions?cursor=X"}}"#)],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    let versionRequests = await transport.urls.filter { $0.contains("/versions") }
    #expect(versionRequests.count == 1)
    #expect(set.isWindowCapped == false)
    #expect(set.changes.isEmpty)
}
