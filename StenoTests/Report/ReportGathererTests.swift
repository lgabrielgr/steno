import Foundation
import SwiftData
import Testing

@testable import StenoKit

@MainActor
@Test("FR-4 step 3: the window's events are gathered, oldest first")
func theWindowsEventsAreGatheredOldestFirst() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("second", on: task, at: 120)
    try fixture.event("first", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.count == 1)
    #expect(window.tasks[0].events.map(\.body) == ["first", "second"])
    #expect(window.projectID == fixture.alpha.id)
    #expect(window.cadence == .daily)
}

@MainActor
@Test("events outside the window are not gathered")
func eventsOutsideTheWindowAreExcluded() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("before the window", on: task, at: -60)
    try fixture.event("inside", on: task, at: 60)
    try fixture.event("after the window", on: task, at: 600)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].events.map(\.body) == ["inside"])
}

@MainActor
@Test("§3.3: redacted events are excluded")
func redactedEventsAreExcluded() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("kept", on: task, at: 60)
    try fixture.event("withdrawn", on: task, at: 90, redacted: true)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].events.map(\.body) == ["kept"])
}

@MainActor
@Test("a standupReported event stamped exactly at windowStart does not appear")
func theLastReportsOwnEventIsNotGathered() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    // Exactly what M2-03's Copy leaves behind: the event and the new
    // lastStandupAt share one instant, and FR-4's interval is closed.
    try fixture.event("reported", on: task, at: 0, kind: .standupReported)
    try fixture.event("real work", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].events.map(\.body) == ["real work"])
}

@MainActor
@Test("the interval stays closed: an ordinary event at windowStart is kept")
func anOrdinaryEventOnTheBoundaryIsKept() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("on the start boundary", on: task, at: 0)
    try fixture.event("on the end boundary", on: task, at: 300)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    // This is the test that keeps the standupReported exclusion falsifiable. A
    // half-open interval would pass the test above and fail this one.
    #expect(
        window.tasks[0].events.map(\.body) == ["on the start boundary", "on the end boundary"])
}

@MainActor
@Test("an archived task is dropped even with events in the window")
func anArchivedTaskIsDropped() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task(
        "abandoned", in: fixture.alpha, status: .inProgress, archived: true)
    try fixture.event("still noisy", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.isEmpty)
}

@MainActor
@Test("ticket keys carry every jiraIssue ref, sorted, and no other kind")
func ticketKeysCarryEveryJiraRefSorted() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("two tickets", in: fixture.alpha, status: .inProgress)
    try fixture.jiraRef("PAY-14", on: task)
    try fixture.jiraRef("ACC-2", on: task)
    let link = SourceRef(
        taskID: task.id, kind: .githubPR, identifier: "steno#21",
        url: "https://github.com/x/y/pull/21")
    fixture.context.insert(link)
    link.task = task
    try fixture.context.save()
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks[0].ticketKeys == ["ACC-2", "PAY-14"])
}

@MainActor
@Test("FR-4 step 2: a project that has never reported gets a 24h window")
func aFirstReportGetsATwentyFourHourWindow() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("yesterday evening", on: task, at: -3_600)
    try fixture.event("two days ago", on: task, at: -172_800)

    #expect(fixture.alpha.lastStandupAt == nil)
    let window = try fixture.gatherer(nowOffset: 0).gather(for: fixture.alpha)

    #expect(window.start == ReportFixture.origin.addingTimeInterval(-86_400))
    #expect(window.tasks[0].events.map(\.body) == ["yesterday evening"])
}

@MainActor
@Test("§10.1 clock skew: a future lastStandupAt yields an empty, non-inverted window")
func aFutureLastStandupYieldsAnEmptyWindow() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("carried over", in: fixture.alpha, status: .inProgress)
    try fixture.event("real work", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin.addingTimeInterval(600), on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.start == window.end)
    #expect(window.tasks[0].events.isEmpty, "no events, but the open task still reports")
    #expect(window.tasks.count == 1)
}

@MainActor
@Test("D17: cadence travels with the window")
func cadenceTravelsWithTheWindow() throws {
    let fixture = try ReportFixture()
    let biweekly = Project(
        name: "EM sync", colorHex: "#778899", reportCadence: .periodic,
        modifiedAt: ReportFixture.origin)
    fixture.context.insert(biweekly)
    try fixture.context.save()

    let window = try fixture.gatherer(nowOffset: 0).gather(for: biweekly)

    #expect(window.cadence == .periodic)
}

@MainActor
@Test("a quiet in-progress task is still reported, with no events")
func aQuietOpenTaskSurvives() throws {
    let fixture = try ReportFixture()
    // Set in progress on Friday; nothing said over the weekend. FR-4's "Today"
    // section is about exactly this task.
    try fixture.task("carried over", in: fixture.alpha, status: .inProgress)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.count == 1)
    #expect(window.tasks[0].title == "carried over")
    #expect(window.tasks[0].events.isEmpty)
}

@MainActor
@Test("a quiet blocked task is still reported")
func aQuietBlockedTaskSurvives() throws {
    let fixture = try ReportFixture()
    try fixture.task("waiting on infra", in: fixture.alpha, status: .blocked)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.map(\.title) == ["waiting on infra"])
}

@MainActor
@Test("a quiet finished task is dropped")
func aQuietFinishedTaskIsDropped() throws {
    let fixture = try ReportFixture()
    try fixture.task("shipped last month", in: fixture.alpha, status: .done)
    try fixture.task("not started", in: fixture.alpha, status: .todo)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.isEmpty)
}

@MainActor
@Test("a finished task that moved during the window is reported")
func aTaskCompletedInsideTheWindowIsReported() throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("shipped this morning", in: fixture.alpha, status: .done)
    try fixture.event("TODO → DONE", on: task, at: 60, kind: .statusChanged)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.map(\.title) == ["shipped this morning"])
}

@MainActor
@Test("tasks are ordered by createdAt, not by whatever the fetch returns")
func tasksAreOrderedByCreatedAt() throws {
    let fixture = try ReportFixture()
    // Inserted newest-first, deliberately. A test that inserted them in the
    // expected order would pass against no sort at all: SwiftData returns
    // insertion order here, so the two would agree and the assertion would be
    // measuring nothing. Making insertion order disagree with the sort key is
    // what gives this test the power to fail.
    for index in (0..<6).reversed() {
        try fixture.task(
            "task \(index)", in: fixture.alpha, status: .inProgress,
            createdAt: ReportFixture.origin.addingTimeInterval(Double(index)))
    }
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)

    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    #expect(window.tasks.map(\.title) == (0..<6).map { "task \($0)" })
}

@MainActor
@Test("tasks created in the same instant are ordered by id, in both directions")
func tasksCreatedTogetherAreTieBrokenById() throws {
    let fixture = try ReportFixture()
    let earlier = try fixture.task(
        "a", in: fixture.alpha, createdAt: ReportFixture.origin)
    let later = try fixture.task(
        "b", in: fixture.alpha, createdAt: ReportFixture.origin)

    // Asserted on the comparator, not on a gathered order: at the sizes D18
    // permits, `sorted(by:)` is stable in practice, so an output-order test
    // would pass just as well with no tie-break at all.
    let (low, high) =
        earlier.id.uuidString < later.id.uuidString ? (earlier, later) : (later, earlier)

    #expect(ReportGatherer.precedes(low, high))
    #expect(ReportGatherer.precedes(high, low) == false)
}
