import Foundation
import Testing

@testable import StenoKit

/// D-207: what a cancelled page walk does, for **both** Atlassian connectors.
///
/// **One file rather than a test beside each client**, deliberately. The rule is shared
/// and the defect was shared: `SourceRefreshService.fetchAll` discards a *failed* fetch
/// once the pass budget has expired and keeps a *successful* one, so a walk that
/// answered cancellation by returning what it had read filed a truncated delta as a
/// complete fetch — into a log that cannot be edited afterwards. Fixing only the
/// connector that happened to be in the diff is the failure mode this repo keeps
/// meeting, so the two assertions sit where the next reader sees them together.
///
/// Every test here holds its task at a `TaskGate` until after `cancel()`, which is what
/// makes the ordering a property of the code rather than of the scheduler.

@Test("D-207: a cancelled Confluence walk fails the ref rather than filing a short answer")
func confluenceCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(),
        users: [ConfluenceFixture.leo: .ok(ConfluenceFixture.user())])
    let subject = ConfluenceClient(transport: transport)
    let gate = TaskGate()

    let task = Task {
        await gate.wait()
        return try await subject.changeSet(
            pageID: ConfluenceFixture.pageID, since: ConfluenceFixture.windowStart,
            credential: ConfluenceFixture.credential())
    }
    task.cancel()
    await gate.open()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}

@Test("D-207: a cancelled Jira walk fails the ref rather than filing a short answer")
func jiraCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubJiraTransport(routes: JiraFixture.quietRoutes())
    let subject = JiraClient(transport: transport)
    let gate = TaskGate()

    let task = Task {
        await gate.wait()
        return try await subject.changeSet(
            key: JiraFixture.key, since: JiraFixture.windowStart,
            credential: JiraFixture.credential())
    }
    task.cancel()
    await gate.open()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}

@Test("D-211: cancellation during the name lookups fails the ref, rather than \"someone\"")
func confluenceCancellationDuringNameLookupsThrows() async throws {
    // The second place D-207's failure mode lives. Each lookup's `try?` turns a cancelled
    // request into an unresolved name, so a budget expiring here produced an ordinary
    // *success* in which every editor read "someone" — and `SourceRefreshService` keeps a
    // success after the budget, writing that attribution into a log that cannot be edited.
    //
    // Staged with two gates so the cancellation lands exactly where it matters: the walk
    // is held at its first name lookup, cancelled while held, then released. Nothing here
    // depends on which thread wins a race.
    let reachedLookup = TaskGate()
    let releaseLookup = TaskGate()

    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(),
        users: [ConfluenceFixture.leo: .ok(ConfluenceFixture.user())],
        onUserRequest: {
            await reachedLookup.open()
            await releaseLookup.wait()
        })
    let subject = ConfluenceClient(transport: transport)

    let task = Task {
        try await subject.changeSet(
            pageID: ConfluenceFixture.pageID, since: ConfluenceFixture.windowStart,
            credential: ConfluenceFixture.credential())
    }

    await reachedLookup.wait()  // the page and the versions are already read
    task.cancel()
    await releaseLookup.open()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}
