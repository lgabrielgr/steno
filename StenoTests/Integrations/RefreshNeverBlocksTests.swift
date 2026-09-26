import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// M4-01's headline acceptance criteria (§5.5, §7.4).
///
/// Each test here discharges a criterion the task file states outright, and each
/// names the mutation it was verified against.

@MainActor
@Test("§5.5: a connector that always throws does not block report generation")
func aFailingIntegrationNeverBlocksAReport() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    // Observed yesterday, so there is cached state to degrade to — which is the
    // situation §7.4 is about.
    try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-86400),
        summary: "In Review")
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin.addingTimeInterval(-3600),
            kind: .note, body: "found the race in the retry handler"))
    try fixture.context.save()

    // The pass fails in full, and returns rather than throwing: `refresh` has no
    // `throws`, so this call site has no error to handle and none to forget.
    let outcome = await fixture.service(connectors: [AlwaysFailingConnector()])
        .refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 1)
    #expect(outcome.failures.map(\.error) == [.network])
    #expect(outcome.cached == 0)

    // And the report still generates, from the log and the cache the failed pass
    // left untouched. Mutation: make the task group's `try` propagate — the
    // service stops compiling as non-throwing, which is the point.
    fixture.project.lastStandupAt = RefreshFixture.origin.addingTimeInterval(-86400)
    try fixture.context.save()
    let window = try ReportGatherer(
        context: fixture.context, now: { RefreshFixture.origin }
    ).gather(for: fixture.project)

    #expect(window.tasks.count == 1)
    #expect(window.tasks.first?.events.map(\.body) == ["found the race in the retry handler"])
    #expect(try fixture.refInStore("PAY-421")?.cachedSummary == "In Review")
}

@MainActor
@Test("§5.5: one connector failing does not stop the others")
func oneFailureDoesNotStopTheRest() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    try fixture.ref("DOCS-7", on: task, kind: .confluencePage)

    let failing = AlwaysFailingConnector(error: .invalidCredential, kinds: [.jiraIssue])
    let working = StubSourceConnector(
        id: "confluence", displayName: "Confluence", kinds: [.confluencePage],
        scripts: ["DOCS-7": .success(.stub(summary: "Runbook v4"))])

    // The failing connector is registered first, so an implementation that
    // abandoned the pass on the first failure would never reach the second ref.
    let outcome = await fixture.service(connectors: [failing, working])
        .refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 2)
    #expect(outcome.failures.map(\.error) == [.invalidCredential])
    #expect(outcome.failures.map(\.displayName) == ["Always Failing"])

    // Both halves asserted: the survivor's cache *and* its event. Mutation:
    // `break` on the first failure in the apply loop.
    #expect(outcome.cached == 1)
    #expect(try fixture.refInStore("DOCS-7")?.cachedSummary == "Runbook v4")
    #expect(try fixture.eventsInStore(kind: .externalUpdate).map(\.body) == ["DOCS-7: Runbook v4"])
    #expect(try fixture.refInStore("PAY-421")?.cachedSummary == nil)
}

@MainActor
@Test("§5.2: with nothing configured, the report still generates and is labeled stale")
func anOfflineReportIsLabeledStale() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let twoDaysAgo = RefreshFixture.origin.addingTimeInterval(-2 * 86400)
    try fixture.ref("PAY-421", on: task, fetched: twoDaysAgo, summary: "In Review")

    let outcome = await fixture.service(connectors: [AlwaysFailingConnector()])
        .refresh(taskIDs: [task.id])

    // The outcome carries what the label is built from. Mutation: drop the
    // `oldestFetch` plumbing and the notice goes nil.
    #expect(outcome.oldestFetch == twoDaysAgo)
    #expect(
        SourceNotice.text(for: outcome, now: RefreshFixture.origin)
            == "Couldn't reach Always Failing — using 2 days old data.")
}

@MainActor
@Test("D-178: one hanging fetch times out without taking the pass with it")
func aHangingFetchIsBounded() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-HANG", on: task)
    try fixture.ref("PAY-OK", on: task)
    let connector = StubSourceConnector(
        scripts: [
            "PAY-HANG": .hang,
            "PAY-OK": .success(.stub(summary: "In Review")),
        ])

    let outcome = await fixture.service(
        connectors: [connector], perFetch: .milliseconds(80), budget: .seconds(5)
    ).refresh(taskIDs: [task.id])

    #expect(outcome.failures.map(\.error) == [.timedOut])
    // The sibling still landed: a per-fetch deadline that took the group down
    // would lose it.
    #expect(outcome.cached == 1)
    #expect(try fixture.refInStore("PAY-OK")?.cachedSummary == "In Review")
}

@MainActor
@Test("D-178: the pass budget keeps completed fetches and counts the rest as skipped")
func theBudgetKeepsWhatItAlreadyHas() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    // More refs than `maxInFlight`, so some are still unstarted when the budget
    // expires — which is the case a deadline wrapped around the whole group would
    // discard entirely.
    for index in 0..<8 {
        try fixture.ref("PAY-\(index)", on: task, kind: .jiraIssue)
    }
    let connector = StubSourceConnector(fallback: .hang)

    let outcome = await fixture.service(
        connectors: [connector], perFetch: .seconds(30), budget: .milliseconds(120)
    ).refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 8)
    #expect(outcome.skipped > 0)
    // Skipped is not failed: nothing went wrong with a ref the clock ran out on.
    #expect(outcome.failures.isEmpty)
    #expect(outcome.skipped + outcome.cached + outcome.failures.count == outcome.attempted)
}

@MainActor
@Test("a connector that breaks the error contract degrades rather than escaping")
func aBrokenContractDegrades() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)

    let outcome = await fixture.service(connectors: [ContractBreakingConnector()])
        .refresh(taskIDs: [task.id])

    // `SourceConnector`'s contract is `SourceError` and nothing else. Without the
    // catch-all, a leaked `URLError` would escape a pass that cannot throw.
    #expect(outcome.failures.map(\.error) == [.invalidResponse])
    #expect(outcome.cached == 0)
}

@MainActor
@Test("D-163: a pass that attempted nothing is distinguishable from one that failed")
func nothingAttemptedIsNotTheSameAsEverythingFailed() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)

    let noConnector = await fixture.service(connectors: []).refresh(taskIDs: [task.id])
    let allFailed = await fixture.service(connectors: [AlwaysFailingConnector()])
        .refresh(taskIDs: [task.id])

    // Both have an empty `failures` *or* an empty write count; the counts are
    // what tell them apart, which is why the outcome carries `attempted`.
    #expect(noConnector.attempted == 0)
    #expect(noConnector.failures.isEmpty)
    #expect(allFailed.attempted == 1)
    #expect(allFailed.failures.count == 1)
}

@MainActor
@Test("a pass whose fetches all succeed returns at once, not at the end of its budget")
func aSuccessfulPassDoesNotWaitOutTheBudget() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-1", on: task)
    try fixture.ref("PAY-2", on: task)

    // **A minute of budget against two instant fetches.** The budget sentinel is a
    // child of the same task group, so before this was fixed the loop could not end
    // until the sleeper woke — every successful Prepare refresh sat out the whole
    // budget before the polish could start. The millisecond budgets the other tests
    // inject hid it as nothing worse than a slightly slow suite (Copilot, PR #42).
    let started = ContinuousClock.now
    let outcome = await fixture.service(
        connectors: [StubSourceConnector()], perFetch: .seconds(30), budget: .seconds(60)
    ).refresh(taskIDs: [task.id])
    let elapsed = ContinuousClock.now - started

    #expect(outcome.cached == 2)
    #expect(outcome.skipped == 0)
    // A twelve-fold margin, so this is a correctness assertion rather than a
    // performance gate: the broken version takes the full sixty seconds.
    #expect(elapsed < .seconds(5))
}

@MainActor
@Test("the budget still bounds a pass whose fetches hang")
func theBudgetStillAppliesWhenWorkIsOutstanding() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-HANG", on: task)

    // The other half of the fix: settling the sentinel early must not disarm it
    // while a fetch is still in flight.
    let outcome = await fixture.service(
        connectors: [StubSourceConnector(fallback: .hang)],
        perFetch: .seconds(30), budget: .milliseconds(120)
    ).refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 1)
    #expect(outcome.skipped == 1)
    #expect(outcome.failures.isEmpty)
}
