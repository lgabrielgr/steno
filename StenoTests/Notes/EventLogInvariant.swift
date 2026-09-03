import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// Every field of an `Event` **except `isRedacted`**.
///
/// The omission is the whole point. Comparing two snapshots for equality
/// therefore permits exactly one change — the redaction flag — and rejects
/// every other write, which is §3.3's invariant stated as a type rather than
/// as a review comment.
struct EventSnapshot: Hashable {
    let id: UUID
    let taskID: UUID
    let timestamp: Date
    let kind: EventKind
    let body: String
    let payload: Data?

    init(
        id: UUID, taskID: UUID, timestamp: Date, kind: EventKind, body: String,
        payload: Data? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.payload = payload
    }

    init(_ event: Event) {
        self.init(
            id: event.id, taskID: event.taskID, timestamp: event.timestamp, kind: event.kind,
            body: event.body, payload: event.payload)
    }
}

@MainActor
func eventSnapshots(_ context: ModelContext) throws -> [UUID: EventSnapshot] {
    var result: [UUID: EventSnapshot] = [:]
    for event in try context.fetch(FetchDescriptor<Event>()) {
        result[event.id] = EventSnapshot(event)
    }
    return result
}

/// The comparison, separated from the fetching.
///
/// Split out so `theInvariantGuardCanActuallyFail` can feed it a doctored pair
/// of snapshots and prove it reports the mutation — without `Event` acquiring
/// a test-only setter it spent its whole doc comment forbidding.
func expectAppendOnly(
    before: [UUID: EventSnapshot],
    after: [UUID: EventSnapshot],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for (id, was) in before {
        let now = try #require(
            after[id], "event \(id) was deleted from the log", sourceLocation: sourceLocation)
        #expect(
            now == was, "event \(id) was mutated in place, not appended to",
            sourceLocation: sourceLocation)
    }
}

/// Run `operation` and assert it mutated no existing event and deleted none.
///
/// `EventLogInvariantTests` is the only file that calls this, but it runs
/// every write method in the app through it — `setStatus`, `addBlockedReason`,
/// `addNote`, both `correct` outcomes, and `redact` — because the invariant is
/// a property of the whole system (§13), not of the note paths. A status change
/// that started rewriting bodies fails here, in the notes suite.
@MainActor
func expectingAppendOnly(
    _ context: ModelContext,
    _ operation: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let before = try eventSnapshots(context)
    try operation()
    try expectAppendOnly(
        before: before, after: try eventSnapshots(context), sourceLocation: sourceLocation)
}
