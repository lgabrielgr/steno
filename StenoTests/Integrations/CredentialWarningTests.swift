import Foundation
import Testing

@testable import StenoKit

/// D-194: §5.2's warning reaches the sheet from every pass, including the ones that
/// fetch nothing.

private let warning = SourceCredentialWarning(
    displayName: "Windowed", daysRemaining: 9, renewalURL: AtlassianTokenExpiry.renewalURL)

@MainActor
@Test("a pass that fetched carries the warning")
func apassThatFetchedCarriesTheWarning() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let connector = WindowedConnector(credentialWarning: warning)

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.credentialWarnings == [warning])
}

@MainActor
@Test("a pass with no refs in scope still carries the warning")
func apassWithNothingToDoStillCarriesTheWarning() async throws {
    let fixture = try RefreshFixture()
    let connector = WindowedConnector(credentialWarning: warning)

    // `.idle` is a constant and the warnings are not: a user whose token expires on
    // Friday must hear about it on a draft whose refs are all on done tasks, which is
    // exactly the pass that has nothing to fetch. Mutation: return `.idle` unchanged
    // and this goes red.
    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [])

    #expect(outcome.attempted == 0)
    #expect(outcome.credentialWarnings == [warning])
}

@MainActor
@Test("a pass whose refs nobody claims still carries the warning")
func apassWithNoClaimedRefsStillCarriesTheWarning() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    // A `.url` ref, which no connector claims — the ordinary case, per D-166.
    try fixture.ref("https://example.com", on: task, kind: .url)
    let connector = WindowedConnector(credentialWarning: warning)

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 0)
    #expect(outcome.credentialWarnings == [warning])
}

@MainActor
@Test("an unconfigured connector's warning still reaches the sheet")
func anUnconfiguredConnectorStillWarns() async throws {
    // The pass reports the ref as not-configured and fetches nothing, and the token is
    // still expiring — both facts are true, and `SourceNotice` ranks them.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let connector = WindowedConnector(isConfigured: false, credentialWarning: warning)

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.notConfigured == 1)
    #expect(outcome.credentialWarnings == [warning])
}

@MainActor
@Test("the warning is read once per pass, not once per ref")
func thewarningIsReadOncePerPass() async throws {
    // The contract `SourceConnector` states, and the reason it can read a Keychain at
    // all: three refs on one task must not mean three reads.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    try fixture.ref("PAY-9", on: task)
    try fixture.ref("PAY-77", on: task)
    let connector = CountingWarningConnector(warning: warning)

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 3)
    #expect(connector.warningReads == 1)
}

@Test("a warning-free pass carries nothing, and the outcome is untouched")
func awarningFreePassIsUnchanged() {
    // `warning(about:)` returns `self` for an empty list rather than rebuilding the
    // value, so the no-integration case cannot drift from the plain initializer.
    let outcome = RefreshOutcome(attempted: 2, cached: 2)
    #expect(outcome.warning(about: []) == outcome)
}

@Test("attaching a warning preserves every other field")
func attachingAwarningPreservesEverything() {
    // A hand-written copy is where a field gets dropped — `superseded` and `duplicates`
    // were the two most recently added, so they are the two most likely to be missed.
    let original = RefreshOutcome(
        attempted: 4, cached: 3, changed: 2,
        failures: [
            RefreshOutcome.Failure(connectorID: "jira", displayName: "Jira", error: .network)
        ],
        notConfigured: 1, skipped: 5, superseded: 6, duplicates: 7,
        oldestFetch: Date(timeIntervalSince1970: 1), readFailed: true, saveFailed: true)

    let carried = original.warning(about: [warning])

    #expect(carried.credentialWarnings == [warning])
    #expect(carried.attempted == 4)
    #expect(carried.cached == 3)
    #expect(carried.changed == 2)
    #expect(carried.failures.count == 1)
    #expect(carried.notConfigured == 1)
    #expect(carried.skipped == 5)
    #expect(carried.superseded == 6)
    #expect(carried.duplicates == 7)
    #expect(carried.oldestFetch == Date(timeIntervalSince1970: 1))
    #expect(carried.readFailed)
    #expect(carried.saveFailed)
}

/// Counts how often its warning was read, for the once-per-pass contract.
private final class CountingWarningConnector: SourceConnector, @unchecked Sendable {
    let id = "counting"
    let displayName = "Counting"
    let isConfigured = true

    private let warning: SourceCredentialWarning
    private let lock = NSLock()
    private var reads = 0

    var warningReads: Int { lock.withLock { reads } }

    init(warning: SourceCredentialWarning) {
        self.warning = warning
    }

    var credentialWarning: SourceCredentialWarning? {
        lock.withLock { reads += 1 }
        return warning
    }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool { ref.kind == .jiraIssue }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        SourceUpdate(
            summary: "In Review", changes: [], url: nil, fetchedAt: RefreshFixture.origin,
            isWindowCapped: false)
    }

    func testConnection() async throws {}
}
