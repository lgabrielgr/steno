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

/// Holds a task at its first line until the test says otherwise.
///
/// **The first version of these tests had no gate**, and claimed in its own comment that
/// `Task { … }` followed by `cancel()` was deterministic "because a Task cancelled before
/// it runs still reports `isCancelled`". The premise is false: the body is scheduled on
/// the global executor and may begin on another thread *concurrently* with the next line
/// of the test, so the walk could read its one stubbed page and return successfully
/// before the cancellation landed — a test that passes or fails on scheduling, which is
/// worse than no test because it teaches people to re-run. Raised by Copilot in review of
/// PR #44.
///
/// With the gate the ordering is a property of the code rather than of the machine: the
/// body cannot reach the fetch until `open()` is called, and `open()` is called after
/// `cancel()`.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Let everything through, now and later.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Suspend until `open()`. Returns immediately once it has been called, so the test
    /// cannot deadlock by opening the gate before anything waits on it.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Test("D-207: a cancelled Confluence walk fails the ref rather than filing a short answer")
func confluenceCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(),
        users: [ConfluenceFixture.leo: .ok(ConfluenceFixture.user())])
    let subject = ConfluenceClient(transport: transport)
    let gate = Gate()

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
    let gate = Gate()

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
