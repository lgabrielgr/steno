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

@Test("D-211: the current editor is named even when the window is full of other editors")
func confluenceCurrentEditorSurvivesTheLookupCap() async throws {
    // §5.3 asks for the last editor by name — it is the one attribution the section
    // actually specifies, and the summary is built from it. Appended after the version
    // authors, it was the first name dropped once ten other editors filled the cap.
    let currentEditor = "557058:current"
    let editors = (0..<12).map { "557058:editor-\($0)" }

    var users: [String: Answer] = [
        currentEditor: .ok(ConfluenceFixture.user(displayName: "Priya Anand"))
    ]
    for id in editors {
        users[id] = .ok(ConfluenceFixture.user(displayName: "Editor \(id.suffix(1))"))
    }

    let transport = StubConfluenceTransport(
        routes: [
            "page": [
                .ok(
                    ConfluenceFixture.page(
                        currentVersion: ConfluenceFixture.version(
                            number: 101, createdAt: ConfluenceFixture.inWindow,
                            authorID: currentEditor)))
            ],
            "versions": [
                .ok(
                    ConfluenceFixture.versions(
                        editors.enumerated().map { index, id in
                            ConfluenceFixture.version(
                                number: 100 - index, createdAt: ConfluenceFixture.inWindow,
                                authorID: id)
                        }))
            ],
        ], users: users)

    let set = try await changeSet(transport)

    #expect(set.summary == "Payments Migration Plan — v101, edited by Priya Anand")
    // The cap still bites — it just no longer bites the one name §5.3 requires.
    let counts = await transport.callCounts
    #expect(counts["user"] == ConfluenceClient.maxNameLookups)
}

@Test("D-217 revised: a 404 from the verify endpoint is a wrong site, not a missing page")
func theConfluenceConnectionTestReportsAWrongSite() async throws {
    // `JiraClient.verify`'s finding, on the other API. The v2 spaces endpoint answers
    // 200 or 401 on a site serving Confluence, so a 404 means this host is not serving
    // it — a mistyped site, or a site without Confluence. Mutation: drop
    // `notFound: .siteNotFound` from `verify`. Red.
    let wrongSite = StubConfluenceTransport(routes: ["spaces": [.status(404)]])
    await #expect(throws: SourceError.siteNotFound) {
        try await ConfluenceClient(transport: wrongSite)
            .verify(credential: JiraFixture.credential())
    }
}
