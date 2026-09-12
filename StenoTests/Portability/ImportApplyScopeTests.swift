import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// A save that fails, local to this file — `ImportRejectionTests` has its own.
private struct ApplyFailure: Error {}

/// What `apply` is allowed to touch, and when it is allowed to touch anything.
///
/// Every test here covers a defect found in review of PR #29. They share a
/// shape: the suite was green, and the behaviour was wrong in a way that no
/// existing assertion could see — because the round-trip tests compare
/// **wire-normalized** snapshots, and every one of these defects is invisible at
/// that precision.

/// A store whose timestamps came from the app's own clock, not from a file.
@MainActor
private func fullPrecisionStore() throws -> ExportFixture {
    let fixture = try ExportFixture()
    let project = try fixture.project(
        "Payments", lastStandupAt: nil, modifiedAt: ExportFixture.at(10.481_726_3))
    let task = try fixture.task(
        "Fix the retry handler", in: project, createdAt: ExportFixture.at(20.301_59))
    try fixture.event("repro'd the race", on: task, at: ExportFixture.at(40.717_28))
    return fixture
}

@MainActor
@Test("an empty plan writes nothing and posts nothing")
func anEmptyPlanIsTrulyANoOp() throws {
    let fixture = try fullPrecisionStore()
    let data = try fixture.encoder(includingCachedData: true).encode()
    let counter = WriteCounter()

    let service = ImportService(context: fixture.context)
    let plan = try service.plan(data)
    #expect(plan.isEmpty)

    try service.apply(plan)

    // It used to reapply every merged row, save, and post — so importing a file
    // that changes nothing made every observer reload, and would have dirtied
    // the store enough for M2.5-05's auto-export to fire.
    #expect(counter.posts == 0)
}

@MainActor
@Test("an unchanged row keeps its full-precision timestamps")
func anUnchangedRowIsNotQuantized() throws {
    // A file that adds one new project, so the plan is **not** empty and the
    // early return does not cover this. Every pre-existing row is counted as
    // unchanged and must therefore not be written.
    let fixture = try fullPrecisionStore()
    let task = try #require(try fixture.context.fetch(FetchDescriptor<TaskItem>()).first)
    let createdAt = task.createdAt

    let incoming = try ExportFixture()
    try incoming.project("Somewhere else", modifiedAt: ExportFixture.at(70.5))
    let data = try incoming.encoder(includingCachedData: true).encode()

    let service = ImportService(context: fixture.context)
    let plan = try service.plan(data)
    #expect(plan.projects.inserted == 1)
    #expect(plan.tasks.unchanged == 1)
    #expect(plan.writes.tasks.isEmpty)

    try service.apply(plan)

    // `apply` used to write every merged row, quantizing this to `.302`. The
    // round-trip tests compare wire-normalized snapshots, so they cannot see it:
    // both sides round to the same string either way.
    #expect(task.createdAt == createdAt)
    #expect(task.createdAt != ExportDocument.wireString(createdAt).asWireDate)
}

@MainActor
@Test("a plan is refused once the store has moved under it")
func aStalePlanIsRefused() throws {
    let fixture = try fullPrecisionStore()
    let incoming = try ExportFixture()
    try incoming.project("Somewhere else", modifiedAt: ExportFixture.at(70.5))
    let data = try incoming.encoder(includingCachedData: true).encode()

    let service = ImportService(context: fixture.context)
    let plan = try service.plan(data)

    // The user captures something while the preview is open.
    let project = try #require(try fixture.context.fetch(FetchDescriptor<Project>()).first)
    try fixture.task("captured while previewing", in: project, createdAt: ExportFixture.at(80))

    // Applying now would both mis-describe the result and resolve the newer rows
    // against a merge that never saw them.
    #expect(throws: ImportError.storeChanged) { try service.apply(plan) }

    // Re-planning is the recovery, and it works.
    let fresh = try service.plan(data)
    try service.apply(fresh)
    #expect(try fixture.context.fetch(FetchDescriptor<Project>()).count == 2)
}

@MainActor
@Test("an existing task's creation time is never rewritten by an import")
func anExistingTasksCreationTimeIsNeverRewritten() throws {
    // **`createdAt` is immutable, and writing it back was quantizing it.** The
    // merge compares the *wire-normalized* local snapshot, so the record it
    // resolves carries a rounded `createdAt` while the live row holds the full
    // precision its own clock produced. `applyImported` wrote that rounded value
    // back — so any unrelated remote change that made the row writable, a title
    // or an archive flag, silently moved the task's creation time.
    //
    // The write-set filter does not cover this: the row genuinely *is* being
    // updated. Only not writing the field does.
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try fixture.task(
        "Fix the retry handler", in: project, createdAt: ExportFixture.at(20.301_59))
    let createdAt = task.createdAt

    // A file that renames the same task, later than the local copy.
    let source = try ExportFixture()
    let sourceProject = try source.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: project.id)
    let sourceTask = try source.task(
        "Fix the retry handler", in: sourceProject, createdAt: ExportFixture.at(20.301_59))
    sourceTask.rename(to: "renamed on the other Mac", at: ExportFixture.at(90))
    try source.context.save()

    let document = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try source.encoder(includingCachedData: true).encode())
    let remote = try #require(document.tasks.first)
    let retitled = ExportedTask(
        id: task.id, title: remote.title, projectID: project.id, status: remote.status,
        createdAt: remote.createdAt, statusChangedAt: remote.statusChangedAt,
        completedAt: remote.completedAt, isArchived: remote.isArchived,
        modifiedAt: remote.modifiedAt)
    let file = ExportDocument(
        schemaVersion: document.schemaVersion, exportedAt: document.exportedAt,
        exportedBy: document.exportedBy, includesCachedExternalData: true,
        projects: document.projects.map {
            ExportedProject(
                id: project.id, name: $0.name, colorHex: $0.colorHex,
                jiraProjectKeys: $0.jiraProjectKeys, isArchived: $0.isArchived,
                sortOrder: $0.sortOrder, lastStandupAt: $0.lastStandupAt,
                reportCadence: $0.reportCadence, staleThresholdDays: $0.staleThresholdDays,
                modifiedAt: $0.modifiedAt)
        },
        tasks: [retitled], events: [], sourceRefs: [], reports: [])

    let service = ImportService(context: fixture.context)
    let plan = try service.plan(try ExportDocument.encoder().encode(file))
    #expect(plan.tasks.updated == 1)
    try service.apply(plan)

    // **Refetched through a fresh context, and both halves of that matter.**
    // `apply` now stages its writes in a scratch context, so the instance held
    // above is deliberately not updated — the caller learns through
    // `.stenoDidWrite` and reloads. And a fetch through `fixture.context` would
    // hand back that same stale instance rather than what landed, so it has to
    // be a context that has not seen it.
    let fresh = ModelContext(fixture.container)
    let reloaded = try #require(try fresh.fetch(FetchDescriptor<TaskItem>()).first)

    #expect(reloaded.title == "renamed on the other Mac")
    #expect(reloaded.createdAt == createdAt)
}

@MainActor
@Test("a failed save leaves no imported value on a live model instance")
func aFailedSaveLeavesLiveObjectsUntouched() throws {
    // **`rollback()` restores the store, not the objects.** That is pinned for
    // the services in `StatusServiceTests`, and it is why `apply` stages its
    // writes in a scratch context: a save failing partway used to return with
    // the caller's own `Project` holding the imported name, so the UI could show
    // it as imported and any later write to that object would persist it —
    // §10.4's "nothing was changed", violated after the error was reported.
    let fixture = try ExportFixture()
    let project = try fixture.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: UUID())
    let originalName = project.name

    let source = try ExportFixture()
    let renamed = try source.project(
        "renamed on the other Mac", modifiedAt: ExportFixture.at(90), id: project.id)
    _ = renamed
    let data = try source.encoder(includingCachedData: true).encode()

    let service = ImportService(context: fixture.context, save: { _ in throw ApplyFailure() })
    let plan = try service.plan(data)
    #expect(plan.projects.updated == 1)
    #expect(throws: ImportError.self) { try service.apply(plan) }

    // The instance the caller holds never saw the import.
    #expect(project.name == originalName)

    // And neither did the store, checked through a context of its own after a
    // later successful save.
    try fixture.context.save()
    let fresh = ModelContext(fixture.container)
    let stored = try #require(try fresh.fetch(FetchDescriptor<Project>()).first)
    #expect(stored.name == originalName)
}

@MainActor
@Test("a project's stand-up clock is not quantized by an unrelated change")
func aProjectClockIsNotQuantizedByAnUnrelatedChange() throws {
    // Same class as the task's `createdAt`: the merge resolves against
    // wire-normalized snapshots, so writing its resolution back drags a live
    // full-precision clock down to the millisecond as collateral. `ReportGatherer`
    // compares this value against a closed window boundary, so the two Macs would
    // disagree about whether an event in that sub-millisecond interval is in the
    // next report.
    // The clock has to be *derivable*, or D-099 repairs it to nil and the test
    // measures the wrong thing: a project carrying a stand-up time with no report
    // behind it is a store the app cannot produce. Both sides therefore hold the
    // report the clock comes from.
    let clock = ExportFixture.at(50.481_726_3)
    let reportID = UUID()
    let projectID = UUID()

    let fixture = try ExportFixture()
    let project = try fixture.project(
        "Payments", lastStandupAt: clock, modifiedAt: ExportFixture.at(10), id: projectID)
    try fixture.report(
        for: project, generatedAt: clock, windowStart: ExportFixture.at(0), windowEnd: clock,
        id: reportID)

    let source = try ExportFixture()
    let remote = try source.project(
        "renamed on the other Mac", lastStandupAt: clock, modifiedAt: ExportFixture.at(90),
        id: projectID)
    try source.report(
        for: remote, generatedAt: clock, windowStart: ExportFixture.at(0), windowEnd: clock,
        id: reportID)
    let data = try source.encoder(includingCachedData: true).encode()

    let service = ImportService(context: fixture.context)
    try service.apply(service.plan(data))

    let fresh = ModelContext(fixture.container)
    let stored = try #require(try fresh.fetch(FetchDescriptor<Project>()).first)

    #expect(stored.name == "renamed on the other Mac")
    #expect(stored.lastStandupAt == clock)
}
