import Foundation
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

private func makeProject(_ name: String, keys: [String] = [], order: Int = 0) -> Project {
    Project(
        name: name,
        colorHex: ProjectPalette.hex(forIndex: order),
        jiraProjectKeys: keys,
        sortOrder: order,
        modifiedAt: epoch
    )
}

@Test("a configured ticket key routes to its project")
func configuredKeyRoutes() throws {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let match = try #require(
        ProjectRouter.ticketKeyMatch(
            text: "PAY-421 fix the retry handler", projects: [payments, hiring])
    )

    #expect(match.key == "PAY-421")
    #expect(match.projectID == payments.id)
}

@Test("the first *matching* key wins, not the first key")
func firstMatchingKeyWins() throws {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)

    let match = try #require(
        ProjectRouter.ticketKeyMatch(text: "UTF-8 fix for PAY-421", projects: [payments])
    )

    // UTF-8 matches JiraKey.pattern but no configured project, so the scan
    // continues. This is what absorbs M1-01's documented false positives.
    #expect(match.key == "PAY-421")
}

@Test("a key inside a URL still routes")
func keyInsideURLRoutes() throws {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let text = "see https://acme.atlassian.net/browse/PAY-421"

    let match = try #require(ProjectRouter.ticketKeyMatch(text: text, projects: [payments]))

    // Deliberately unlike M1-01's extractor, whose overlap rule suppresses
    // keys inside links. That rule is right for refs and wrong for routing.
    #expect(match.key == "PAY-421")
}

@Test("an unconfigured prefix does not match")
func unconfiguredPrefixDoesNotMatch() {
    let hiring = makeProject("EM — Hiring", order: 0)

    #expect(ProjectRouter.ticketKeyMatch(text: "PAY-421", projects: [hiring]) == nil)
}

@Test("prefix comparison ignores case and surrounding space")
func prefixComparisonIsNormalised() throws {
    let payments = makeProject("Payments", keys: [" pay "], order: 0)

    let match = try #require(ProjectRouter.ticketKeyMatch(text: "PAY-421", projects: [payments]))

    #expect(match.projectID == payments.id)
}

@Test("two projects claiming one prefix resolve by sortOrder")
func contestedPrefixResolvesBySortOrder() throws {
    let second = makeProject("Second", keys: ["PAY"], order: 5)
    let first = makeProject("First", keys: ["PAY"], order: 1)

    // Passed out of order deliberately: the rule is sortOrder, not array order.
    let match = try #require(
        ProjectRouter.ticketKeyMatch(text: "PAY-1", projects: [second, first]))

    #expect(match.projectID == first.id)
}

@Test("a ticket key outranks every other rung")
func ticketKeyOutranksEverything() {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "PAY-421 fix it",
        projects: [payments, hiring],
        preferred: hiring.id,
        lastUsed: hiring.id,
        defaultProjectID: hiring.id,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == payments.id)
    #expect(decision.source == .ticketKey("PAY-421"))
}

@Test("with no key match, the surface's preference wins")
func preferredWinsWithoutAKey() {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "write the interview loop doc",
        projects: [payments, hiring],
        preferred: hiring.id,
        lastUsed: payments.id,
        defaultProjectID: nil,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .preferred)
}

@Test("with no preference, the last-used project wins")
func lastUsedWinsWithoutAPreference() {
    let payments = makeProject("Payments", order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments, hiring],
        preferred: nil,
        lastUsed: hiring.id,
        defaultProjectID: payments.id,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .lastUsed)
}

@Test("with no last-used, FR-6's configured default wins")
func configuredDefaultIsRungFour() {
    let payments = makeProject("Payments", order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments, hiring],
        preferred: nil,
        lastUsed: nil,
        defaultProjectID: hiring.id,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .configuredDefault)
}

@Test("the last resort is the first project by sortOrder")
func firstProjectIsTheLastResort() {
    let payments = makeProject("Payments", order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments, hiring],
        preferred: nil,
        lastUsed: nil,
        defaultProjectID: nil,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == payments.id)
    #expect(decision.source == .firstProject)
}

@Test("a rung naming an archived project is skipped, not honoured")
func staleRungIsSkipped() {
    let payments = makeProject("Payments", order: 0)
    let vanished = UUID()

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments],
        preferred: vanished,
        lastUsed: vanished,
        defaultProjectID: vanished,
        ignoringTicketKey: false
    )

    // `projects` is the live list; a rung pointing outside it is stale.
    #expect(decision.projectID == payments.id)
    #expect(decision.source == .firstProject)
}

@Test("ignoringTicketKey skips rung one and lands on rung two")
func dismissedChipFallsThrough() {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "PAY-421 fix it",
        projects: [payments, hiring],
        preferred: hiring.id,
        lastUsed: nil,
        defaultProjectID: nil,
        ignoringTicketKey: true
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .preferred)
}

@Test("with no projects at all there is nowhere to route")
func noProjectsRoutesNowhere() {
    let decision = ProjectRouter.route(
        text: "PAY-421",
        projects: [],
        preferred: nil,
        lastUsed: nil,
        defaultProjectID: nil,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == nil)
    #expect(decision.source == .none)
}
