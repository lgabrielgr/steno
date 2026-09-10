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

@MainActor
@Test("the window query is closed at both ends and excludes redacted rows")
func theWindowQueryIsClosedAtBothEnds() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    let events = [
        Event(
            taskID: taskID, timestamp: origin.addingTimeInterval(-1), kind: .note, body: "before"),
        Event(taskID: taskID, timestamp: origin, kind: .note, body: "start"),
        Event(
            taskID: taskID, timestamp: origin.addingTimeInterval(30), kind: .note, body: "middle"),
        Event(taskID: taskID, timestamp: origin.addingTimeInterval(60), kind: .note, body: "end"),
        Event(taskID: taskID, timestamp: origin.addingTimeInterval(61), kind: .note, body: "after"),
    ]
    let hidden = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(30), kind: .note, body: "hidden")
    for event in events + [hidden] { context.insert(event) }
    hidden.redact()
    try context.save()

    let found = try context.fetch(
        EventQueries.inWindow(start: origin, end: origin.addingTimeInterval(60)))

    // Both boundaries inclusive. FR-4 step 3 specifies a closed interval, and a
    // standupReported event can land exactly on a later window's start — D-076
    // stamps lastStandupAt with the generate instant while the event carries
    // the Copy instant, so they coincide whenever the user copies the moment
    // they generate. This is the behaviour ReportGatherer's kind filter exists
    // to absorb.
    #expect(found.map(\.body) == ["start", "middle", "end"])
}

@MainActor
@Test("the window query returns events oldest first")
func theWindowQueryIsAscending() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    // Inserted newest-first, so insertion order disagrees with the sort.
    for offset in [50, 10, 30] {
        context.insert(
            Event(
                taskID: taskID, timestamp: origin.addingTimeInterval(Double(offset)),
                kind: .note, body: "at \(offset)"))
    }
    try context.save()

    let found = try context.fetch(
        EventQueries.inWindow(start: origin, end: origin.addingTimeInterval(60)))

    // Ascending, unlike timeline(forTaskID:): a report narrates a window
    // forwards, while a timeline shows the newest note first.
    #expect(found.map(\.body) == ["at 10", "at 30", "at 50"])
}

@MainActor
@Test("the undo query is inclusive at its bound and excludes redacted rows")
func theUndoQueryBoundsAndExcludesRedacted() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let taskID = UUID()
    // Inserted out of order, so a passing result cannot come from insertion
    // order agreeing with the assertion by accident.
    for (offset, body) in [(30, "after"), (-10, "before"), (0, "on the bound")] {
        context.insert(
            Event(
                taskID: taskID, timestamp: origin.addingTimeInterval(Double(offset)),
                kind: .standupReported, body: body))
    }
    let redacted = Event(
        taskID: taskID, timestamp: origin.addingTimeInterval(20),
        kind: .standupReported, body: "already redacted")
    context.insert(redacted)
    redacted.redact()
    try context.save()

    let found = try context.fetch(EventQueries.notRedacted(atOrAfter: origin))

    // Inclusive at the bound: `StandupUndoService` calls this with the report's
    // `windowEnd`, and an event stamped exactly there is the boundary case
    // D-066 describes — the user copying the instant they generate.
    #expect(Set(found.map(\.body)) == ["on the bound", "after"])
}
