import Foundation
import Testing

@testable import StenoKit

private func ref(
    taskID: UUID,
    kind: SourceRefKind = .jiraIssue,
    identifier: String
) -> SourceRef {
    SourceRef(taskID: taskID, kind: kind, identifier: identifier)
}

@Test("§3.4: re-extracting an existing ref yields nothing")
func existingRefIsNotDuplicated() {
    let taskID = UUID()
    let existing = [ref(taskID: taskID, identifier: "PAY-421")]
    let candidates = [ref(taskID: taskID, identifier: "PAY-421")]

    #expect(SourceRef.newRefs(from: candidates, existing: existing).isEmpty)
}

@Test("§3.4: a genuinely new ref is returned")
func newRefIsReturned() {
    let taskID = UUID()
    let existing = [ref(taskID: taskID, identifier: "PAY-421")]
    let candidates = [ref(taskID: taskID, identifier: "BILL-7")]

    let result = SourceRef.newRefs(from: candidates, existing: existing)

    #expect(result.count == 1)
    #expect(result.first?.identifier == "BILL-7")
}

// Extraction runs on the title and on every note (FR-1.5), so one pass over a
// task legitimately yields the same key several times.
@Test("§3.4: duplicates within one batch collapse to one")
func intraBatchDuplicatesCollapse() {
    let taskID = UUID()
    let candidates = [
        ref(taskID: taskID, identifier: "PAY-421"),
        ref(taskID: taskID, identifier: "PAY-421"),
        ref(taskID: taskID, identifier: "PAY-421"),
    ]

    let result = SourceRef.newRefs(from: candidates, existing: [])

    #expect(result.count == 1)
}

@Test("§3.4: the key is (taskID, kind, identifier) — each part discriminates")
func everyKeyComponentDiscriminates() {
    let taskA = UUID()
    let taskB = UUID()
    let existing = [ref(taskID: taskA, kind: .jiraIssue, identifier: "PAY-421")]

    // Same identifier, different task.
    #expect(
        SourceRef.newRefs(
            from: [ref(taskID: taskB, kind: .jiraIssue, identifier: "PAY-421")],
            existing: existing
        ).count == 1
    )
    // Same identifier and task, different kind.
    #expect(
        SourceRef.newRefs(
            from: [ref(taskID: taskA, kind: .url, identifier: "PAY-421")],
            existing: existing
        ).count == 1
    )
}

// Normalizing case or whitespace belongs to extraction (M1-01). Doing it here
// too would mean two components decide what "the same ticket" means, and they
// would eventually disagree.
@Test("§3.4: identifiers match exactly, without normalization")
func identifierMatchIsExact() {
    let taskID = UUID()
    let existing = [ref(taskID: taskID, identifier: "PAY-421")]

    let result = SourceRef.newRefs(
        from: [ref(taskID: taskID, identifier: "pay-421")],
        existing: existing
    )

    #expect(result.count == 1)
}

@Test("§10.1: recordFetch moves the summary and the timestamp together")
func recordFetchSetsBothFields() {
    let fetched = Date(timeIntervalSince1970: 5_000)
    let sourceRef = ref(taskID: UUID(), identifier: "PAY-421")

    #expect(sourceRef.lastFetchedAt == nil)
    #expect(sourceRef.cachedSummary == nil)

    sourceRef.recordFetch(summary: "In Review; 2 new comments", at: fetched)

    #expect(sourceRef.cachedSummary == "In Review; 2 new comments")
    #expect(sourceRef.lastFetchedAt == fetched)
}
