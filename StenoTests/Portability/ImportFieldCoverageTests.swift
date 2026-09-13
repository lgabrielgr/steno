import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// Every field of an imported record actually reaches the row.
///
/// **Asserted by re-deriving the DTO from the model, not by reading
/// `applyImported`.** If that method forgets a field, the row keeps its old
/// value, the re-derived record differs from the one that went in, and this
/// fails. A test that listed the fields it expected would need the same
/// maintenance as the method it is guarding, and would be forgotten in the same
/// commit.
///
/// This closes the loop with D-095's `everyModelFieldIsAccountedFor`, which
/// asserts the other direction: that every stored property of every `@Model`
/// appears in its DTO. Together they mean a field added to a model is carried by
/// the export *and* restored by the import, or a test goes red.
///
/// **Every "before" value differs from its "after".** A field left at a value
/// that happens to match would make the assertion pass while the write was
/// missing, which is the failure this exists to catch.

@MainActor
@Test("applyImported writes every field of a project")
func applyImportedWritesEveryProjectField() throws {
    let fixture = try ExportFixture()
    let identifier = UUID()
    let project = try fixture.project(
        "before", colorHex: "#000000", jiraKeys: ["BEFORE"], sortOrder: 1, cadence: .daily,
        staleThresholdDays: 1, lastStandupAt: ExportFixture.at(1), archived: true,
        modifiedAt: ExportFixture.at(1), id: identifier)

    let record = ExportedProject(
        id: identifier, name: "after", colorHex: "#FFFFFF", jiraProjectKeys: ["AFTER"],
        isArchived: false, sortOrder: 2, lastStandupAt: ExportFixture.at(2),
        reportCadence: .periodic, staleThresholdDays: 2, modifiedAt: ExportFixture.at(2))

    project.applyImported(record)

    #expect(ExportedProject(project) == record)
}

@MainActor
@Test("applyImported writes every field of a task")
func applyImportedWritesEveryTaskField() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    let other = try fixture.project("Platform")
    let task = try fixture.task(
        "before", in: project, status: .todo, createdAt: ExportFixture.at(1),
        statusAt: ExportFixture.at(1))

    // `createdAt` matches the row's own, because `applyImported` deliberately
    // does not write it — see `anExistingTasksCreationTimeIsNeverRewritten`.
    // Every other field differs, which is what makes a dropped write visible.
    let record = ExportedTask(
        id: task.id, title: "after", projectID: other.id, status: .done,
        createdAt: ExportFixture.at(1), statusChangedAt: ExportFixture.at(4),
        completedAt: ExportFixture.at(4), isArchived: true, modifiedAt: ExportFixture.at(5))

    task.applyImported(record)

    #expect(ExportedTask(task) == record)
}

@MainActor
@Test("applyImported does not route status through setStatus's guard")
func applyImportedBypassesTheStatusGuard() throws {
    // `setStatus` returns early when the status is unchanged, and derives
    // `completedAt` from the transition it thinks it is making. The merge has
    // already resolved all three fields together from the log, so a resolution
    // that only *looks* like a no-op — same status, later `statusChangedAt` —
    // must still land.
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    let task = try fixture.task(
        "unchanged status", in: project, status: .done, createdAt: ExportFixture.at(1),
        statusAt: ExportFixture.at(1))

    let record = ExportedTask(
        id: task.id, title: "unchanged status", projectID: project.id, status: .done,
        createdAt: ExportFixture.at(1), statusChangedAt: ExportFixture.at(9),
        completedAt: ExportFixture.at(9), isArchived: false, modifiedAt: ExportFixture.at(1))

    task.applyImported(record)

    #expect(task.statusChangedAt == ExportFixture.at(9))
    #expect(task.completedAt == ExportFixture.at(9))
}

// MARK: - The three types with no `applyImported`

/// `Event`, `SourceRef` and `StandupReport` are inserted through their
/// initialisers and never rewritten, so there is no `applyImported` for the
/// tests above to guard. Their equivalent is this: insert through the real
/// service, re-derive the DTO from the row, and compare.
///
/// **Found by auditing the five record paths as a set.** Mutation testing showed
/// `Event.payload`, `StandupReport.modelUsed` and `StandupReport.wasAIGenerated`
/// could each be dropped on insert with the whole suite still green — the
/// round-trip fixture left all three at their empty values, so a dropped write
/// and a nil field were indistinguishable. That is D-095's lesson arriving on
/// the import side: a field with no fixture value is never anything *but* nil.

@MainActor
private func importedStore(from source: ExportFixture) throws -> ExportFixture {
    let data = try source.encoder(includingCachedData: true).encode()
    let target = try ExportFixture()
    let service = ImportService(context: target.context)
    try service.apply(service.plan(data))
    return target
}

@MainActor
@Test("inserting an event preserves every field, payload included")
func insertingAnEventPreservesEveryField() throws {
    let source = try ExportFixture()
    let project = try source.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try source.task("Fix the retry handler", in: project)
    try source.event(
        "waiting on infra", on: task, at: ExportFixture.at(20), kind: .blockedReason,
        payload: Data("{\"ticket\":\"PAY-421\"}".utf8), redacted: true)

    let target = try importedStore(from: source)
    let imported = try #require(try target.context.fetch(FetchDescriptor<Event>()).first)
    let original = try #require(try source.context.fetch(FetchDescriptor<Event>()).first)

    #expect(ExportedEvent(imported) == ExportedEvent(original))
}

@MainActor
@Test("inserting a report preserves every field, including the AI provenance")
func insertingAReportPreservesEveryField() throws {
    let source = try ExportFixture()
    let project = try source.project("Payments", modifiedAt: ExportFixture.at(10))
    try source.report(
        for: project, generatedAt: ExportFixture.at(30), windowStart: ExportFixture.at(10),
        windowEnd: ExportFixture.at(30), body: "*Yesterday*\n- shipped it",
        wasAIGenerated: true, modelUsed: "claude-opus-5", undone: true)

    let target = try importedStore(from: source)
    let imported = try #require(try target.context.fetch(FetchDescriptor<StandupReport>()).first)
    let original = try #require(try source.context.fetch(FetchDescriptor<StandupReport>()).first)

    #expect(ExportedReport(imported) == ExportedReport(original))
}

@MainActor
@Test("inserting a source ref preserves every field, cache included")
func insertingARefPreservesEveryField() throws {
    let source = try ExportFixture()
    let project = try source.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try source.task("Fix the retry handler", in: project)
    try source.ref(
        "acme/api#421", on: task, kind: .githubPR,
        url: "https://github.com/acme/api/pull/421", cachedSummary: "In review, 2 comments",
        lastFetchedAt: ExportFixture.at(40))

    let target = try importedStore(from: source)
    let imported = try #require(try target.context.fetch(FetchDescriptor<SourceRef>()).first)
    let original = try #require(try source.context.fetch(FetchDescriptor<SourceRef>()).first)

    #expect(
        ExportedSourceRef(imported, includingCachedData: true)
            == ExportedSourceRef(original, includingCachedData: true))
}
