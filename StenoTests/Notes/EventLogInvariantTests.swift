import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)
private let withinWindow = origin.addingTimeInterval(120)

@MainActor
private func makeTask() throws -> (TaskItem, ModelContext) {
    let context = ModelContext(try StenoStore.inMemory())
    let task = TaskItem(title: "Fix the retry handler", projectID: UUID(), createdAt: origin)
    context.insert(task)
    try context.save()
    return (task, context)
}

@MainActor
private func allEvents(_ context: ModelContext) throws -> [Event] {
    try context.fetch(FetchDescriptor<Event>())
}

/// M1-06's acceptance criterion 2, and §3.3's invariant, as one test over
/// **every** write path in the app rather than one assertion per method.
///
/// `expectingAppendOnly` compares `EventSnapshot`s, which deliberately omit
/// `isRedacted` — so a redaction passes and any other change to any existing
/// row fails, as does a deletion.
@MainActor
@Test("no write path mutates an existing event except to flip isRedacted")
func appendOnlyHoldsAcrossEveryWritePath() throws {
    let (task, context) = try makeTask()
    var clock = origin
    let notes = NoteService(context: context, now: { clock })
    let statuses = StatusService(context: context, now: { clock })

    // A log carrying one of every kind this milestone can produce.
    try statuses.setStatus(.inProgress, on: task)
    let note = try #require(try notes.addNote("first note about PAY-421", to: task))
    try statuses.setStatus(.blocked, on: task)
    try statuses.addBlockedReason("waiting on infra", to: task)
    let reason = try #require(try allEvents(context).first { $0.kind == .blockedReason })

    clock = withinWindow

    try expectingAppendOnly(context) {
        _ = try notes.correct(note, to: "corrected note about PAY-421", on: task)
    }
    try expectingAppendOnly(context) {
        _ = try notes.correct(reason, to: "waiting on staging infra", on: task)
    }
    try expectingAppendOnly(context) {
        try statuses.setStatus(.done, on: task)
    }
    let liveNote = try #require(
        try allEvents(context).first { $0.kind == .note && !$0.isRedacted })
    try expectingAppendOnly(context) {
        _ = try notes.redact(liveNote)
    }
    try expectingAppendOnly(context) {
        _ = try notes.addNote("a later note", to: task)
    }

    // The log only ever grew: 3 statusChanged, 2 note, 1 replacement note,
    // 1 blockedReason, 1 replacement blockedReason.
    #expect(try allEvents(context).count == 8)
}

private let sampleID = UUID()
private let sampleTaskID = UUID()

private func sampleSnapshot(body: String) -> [UUID: EventSnapshot] {
    [
        sampleID: EventSnapshot(
            id: sampleID, taskID: sampleTaskID, timestamp: origin, kind: .note, body: body)
    ]
}

@Test("the invariant guard reports a body rewritten in place")
func theInvariantGuardCanActuallyFail() throws {
    // The guard above is the load-bearing test of this task, so prove it can
    // fail. `withKnownIssue` records the failure rather than propagating it:
    // this test passes only while the guard still notices the mutation, and
    // starts failing the day it stops.
    withKnownIssue("an in-place body rewrite must be caught") {
        try expectAppendOnly(
            before: sampleSnapshot(body: "original"),
            after: sampleSnapshot(body: "rewritten in place"))
    }
}

@Test("the invariant guard reports a deleted row")
func theInvariantGuardCatchesDeletion() throws {
    withKnownIssue("a deleted event must be caught") {
        try expectAppendOnly(before: sampleSnapshot(body: "original"), after: [:])
    }
}

@Test("the invariant guard accepts a redaction")
func theInvariantGuardAcceptsARedaction() throws {
    // `EventSnapshot` omits `isRedacted`, so the one permitted write is
    // invisible to the comparison and passes cleanly.
    try expectAppendOnly(
        before: sampleSnapshot(body: "same"), after: sampleSnapshot(body: "same"))
}
