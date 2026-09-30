import Foundation
import Testing

@testable import StenoKit

/// D-197: the harness that answers "have these Confluence fixtures ever met the real
/// API?".

private let selftestNow = Date(timeIntervalSince1970: 1_700_000_000)

private func selftestRoutes() -> [String: [StubConfluenceTransport.Answer]] {
    [
        "page": [.ok(ConfluenceFixture.page())],
        "versions": [
            .ok(
                ConfluenceFixture.versions([
                    ConfluenceFixture.version(
                        number: 9, createdAt: ConfluenceFixture.inWindow, message: "final pass")
                ]))
        ],
    ]
}

private let selftestUsers: [String: StubConfluenceTransport.Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez"))
]

/// One harness run: what it exited with, what it printed, and what it sent.
private struct ConfluenceHarnessRun {
    let code: Int32
    let output: [String]
    let transport: StubConfluenceTransport

    var text: String { output.joined(separator: "\n") }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var lines: [String] { lock.withLock { collected } }

    func append(_ line: String) {
        lock.withLock { collected.append(line) }
    }
}

private func runHarness(
    pageID: String = ConfluenceFixture.pageID,
    credential: AtlassianCredential? = ConfluenceFixture.credential(),
    readError: (any Error)? = nil,
    routes: [String: [StubConfluenceTransport.Answer]]? = nil
) async -> ConfluenceHarnessRun {
    let transport = StubConfluenceTransport(
        routes: routes ?? selftestRoutes(), users: selftestUsers)
    let collected = LineCollector()
    let code = await ConfluenceSelftest.run(
        pageID: pageID,
        credentials: InMemoryAtlassianStore(credential, readError: readError),
        transport: transport, now: { selftestNow }, out: { collected.append($0) })
    return ConfluenceHarnessRun(code: code, output: collected.lines, transport: transport)
}

@Test("it reports what the connector would say, and that every Confluence request was a GET")
func theConfluenceHarnessReportsAndPasses() async {
    let run = await runHarness()

    #expect(run.code == 0)
    #expect(run.text.contains("Payments Migration Plan — v9, edited by Leo Gutierrez"))
    #expect(run.text.contains("v9 by Leo Gutierrez: final pass"))
    #expect(run.text.contains("read-only"))

    let methods = await run.transport.methods
    #expect(methods.allSatisfy { $0 == .get })
}

@Test("it asks a 30-day window, because a first observation would print nothing")
func theConfluenceHarnessAsksAWindow() async {
    // `nil` means "establish an anchor and report nothing" (D-188) — correct behaviour
    // and useless output for a human checking whether the delta comes through.
    let run = await runHarness()

    #expect(run.text.contains("no new versions") == false)
    #expect(ConfluenceSelftest.window == 30 * 24 * 60 * 60)
}

@Test("a capped walk says so, so a short delta is not read as the whole truth")
func theConfluenceHarnessReportsACappedWalk() async {
    let pages = (0..<12).map { index in
        StubConfluenceTransport.Answer.ok(
            ConfluenceFixture.versions(
                [
                    ConfluenceFixture.version(
                        number: 100 - index, createdAt: ConfluenceFixture.inWindow)
                ],
                next: ConfluenceFixture.next(cursor: "PAGE\(index)")))
    }
    let run = await runHarness(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": pages])

    #expect(run.code == 0)
    #expect(run.text.contains("the version walk ended early"))
    // Not "the page cap": the same flag is true for a cursor that did not advance and
    // for a `next` with no usable cursor, so a harness naming one cause would mislead
    // two thirds of the time (D-213).
    #expect(run.text.contains("page cap") == false)
}

@Test("with no credential it says what to run, and verifies nothing")
func theConfluenceHarnessWithoutACredential() async {
    let run = await runHarness(credential: nil)

    #expect(run.code == 1)
    #expect(run.text.contains("make atlassian-login"))
    let received = await run.transport.received
    #expect(received.isEmpty)
}

@Test("a non-Cloud site is refused before a request is built (D19)")
func theConfluenceHarnessRefusesANonCloudSite() async {
    let run = await runHarness(
        credential: AtlassianCredential(
            site: "wiki.corp.net", email: "leo@example.com", apiToken: "t"))

    #expect(run.code == 1)
    #expect(run.text.contains("atlassian.net"))
    let received = await run.transport.received
    #expect(received.isEmpty)
}

@Test("a page id that is not digits is refused locally, not spent on a 400")
func theConfluenceHarnessRefusesABadPageID() async {
    let run = await runHarness(pageID: "ENG/Payments")

    #expect(run.code == 1)
    #expect(run.text.contains("is not a page id"))
    let received = await run.transport.received
    #expect(received.isEmpty)
}

@Test("a failure prints the error's own sentence, and never the token")
func theConfluenceHarnessPrintsAFailure() async {
    let run = await runHarness(routes: ["page": [.status(401)]])

    #expect(run.code == 1)
    #expect(run.text.contains("token-value") == false)
    #expect(run.text.lowercased().contains("expired"))
}

@Test("a Keychain that refuses is reported as such, not as a missing credential")
func theConfluenceHarnessReportsAKeychainFailure() async {
    let run = await runHarness(
        credential: nil, readError: KeychainError.unexpected(-25300))

    #expect(run.code == 1)
    #expect(run.text.contains("Keychain refused"))
}

@Test(
    "D5: the read-only rule the harnesses assert, asserted itself",
    arguments: [
        (["GET", "GET", "GET"], true),
        (["GET", "POST"], false),
        (["POST"], false),
        ([], true),
    ])
func countingTransportReadOnlyRule(methods: [String], expected: Bool) {
    // The situation this guards — a live run that built a write — cannot be staged in a
    // test, because `ReadOnlyTransport` traps before a non-GET can be recorded. So the
    // rule is asserted directly, exactly as `ReadOnlyTransport.isAllowed` is, and the
    // one-line call site in each harness is what a reviewer reads.
    //
    // An empty list is `true` on purpose: "nothing was sent" is not a D5 violation, and
    // the harnesses print the request count beside this verdict so a silent zero is
    // visible to the human running it.
    #expect(CountingTransport.isReadOnly(methods) == expected)
}

@Test("the harness's fallback URL is built from the validated site, not the typed one")
func theConfluenceHarnessBuildsAWellFormedFallbackURL() async {
    // `AtlassianCredential.site` keeps what the user typed and accepts a pasted URL with
    // a path, so interpolating it produced `https://https://acme.atlassian.net/…`. The
    // harness prints that as the page's URL whenever `_links.webui` is absent, which is
    // exactly when a human is squinting at the output to decide whether the connector
    // works. Raised by Copilot in review of PR #44.
    let pasted = AtlassianCredential(
        site: "https://acme.atlassian.net/wiki/spaces/ENG/overview",
        email: "leo@example.com", apiToken: "token-value")
    let run = await runHarness(
        credential: pasted,
        routes: [
            "page": [.ok(ConfluenceFixture.page(webui: nil))],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ])

    #expect(run.code == 0)
    #expect(run.text.contains("https://https://") == false)
    #expect(run.text.contains("url       https://acme.atlassian.net/wiki/pages/12345"))
}
