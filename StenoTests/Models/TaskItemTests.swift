import Foundation
import Testing

@testable import StenoKit

private let created = Date(timeIntervalSince1970: 0)
private let firstMove = Date(timeIntervalSince1970: 100)
private let secondMove = Date(timeIntervalSince1970: 200)

private func task() -> TaskItem {
    TaskItem(title: "Repro the retry-handler race", projectID: UUID(), createdAt: created)
}

// All 16 (from, to) pairs. §3.2 allows any status to move to any other, so the
// table is the whole space rather than a sampled workflow.
@Test(
    "§3.2 + design §5.1: status transitions",
    arguments: Status.allCases, Status.allCases
)
func statusTransition(from: Status, to targetStatus: Status) {
    let item = task()
    item.setStatus(from, at: firstMove)

    let statusChangedBefore = item.statusChangedAt
    let completedBefore = item.completedAt
    let modifiedBefore = item.modifiedAt

    item.setStatus(targetStatus, at: secondMove)

    #expect(item.status == targetStatus)

    if targetStatus == from {
        // A redundant set is a complete no-op. Re-stamping would reset a
        // completed task's completion time and hand M1-05 a statusChanged
        // event describing a transition that never happened.
        #expect(item.statusChangedAt == statusChangedBefore)
        #expect(item.completedAt == completedBefore)
    } else {
        #expect(item.statusChangedAt == secondMove)
        #expect(item.completedAt == (targetStatus == .done ? secondMove : nil))
    }

    // §4 of the design doc: status is event-governed, so it never stamps
    // modifiedAt. A broad rule here would let a status-only change on one
    // machine win the title at merge time and revert a retitle made on another.
    #expect(item.modifiedAt == modifiedBefore)
}

@Test("§3.2: entering done sets completedAt, leaving it clears it")
func completedAtFollowsDone() {
    let item = task()

    item.setStatus(.done, at: firstMove)
    #expect(item.completedAt == firstMove)

    item.setStatus(.inProgress, at: secondMove)
    #expect(item.completedAt == nil)
}

@Test("a new task starts in todo with its timestamps seeded from createdAt")
func taskItemInitialState() {
    let item = task()
    #expect(item.status == .todo)
    #expect(item.createdAt == created)
    #expect(item.statusChangedAt == created)
    #expect(item.modifiedAt == created)
    #expect(item.completedAt == nil)
    #expect(!item.isArchived)
}

@Test("design §4: rename stamps modifiedAt")
func renameStampsModifiedAt() {
    let item = task()
    item.rename(to: "Fix the retry-handler race", at: firstMove)
    #expect(item.title == "Fix the retry-handler race")
    #expect(item.modifiedAt == firstMove)
}

@Test("design §4: move stamps modifiedAt")
func moveStampsModifiedAt() {
    let item = task()
    let destination = UUID()
    item.move(toProject: destination, at: firstMove)
    #expect(item.projectID == destination)
    #expect(item.modifiedAt == firstMove)
}

@Test("design §4: setArchived stamps modifiedAt")
func setArchivedStampsModifiedAt() {
    let item = task()
    item.setArchived(true, at: firstMove)
    #expect(item.isArchived)
    #expect(item.modifiedAt == firstMove)
}
