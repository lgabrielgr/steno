import Foundation
import Testing

@testable import StenoKit

@Test("§3.3: redact() hides the event without destroying it")
func redactRetainsTheRow() {
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let payload = Data("{\"key\":\"PAY-421\"}".utf8)
    let event = Event(
        taskID: UUID(),
        timestamp: timestamp,
        kind: .note,
        body: "Repro'd the race condition, it's in the retry handler",
        payload: payload
    )

    #expect(!event.isRedacted)

    event.redact()

    #expect(event.isRedacted)
    // Soft delete: the row is retained in full. §3.3 permits hiding an event
    // from summaries, never erasing what it said.
    #expect(event.body == "Repro'd the race condition, it's in the retry handler")
    #expect(event.timestamp == timestamp)
    #expect(event.payload == payload)
    #expect(event.kind == .note)
}

@Test("redact() is idempotent")
func redactIsIdempotent() {
    let event = Event(taskID: UUID(), timestamp: .now, kind: .note, body: "note")
    event.redact()
    event.redact()
    #expect(event.isRedacted)
}

@Test("the initialiser is the only place any field except isRedacted is set")
func initialiserPopulatesEveryField() {
    let id = UUID()
    let taskID = UUID()
    let timestamp = Date(timeIntervalSince1970: 42)
    let event = Event(
        id: id,
        taskID: taskID,
        timestamp: timestamp,
        kind: .statusChanged,
        body: "IN-PROGRESS → BLOCKED"
    )

    #expect(event.id == id)
    #expect(event.taskID == taskID)
    #expect(event.timestamp == timestamp)
    #expect(event.kind == .statusChanged)
    #expect(event.body == "IN-PROGRESS → BLOCKED")
    #expect(event.payload == nil)
    #expect(!event.isRedacted)
}
