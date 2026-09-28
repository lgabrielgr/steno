import Foundation
import Testing

@testable import StenoKit

/// The wire shapes, and Jira's timestamps.

@Test("Jira's own format, with fractional seconds, parses")
func jiraTimestampsParse() throws {
    // The form Atlassian actually sends: milliseconds, and a zone with no colon.
    let parsed = try #require(JiraDate.parse("2026-09-25T18:04:11.123+0000"))
    #expect(parsed.timeIntervalSince1970 == 1_790_359_451.123)
}

@Test("the same instant without a fraction parses too")
func timestampsWithoutFractionsParse() throws {
    // `.withFractionalSeconds` is a requirement rather than a permission, so one
    // formatter cannot read both forms — which is why there are two, tried in order.
    // Mutation: drop the second formatter and this goes red.
    let parsed = try #require(JiraDate.parse("2026-09-25T18:04:11Z"))
    #expect(parsed.timeIntervalSince1970 == 1_790_359_451)
}

@Test("a zone offset is honoured, not ignored")
func zoneOffsetsAreHonoured() throws {
    let utc = try #require(JiraDate.parse("2026-09-25T18:04:11.000+0000"))
    let plusTwo = try #require(JiraDate.parse("2026-09-25T20:04:11.000+0200"))
    #expect(utc == plusTwo)
}

@Test("nonsense is nil, not a crash and not an epoch", arguments: ["", "yesterday", "2026-13-45"])
func nonsenseTimestampsAreNil(value: String) {
    // `nil` matters more than it looks: a timestamp silently becoming 1970 would make
    // every item look ancient and the watermark meaningless.
    #expect(JiraDate.parse(value) == nil)
}

@Test("a comment's stamp is the later of created and updated")
func aCommentsStampIsTheLater() throws {
    let page = try JSONDecoder().decode(
        JiraCommentPage.self,
        from: Data(
            JiraFixture.comments([
                JiraFixture.Comment(
                    id: "9001", created: "2026-09-20T09:00:00.000+0000",
                    updated: "2026-09-26T11:30:00.000+0000")
            ]).utf8))

    let comment = try #require(page.comments?.first)
    // An edit is news: the text the user would read out has changed, and `created`
    // alone would put this comment outside a window it belongs in.
    #expect(comment.stamp == JiraDate.parse("2026-09-26T11:30:00.000+0000"))
}

@Test("the changelog page carries isLast, which the comment page does not")
func thePagingFieldsDifferByEndpoint() throws {
    let changelog = try JSONDecoder().decode(
        JiraChangelogPage.self,
        from: Data(
            JiraFixture.changelog(
                [.status(id: "1", created: "2026-09-25T18:04:11.123+0000", from: "A", to: "B")],
                total: 1, isLast: true
            ).utf8))
    #expect(changelog.isLast == true)
    #expect(changelog.total == 1)

    let comments = try JSONDecoder().decode(
        JiraCommentPage.self,
        from: Data(JiraFixture.comments([], total: 0).utf8))
    // Asserting the asymmetry, because D-196's paging depends on it: comments page on
    // `startAt + total` precisely because there is no `isLast` to read.
    #expect(comments.total == 0)
}

@Test("`toString` reaches Swift as `toValue`")
func toStringIsRenamed() throws {
    let page = try JSONDecoder().decode(
        JiraChangelogPage.self,
        from: Data(
            JiraFixture.changelog([
                .status(
                    id: "1", created: "2026-09-25T18:04:11.123+0000", from: "In Progress",
                    to: "In Review")
            ]).utf8))

    let item = try #require(page.values?.first?.items?.first)
    #expect(item.fromString == "In Progress")
    // The coding key is what keeps the wire contract while the Swift name stays
    // readable. Mutation: remove the `CodingKeys` entry and this is nil.
    #expect(item.toValue == "In Review")
}

@Test("a remote link's id is an Int, unlike every other id")
func aRemoteLinkIdIsAnInt() throws {
    let links = try JSONDecoder().decode(
        [JiraRemoteLink].self,
        from: Data(JiraFixture.remoteLinks([JiraFixture.Link(id: 10_001)]).utf8))
    #expect(links.first?.id == 10_001)
    #expect(links.first?.object?.title == "acme/api#421")
}

@Test("a missing field costs that field, not the whole decode")
func aMissingFieldCostsOnlyItself() throws {
    // Every wire field is optional for this reason: §5.5 degrades, and one absent
    // `displayName` must not fail a fetch that would otherwise report a transition.
    let issue = try JSONDecoder().decode(
        JiraIssue.self,
        from: Data(JiraFixture.issue(title: nil, status: "In Review", assignee: nil).utf8))
    #expect(issue.fields?.summary == nil)
    #expect(issue.fields?.assignee == nil)
    #expect(issue.fields?.status?.name == "In Review")
}
