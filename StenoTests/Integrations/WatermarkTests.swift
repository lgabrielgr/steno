import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// D-183's defect, and the watermark that closes it (D-184 to D-188).

/// The newest item the log has heard about: 30 minutes before the fixture's origin.
private let watermark = RefreshFixture.origin.addingTimeInterval(-1800)

/// When the app last fetched: *after* the watermark, which is the whole problem.
private let lastFetched = RefreshFixture.origin.addingTimeInterval(-600)

private func payload(of event: Event) -> ExternalUpdatePayload? {
    ExternalUpdatePayload.decoded(from: event.payload)
}

@MainActor
@Test("D-183: a change the source revealed late is still reported")
func aLateChangeIsStillReported() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    try fixture.observed(ref, watermark: watermark)

    // The item Jira served *after* the pass that should have seen it: created at
    // 09:58, visible only after the 10:00 pass had asked. Atlassian Cloud is
    // eventually consistent, so this is ordinary rather than exotic.
    let late = lastFetched.addingTimeInterval(-60)
    let connector = WindowedConnector(items: [
        .init(id: "c-late", text: "status: In Progress → In Review", stamp: late)
    ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    // **This is the assertion D-183 was about.** Before M4-02 the window started at the
    // row's `lastFetchedAt` — the app's clock — so `late` was already behind it and this
    // change was lost for good. Mutation: send `ref.lastFetchedAt` as `since` and this
    // goes red.
    #expect(connector.asked == [RefreshFixture.since(after: watermark)])
    #expect(outcome.changed == 1)
    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body).last
            == "PAY-421: status: In Progress → In Review")
}

@MainActor
@Test("D-188: a first observation records the watermark and reports only the summary")
func aFirstObservationRecordsItsAnchor() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)

    let older = RefreshFixture.origin.addingTimeInterval(-7200)
    let newest = RefreshFixture.origin.addingTimeInterval(-3600)
    let connector = WindowedConnector(
        summary: "In Review · assigned to Leo",
        items: [
            .init(id: "c-old", text: "status: To Do → In Progress", stamp: older),
            .init(id: "c-new", text: "comment from Ana", stamp: newest),
        ],
        present: [SourceChange(id: "L1", text: "linked acme/api#421")])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(connector.asked == [nil])
    #expect(outcome.changed == 1)

    let event = try #require(try fixture.eventsInStore(kind: .externalUpdate).last)
    #expect(event.body == "PAY-421: In Review · assigned to Leo")

    let recorded = try #require(payload(of: event))
    // **The subtle half.** The event says only the summary, but it records the anchor
    // and every id seen — otherwise the *second* pass asks from nil, and a ticket with
    // three years of history arrives as a hundred-line stand-up. Mutation: stop
    // stamping `watermark` here and `theSecondPassSaysNothingNew` goes red instead.
    #expect(recorded.watermark == newest)
    #expect(recorded.changeIDs.map(Set.init) == Set(["c-old", "c-new"]))
    #expect(recorded.presentIDs == ["L1"])
    #expect(recorded.changes.isEmpty)
}

@MainActor
@Test("a second pass with nothing new writes no event at all")
func theSecondPassSaysNothingNew() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)

    let newest = RefreshFixture.origin.addingTimeInterval(-3600)
    let connector = WindowedConnector(items: [
        .init(id: "c-new", text: "comment from Ana", stamp: newest)
    ])

    let service = fixture.service(connectors: [connector])
    _ = await service.refresh(taskIDs: [task.id])
    let second = await fixture.service(connectors: [connector], nowOffset: 60)
        .refresh(taskIDs: [task.id])

    // The second pass resumes at the watermark less the overlap, re-reads the one item
    // it already recorded, and drops it — so §3.3's log gains no row saying a ticket
    // has not moved.
    #expect(connector.asked == [nil, RefreshFixture.since(after: newest)])
    #expect(second.changed == 0)
    #expect(second.duplicates == 1)
    #expect(second.cached == 1)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).count == 1)
}

@MainActor
@Test("D-186: a change the log has already reported is dropped, not repeated")
func anAlreadyReportedChangeIsDropped() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    try fixture.observed(ref, watermark: watermark, changeIDs: ["c-known"])

    let connector = WindowedConnector(items: [
        .init(id: "c-known", text: "status: To Do → In Progress", stamp: watermark),
        .init(id: "c-fresh", text: "comment from Ana", stamp: RefreshFixture.origin),
    ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.duplicates == 1)
    #expect(outcome.changed == 1)
    // Only the fresh one reaches the stand-up. Mutation: drop the dedup filter and the
    // user hears about the same transition on every pass for fifteen minutes.
    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body).last
            == "PAY-421: comment from Ana")
}

@MainActor
@Test("D-187: only a link absent from the recorded set is news")
func onlyANewLinkIsNews() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    try fixture.observed(ref, watermark: watermark, presentIDs: ["L1"])

    let connector = WindowedConnector(
        items: [],
        present: [
            SourceChange(id: "L1", text: "linked acme/api#421"),
            SourceChange(id: "L2", text: "linked acme/api#999"),
        ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.changed == 1)
    #expect(outcome.duplicates == 1)
    #expect(
        try fixture.eventsInStore(kind: .externalUpdate).map(\.body).last
            == "PAY-421: linked acme/api#999")

    // The whole set is recorded again, not just the newcomer — a delta would make L1
    // look new the next time a payload was written.
    let event = try #require(try fixture.eventsInStore(kind: .externalUpdate).last)
    #expect(payload(of: event)?.presentIDs.map(Set.init) == Set(["L1", "L2"]))
}

@MainActor
@Test("a payload that recorded no link set is not read as an empty one")
func anUnrecordedLinkSetIsNotAnEmptySet() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    // A payload written before M4-02 carries no `presentIDs` at all.
    try fixture.observed(ref, watermark: watermark, presentIDs: nil)

    let connector = WindowedConnector(
        present: [SourceChange(id: "L1", text: "linked acme/api#421")])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    // Reported, because nothing has ever recorded this link — which is the honest
    // reading of "not recorded" and the reason `ResumePoint` skips such payloads rather
    // than treating them as an empty set.
    #expect(outcome.changed == 1)
}

@MainActor
@Test("a redaction does not make a reported change look unreported")
func aRedactionDoesNotResurrectAChange() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    let event = try fixture.observed(ref, watermark: watermark, changeIDs: ["c-known"])

    // §3.3 hides a redacted event from summaries. It must not hide it from the dedup:
    // redacting the sentence a user reads is not a statement that the ticket never
    // moved. Mutation: use `EventQueries.timeline`, which excludes redacted rows, and
    // this goes red.
    event.redact()
    try fixture.context.save()

    let connector = WindowedConnector(items: [
        .init(id: "c-known", text: "status: To Do → In Progress", stamp: watermark)
    ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(outcome.duplicates == 1)
    #expect(outcome.changed == 0)
}

@MainActor
@Test("D-184: the resume point survives what an export leaves behind")
func theResumePointSurvivesAnExport() async throws {
    // §10.2 excludes `cachedSummary` and `lastFetchedAt` from an export by default,
    // while events always travel — which is why the watermark lives in the log. This is
    // that claim as a test: a ref with no cached columns at all still resumes.
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    let ref = try fixture.ref("PAY-421", on: task)
    try fixture.observed(ref, watermark: watermark, changeIDs: ["c-known"])

    let connector = WindowedConnector(items: [
        .init(id: "c-known", text: "status: To Do → In Progress", stamp: watermark)
    ])

    _ = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(connector.asked == [RefreshFixture.since(after: watermark)])
}
