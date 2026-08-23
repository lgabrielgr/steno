import Foundation
import Testing

@testable import StenoKit

// swiftlint:disable:next identifier_name
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func task(_ title: String, _ status: Status, changedAt: Date = t0) -> TaskItem {
    let item = TaskItem(title: title, projectID: UUID(), createdAt: t0)
    // setStatus has a guard that returns early if the status doesn't change.
    // To ensure statusChangedAt is updated, we need to ensure a status transition.
    // For .todo (the default), transition through another status first.
    if status == .todo {
        item.setStatus(.inProgress, at: changedAt)
        item.setStatus(.todo, at: changedAt)
    } else {
        item.setStatus(status, at: changedAt)
    }
    return item
}

@Test("FR-3 order is IN-PROGRESS, BLOCKED, TODO, DONE — not the enum's declaration order")
func groupsUseFR3Order() {
    let tasks = [
        task("d", .done),
        task("t", .todo),
        task("b", .blocked),
        task("p", .inProgress),
    ]

    let groups = TaskGrouping.groups(from: tasks, doneSince: t0.addingTimeInterval(-3600))

    #expect(groups.map(\.status) == [.inProgress, .blocked, .todo, .done])
}

@Test("a status with no tasks produces no group")
func emptyGroupsAreOmitted() {
    let groups = TaskGrouping.groups(from: [task("t", .todo)], doneSince: t0)

    #expect(groups.count == 1)
    #expect(groups.first?.status == .todo)
}

@Test("DONE shows completions inside the cutoff and hides older ones")
func doneHonoursCutoff() {
    let cutoff = t0.addingTimeInterval(-24 * 3600)
    let recent = task("recent", .done, changedAt: t0.addingTimeInterval(-3600))
    let ancient = task("ancient", .done, changedAt: t0.addingTimeInterval(-30 * 3600))

    let groups = TaskGrouping.groups(from: [recent, ancient], doneSince: cutoff)

    #expect(groups.count == 1)
    #expect(groups[0].status == .done)
    #expect(groups[0].tasks.map(\.title) == ["recent"])
}

@Test("a task that was never completed never appears in DONE")
func neverCompletedIsNotInDone() {
    // `completedAt` is nil for anything that has not been through
    // setStatus(.done), so the DONE filter must not admit it on the strength
    // of the cutoff alone.
    let fresh = TaskItem(title: "fresh", projectID: UUID(), createdAt: t0)

    let groups = TaskGrouping.groups(from: [fresh], doneSince: t0)

    #expect(groups.map(\.status) == [.todo])
}

@Test("the four statuses render with FR-3's spelling")
func statusDisplayNames() {
    #expect(Status.inProgress.displayName == "IN-PROGRESS")
    #expect(Status.blocked.displayName == "BLOCKED")
    #expect(Status.todo.displayName == "TODO")
    #expect(Status.done.displayName == "DONE")
    // Every case is covered, so adding a fifth status breaks this test rather
    // than silently rendering an unlabelled group. D11 says there is no fifth.
    #expect(Status.allCases.count == 4)
}

@Test("within a group, most recently touched comes first")
func groupsSortByRecency() {
    let older = task("older", .todo, changedAt: t0.addingTimeInterval(-7200))
    let newer = task("newer", .todo, changedAt: t0.addingTimeInterval(-60))

    let groups = TaskGrouping.groups(from: [older, newer], doneSince: t0)

    #expect(groups[0].tasks.map(\.title) == ["newer", "older"])
}
