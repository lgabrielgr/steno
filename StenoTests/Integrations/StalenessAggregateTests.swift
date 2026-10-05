import Foundation
import SwiftData
import Testing

@testable import StenoKit

// Which refs' ages reach §5.2's staleness label, and which must not.
//
// Split from `SourceRefreshServiceTests` at SwiftLint's 400-line limit, and it is
// a coherent subject on its own: every test here is about `oldestFetch(of:)`
// deciding whose cache age the user is told about.

@MainActor
@Test("D-216: a switched-off ref's cache age does not reach the staleness label")
func aDisabledRefsAgeDoesNotReachTheStalenessLabel() async throws {
    // **Copilot, PR #45 — the hole in D-216's silence.** A ref fetched three days
    // ago and since switched off still carried its age into the outcome, so
    // `SourceNotice` fell through every branch above staleness and told the user
    // "Some integration data is 3 days old" about data they had deliberately
    // stopped refreshing. The first test of that silence passed `oldestFetch: nil`
    // — the state of a store that never fetched — so it could not see this.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-3 * 86400),
        summary: "In Review")
    let connector = StubSourceConnector(id: "jira", kinds: [.jiraIssue])

    let outcome = await fixture.service(connectors: [connector], disabled: ["jira"])
        .refresh(taskIDs: [task.id])

    #expect(outcome.disabled == 1)
    #expect(outcome.attempted == 0)
    // Mutation: drop `ignoring:` from the `oldestFetch` calls. Red.
    #expect(outcome.oldestFetch == nil)
    #expect(SourceNotice.message(for: outcome, now: RefreshFixture.origin) == nil)
}

@MainActor
@Test("D-216: an enabled ref's age still reaches the label when a disabled one is older")
func anEnabledRefsAgeIsStillReported() async throws {
    // The other direction, so the exclusion is not a blanket suppression: the
    // switched-off ref is the *older* one, and the sentence must quote the enabled
    // ref's age rather than going silent.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin.addingTimeInterval(-9 * 86400),
        summary: "stale and switched off")
    try fixture.ref(
        "12345", on: task, kind: .confluencePage,
        fetched: RefreshFixture.origin.addingTimeInterval(-2 * 86400), summary: "older page")
    let jira = StubSourceConnector(id: "jira", kinds: [.jiraIssue])
    let confluence = StubSourceConnector(id: "confluence", kinds: [.confluencePage])

    // Nothing is due within 30 minutes of the origin, so this pass fetches neither
    // and the aggregate is read over the rows as they stand.
    let outcome = await fixture.service(
        connectors: [jira, confluence], disabled: ["jira"]
    ).refreshDue(olderThan: .seconds(60 * 60 * 24 * 365))

    #expect(outcome.oldestFetch == RefreshFixture.origin.addingTimeInterval(-2 * 86400))
    #expect(
        SourceNotice.message(for: outcome, now: RefreshFixture.origin)?.text
            == "Some integration data is 2 days old.")
}

@MainActor
@Test("a ref orphaned by a site change does not leak its age into the staleness label")
func anOrphanedRefsAgeDoesNotReachTheStalenessLabel() async throws {
    // **Copilot, PR #45 round 4 — and my own comment asserted the opposite.**
    // `oldestFetch`'s doc claimed `.unhandled` implies nothing ever fetched the ref,
    // so it needed no exclusion. False: `canHandle` compares a ref's URL host against
    // the configured site, so after the user moves from site A to site B, a ref
    // cached from site A dispatches `.unhandled` *while keeping its
    // `lastFetchedAt`*. Its age then reached the label — and with the integration
    // also switched off, D-216's silence broke again by a second route.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref(
        "PAY-421", on: task, url: "https://site-a.atlassian.net/browse/PAY-421",
        fetched: RefreshFixture.origin.addingTimeInterval(-4 * 86400), summary: "from site A")

    // The connector is configured for site B, so the site-A ref is unclaimed.
    let connector = JiraConnector(
        credentials: InMemoryAtlassianStore(
            AtlassianCredential(
                site: "site-b.atlassian.net", email: "leo@example.com", apiToken: "token-value")),
        transport: StubJiraTransport(routes: [:]))

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.attempted == 0)
    // Mutation: drop `.unhandled` from the exclusion. Red.
    #expect(outcome.oldestFetch == nil)
    #expect(SourceNotice.message(for: outcome, now: RefreshFixture.origin) == nil)
}
