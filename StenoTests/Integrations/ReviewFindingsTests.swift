import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// The findings Copilot raised on PR #43, each as the test that was missing.
///
/// Kept together rather than scattered because what they have in common is the reason they
/// were missing: five of the seven live at a *seam* — the connector's window against the
/// service's dedup, the log read against the write phase, an export against the next fetch —
/// and every test that existed covered one side of the seam alone.

private let watermark = RefreshFixture.origin.addingTimeInterval(-1800)
private let lastFetched = RefreshFixture.origin.addingTimeInterval(-600)

@MainActor
@Test("an edit to a comment already reported is reported, not swallowed by dedup")
func anEditToAReportedCommentIsReported() async throws {
    // **The finding:** `SourceChange.id` was the bare comment id, and Jira keeps one id
    // across edits — so the service's dedup dropped every edit after the first observation,
    // exactly cancelling the `stamp` rule that treats an edit as news. The change-set test
    // for edits passed because it never went through the dedup.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")

    let original = SourceChange(id: "9001@1000", text: "comment from Ana: first thought")
    try fixture.observed(ref, watermark: watermark, changeIDs: [original.id])

    // The same comment, edited: same source id, new revision.
    let edited = SourceChange(id: "9001@2000", text: "edited comment from Ana: second thought")
    let connector = ScriptedChangeConnector(changes: [edited], watermark: RefreshFixture.origin)

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.changed == 1)
    #expect(outcome.duplicates == 0)
    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body).last
            == "PAY-421: edited comment from Ana: second thought")
}

@MainActor
@Test("a ref whose event log cannot be read is skipped, not fetched")
func anUnreadableLogSkipsTheRef() async throws {
    // **The finding:** a failed log read left the ref with no resume point, which means a
    // `nil` since — and a connector handed `nil` returns what a page holds while `apply`
    // decided first-observation from `row.lastFetchedAt`. So a transient read failure
    // appended recent Jira history to the stand-up as news.
    struct Refused: Error {}
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    try fixture.observed(ref, watermark: watermark, changeIDs: ["c-known"])

    let connector = WindowedConnector(items: [
        .init(id: "c-known", text: "status: To Do → In Progress", stamp: watermark),
        .init(id: "c-other", text: "comment from Ana", stamp: RefreshFixture.origin),
    ])

    let outcome = await fixture.service(
        connectors: [connector], readEvents: { _, _ in throw Refused() }
    ).refresh(taskIDs: [task.id])

    // Not fetched at all, and counted as skipped rather than failed: nothing went wrong
    // with the ref, and the pass simply cannot tell what it has already said.
    #expect(connector.asked.isEmpty)
    #expect(outcome.attempted == 0)
    #expect(outcome.skipped == 1)
    #expect(outcome.failures.isEmpty)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).count == 1)
}

@MainActor
@Test("after an import, a ref with events but no cached timestamp still reports its changes")
func anImportedRefReportsItsChanges() async throws {
    // **The finding:** §10.2 omits `lastFetchedAt` from an export by default while the
    // `externalUpdate` payloads travel — so an imported ref has a resume point and a nil row
    // timestamp. Reading only the column made this look like a first observation, which
    // suppressed the changes *and* recorded their ids, so they were never reported at all.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    // No `fetched:` — exactly what an import leaves behind.
    let ref = try fixture.ref("PAY-421", on: task)
    try fixture.observed(ref, watermark: watermark, changeIDs: ["c-old"])

    let connector = WindowedConnector(items: [
        .init(id: "c-new", text: "status: In Progress → In Review", stamp: RefreshFixture.origin)
    ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.changed == 1)
    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body).last
            == "PAY-421: status: In Progress → In Review")
}

@MainActor
@Test("a ref the log has never mentioned is still a first observation")
func atrulyNewRefIsStillAFirstObservation() async throws {
    // The other direction of the same rule: with no row timestamp *and* no payload, D-169's
    // summary-only event is still what should be written. Without this, the fix above could
    // have been "always report", which passes the test above and breaks D-169.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)

    let connector = WindowedConnector(
        summary: "In Review · assigned to Leo",
        items: [.init(id: "c-new", text: "comment from Ana", stamp: RefreshFixture.origin)])

    _ = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body)
            == ["PAY-421: In Review · assigned to Leo"])
}

@MainActor
@Test("routing many refs reads the credential once, not once per ref")
func routingReadsTheCredentialOnce() async throws {
    // **The finding:** `SourceRegistry.dispatch` asks `isConfigured` for every ref, and this
    // connector answered with a Keychain read — twenty synchronous reads on the main actor
    // for a twenty-ref pass, in a path M4-01 spent a milestone keeping non-blocking.
    let store = InMemoryAtlassianStore(JiraFixture.credential())
    let connector = JiraConnector(
        credentials: store, transport: StubJiraTransport(routes: [:]),
        now: { RefreshFixture.origin })

    for _ in 0..<20 {
        _ = connector.isConfigured
    }
    _ = connector.credentialWarning

    #expect(store.readCount == 1)
}

@Test("the credential memo expires, so a token saved later is still seen")
func thecredentialMemoExpires() {
    // The memo must not become a cache that hides a credential the user has just entered.
    // `testConnection()` bypasses it outright; everything else waits out the TTL.
    let store = InMemoryAtlassianStore(JiraFixture.credential())
    let cache = AtlassianCredentialCache()
    let start = RefreshFixture.origin

    _ = cache.credential(now: start, fresh: false) { try? store.credential() }
    _ = cache.credential(
        now: start.addingTimeInterval(AtlassianCredentialCache.ttl - 1), fresh: false
    ) { try? store.credential() }
    #expect(store.readCount == 1)

    _ = cache.credential(
        now: start.addingTimeInterval(AtlassianCredentialCache.ttl + 1), fresh: false
    ) { try? store.credential() }
    #expect(store.readCount == 2)

    // And `invalidate()` is what M4-04 will call when it writes one.
    cache.invalidate()
    _ = cache.credential(
        now: start.addingTimeInterval(AtlassianCredentialCache.ttl + 1), fresh: false
    ) { try? store.credential() }
    #expect(store.readCount == 3)
}

@Test("FR-6's connection test never answers from the memo")
func theConnectionTestNeverUsesTheMemo() async throws {
    let store = InMemoryAtlassianStore(JiraFixture.credential())
    let connector = JiraConnector(
        credentials: store,
        transport: StubJiraTransport(routes: ["myself": [.ok(JiraFixture.currentUser)]]),
        now: { RefreshFixture.origin })

    _ = connector.isConfigured
    try await connector.testConnection()

    // Two reads, because the button exists to say whether what is stored *now* works.
    #expect(store.readCount == 2)
}

/// A connector that answers with exactly the changes it was given.
///
/// `WindowedConnector` filters by timestamp, which is what most of these tests want; this one
/// is for the dedup seam, where the subject is the *id* and a timestamp would only get in the
/// way.
private final class ScriptedChangeConnector: SourceConnector, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted"
    let isConfigured = true

    private let changes: [SourceChange]
    private let watermark: Date?

    init(changes: [SourceChange], watermark: Date?) {
        self.changes = changes
        self.watermark = watermark
    }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool { ref.kind == .jiraIssue }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        SourceUpdate(
            summary: "In Review", changes: changes, url: nil, fetchedAt: RefreshFixture.origin,
            watermark: watermark)
    }

    func testConnection() async throws {}
}
