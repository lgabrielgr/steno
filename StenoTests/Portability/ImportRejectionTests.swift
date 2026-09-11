import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §10.6: malformed and truncated files are cleanly rejected, store unchanged.
///
/// **"Store unchanged" is asserted through a second `ModelContext` after a later
/// successful save.** Reading back through the same context returns the objects
/// already held rather than what landed, and without a later save that succeeds,
/// "the store is empty" is unfalsifiable — nothing would have been written even
/// if the rollback had done nothing at all.

private struct SaveFailure: Error {}

@MainActor
private func populatedExport() throws -> Data {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try fixture.task("Fix the retry handler", in: project)
    try fixture.event("repro'd the race", on: task, at: ExportFixture.at(20))
    return try fixture.encoder().encode()
}

@MainActor
private func isEmpty(_ container: ModelContainer) throws -> Bool {
    // A second context, deliberately: a fetch through the one that did the work
    // hands back the objects it is still holding.
    let fresh = ModelContext(container)
    return try fresh.fetch(FetchDescriptor<Project>()).isEmpty
        && fresh.fetch(FetchDescriptor<TaskItem>()).isEmpty
        && fresh.fetch(FetchDescriptor<Event>()).isEmpty
}

@MainActor
@Test("bytes that are not JSON are refused")
func bytesThatAreNotJSONAreRefused() throws {
    let target = try ExportFixture()

    #expect(throws: ImportError.self) {
        try ImportService(context: target.context).plan(Data("this is not an export".utf8))
    }
    #expect(try isEmpty(target.container))
}

@MainActor
@Test("a truncated file is refused as malformed, not as an unknown version")
func aTruncatedFileIsRefusedAsMalformed() throws {
    let whole = try populatedExport()
    let half = whole.prefix(whole.count / 2)
    let target = try ExportFixture()

    // The distinction matters to the user: "update Steno" is the wrong advice
    // for a file that was cut in half by a failed copy.
    let error = importError(from: half, into: target)
    guard case .malformed = error else {
        Issue.record("expected .malformed, got \(String(describing: error))")
        return
    }
    #expect(try isEmpty(target.container))
}

@MainActor
@Test("§10.2: an unknown schemaVersion is refused with a clear message")
func anUnknownSchemaVersionIsRefused() throws {
    let target = try ExportFixture()
    let future = Data(
        """
        { "schemaVersion": 99, "exportedAt": "2026-09-11T00:00:00.000Z",
          "exportedBy": "steno/9.0 (macOS)", "includesCachedExternalData": false,
          "projects": [], "tasks": [], "events": [], "sourceRefs": [], "reports": [] }
        """.utf8)

    #expect(throws: ImportError.unsupportedSchemaVersion(found: 99, supported: 1)) {
        try ImportService(context: target.context).plan(future)
    }
    #expect(
        ImportError.unsupportedSchemaVersion(found: 99, supported: 1).message
            .contains("newer version"))
    #expect(try isEmpty(target.container))
}

@MainActor
@Test("a file whose records have lost their parent is refused")
func anOrphanedRecordIsRefused() throws {
    let whole = try populatedExport()
    let document = try ExportDocument.decoder().decode(ExportDocument.self, from: whole)
    // Everything except the tasks: the events and the task's project now point
    // at something that exists in neither the file nor an empty store.
    let trimmed = ExportDocument(
        schemaVersion: document.schemaVersion, exportedAt: document.exportedAt,
        exportedBy: document.exportedBy,
        includesCachedExternalData: document.includesCachedExternalData,
        projects: document.projects, tasks: [], events: document.events,
        sourceRefs: document.sourceRefs, reports: document.reports)
    let data = try ExportDocument.encoder().encode(trimmed)
    let target = try ExportFixture()

    let error = importError(from: data, into: target)
    guard case .danglingReference = error else {
        Issue.record("expected .danglingReference, got \(String(describing: error))")
        return
    }
    #expect(try isEmpty(target.container))
}

@MainActor
@Test("§10.2: the same trimmed file imports where the missing parent exists")
func aTrimmedFileImportsWhereTheParentAlreadyExists() throws {
    // Closure is checked against the file **and the store together**, which is
    // what keeps §10.2's hand-editability promise: trimming a project out of an
    // export must still import on a Mac that already has that project. Checking
    // the file alone would refuse this, and refusing it would make the format's
    // readability a lie.
    let source = try ExportFixture()
    let project = try source.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try source.task("Fix the retry handler", in: project)
    try source.event("repro'd the race", on: task, at: ExportFixture.at(20))
    let whole = try source.encoder().encode()

    let document = try ExportDocument.decoder().decode(ExportDocument.self, from: whole)
    let withoutProjects = ExportDocument(
        schemaVersion: document.schemaVersion, exportedAt: document.exportedAt,
        exportedBy: document.exportedBy,
        includesCachedExternalData: document.includesCachedExternalData,
        projects: [], tasks: document.tasks, events: document.events,
        sourceRefs: document.sourceRefs, reports: document.reports)
    let trimmed = try ExportDocument.encoder().encode(withoutProjects)

    // The same store that produced it already holds the project.
    let plan = try ImportService(context: source.context).plan(trimmed)
    #expect(plan.isEmpty)
}

@MainActor
@Test("a failed save rolls back: nothing from the file reaches the store")
func aFailedSaveRollsBack() throws {
    let data = try populatedExport()
    let target = try ExportFixture()
    let service = ImportService(context: target.context, save: { _ in throw SaveFailure() })

    let plan = try service.plan(data)
    #expect(plan.isEmpty == false)
    #expect(throws: ImportError.self) { try service.apply(plan) }

    // The later successful save is what makes the assertion below falsifiable.
    try target.context.save()
    #expect(try isEmpty(target.container))
}

@MainActor
private func importError(from data: Data, into fixture: ExportFixture) -> ImportError? {
    do {
        _ = try ImportService(context: fixture.context).plan(data)
        return nil
    } catch let error as ImportError {
        return error
    } catch {
        return nil
    }
}

@Test("one id with two different histories is refused, not silently resolved")
func aDivergentLineageIsRefused() throws {
    // Vanishingly unlikely — it takes a UUID collision or a hand-edited file —
    // and the alternative is worse than a refusal: picking a winner discards the
    // other event's content, and §3.3 has no recovery path for that.
    let project = MergeFixture.project(1)
    let task = MergeFixture.task(2)
    let mine = try MergeFixture.store(
        projects: [project], tasks: [task],
        events: [MergeFixture.event(3, at: MergeFixture.at(20), body: "what I wrote")])
    let theirs = try MergeFixture.store(
        projects: [project], tasks: [task],
        events: [MergeFixture.event(3, at: MergeFixture.at(20), body: "something else")])

    #expect(throws: ImportError.self) { try StoreMerge.merge(local: mine, incoming: theirs) }
    #expect(throws: ImportError.self) { try StoreMerge.merge(local: theirs, incoming: mine) }
}
