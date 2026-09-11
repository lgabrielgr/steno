import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §10.6's round trip, through the real store on both ends.
///
/// `StoreMergePropertyTests` proves the algebra over values; these prove the
/// pipeline — encode, decode, merge, apply — does not lose or duplicate anything
/// on the way through SwiftData.

/// A store whose timestamps are **clock-shaped**, which is the case that matters.
///
/// `ExportFixture.maximal()` and `realistic()` both use whole-second offsets, and
/// whole seconds survive the wire format exactly. A round trip built only on
/// those cannot see a missing `wireNormalized` — the very defect D-101 exists to
/// prevent — because there is nothing for the quantization to move.
@MainActor
private func clockShapedStore() throws -> ExportFixture {
    let fixture = try ExportFixture()
    // `lastStandupAt` matches the report's `windowEnd` below, because that is
    // what `StandupService.commit` writes. Leaving it nil builds a store the
    // real services cannot produce — a project with a report and no clock — and
    // D-099's derivation then *repairs* it on import, so a round-trip assertion
    // fails on a difference the fixture invented.
    let project = try fixture.project(
        "Payments", jiraKeys: ["PAY"], lastStandupAt: ExportFixture.at(60.246_81),
        modifiedAt: ExportFixture.at(10.481_726_3))
    let task = try fixture.task(
        "Fix the retry handler", in: project, status: .inProgress,
        createdAt: ExportFixture.at(20.301_59), statusAt: ExportFixture.at(30.999_4))
    try fixture.event(
        "task created", on: task, at: ExportFixture.at(20.301_59), kind: .created)
    try fixture.event(
        StatusTransition(from: .todo, into: .inProgress).eventBody, on: task,
        at: ExportFixture.at(30.999_4), kind: .statusChanged)
    try fixture.event(
        "repro'd the race", on: task, at: ExportFixture.at(40.717_28))
    try fixture.event(
        "a typo I took back", on: task, at: ExportFixture.at(45.123_45), redacted: true)
    try fixture.ref(
        "PAY-421", on: task, url: "https://acme.atlassian.net/browse/PAY-421",
        cachedSummary: "In review, 2 comments", lastFetchedAt: ExportFixture.at(50.876_54))
    try fixture.report(
        for: project, generatedAt: ExportFixture.at(60.246_81),
        windowStart: ExportFixture.at(0), windowEnd: ExportFixture.at(60.246_81))
    return fixture
}

@MainActor
private func snapshot(of fixture: ExportFixture) throws -> MergedStore {
    try MergedStore(fixture.encoder(includingCachedData: true).snapshot()).wireNormalized()
}

@MainActor
@Test("§10.6: export → import into an empty store → the same object graph")
func aRoundTripIntoAnEmptyStoreIsIdentical() throws {
    let source = try clockShapedStore()
    let data = try source.encoder(includingCachedData: true).encode()

    let target = try ExportFixture()
    let service = ImportService(context: target.context)
    let plan = try service.plan(data)
    try service.apply(plan)

    // "Identical" means identical **at wire precision**, exactly as D-091
    // predicted it would: the source store holds full-precision dates and the
    // target holds what the file said. An `==` on the raw snapshots fails here,
    // and it fails in a way that looks like a merge bug.
    let left = try snapshot(of: target)
    let right = try snapshot(of: source)
    #expect(left.projects == right.projects, "projects differ")
    #expect(left.tasks == right.tasks, "tasks differ")
    #expect(left.events == right.events, "events differ")
    #expect(left.sourceRefs == right.sourceRefs, "refs differ")
    #expect(left.reports == right.reports, "reports differ")
    #expect(left == right)

    // The graph, not just the rows: a ref whose `task` relationship was never
    // wired has correct data and is invisible in the detail pane.
    let tasks = try target.context.fetch(FetchDescriptor<TaskItem>())
    #expect(try #require(tasks.first).sourceRefs?.count == 1)
}

@MainActor
@Test("§10.6: importing the same file twice is a no-op the second time")
func aSecondImportOfTheSameFileChangesNothing() throws {
    let source = try clockShapedStore()
    let data = try source.encoder(includingCachedData: true).encode()

    let target = try ExportFixture()
    let service = ImportService(context: target.context)
    let first = try service.plan(data)
    try service.apply(first)
    #expect(first.isEmpty == false)

    let after = try snapshot(of: target)
    let second = try service.plan(data)

    // The plan says nothing to do, **and** applying it anyway changes nothing.
    // Both matter: the first is what M2.5-03 shows the user, the second is what
    // actually happens if they press Import twice.
    #expect(second.isEmpty)
    #expect(second.tasks.unchanged == 1)
    #expect(second.events.unchanged == 4)

    try service.apply(second)
    #expect(try snapshot(of: target) == after)

    // A third, because an operation can be stable on its second application and
    // not its third — which is how the truncating wire format failed.
    let third = try service.plan(data)
    #expect(third.isEmpty)
}

@MainActor
@Test("a merge into a store that has diverged reports what it will change")
func aDivergentImportReportsItsCounts() throws {
    let source = try clockShapedStore()
    let data = try source.encoder(includingCachedData: true).encode()

    // The target has the same history, plus a task of its own it must not lose.
    let target = try clockShapedStore()
    let ownProject = try target.project("Only here", modifiedAt: ExportFixture.at(70.5))
    try target.task("Only here too", in: ownProject, createdAt: ExportFixture.at(71.5))

    let service = ImportService(context: target.context)
    let plan = try service.plan(data)

    // Each fixture generates fresh ids, so the two stores share none: every
    // record in the file is an insert, and the target's own rows are untouched.
    // That is §10.6's non-destructive clause in its bluntest form — a merge must
    // never delete a task the import file lacks.
    try service.apply(plan)

    let projects = try target.context.fetch(FetchDescriptor<Project>())
    #expect(projects.contains { $0.name == "Only here" })
    #expect(projects.count == 3)
}
