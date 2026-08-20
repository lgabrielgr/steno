import Foundation
import SwiftData
import Testing

@testable import StenoKit

// The dual representation the design chose (design doc §1.1): taskID is
// authoritative for export, import, and M2.5-02's merge; the relationship is
// there for call-site ergonomics. This is the test that stops them diverging.
@Test("design §1.1: taskID and the relationship never disagree")
func foreignKeyMatchesRelationship() throws {
    let container = try inMemoryContainer()
    let context = ModelContext(container)

    let task = TaskItem(
        title: "Fix the retry-handler race",
        projectID: UUID(),
        createdAt: Date(timeIntervalSince1970: 0)
    )
    context.insert(task)

    let sourceRef = SourceRef(taskID: task.id, kind: .jiraIssue, identifier: "PAY-421")
    sourceRef.task = task
    context.insert(sourceRef)

    try context.save()

    let fetched = try context.fetch(FetchDescriptor<SourceRef>())
    let persisted = try #require(fetched.first)

    #expect(persisted.taskID == persisted.task?.id)
    #expect(persisted.taskID == task.id)
    #expect(task.sourceRefs?.count == 1)
}

@Test("§3.4: the dedup rule holds against a live context")
func dedupHoldsWithAContext() throws {
    let container = try inMemoryContainer()
    let context = ModelContext(container)

    let taskID = UUID()
    let first = SourceRef(taskID: taskID, kind: .jiraIssue, identifier: "PAY-421")
    context.insert(first)
    try context.save()

    // Extraction runs again over the same task and sees the same ticket key.
    let existing = try context.fetch(FetchDescriptor<SourceRef>())
    let candidates = [SourceRef(taskID: taskID, kind: .jiraIssue, identifier: "PAY-421")]
    for newRef in SourceRef.newRefs(from: candidates, existing: existing) {
        context.insert(newRef)
    }
    try context.save()

    #expect(try context.fetch(FetchDescriptor<SourceRef>()).count == 1)
}

@Test("models survive a save and fetch with their invariant fields intact")
func modelsRoundTrip() throws {
    let container = try inMemoryContainer()
    let context = ModelContext(container)

    let completedAt = Date(timeIntervalSince1970: 500)
    let task = TaskItem(
        title: "Fix the retry-handler race",
        projectID: UUID(),
        createdAt: Date(timeIntervalSince1970: 0)
    )
    task.setStatus(.done, at: completedAt)
    context.insert(task)

    let event = Event(
        taskID: task.id,
        timestamp: completedAt,
        kind: .statusChanged,
        body: "IN-PROGRESS → DONE"
    )
    event.redact()
    context.insert(event)

    try context.save()

    let fetchedTask = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
    #expect(fetchedTask.status == .done)
    #expect(fetchedTask.completedAt == completedAt)
    #expect(fetchedTask.statusChangedAt == completedAt)

    let fetchedEvent = try #require(try context.fetch(FetchDescriptor<Event>()).first)
    #expect(fetchedEvent.isRedacted)
    #expect(fetchedEvent.body == "IN-PROGRESS → DONE")
}
