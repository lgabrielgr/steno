import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// M2.5-03's first acceptance criterion: "the preview's counts match what the
/// import actually does. A preview that under-reports is worse than no
/// preview."
///
/// **The obvious version of this test is worthless.** Comparing `plan.tasks`
/// against anything `ImportPlan.diff` computed is comparing a value to itself —
/// it would pass with every count hard-coded to zero. What follows derives the
/// same four numbers from the store as it was and the store as it became, by a
/// route that never touches `ImportPlan`, and compares those.

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

/// What actually happened to one record type, computed from two snapshots.
private struct Actual: Equatable {
    var inserted = 0
    var updated = 0
    var unchanged = 0
    var deleted = 0

    init<Element: ExportRecord>(before: [Element], after: [Element]) {
        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, record) in now {
            guard let old = was[id] else {
                inserted += 1
                continue
            }
            if old == record { unchanged += 1 } else { updated += 1 }
        }
        deleted = was.keys.filter { now[$0] == nil }.count
    }

    init(plan counts: ImportPlan.Counts, deletions: Set<UUID>) {
        inserted = counts.inserted
        updated = counts.updated
        unchanged = counts.unchanged
        deleted = deletions.count
    }
}

/// Apply the plan and confirm it described itself accurately, per type.
@MainActor
private func assertPreviewMatchesReality(
    fixtureLocal local: ExportFixture, file: ExportFixture, mode: ImportMode,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = try file.encoder(includingCachedData: true).encode()
    let service = ImportService(context: local.context)
    let plan = try service.plan(data, mode: mode)

    let before = try snapshot(local.context)
    try service.apply(plan)
    let after = try snapshot(local.context)

    #expect(
        Actual(before: before.projects, after: after.projects)
            == Actual(plan: plan.projects, deletions: plan.deletions.projects),
        "projects", sourceLocation: sourceLocation)
    #expect(
        Actual(before: before.tasks, after: after.tasks)
            == Actual(plan: plan.tasks, deletions: plan.deletions.tasks),
        "tasks", sourceLocation: sourceLocation)
    #expect(
        Actual(before: before.events, after: after.events)
            == Actual(plan: plan.events, deletions: plan.deletions.events),
        "events", sourceLocation: sourceLocation)
    #expect(
        Actual(before: before.sourceRefs, after: after.sourceRefs)
            == Actual(plan: plan.sourceRefs, deletions: plan.deletions.sourceRefs),
        "source refs", sourceLocation: sourceLocation)
    #expect(
        Actual(before: before.reports, after: after.reports)
            == Actual(plan: plan.reports, deletions: plan.deletions.reports),
        "reports", sourceLocation: sourceLocation)
}

/// A local store and a file that disagree in every way the merge has a rule
/// for, so all four categories are non-zero on both sides.
@MainActor
private func divergentPair() throws -> (local: ExportFixture, file: ExportFixture) {
    let sharedProject = UUID()
    let sharedTask = UUID()
    let sharedEvent = UUID()

    let local = try ExportFixture()
    let payments = try local.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: sharedProject)
    let shared = try local.task(
        "Fix the retry handler", in: payments, createdAt: ExportFixture.at(20), id: sharedTask)
    // Stamped explicitly so the fixture does not depend on the ambient clock —
    // see `ImportReplaceTests.divergentStores` for the full reasoning.
    shared.rename(to: "Fix the retry handler", at: ExportFixture.at(21))
    try local.context.save()
    // Present on both sides and identical — the `unchanged` category.
    try local.event("repro'd the race", on: shared, at: ExportFixture.at(30), id: sharedEvent)
    let localOnly = try local.project("Local only", modifiedAt: ExportFixture.at(40))
    let localTask = try local.task(
        "Only here", in: localOnly, createdAt: ExportFixture.at(50))
    try local.ref("PAY-9", on: localTask)
    try local.report(for: localOnly, generatedAt: ExportFixture.at(60))

    let file = try ExportFixture()
    let paymentsInFile = try file.project(
        "Payments", modifiedAt: ExportFixture.at(10), id: sharedProject)
    // Renamed and moved to IN-PROGRESS on the other machine, so this is an
    // `updated` task under both of §10.1's rules at once: later `modifiedAt`
    // wins the title, the log decides the status (D-100).
    let sharedInFile = try file.task(
        "Fix the retry handler", in: paymentsInFile, status: .inProgress,
        createdAt: ExportFixture.at(20), statusAt: ExportFixture.at(25), id: sharedTask)
    sharedInFile.rename(to: "Fix the retry handler properly", at: ExportFixture.at(26))
    try file.context.save()
    try file.event(
        StatusTransition(from: .todo, into: .inProgress).eventBody, on: sharedInFile,
        at: ExportFixture.at(25), kind: .statusChanged)
    try file.event("repro'd the race", on: sharedInFile, at: ExportFixture.at(30), id: sharedEvent)
    let fileOnly = try file.project("File only", modifiedAt: ExportFixture.at(70))
    let fileTask = try file.task("Only in the file", in: fileOnly, createdAt: ExportFixture.at(80))
    try file.event("file note", on: fileTask, at: ExportFixture.at(90))
    try file.report(for: fileOnly, generatedAt: ExportFixture.at(100))

    return (local, file)
}

@MainActor
@Test("a merge preview describes exactly what the merge does")
func mergePreviewMatchesReality() throws {
    let (local, file) = try divergentPair()
    try assertPreviewMatchesReality(fixtureLocal: local, file: file, mode: .merge)
}

@MainActor
@Test("a replace preview describes exactly what the replace does")
func replacePreviewMatchesReality() throws {
    let (local, file) = try divergentPair()
    try assertPreviewMatchesReality(fixtureLocal: local, file: file, mode: .replace)
}

@MainActor
@Test("the merge preview's categories are all exercised by the fixture")
func theFixtureIsNotDegenerate() throws {
    // **A guard on the two tests above, not a test of the product.** Every
    // assertion in them is `actual == planned`, which holds trivially when both
    // are zero — a fixture that drifted into producing no updates would leave
    // them green and blind. This fails loudly if that happens.
    let (local, file) = try divergentPair()
    let data = try file.encoder(includingCachedData: true).encode()
    let plan = try ImportService(context: local.context).plan(data, mode: .replace)

    #expect(plan.tasks.inserted > 0)
    #expect(plan.tasks.updated > 0)
    #expect(plan.events.unchanged > 0)
    #expect(!plan.deletions.isEmpty)
}
