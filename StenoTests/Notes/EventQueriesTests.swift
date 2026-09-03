import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
@Test("the timeline query excludes redacted rows and sorts newest first")
func theTimelineQueryExcludesRedactedRows() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    let older = Event(taskID: taskID, timestamp: origin, kind: .note, body: "older")
    let newer = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(60), kind: .note, body: "newer")
    let hidden = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(30), kind: .note, body: "hidden")
    let other = Event(taskID: UUID(), timestamp: origin, kind: .note, body: "another task")
    for event in [older, newer, hidden, other] { context.insert(event) }
    hidden.redact()
    try context.save()

    let timeline = try context.fetch(EventQueries.timeline(forTaskID: taskID))

    #expect(timeline.map(\.body) == ["newer", "older"])
}
