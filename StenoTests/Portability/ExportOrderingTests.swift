import Foundation
import Testing

@testable import StenoKit

/// Every array's order, asserted against an insertion order that disagrees with
/// it. Encoding twice and comparing the results would prove nothing.

@MainActor
@Test("projects export in sortOrder, whatever order they were inserted in")
func projectsExportInSortOrder() throws {
    let fixture = try ExportFixture()
    try fixture.project("Third", sortOrder: 2)
    try fixture.project("First", sortOrder: 0)
    try fixture.project("Second", sortOrder: 1)

    let names = try fixture.encoder().snapshot().projects.map(\.name)

    #expect(names == ["First", "Second", "Third"])
}

@MainActor
@Test("projects sharing a sortOrder fall back to name, as the sidebar does")
func projectsTiedOnSortOrderFallBackToName() throws {
    let fixture = try ExportFixture()
    try fixture.project("Zebra", sortOrder: 3)
    try fixture.project("Apple", sortOrder: 3)
    try fixture.project("Mango", sortOrder: 3)

    let names = try fixture.encoder().snapshot().projects.map(\.name)

    // `sortOrder` is not unique, and `MainWindowModel.fetchProjects` breaks the
    // tie on `name`. Breaking it on `id` instead would export three projects in
    // an order that matches nothing the user has ever seen.
    #expect(names == ["Apple", "Mango", "Zebra"])
}

@MainActor
@Test("tasks export oldest first, whatever order they were inserted in")
func tasksExportOldestFirst() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    try fixture.task("third", in: project, createdAt: ExportFixture.at(300))
    try fixture.task("first", in: project, createdAt: ExportFixture.at(100))
    try fixture.task("second", in: project, createdAt: ExportFixture.at(200))

    let titles = try fixture.encoder().snapshot().tasks.map(\.title)

    #expect(titles == ["first", "second", "third"])
}

@MainActor
@Test("events export oldest first, so a day's appends land at the end")
func eventsExportOldestFirst() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    let task = try fixture.task("ship it", in: project)
    try fixture.event("third", on: task, at: ExportFixture.at(300))
    try fixture.event("first", on: task, at: ExportFixture.at(100))
    try fixture.event("second", on: task, at: ExportFixture.at(200))

    let bodies = try fixture.encoder().snapshot().events.map(\.body)

    #expect(bodies == ["first", "second", "third"])
}

@MainActor
@Test("reports export oldest first")
func reportsExportOldestFirst() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    try fixture.report(for: project, generatedAt: ExportFixture.at(300), body: "third")
    try fixture.report(for: project, generatedAt: ExportFixture.at(100), body: "first")
    try fixture.report(for: project, generatedAt: ExportFixture.at(200), body: "second")

    let bodies = try fixture.encoder().snapshot().reports.map(\.markdownBody)

    #expect(bodies == ["first", "second", "third"])
}

@MainActor
@Test("refs export by §3.4's dedup key, so a task's refs group together")
func refsExportByDedupKey() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    let task = try fixture.task("ship it", in: project)
    try fixture.ref("PAY-9", on: task, kind: .jiraIssue)
    try fixture.ref("https://example.com", on: task, kind: .url)
    try fixture.ref("PAY-1", on: task, kind: .jiraIssue)

    let identifiers = try fixture.encoder().snapshot().sourceRefs.map(\.identifier)

    // One task, so the taskID component ties and the order is (kind, identifier):
    // jiraIssue before url, and PAY-1 before PAY-9 within the kind.
    #expect(identifiers == ["PAY-1", "PAY-9", "https://example.com"])
}

@MainActor
@Test("the export order survives a round trip, even below the wire precision")
func subMillisecondOrderSurvivesTheRoundTrip() throws {
    // Ids chosen so that falling through to the tie-break *reverses* the pair:
    // the earlier event carries the higher id. Without that, a comparator bug
    // and a correct comparator would produce the same array and this test
    // could not tell them apart.
    let high = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000FF"))
    let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"))

    let fixture = try ExportFixture()
    let task = try fixture.task("ship it", in: try fixture.project("Payments"))
    // A tenth of a millisecond apart: distinguishable in memory, identical on
    // the wire, because encoding truncates to three fractional digits.
    try fixture.event("earlier", on: task, at: ExportFixture.at(0.5001), id: high)
    try fixture.event("later", on: task, at: ExportFixture.at(0.5002), id: low)

    let exported = try fixture.encoder().snapshot().events.map(\.body)
    let decoded = try ExportDocument.decoder()
        .decode(ExportDocument.self, from: try fixture.encoder().encode())
    let reExported = ExportEncoder.sortedByWireInstant(
        decoded.events, instant: { $0.timestamp }, id: { $0.id }
    ).map(\.body)

    // Any store built from this file — M2.5-02's import, then M2.5-05's next
    // auto-export — sorts the decoded values, which no longer carry the
    // sub-millisecond difference. If the comparator ordered on the in-memory
    // instant, these two arrays would disagree and an unchanged store would
    // export differently after a round trip.
    #expect(exported == reExported)
}

@MainActor
@Test("two events sharing a timestamp order by id, whichever went in first")
func tiedTimestampsAreBrokenByID() throws {
    // The tie-break is what makes the output byte-stable. Without it
    // `sorted(by:)` — which is not documented as stable — leaves two
    // same-instant rows in an unspecified order, two exports of an unchanged
    // store differ, and M2.5-05's backup history becomes churn.
    let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"))
    let high = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000FF"))
    let tie = ExportFixture.at(500)

    let forwards = try ExportFixture()
    let forwardsTask = try forwards.task(
        "ship it", in: try forwards.project("Payments"))
    try forwards.event("low", on: forwardsTask, at: tie, id: low)
    try forwards.event("high", on: forwardsTask, at: tie, id: high)

    let backwards = try ExportFixture()
    let backwardsTask = try backwards.task(
        "ship it", in: try backwards.project("Payments"))
    try backwards.event("high", on: backwardsTask, at: tie, id: high)
    try backwards.event("low", on: backwardsTask, at: tie, id: low)

    #expect(try forwards.encoder().snapshot().events.map(\.id) == [low, high])
    #expect(try backwards.encoder().snapshot().events.map(\.id) == [low, high])
}
