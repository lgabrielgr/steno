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
/// Both tests cancel the task **before its body starts**, which is deterministic: a
/// `Task` cancelled before it runs still reports `isCancelled` at the loop's first
/// check. No sleeping, no racing the scheduler, nothing to flake.

@Test("D-207: a cancelled Confluence walk fails the ref rather than filing a short answer")
func confluenceCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(),
        users: [ConfluenceFixture.leo: .ok(ConfluenceFixture.user())])
    let subject = ConfluenceClient(transport: transport)

    let task = Task {
        try await subject.changeSet(
            pageID: ConfluenceFixture.pageID, since: ConfluenceFixture.windowStart,
            credential: ConfluenceFixture.credential())
    }
    task.cancel()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}

@Test("D-207: a cancelled Jira walk fails the ref rather than filing a short answer")
func jiraCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubJiraTransport(routes: JiraFixture.quietRoutes())
    let subject = JiraClient(transport: transport)

    let task = Task {
        try await subject.changeSet(
            key: JiraFixture.key, since: JiraFixture.windowStart,
            credential: JiraFixture.credential())
    }
    task.cancel()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}
