import Foundation
import Testing

@testable import StenoKit

/// D-197: the harness that answers "have these fixtures ever met the real API?".

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func routes() -> [String: [StubJiraTransport.Answer]] {
    [
        "issue": [.ok(JiraFixture.issue())],
        "changelog@0": [
            .ok(
                JiraFixture.changelog(
                    [
                        JiraFixture.Entry.status(
                            id: "10001", created: "2026-09-25T18:04:11.000+0000",
                            from: "In Progress", to: "In Review")
                    ], total: 1, isLast: true))
        ],
        "comment@0": [.ok(JiraFixture.comments([], total: 0))],
        "remotelink": [.ok(JiraFixture.remoteLinks([JiraFixture.Link()]))],
    ]
}

/// One harness run: what it exited with, what it printed, and what it sent.
private struct HarnessRun {
    let code: Int32
    let output: [String]
    let transport: StubJiraTransport
}

private func run(
    credential: AtlassianCredential? = JiraFixture.credential(),
    readError: (any Error)? = nil,
    routes scripted: [String: [StubJiraTransport.Answer]]? = nil
) async -> HarnessRun {
    let transport = StubJiraTransport(routes: scripted ?? routes())
    let collected = Collector()
    let code = await JiraSelftest.run(
        issueKey: JiraFixture.key,
        credentials: InMemoryAtlassianStore(credential, readError: readError),
        transport: transport, now: { now }, out: { collected.append($0) })
    return HarnessRun(code: code, output: collected.lines, transport: transport)
}

/// Collects printed lines from a `@Sendable` closure.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var lines: [String] { lock.withLock { collected } }

    func append(_ line: String) {
        lock.withLock { collected.append(line) }
    }
}

@Test("it reports what the connector would say, and that every request was a GET")
func theHarnessReportsAndPasses() async {
    let result = await run()

    #expect(result.code == 0)
    #expect(result.output.contains { $0.contains("summary   Add the migration plan — In Review") })
    #expect(result.output.contains { $0.contains("change    status: In Progress → In Review") })
    #expect(result.output.contains { $0.contains("present   linked acme/api#421") })
    #expect(result.output.contains { $0.contains("requests  4 — GET") })
    #expect(result.output.contains { $0.contains("PASS") })
}

@Test("it asks for a real window, so a run has something to show")
func theHarnessAsksForARealWindow() async {
    let result = await run()

    // `nil` would establish an anchor and report nothing (D-188) — correct for a first
    // observation and useless for a human checking whether transitions come through.
    let urls = await result.transport.urls
    #expect(urls.count == 4)
    #expect(result.output.contains { $0.contains("changes   none in the last 30 days") } == false)
}

@Test("no stored credential is an instruction, not a stack trace")
func nocredentialIsAnInstruction() async {
    let result = await run(credential: nil)

    #expect(result.code == 1)
    #expect(result.output.contains { $0.contains("Run `make atlassian-login`") })
    // And nothing was sent: there was nothing to send it with.
    #expect(await result.transport.received.isEmpty)
}

@Test("D19: a stored site that is not Atlassian Cloud fails before the network")
func abadSiteFailsBeforeTheNetwork() async {
    let result = await run(
        credential: AtlassianCredential(site: "evil.com", email: "leo@example.com", apiToken: "t"))

    #expect(result.code == 1)
    #expect(result.output.contains { $0.contains("not an *.atlassian.net host") })
    #expect(await result.transport.received.isEmpty)
}

@Test("a Keychain that refuses is reported as a Keychain problem")
func akeychainFailureIsReported() async {
    struct Refused: Error {}
    let result = await run(readError: Refused())

    #expect(result.code == 1)
    #expect(result.output.contains { $0.contains("the Keychain refused") })
}

@Test("§5.2: a 401 prints the expiry sentence, not a network one")
func afourOhOnePrintsTheExpirySentence() async {
    var scripted = routes()
    scripted["issue"] = [.status(401)]
    let result = await run(routes: scripted)

    #expect(result.code == 1)
    // `SourceError` carries no free-form string by construction (D-165), so printing its
    // own sentence is safe — and the sentence is the one §5.2 requires.
    #expect(result.output.contains { $0.contains("expired or was revoked") })
    #expect(result.output.contains { $0.contains("credentialExpired") })
}

@Test("§8: nothing it prints carries the token")
func theHarnessNeverPrintsTheToken() async {
    let result = await run()
    #expect(result.output.contains { $0.contains("token-value") } == false)
}

@Test("a failing fetch is a failure, not a pass with no data")
func afailingFetchFails() async {
    var scripted = routes()
    scripted["remotelink"] = [.fail(URLError(.notConnectedToInternet))]
    let result = await run(routes: scripted)

    #expect(result.code == 1)
    #expect(result.output.contains { $0.contains("PASS") } == false)
}
