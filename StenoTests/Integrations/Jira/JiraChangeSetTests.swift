import Foundation
import Testing

@testable import StenoKit

/// §5.2's change vocabulary, and the watermark the next window starts from
/// (D-184, D-187, D-188, D-195).

private let recent = "2026-09-25T18:04:11.000+0000"
private let older = "2026-09-20T09:00:00.000+0000"
private let ancient = "2024-01-02T03:04:05.000+0000"

/// The window start used by most tests here: after `older`, before `recent`.
private let since = AtlassianDate.parse("2026-09-22T00:00:00.000+0000")

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func issue(_ json: String = JiraFixture.issue()) throws -> JiraIssue {
    try decode(JiraIssue.self, json)
}

private func history(_ entries: [JiraFixture.Entry]) throws -> [JiraChangelogEntry] {
    try decode(JiraChangelogPage.self, JiraFixture.changelog(entries)).values ?? []
}

private func comments(_ items: [JiraFixture.Comment]) throws -> [JiraComment] {
    try decode(JiraCommentPage.self, JiraFixture.comments(items)).comments ?? []
}

private func links(_ items: [JiraFixture.Link]) throws -> [JiraRemoteLink] {
    try decode([JiraRemoteLink].self, JiraFixture.remoteLinks(items))
}

private func make(
    issue issueJSON: String = JiraFixture.issue(),
    history entries: [JiraFixture.Entry] = [],
    comments items: [JiraFixture.Comment] = [],
    links linkItems: [JiraFixture.Link] = [],
    since window: Date? = since
) throws -> JiraChangeSet {
    JiraChangeSet.make(
        issue: try issue(issueJSON), history: try history(entries),
        comments: try comments(items), links: try links(linkItems), since: window)
}

// MARK: - Summary

@Test("§5.2: the summary is the last-known state, with no timestamp baked into it")
func theSummaryIsLastKnownState() throws {
    let set = try make()
    // No "updated 2h ago": the age of this data is the staleness banner's job (D-176),
    // and a relative time baked into a *cached* string is wrong the moment it is stored.
    #expect(set.summary == "Add the migration plan — In Review · assigned to Leo Gutierrez")
}

@Test("an unassigned ticket says so rather than saying nothing")
func anUnassignedTicketSaysSo() throws {
    let set = try make(issue: JiraFixture.issue(assignee: nil))
    #expect(set.summary == "Add the migration plan — In Review · unassigned")
}

@Test("a missing title leaves the state, not the word unknown")
func aMissingTitleLeavesTheState() throws {
    let set = try make(issue: JiraFixture.issue(title: nil))
    #expect(set.summary == "In Review · assigned to Leo Gutierrez")
}

// MARK: - Transitions

@Test("§5.2: a status transition inside the window is reported")
func aStatusTransitionIsReported() throws {
    let set = try make(history: [
        .status(id: "10001", created: recent, from: "In Progress", to: "In Review")
    ])

    #expect(set.changes.map(\.text) == ["status: In Progress → In Review"])
    #expect(set.changes.map(\.id) == ["10001#status"])
}

@Test("§5.2: an assignee change is reported")
func anAssigneeChangeIsReported() throws {
    let set = try make(history: [
        JiraFixture.Entry(
            id: "10002", created: recent,
            items: [JiraFixture.Change(field: "assignee", from: nil, toValue: "Leo")])
    ])
    #expect(set.changes.map(\.text) == ["assignee: unassigned → Leo"])
}

@Test("D-186: one entry carrying two changes yields two ids, not one")
func abatchedEntryYieldsTwoIds() throws {
    // **Jira batches a status change and an assignee change made together into one
    // changelog entry with two items.** The entry id alone as a dedup key therefore
    // drops the second change as a duplicate of the first. Mutation: key on `entry.id`
    // and this goes red.
    let set = try make(history: [
        JiraFixture.Entry(
            id: "10003", created: recent,
            items: [
                JiraFixture.Change(field: "status", from: "In Progress", toValue: "In Review"),
                JiraFixture.Change(field: "assignee", from: "Ana", toValue: "Leo"),
            ])
    ])

    #expect(set.changes.count == 2)
    #expect(Set(set.changes.map(\.id)) == ["10003#status", "10003#assignee"])
}

@Test("§5.2 names two fields, so the rest of the changelog is silent")
func otherFieldsAreIgnored() throws {
    // A stand-up reciting every description edit and label change buries the two
    // things that matter.
    let set = try make(history: [
        JiraFixture.Entry(
            id: "10004", created: recent,
            items: [
                JiraFixture.Change(field: "description", from: "old", toValue: "new"),
                JiraFixture.Change(field: "labels", from: "", toValue: "backend"),
                JiraFixture.Change(field: "Sprint", from: "12", toValue: "13"),
            ])
    ])
    #expect(set.changes.isEmpty)
}

@Test("an entry older than the window is not reported")
func anOlderEntryIsNotReported() throws {
    let set = try make(history: [
        .status(id: "10005", created: older, from: "To Do", to: "In Progress")
    ])
    #expect(set.changes.isEmpty)
}

@Test("the window is applied per item, whatever order they arrive in")
func theWindowIsAppliedPerItem() throws {
    // **Input order deliberately disagrees with the expected order**: a filter that
    // stopped at the first out-of-window entry, or one that trusted the API's ordering,
    // passes a same-order test and fails this one.
    let set = try make(history: [
        .status(id: "a", created: older, from: "To Do", to: "In Progress"),
        .status(id: "b", created: recent, from: "In Progress", to: "In Review"),
        .status(id: "c", created: ancient, from: "Backlog", to: "To Do"),
    ])

    #expect(set.changes.map(\.id) == ["b#status"])
}

@Test("an unparseable timestamp is reported rather than lost")
func anUnparseableTimestampIsReported() throws {
    // It cannot be placed in the window, and the safe direction is to say it: the
    // id-based dedup stops it being said twice, while dropping it would lose a real
    // transition to a date-format change.
    let set = try make(history: [
        .status(id: "10006", created: "not a date", from: "In Progress", to: "In Review")
    ])
    #expect(set.changes.map(\.id) == ["10006#status"])
}

// MARK: - Comments

@Test("§5.2: a new comment is reported with its author and a gist")
func aNewCommentIsReported() throws {
    let set = try make(comments: [JiraFixture.Comment(id: "9001", created: recent)])
    #expect(set.changes.map(\.text) == ["comment from Ana Ruiz: Could you add the migration plan?"])
    // **The id carries the comment's revision**, because the service de-duplicates on it
    // and Jira keeps one comment id across edits (Copilot, PR #43). The revision is Jira's
    // own timestamp string, so it cannot lose precision the source sent.
    #expect(set.changes.map(\.id) == ["9001@\(recent)"])
}

@Test("a comment with no readable body still says who commented")
func anEmptyCommentStillSaysWho() throws {
    let set = try make(comments: [JiraFixture.Comment(id: "9002", created: recent, text: nil)])
    #expect(set.changes.map(\.text) == ["comment from Ana Ruiz"])
}

@Test("a comment with no author reads as someone, not as a crash")
func anAuthorlessCommentReadsAsSomeone() throws {
    let set = try make(comments: [
        JiraFixture.Comment(id: "9003", created: recent, author: nil, text: "ping")
    ])
    #expect(set.changes.map(\.text) == ["comment from someone: ping"])
}

@Test("D-195: an edited comment is news even though it was created long ago")
func anEditedCommentIsNews() throws {
    // `created` is outside the window and `updated` is inside it. Mutation: window on
    // `created` alone and this goes red — and the user never hears that the comment
    // they are about to read out loud has changed.
    let set = try make(comments: [
        JiraFixture.Comment(id: "9004", created: older, updated: recent)
    ])
    #expect(set.changes.map(\.id) == ["9004@\(recent)"])
    // And it says so, rather than reading as a comment that has just arrived.
    #expect(
        set.changes.map(\.text) == [
            "edited comment from Ana Ruiz: Could you add the migration plan?"
        ])
}

@Test("the revision changes with the edit, so a second edit is its own change")
func eachEditIsItsOwnChange() throws {
    // This is the property the service's dedup needs: one comment id, two revisions, two
    // change ids — otherwise the first edit is reported and every later one is dropped.
    // Both timestamps inside the window: the point here is the revision, not the window —
    // the first version of this test used `older` and silently compared two empty arrays.
    let later = "2026-09-26T10:00:00.000+0000"
    let first = try make(comments: [
        JiraFixture.Comment(id: "9004", created: recent, updated: recent)
    ])
    let second = try make(comments: [
        JiraFixture.Comment(id: "9004", created: recent, updated: later)
    ])

    #expect(first.changes.map(\.id) != second.changes.map(\.id))
    #expect(first.changes.first?.id.hasPrefix("9004@") == true)
    #expect(second.changes.first?.id.hasPrefix("9004@") == true)
}

@Test("two edits inside one second are two revisions, not one")
func twoEditsInOneSecondAreTwoRevisions() throws {
    // **Whole-second precision was the first fix's own bug.** Jira sends fractional
    // seconds, so truncating the revision to `Int(timeIntervalSince1970)` made two edits
    // inside one second collide — and the second was dropped by the same dedup the revision
    // was added to satisfy. Raised by Copilot in review round 2 of PR #43.
    let first = try make(comments: [
        JiraFixture.Comment(id: "9004", created: recent, updated: "2026-09-25T18:04:11.100+0000")
    ])
    let second = try make(comments: [
        JiraFixture.Comment(id: "9004", created: recent, updated: "2026-09-25T18:04:11.900+0000")
    ])

    #expect(first.changes.map(\.id) != second.changes.map(\.id))
    #expect(first.changes.count == 1)
    #expect(second.changes.count == 1)
}

@Test("a comment with no usable timestamp falls back to its bare id")
func acommentWithoutATimestampUsesItsBareId() throws {
    let set = try make(comments: [JiraFixture.Comment(id: "9005", created: "not a date")])
    #expect(set.changes.map(\.id) == ["9005"])
}

@Test("a comment older than the window on both timestamps is not reported")
func anOldUneditedCommentIsNotReported() throws {
    let set = try make(comments: [
        JiraFixture.Comment(id: "9005", created: ancient, updated: older)
    ])
    #expect(set.changes.isEmpty)
}

// MARK: - Links

@Test("§5.2: a linked PR arrives as state, not as a change")
func aLinkedPRIsState() throws {
    let set = try make(links: [JiraFixture.Link(id: 10_001)])

    // `present`, not `changes`: remote links carry no timestamp of any kind, so no
    // window can decide whether one is new — only set difference can (D-187).
    #expect(set.changes.isEmpty)
    #expect(set.present.map(\.text) == ["linked acme/api#421"])
    #expect(set.present.map(\.id) == ["10001"])
}

@Test("a link with no numeric id falls back to its global id")
func aLinkFallsBackToItsGlobalId() throws {
    let set = try make(links: [
        JiraFixture.Link(id: nil, globalID: "appId=123&issueId=456", title: "acme/api#9")
    ])
    #expect(set.present.map(\.id) == ["appId=123&issueId=456"])
}

@Test("a link with no stable key at all is skipped")
func aKeylessLinkIsSkipped() throws {
    // Without a key it would be reported as new on every pass, which is worse than not
    // reporting it.
    let set = try make(links: [JiraFixture.Link(id: nil, globalID: nil)])
    #expect(set.present.isEmpty)
}

@Test("a link with no title is labelled by its URL")
func alinkWithoutATitleUsesItsURL() throws {
    let set = try make(links: [
        JiraFixture.Link(id: 7, title: nil, url: "https://github.com/acme/api/pull/9")
    ])
    #expect(set.present.map(\.text) == ["linked https://github.com/acme/api/pull/9"])
}

// MARK: - Watermark

@Test("D-184: the watermark is the newest timestamp Jira put on anything seen")
func theWatermarkIsTheNewestSeen() throws {
    let set = try make(
        history: [.status(id: "a", created: older, from: "To Do", to: "In Progress")],
        comments: [JiraFixture.Comment(id: "9001", created: recent)])

    // **Over everything, not over what was reported.** Taking it from the reported
    // subset would move it backwards whenever a pass reported nothing, and re-report
    // everything in between.
    #expect(set.watermark == AtlassianDate.parse(recent))
}

@Test("the watermark counts items outside the window too")
func theWatermarkCountsUnreportedItems() throws {
    // Nothing here is inside the window, yet the anchor must still advance — otherwise
    // the next pass asks the same question and gets the same answer forever.
    let set = try make(
        history: [.status(id: "a", created: older, from: "To Do", to: "In Progress")],
        since: AtlassianDate.parse(recent))

    #expect(set.changes.isEmpty)
    #expect(set.watermark == AtlassianDate.parse(older))
}

@Test("an edited comment moves the watermark to its edit")
func theWatermarkFollowsAnEdit() throws {
    let set = try make(comments: [JiraFixture.Comment(id: "9004", created: older, updated: recent)])
    #expect(set.watermark == AtlassianDate.parse(recent))
}

@Test("nothing timestamped means no watermark, which leaves the window open")
func noTimestampsMeansNoWatermark() throws {
    let set = try make(links: [JiraFixture.Link()])
    #expect(set.watermark == nil)
}

// MARK: - First observation

@Test("D-188: with no anchor, everything seen is returned so its ids can be recorded")
func withNoAnchorEverythingIsReturned() throws {
    let set = try make(
        history: [.status(id: "a", created: recent, from: "In Progress", to: "In Review")],
        comments: [JiraFixture.Comment(id: "9001", created: recent)],
        links: [JiraFixture.Link()],
        since: nil)

    // **What a first observation returns is not what it reports.** The service keeps
    // these out of the event body (D-188) and records their ids, so the next pass —
    // which re-reads the last fifteen minutes on purpose (D-185) — knows it has already
    // seen them. Filtering here as well left those ids unrecorded and made the second
    // pass announce them; that cost a test to find.
    #expect(set.changes.count == 2)
    #expect(set.watermark == AtlassianDate.parse(recent))
    // The link set is recorded too, so an existing PR reference is not news later.
    #expect(set.present.count == 1)
}
