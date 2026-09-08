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
