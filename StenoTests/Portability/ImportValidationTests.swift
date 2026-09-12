import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// What the import refuses, and where the refusal happens.
///
/// Split from `ImportApplyScopeTests` when that file passed SwiftLint's 400-line
/// cap. The division is by question: that file asks what `apply` is allowed to
/// *touch*, this one asks what the pipeline is allowed to *accept*.
///
/// Several of these exist in pairs — the same rule checked in `ImportReader` and
/// again in `StoreMerge` — because the reader covers files and the merge covers
/// every other caller, and three review rounds found the guard landing in one of
/// the two and not the other.

@MainActor
@Test("a file with two records under one id is refused, not fatal")
func duplicateIdsAreRefusedRatherThanFatal() throws {
    // `Dictionary(uniqueKeysWithValues:)` **traps** on a duplicate key, so this
    // used to terminate the process where §10.4 asks for a clean rejection.
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments", modifiedAt: ExportFixture.at(10))
    try fixture.task("Fix the retry handler", in: project, createdAt: ExportFixture.at(20))
    let data = try fixture.encoder().encode()

    let document = try ExportDocument.decoder().decode(ExportDocument.self, from: data)
    let doubled = ExportDocument(
        schemaVersion: document.schemaVersion, exportedAt: document.exportedAt,
        exportedBy: document.exportedBy,
        includesCachedExternalData: document.includesCachedExternalData,
        projects: document.projects, tasks: document.tasks + document.tasks,
        events: document.events, sourceRefs: document.sourceRefs, reports: document.reports)
    let duplicated = try ExportDocument.encoder().encode(doubled)

    let target = try ExportFixture()
    #expect(throws: ImportError.self) {
        try ImportService(context: target.context).plan(duplicated)
    }
}

@MainActor
@Test("a cached summary with no fetch time is refused, not silently dropped")
func aHalfCachePairIsRefused() throws {
    // §10.2 writes the two together or omits both, and `SourceRef.recordFetch`
    // cannot produce any other state. The applier only records a fetch when it
    // has a date to record it at, so this used to be accepted and then dropped.
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments", modifiedAt: ExportFixture.at(10))
    let task = try fixture.task("Fix the retry handler", in: project)
    try fixture.ref("PAY-421", on: task)
    let document = try ExportDocument.decoder().decode(
        ExportDocument.self, from: try fixture.encoder(includingCachedData: true).encode())

    let ref = try #require(document.sourceRefs.first)
    let halfPair = ExportedSourceRef(
        id: ref.id, taskID: ref.taskID, kind: ref.kind, identifier: ref.identifier, url: ref.url,
        lastFetchedAt: nil, cachedSummary: "a summary with no fetch time")
    let broken = ExportDocument(
        schemaVersion: document.schemaVersion, exportedAt: document.exportedAt,
        exportedBy: document.exportedBy, includesCachedExternalData: true,
        projects: document.projects, tasks: document.tasks, events: document.events,
        sourceRefs: [halfPair], reports: document.reports)

    let target = try ExportFixture()
    #expect(throws: ImportError.self) {
        try ImportService(context: target.context).plan(try ExportDocument.encoder().encode(broken))
    }
}

@Test("§3.4: two refs sharing a dedup key both survive a merge")
func duplicateDedupKeysBothSurvive() throws {
    // D-103: union is by `id`, so two machines that each extracted `PAY-421`
    // onto the same task keep both rows. Collapsing them would converge too, and
    // would make import the only path outside Replace mode that deletes a row.
    let project = MergeFixture.project(1)
    let task = MergeFixture.task(2)
    let mine = try MergeFixture.store(
        projects: [project], tasks: [task],
        refs: [MergeFixture.ref(7, identifier: "PAY-421")])
    let theirs = try MergeFixture.store(
        projects: [project], tasks: [task],
        refs: [MergeFixture.ref(8, identifier: "PAY-421")])

    let forward = try StoreMerge.merge(local: mine, incoming: theirs).store
    let backward = try StoreMerge.merge(local: theirs, incoming: mine).store

    #expect(forward == backward)
    #expect(forward.sourceRefs.count == 2)
    #expect(Set(forward.sourceRefs.map(\.identifier)) == ["PAY-421"])
}

extension String {
    /// This wire string parsed back, for asserting that a value was **not**
    /// quantized. Falls back to `.distantPast`, which no fixture uses, so a
    /// decode failure fails the assertion rather than passing it.
    var asWireDate: Date {
        let json = Data("[\"\(self)\"]".utf8)
        let decoded = try? ExportDocument.decoder().decode([Date].self, from: json)
        return decoded?.first ?? .distantPast
    }
}

@Test("the merge refuses a half cache pair, not only the reader")
func theMergeAlsoRefusesAHalfCachePair() throws {
    // `ImportReader` rejects such a file, but `StoreMerge.merge` takes values
    // and does not know where they came from. Without this the plan would carry
    // a summary that `applyRefs` silently drops, because it records a fetch only
    // when it has a date to record it at — the plan promising something apply
    // does not do.
    let project = MergeFixture.project(1)
    let task = MergeFixture.task(2)
    let clean = try MergeFixture.store(
        projects: [project], tasks: [task], refs: [MergeFixture.ref(7)])
    let halfPair = try MergeFixture.store(
        projects: [project], tasks: [task],
        refs: [MergeFixture.ref(7, cachedSummary: "a summary with no fetch time")])

    #expect(throws: ImportError.self) { try StoreMerge.merge(local: clean, incoming: halfPair) }
    #expect(throws: ImportError.self) { try StoreMerge.merge(local: halfPair, incoming: clean) }

    // **And when it exists on one side only.** The validation used to live inside
    // the collision resolver, which never runs for a ref the other side does not
    // have — so this case walked straight through while the comment above the
    // guard claimed otherwise. Raised in review of #29.
    let unmatched = try MergeFixture.store(
        projects: [project], tasks: [task],
        refs: [MergeFixture.ref(9, cachedSummary: "a summary with no fetch time")])
    let noRefs = try MergeFixture.store(projects: [project], tasks: [task])

    #expect(throws: ImportError.self) { try StoreMerge.merge(local: noRefs, incoming: unmatched) }
    #expect(throws: ImportError.self) { try StoreMerge.merge(local: unmatched, incoming: noRefs) }
}

@Test("a duplicate id in any record type is refused, not silently collapsed")
func duplicateIdsAreRefusedForEveryRecordType() throws {
    // `mergeTasks` and `mergeProjects` refused duplicates from the start, but
    // events, reports and refs went through `union`, which built its map with a
    // plain subscript — so a duplicate in the local array silently overwrote the
    // earlier row, losing a physical record before the immutable-field checks
    // ran. Three of the five types bypassed the guard. Found in review of #29.
    let project = MergeFixture.project(1)
    let task = MergeFixture.task(2)
    let clean = try MergeFixture.store(projects: [project], tasks: [task])

    let doubledEvents = try MergeFixture.store(
        projects: [project], tasks: [task],
        events: [MergeFixture.event(3), MergeFixture.event(3, body: "a different body")])
    let doubledReports = try MergeFixture.store(
        projects: [project], tasks: [task],
        reports: [MergeFixture.report(4), MergeFixture.report(4, body: "different")])
    let doubledRefs = try MergeFixture.store(
        projects: [project], tasks: [task],
        refs: [MergeFixture.ref(5), MergeFixture.ref(5, identifier: "PAY-999")])

    for side in [doubledEvents, doubledReports, doubledRefs] {
        // Both directions: the defect was on the `local` side specifically, so
        // only asserting the incoming side would have missed it entirely.
        #expect(throws: ImportError.self) { try StoreMerge.merge(local: side, incoming: clean) }
        #expect(throws: ImportError.self) { try StoreMerge.merge(local: clean, incoming: side) }
    }
}

@MainActor
@Test("a locally duplicated store is refused cleanly, not fatally")
func aDuplicateRowInTheStoreIsRefusedCleanly() throws {
    // §6 forbids `@Attribute(.unique)`, so nothing makes our `id` field unique in
    // the store itself, and a store holding two rows under one id is reachable
    // in principle.
    //
    // **The merge refuses it before the applier sees it**, which is the right
    // answer: the local store is malformed, and §10.4 asks for a clean rejection
    // rather than a half-applied import. Asserted here because it was not
    // obvious — this test was written expecting the import to succeed, and the
    // refusal is the better behaviour.
    //
    // It also means `ImportService.existing`'s trapping dictionary build was
    // unreachable through `plan`/`apply`. It was still worth fixing: "unreachable
    // today" is what every trap in this file was, right up until the review that
    // found two of them.
    let fixture = try ExportFixture()
    let shared = UUID()
    try fixture.project("Payments", modifiedAt: ExportFixture.at(10), id: shared)
    try fixture.project("Payments again", modifiedAt: ExportFixture.at(20), id: shared)

    let source = try ExportFixture()
    try source.project("Somewhere else", modifiedAt: ExportFixture.at(70))
    let data = try source.encoder(includingCachedData: true).encode()

    // **Reported against this Mac, not against the file.** `merge` validates both
    // sides and reports only that something was malformed, and that error's
    // message opens "This file isn't a readable Steno export" — which would send
    // the user to repair an export that is perfectly good.
    var reported: ImportError?
    do {
        _ = try ImportService(context: fixture.context).plan(data)
    } catch let error as ImportError {
        reported = error
    }
    guard case .storeUnreadable = reported else {
        Issue.record("expected .storeUnreadable, got \(String(describing: reported))")
        return
    }
    #expect(reported?.message.contains("could not read its own store") == true)

    // And nothing was written by the attempt.
    #expect(try fixture.context.fetch(FetchDescriptor<Project>()).count == 2)
}

@Test("the merge refuses an inverted report window, not only the reader")
func theMergeAlsoRefusesAnInvertedWindow() throws {
    // Same reasoning as the cache pair: `merge` is the value-level entry point
    // and takes input it cannot trace. An undone report with `windowStart`
    // after `windowEnd` makes `LastStandupClock` advance the project's clock
    // past the report's own window end, so no invalid result may escape here
    // even when nobody read a file.
    let project = MergeFixture.project(1)
    let clean = try MergeFixture.store(projects: [project])
    let inverted = try MergeFixture.store(
        projects: [project],
        reports: [
            MergeFixture.report(
                4, generatedAt: MergeFixture.at(100), windowStart: MergeFixture.at(200),
                windowEnd: MergeFixture.at(50), undone: true)
        ])

    #expect(throws: ImportError.self) { try StoreMerge.merge(local: clean, incoming: inverted) }
    #expect(throws: ImportError.self) { try StoreMerge.merge(local: inverted, incoming: clean) }
}
