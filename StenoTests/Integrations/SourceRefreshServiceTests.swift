import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §5.5's pass: what it fetches, what it writes, and what it refuses to write.

@MainActor
@Test("§3.4: a successful fetch caches the summary and stamps the app's clock")
func aFetchWritesTheCache() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .success(.stub(summary: "In Review, assigned to Dana"))])

    let outcome = await fixture.service(connectors: [connector], nowOffset: 60)
        .refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 1)
    #expect(outcome.cached == 1)
    #expect(outcome.failures.isEmpty)

    let stored = try #require(try fixture.refInStore("PAY-421"))
    #expect(stored.cachedSummary == "In Review, assigned to Dana")
    // D-171: our clock, not the connector's `fetchedAt` — which `.stub` sets to
    // 1_700_000_000, the fixture's origin, so a service reading the wrong one
    // lands on a different value than this.
    #expect(stored.lastFetchedAt == RefreshFixture.origin.addingTimeInterval(60))
}

@MainActor
@Test("D-169: the first observation appends an externalUpdate event")
func theFirstObservationAppendsAnEvent() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .success(.stub(summary: "In Review"))])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.changed == 1)
    let events = try fixture.eventsInStore(kind: .externalUpdate)
    #expect(events.map(\.body) == ["PAY-421: In Review"])
    #expect(events.first?.taskID == task.id)
    let payload = try #require(ExternalUpdatePayload.decoded(from: events.first?.payload))
    #expect(payload.identifier == "PAY-421")
    #expect(payload.kind == .jiraIssue)
}

@MainActor
@Test("a later fetch that finds nothing writes no event but still advances the cache")
func anUnchangedFetchIsSilentButNotIdle() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    // Already observed an hour before the pass, so this is not a first fetch.
    try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-3600),
        summary: "In Review")
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .success(.stub(summary: "In Review", changes: []))])

    let outcome = await fixture.service(connectors: [connector], nowOffset: 60)
        .refresh(taskIDs: [task.id])

    // **Both directions.** "No event was appended" passes trivially if the fetch
    // never happened, so the same test asserts the cache moved forward.
    #expect(try fixture.eventsInStore(kind: .externalUpdate).isEmpty)
    #expect(outcome.changed == 0)
    #expect(outcome.cached == 1)
    #expect(
        try fixture.refInStore("PAY-421")?.lastFetchedAt
            == RefreshFixture.origin.addingTimeInterval(60))
}

@MainActor
@Test("§3.3: a change found on a later fetch appends the change, not the summary")
func aChangeAppendsTheChange() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-3600),
        summary: "In Progress")
    let connector = StubSourceConnector(
        scripts: [
            "PAY-421": .success(
                .stub(summary: "In Review", changes: ["moved to In Review", "2 new comments"]))
        ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.changed == 1)
    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body)
            == ["PAY-421: moved to In Review; 2 new comments"])
}

@MainActor
@Test("the connector is asked for changes since the row's previous observation")
func sinceIsThePreviousObservation() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let previously = RefreshFixture.origin.addingTimeInterval(-3600)
    try fixture.ref("PAY-421", on: task, fetched: previously, summary: "In Progress")
    try fixture.ref("PAY-9", on: task)
    let connector = StubSourceConnector()

    _ = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    // Refresh policy lives in the service, not the connector (D-164): the `since`
    // it was handed is the only externally visible evidence of that.
    //
    // `#require` on each, rather than a dictionary lookup: a `[String: Date?]`
    // subscript yields `Date??`, so `asked["PAY-9"] == nil` is true both when the
    // ref was fetched with no `since` *and* when it was never fetched at all —
    // the one-directional blindness that makes a test unable to fail.
    let seen = try #require(connector.asked.first { $0.identifier == "PAY-421" })
    #expect(seen.since == previously)
    let unseen = try #require(connector.asked.first { $0.identifier == "PAY-9" })
    #expect(unseen.since == nil)
}

@MainActor
@Test("D-173: a refresh never stamps task.modifiedAt")
func aRefreshDoesNotTouchModifiedAt() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let before = task.modifiedAt
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .success(.stub(changes: ["reopened"]))])

    let outcome = await fixture.service(connectors: [connector], nowOffset: 600)
        .refresh(taskIDs: [task.id])

    // Stamping it would let a task whose ticket was merely looked at outrank, in
    // §10.1's "later modifiedAt wins" merge, a task whose title was genuinely
    // edited on another Mac — and the launch pass runs on every launch, so this
    // would be the common case, not a rare one.
    #expect(outcome.cached == 1)
    #expect(try fixture.taskInStore("ship payments")?.modifiedAt == before)
}

@MainActor
@Test("D-172: one .stenoDidWrite per writing pass, and none for a pass that wrote nothing")
func theNotificationIsPostedOncePerWritingPass() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    try fixture.ref("PAY-9", on: task)
    let counter = WriteCounter()

    _ = await fixture.service(connectors: [StubSourceConnector()]).refresh(taskIDs: [task.id])
    #expect(counter.posts == 1)

    // A pass with no configured connector writes nothing and must not make three
    // surfaces refetch.
    _ = await fixture.service(connectors: []).refresh(taskIDs: [task.id])
    #expect(counter.posts == 1)

    // **And a pass that fetched and failed.** The case above returns before the
    // write phase is reached at all, so on its own it cannot see a post moved out
    // from under `didWrite` — a mutation that posted unconditionally survived it.
    // This one attempts two fetches, writes nothing, and must still be silent.
    let failed = await fixture.service(connectors: [AlwaysFailingConnector()])
        .refresh(taskIDs: [task.id])
    #expect(failed.attempted == 2)
    #expect(!failed.didWrite)
    #expect(counter.posts == 1)
}

@MainActor
@Test("D-172: a failed save rolls back, and a later successful pass finds no phantom rows")
func aFailedSaveLeavesNothingBehind() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let failing = FailingSave()
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .success(.stub(summary: "In Review"))])

    let refused = await fixture.service(connectors: [connector], save: failing.save)
        .refresh(taskIDs: [task.id])

    #expect(refused.saveFailed)
    #expect(refused.cached == 0)
    #expect(refused.changed == 0)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).isEmpty)
    #expect(try fixture.refInStore("PAY-421")?.cachedSummary == nil)

    // **The later save is what makes the assertion above falsifiable.** Without
    // the rollback the refused event sits in the context and the *next* save
    // commits it — so "the store is empty" proves nothing until something else
    // has successfully written.
    failing.shouldFail = false
    let second = await fixture.service(
        connectors: [
            StubSourceConnector(scripts: ["PAY-421": .success(.stub(summary: "Done"))])
        ],
        nowOffset: 120, save: failing.save
    ).refresh(taskIDs: [task.id])

    #expect(second.changed == 1)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).map(\.body) == ["PAY-421: Done"])
}

@MainActor
@Test("§5.5: the launch pass skips done and archived tasks")
func theLaunchPassSkipsFinishedWork() async throws {
    let fixture = try RefreshFixture()
    let live = try fixture.task("ship payments", status: .inProgress)
    let done = try fixture.task("shipped last week", status: .done)
    let archived = try fixture.task("abandoned", status: .blocked, archived: true)
    try fixture.ref("PAY-LIVE", on: live)
    try fixture.ref("PAY-DONE", on: done)
    try fixture.ref("PAY-ARCHIVED", on: archived)
    let connector = StubSourceConnector()

    let outcome = await fixture.service(connectors: [connector]).refreshDue()

    // **The live ref must be fetched**, so this cannot pass by fetching nothing —
    // which is what an over-broad filter, or a broken candidate query, would do.
    #expect(connector.asked.map(\.identifier) == ["PAY-LIVE"])
    #expect(outcome.attempted == 1)
}

@MainActor
@Test("§5.5: the launch pass skips refs fetched within the last 30 minutes")
func theLaunchPassRespectsTheStalenessWindow() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref(
        "PAY-STALE", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-3600),
        summary: "old")
    try fixture.ref(
        "PAY-FRESH", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-60),
        summary: "new")
    let connector = StubSourceConnector()

    _ = await fixture.service(connectors: [connector]).refreshDue()

    #expect(connector.asked.map(\.identifier) == ["PAY-STALE"])
}

@MainActor
@Test("D-166: a ref no connector claims is not attempted and not a failure")
func unhandledRefsAreSilent() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("https://example.com/page", on: task, kind: .url)
    let connector = StubSourceConnector(kinds: [.jiraIssue])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 0)
    #expect(outcome.failures.isEmpty)
    #expect(outcome.notConfigured == 0)
    #expect(connector.asked.isEmpty)
}

@MainActor
@Test("a claimant with no credential is counted, not fetched")
func unconfiguredClaimantsAreCounted() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let connector = StubSourceConnector(isConfigured: false)

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.notConfigured == 1)
    #expect(outcome.attempted == 0)
    #expect(connector.asked.isEmpty)
}

@MainActor
@Test("D-170: two rows sharing one identifier are each fetched with their own since")
func rowsSharingAnIdentifierAreNotCoalesced() async throws {
    let fixture = try RefreshFixture()
    let first = try fixture.task("ship payments")
    let second = try fixture.task("write the runbook")
    let earlier = RefreshFixture.origin.addingTimeInterval(-7200)
    try fixture.ref("PAY-421", on: first, fetched: earlier, summary: "In Progress")
    try fixture.ref("PAY-421", on: second)
    let connector = StubSourceConnector()

    _ = await fixture.service(connectors: [connector])
        .refresh(taskIDs: [first.id, second.id])

    // Coalescing would need one `since` for both rows, and the only safe choice
    // — the earlier — hands the other row changes it has already reported,
    // producing a duplicate bullet in a stand-up read aloud.
    #expect(connector.asked.count == 2)
    #expect(Set(connector.asked.map(\.since)) == Set([earlier, nil]))
}

@MainActor
@Test("refreshing no tasks is idle, not an error")
func anEmptyWindowIsIdle() async throws {
    let fixture = try RefreshFixture()

    let outcome = await fixture.service(connectors: [StubSourceConnector()]).refresh(taskIDs: [])

    #expect(outcome == .idle)
    #expect(!outcome.readFailed)
}
