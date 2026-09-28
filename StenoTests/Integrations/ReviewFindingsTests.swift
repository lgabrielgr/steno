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

@MainActor
@Test("a link removed and re-added with nothing else happening is missed")
func aremovedAndReaddedLinkIsMissed() async throws {
    // **A limitation pinned, not a bug hidden.** The recorded link set is only written when an
    // event is written, and D-187 deliberately reports nothing for a link that disappears — so
    // a remove-then-re-add with no other reportable change in between leaves the old set
    // standing and the re-addition reads as the status quo.
    //
    // Closing it needs an event D-187 declined ("unlinked acme/api#421" is Jira's bookkeeping,
    // not the user's work) or row state D-184 declined. Raised by Copilot in review round 3 of
    // PR #43. If a later task decides the trade is wrong, this test is where that decision gets
    // made — it should fail when the behaviour changes.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    try fixture.observed(ref, watermark: watermark, presentIDs: ["L1"])

    let link = SourceChange(id: "L1", text: "linked acme/api#421")

    // Pass one: the link is gone. Nothing is reported, so nothing records the smaller set.
    let removed = await fixture.service(connectors: [WindowedConnector(present: [])])
        .refresh(taskIDs: [task.id])
    #expect(removed.changed == 0)

    // Pass two: it is back, and the log still says it was present all along.
    let readded = await fixture.service(
        connectors: [WindowedConnector(present: [link])], nowOffset: 60
    ).refresh(taskIDs: [task.id])

    #expect(readded.changed == 0)
    #expect(readded.duplicates == 1)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).count == 1)
}

@Test("a credential write tells the memo to forget what it read")
func acredentialWriteInvalidatesTheMemo() {
    // **The finding was a comment promising a method nobody could call.** D-198's memo said
    // M4-04 "should call `invalidate()`", and the cache is a private property on a struct — so a
    // credential saved while the app ran would have left routing on a memoized `nil` for half a
    // minute. Raised by Copilot in review round 4 of PR #43.
    //
    // A private `NotificationCenter` rather than `.default`: this test must not be affected by,
    // or affect, anything else in the bundle.
    let notifications = NotificationCenter()
    let store = InMemoryAtlassianStore(JiraFixture.credential())
    let cache = AtlassianCredentialCache(notifications: notifications)
    let start = RefreshFixture.origin

    _ = cache.credential(now: start, fresh: false) { try? store.credential() }
    _ = cache.credential(now: start, fresh: false) { try? store.credential() }
    #expect(store.readCount == 1)

    notifications.post(name: .stenoCredentialsDidChange, object: nil)

    // Same instant, so only the notification can explain the second read.
    _ = cache.credential(now: start, fresh: false) { try? store.credential() }
    #expect(store.readCount == 2)
}

@Test("an unrelated notification does not drop the memo")
func anUnrelatedNotificationLeavesTheMemoAlone() {
    // The other direction: an observer registered for the wrong name, or for every name, would
    // pass the test above and put the per-ref Keychain read back.
    let notifications = NotificationCenter()
    let store = InMemoryAtlassianStore(JiraFixture.credential())
    let cache = AtlassianCredentialCache(notifications: notifications)
    let start = RefreshFixture.origin

    _ = cache.credential(now: start, fresh: false) { try? store.credential() }
    notifications.post(name: .stenoDidWrite, object: nil)
    _ = cache.credential(now: start, fresh: false) { try? store.credential() }

    #expect(store.readCount == 1)
}

@Test("the memo unregisters from the center it registered on")
func thememoUnregistersFromItsOwnCenter() {
    // **The finding:** the observer was registered on the injected center and removed from
    // `.default`, so every cache built with a center — which is every one in this bundle — left
    // its registration behind. Raised by Copilot in review round 5 of PR #43.
    //
    // Foundation exposes no observer count, so the center itself does the reporting: it is an
    // `open` class, and overriding `removeObserver` turns "verified by inspection" into an
    // assertion. Mutation: remove from `NotificationCenter.default` in `deinit` and this goes red.
    let center = RecordingNotificationCenter()

    do {
        let cache = AtlassianCredentialCache(notifications: center)
        _ = cache.credential(now: RefreshFixture.origin, fresh: false) { nil }
        #expect(center.removals == 0)
    }

    #expect(center.removals == 1)
}

/// A `NotificationCenter` that counts how many observers were removed from it.
private final class RecordingNotificationCenter: NotificationCenter {
    private let lock = NSLock()
    private var removed = 0

    var removals: Int { lock.withLock { removed } }

    override func removeObserver(_ observer: Any) {
        lock.withLock { removed += 1 }
        super.removeObserver(observer)
    }
}

@MainActor
@Test("a capped pass lowers the next pass's window, across two passes")
func acappedPassLowersTheNextWindow() async throws {
    // **The regression the cap tests were missing: they all inspected one fetch.** A capped walk
    // lowers its watermark deliberately, and `ResumePoint` resolved several payloads with `max` —
    // so the previous, higher watermark won on the very next pass and the band below the cap stayed
    // unreachable. The hold-back was inert for three review rounds and no single-fetch test could
    // have shown it. Raised by Copilot in review round 6 of PR #43.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")

    // The log already holds a recent, *un*capped watermark — the value that used to win.
    let recent = RefreshFixture.origin.addingTimeInterval(-600)
    try fixture.observed(ref, watermark: recent)

    // Pass one hits its cap and reports a much older floor, with something to say so an event is
    // written and the floor is recorded.
    let floor = RefreshFixture.origin.addingTimeInterval(-7200)
    let capped = WindowedConnector(
        items: [.init(id: "c-new", text: "comment from Ana", stamp: RefreshFixture.origin)],
        cappedFloor: floor)
    let first = await fixture.service(connectors: [capped]).refresh(taskIDs: [task.id])
    #expect(first.changed == 1)
    #expect(capped.asked == [RefreshFixture.since(after: recent)])

    // Pass two must resume from the floor, not from the recent watermark still sitting in the log.
    let second = WindowedConnector(items: [])
    _ = await fixture.service(connectors: [second], nowOffset: 60).refresh(taskIDs: [task.id])

    #expect(second.asked == [RefreshFixture.since(after: floor)])
    #expect(second.asked != [RefreshFixture.since(after: recent)])
}
