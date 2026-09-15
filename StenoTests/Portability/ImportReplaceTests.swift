import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// §10.1's Replace: the file becomes the whole store.
///
/// The properties here are the ones a merge test cannot state, because merge is
/// a union and can never remove anything. Every one of them is about deletion.

/// Two stores that disagree in both directions: each has a project, a task and
/// an event the other lacks, plus one task they share whose title differs.
@MainActor
private func divergentStores() throws -> (local: ExportFixture, file: ExportFixture) {
    let sharedProject = UUID()
    let sharedTask = UUID()

    let local = try ExportFixture()
    let keptLocally = try local.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: sharedProject)
    let sharedLocally = try local.task(
        "Fix the retry handler", in: keptLocally, createdAt: ExportFixture.at(20),
        id: sharedTask)
    // **Stamped explicitly, on both sides.** `ExportFixture.task` has no
    // `modifiedAt` parameter, so an unstamped task carries a creation-time
    // `Date.now` — and two of those are 2026 values that no `at(...)` offset
    // (2023) can outrank, while a *tie* between them makes
    // `resolveGovernedTask` refuse two differing titles outright. Renaming with
    // an explicit instant removes the ambient clock from the fixture entirely
    // and makes the file the later edit, deterministically.
    sharedLocally.rename(to: "Fix the retry handler", at: ExportFixture.at(21))
    try local.context.save()
    let localOnlyProject = try local.project("Local only", modifiedAt: ExportFixture.at(30))
    let localOnlyTask = try local.task(
        "Only on this Mac", in: localOnlyProject, createdAt: ExportFixture.at(40))
    try local.event("local note", on: localOnlyTask, at: ExportFixture.at(50))
    try local.ref("PAY-1", on: localOnlyTask)
    try local.report(for: localOnlyProject, generatedAt: ExportFixture.at(60))

    let file = try ExportFixture()
    let sharedInFile = try file.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: sharedProject)
    // The shared task, both renamed and moved to IN-PROGRESS on the other
    // machine — an `updated` row rather than an inserted or deleted one, so all
    // three categories are exercised at once, and both of §10.1's task rules
    // are in play: the title resolves by later `modifiedAt`, the status by
    // derivation from the log (D-100).
    let movedInFile = try file.task(
        "Fix the retry handler", in: sharedInFile, status: .inProgress,
        createdAt: ExportFixture.at(20), statusAt: ExportFixture.at(25), id: sharedTask)
    movedInFile.rename(to: "Fix the retry handler properly", at: ExportFixture.at(26))
    try file.context.save()
    // The event the derivation actually reads. Without it the file's `status`
    // field would disagree with its own log, and the merge would install the
    // log's answer — so the file would not be what a Replace produces, and
    // `after == expected` below would fail for a reason that is not a bug.
    try file.event(
        StatusTransition(from: .todo, into: .inProgress).eventBody, on: movedInFile,
        at: ExportFixture.at(25), kind: .statusChanged)
    let fileOnlyProject = try file.project("File only", modifiedAt: ExportFixture.at(70))
    let fileOnlyTask = try file.task(
        "Only in the file", in: fileOnlyProject, createdAt: ExportFixture.at(80))
    try file.event("file note", on: fileOnlyTask, at: ExportFixture.at(90))

    return (local, file)
}

/// The store as a merge would see it: wire precision, cached data included.
@MainActor
private func snapshot(_ context: ModelContext) throws -> MergedStore {
    try MergedStore(
        try ExportEncoder(
            context: context, includesCachedExternalData: true,
            exportedBy: "steno/test (macOS)"
        ).snapshot()
    ).wireNormalized()
}

@MainActor
@Test("replace deletes every local record the file lacks")
func replaceDeletesLocalOnlyRecords() throws {
    let (local, file) = try divergentStores()
    let data = try file.encoder(includingCachedData: true).encode()

    let service = ImportService(context: local.context)
    let plan = try service.plan(data, mode: .replace)

    // One project, one task, one event, one ref, one report exist only locally.
    #expect(plan.deletions.projects.count == 1)
    #expect(plan.deletions.tasks.count == 1)
    #expect(plan.deletions.events.count == 1)
    #expect(plan.deletions.sourceRefs.count == 1)
    #expect(plan.deletions.reports.count == 1)

    try service.apply(plan, backupWith: try replaceBackupWriter(for: local.context))

    let after = try snapshot(local.context)
    #expect(after.projects.count == 2)
    #expect(!after.projects.contains { $0.name == "Local only" })
    #expect(!after.tasks.contains { $0.title == "Only on this Mac" })
    #expect(after.events.allSatisfy { $0.body != "local note" })
    #expect(after.sourceRefs.isEmpty)
    #expect(after.reports.isEmpty)
}

@MainActor
@Test("after replace the store is the file — checked in both directions")
func replaceMakesTheStoreEqualTheFile() throws {
    let (local, file) = try divergentStores()
    let data = try file.encoder(includingCachedData: true).encode()

    let service = ImportService(context: local.context)
    try service.apply(
        try service.plan(data, mode: .replace),
        backupWith: try replaceBackupWriter(for: local.context))

    let after = try snapshot(local.context)
    let expected = try MergedStore(
        try ExportDocument.decoder().decode(ExportDocument.self, from: data)
    ).wireNormalized()

    // **Both directions, and the second one is the point.** "Every row in the
    // store matches the file" is true of a Replace that forgot to delete
    // anything — the surviving local rows simply are not looked at. Comparing
    // the id sets in both directions is what sees them.
    #expect(Set(after.projects.map(\.id)) == Set(expected.projects.map(\.id)))
    #expect(Set(after.tasks.map(\.id)) == Set(expected.tasks.map(\.id)))
    #expect(Set(after.events.map(\.id)) == Set(expected.events.map(\.id)))
    #expect(Set(after.sourceRefs.map(\.id)) == Set(expected.sourceRefs.map(\.id)))
    #expect(Set(after.reports.map(\.id)) == Set(expected.reports.map(\.id)))

    // And the values, not only the identities: a replace that kept the local
    // copy of a shared row would pass every set comparison above. The shared
    // task is unstarted here and in progress in the file, so this is the
    // assertion that sees it. (Spelled out rather than using the status names,
    // because SwiftLint's `todo` rule treats the literal word as an unresolved
    // marker and `--strict` makes that a build failure.)
    #expect(after.tasks == expected.tasks)
    #expect(after.tasks.contains { $0.id == expected.tasks.first?.id && $0.status == .inProgress })
}

@MainActor
@Test("a merge never deletes anything, over stores that diverge in both directions")
func mergeNeverDeletes() throws {
    let (local, file) = try divergentStores()
    let data = try file.encoder(includingCachedData: true).encode()

    let plan = try ImportService(context: local.context).plan(data, mode: .merge)

    // §10.1's "non-destructive by default", as a value rather than a promise.
    // The merged store is a union of both sides, so this set cannot be
    // populated — which is also what makes the append-only rule (§3.3) hold for
    // every path except the one Replace opens.
    #expect(plan.deletions.isEmpty)
}

@MainActor
@Test("replace still works when this Mac's own store is malformed")
func replaceSkipsLocalShapeValidation() throws {
    let (local, file) = try divergentStores()
    // A task whose project is in neither the file nor the store: local
    // corruption of exactly the kind `validateShape` refuses.
    let orphan = TaskItem(
        id: UUID(), title: "orphan", projectID: UUID(), createdAt: ExportFixture.at(100))
    local.context.insert(orphan)
    try local.context.save()

    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)

    // Merge refuses it, and says the *store* is the problem rather than the
    // file — which is the behaviour M2.5-02 shipped and this must not change.
    #expect(throws: ImportError.self) { try service.plan(data, mode: .merge) }

    // Replace does not, because §10.1 has it exist "for restoring a known-good
    // snapshot" — refusing here would disable the recovery operation in exactly
    // the situation it was built for. The orphan is deleted like any other row
    // the file lacks.
    let plan = try service.plan(data, mode: .replace)
    #expect(plan.deletions.tasks.contains(orphan.id))

    try service.apply(plan, backupWith: try replaceBackupWriter(for: local.context))
    let after = try snapshot(local.context)
    #expect(!after.tasks.contains { $0.title == "orphan" })
}

@MainActor
@Test("replacing with an identical file is a no-op the preview can name")
func replaceWithAnIdenticalFileIsEmpty() throws {
    let local = try ExportFixture()
    let project = try local.project("Payments", modifiedAt: ExportFixture.at(10))
    try local.task("Fix the retry handler", in: project, createdAt: ExportFixture.at(20))

    let data = try local.encoder(includingCachedData: true).encode()
    let plan = try ImportService(context: local.context).plan(data, mode: .replace)

    // Nothing to insert, nothing to update, and — the part `isEmpty` gained for
    // Replace — nothing to delete.
    #expect(plan.deletions.isEmpty)
    #expect(plan.isEmpty)
}

@MainActor
@Test("a replace that only deletes is not mistaken for nothing to do")
func replaceThatOnlyDeletesIsNotEmpty() throws {
    let local = try ExportFixture()
    let project = try local.project("Payments", modifiedAt: ExportFixture.at(10))
    try local.task("Fix the retry handler", in: project, createdAt: ExportFixture.at(20))

    // The file is the same store minus one task, so every surviving record is
    // `unchanged` and the only work is a deletion. Before `isEmpty` counted
    // deletions this plan reported as empty, and `apply` returned early —
    // Replace would have silently done nothing.
    let file = try ExportFixture()
    try file.project("Payments", modifiedAt: ExportFixture.at(10), id: project.id)

    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)
    let plan = try service.plan(data, mode: .replace)

    #expect(!plan.isEmpty)
    try service.apply(plan, backupWith: try replaceBackupWriter(for: local.context))
    #expect(try snapshot(local.context).tasks.isEmpty)
}

@MainActor
@Test("replace removes every physical row sharing a duplicated id")
func replaceRemovesEveryDuplicateRow() throws {
    let (local, file) = try divergentStores()
    // Two physical rows under one id — reachable only because D-107 has Replace
    // skip `validateShape`, which is the whole point of that decision. The
    // deletion went through a `[UUID: Model]` dictionary, so it removed one of
    // these and left the other: a store that is not the file, which is exactly
    // what Replace promises it will be. Raised in review of PR #30.
    let twinID = UUID()
    for index in 0..<2 {
        let twin = TaskItem(
            id: twinID, title: "twin \(index)", projectID: UUID(),
            createdAt: ExportFixture.at(200))
        local.context.insert(twin)
    }
    try local.context.save()

    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)
    let plan = try service.plan(data, mode: .replace)
    #expect(plan.deletions.tasks.contains(twinID))

    try service.apply(plan, backupWith: try replaceBackupWriter(for: local.context))

    let survivors = try local.context.fetch(FetchDescriptor<TaskItem>())
    #expect(!survivors.contains { $0.id == twinID })
}

@MainActor
@Test("apply refuses a replace plan with no backup receipt")
func replaceWithoutABackupIsRefused() throws {
    let (local, file) = try divergentStores()
    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)
    let plan = try service.plan(data, mode: .replace)

    // **§10.1's backup is a property of Replace, not of the GUI.** It lived only
    // in `MainWindowModel.applyImport()`, so the destructive engine itself was
    // unguarded for every other caller — and M2.5-04's `steno import --replace`
    // is exactly such a caller. Raised in review of PR #30.
    #expect(throws: ImportError.backupRequired) { try service.apply(plan) }

    // And nothing was touched on the way to refusing.
    let after = try snapshot(local.context)
    #expect(after.tasks.contains { $0.title == "Only on this Mac" })
}

@MainActor
@Test("a merge still applies with no receipt, because it destroys nothing")
func mergeNeedsNoBackup() throws {
    let (local, file) = try divergentStores()
    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)

    // The guard must not spread to the non-destructive path: a merge cannot
    // delete, so demanding a backup of it would be ceremony with no safety.
    try service.apply(try service.plan(data, mode: .merge))
    #expect(try snapshot(local.context).tasks.count == 3)
}

@MainActor
@Test("the preview counts physical rows, not ids, when a store is malformed")
func theDeletionCountIsPhysicalRows() throws {
    let (local, file) = try divergentStores()
    // Two rows under one id, reachable only because Replace skips
    // `validateShape` (D-107). `deletions` holds one entry per doomed *id*
    // while `delete` removes every row carrying one, so the preview announced
    // "1 task will be deleted" over work that destroyed two — §10.4's
    // under-reporting failure, introduced by the fix for the duplicate-row
    // defect earlier in this same review.
    let twinID = UUID()
    for index in 0..<2 {
        local.context.insert(
            TaskItem(
                id: twinID, title: "twin \(index)", projectID: UUID(),
                createdAt: ExportFixture.at(200)))
    }
    try local.context.save()

    let plan = try ImportService(context: local.context).plan(data(file), mode: .replace)

    // One id, two rows, and the preview must say two.
    #expect(plan.deletions.tasks.count == 2)
    #expect(plan.deletedRows.tasks == 3)
    #expect(
        ImportPreviewSummary.lines(for: plan).contains { $0.contains("3 tasks") })
}

/// The file fixture as bytes — a local shorthand for the test above.
@MainActor
private func data(_ fixture: ExportFixture) throws -> Data {
    try fixture.encoder(includingCachedData: true).encode()
}

@MainActor
@Test("replace overwrites a shared row whose content differs from the file")
func replaceOverwritesSharedRows() throws {
    // One id, two different histories — an event body, a report body, and a
    // ref's identity that disagree between this Mac and the file.
    //
    // **Merge cannot reach this state**: `mergeEvents` refuses two different
    // events sharing an id as `.inconsistentRecord`. Replace merges against an
    // empty base, so that check never runs — and the existing-row branches only
    // flip `isRedacted` / `isUndone` / the cache, leaving the local body in
    // place. The store afterwards was therefore *not* the file, which is the
    // one thing Replace promises. Raised in review of PR #30.
    let sharedEvent = UUID()
    let sharedReport = UUID()
    let sharedRef = UUID()

    let local = try ExportFixture()
    let project = try local.project("Payments", modifiedAt: ExportFixture.at(10), id: UUID())
    let task = try local.task(
        "Fix the retry handler", in: project, createdAt: ExportFixture.at(20), id: UUID())
    try local.event("the local wording", on: task, at: ExportFixture.at(30), id: sharedEvent)
    try local.ref("PAY-1", on: task, id: sharedRef)
    try local.report(
        for: project, generatedAt: ExportFixture.at(40), body: "the local report", id: sharedReport)

    let file = try ExportFixture()
    let fileProject = try file.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: project.id)
    let fileTask = try file.task(
        "Fix the retry handler", in: fileProject, createdAt: ExportFixture.at(20), id: task.id)
    try file.event("the file wording", on: fileTask, at: ExportFixture.at(30), id: sharedEvent)
    try file.ref("PAY-999", on: fileTask, id: sharedRef)
    try file.report(
        for: fileProject, generatedAt: ExportFixture.at(40), body: "the file report",
        id: sharedReport)

    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)
    try service.apply(
        try service.plan(data, mode: .replace),
        backupWith: try replaceBackupWriter(for: local.context))

    let after = try snapshot(local.context)
    #expect(after.events.first?.body == "the file wording")
    #expect(after.reports.first?.markdownBody == "the file report")
    #expect(after.sourceRefs.first?.identifier == "PAY-999")
}
