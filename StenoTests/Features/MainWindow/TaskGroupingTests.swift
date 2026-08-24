import Foundation
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

private func task(_ title: String, _ status: Status, changedAt: Date = origin) -> TaskItem {
    // `createdAt` seeds `statusChangedAt`, and `setStatus` deliberately no-ops
    // when the status is unchanged (§3.2) — so a `.todo` task only carries the
    // instant we want if it is created at that instant. Passing `changedAt`
    // here makes the helper correct for all four statuses without branching.
    let item = TaskItem(title: title, projectID: UUID(), createdAt: changedAt)
    item.setStatus(status, at: changedAt)
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

    let groups = TaskGrouping.groups(from: tasks, doneSince: origin.addingTimeInterval(-3600))

    #expect(groups.map(\.status) == [.inProgress, .blocked, .todo, .done])
}

@Test("a status with no tasks produces no group")
func emptyGroupsAreOmitted() {
    let groups = TaskGrouping.groups(from: [task("t", .todo)], doneSince: origin)

    #expect(groups.count == 1)
    #expect(groups.first?.status == .todo)
}

@Test("DONE shows completions inside the cutoff and hides older ones")
func doneHonoursCutoff() {
    let cutoff = origin.addingTimeInterval(-24 * 3600)
    let recent = task("recent", .done, changedAt: origin.addingTimeInterval(-3600))
    let ancient = task("ancient", .done, changedAt: origin.addingTimeInterval(-30 * 3600))

    let groups = TaskGrouping.groups(from: [recent, ancient], doneSince: cutoff)

    #expect(groups.count == 1)
    #expect(groups[0].status == .done)
    #expect(groups[0].tasks.map(\.title) == ["recent"])
}

@Test("a task that was never completed never appears in DONE")
func neverCompletedIsNotInDone() {
    // `fresh` is created without a status change, so its default status is
    // `.todo` — this pins that default, not the nil-`completedAt` guard in
    // `TaskGrouping`. The task short-circuits at the earlier
    // `task.status == status` check before that guard is ever reached, and
    // the guard is in fact unreachable through `setStatus`, which always
    // stamps `completedAt` on entering `.done` and clears it on leaving —
    // there is no path through the public API that puts a task into `.done`
    // with a nil `completedAt`.
    let fresh = TaskItem(title: "fresh", projectID: UUID(), createdAt: origin)

    let groups = TaskGrouping.groups(from: [fresh], doneSince: origin)

    #expect(groups.map(\.status) == [.todo])
}

@Test("within a group, most recently touched comes first")
func groupsSortByRecency() {
    let older = task("older", .todo, changedAt: origin.addingTimeInterval(-7200))
    let newer = task("newer", .todo, changedAt: origin.addingTimeInterval(-60))

    let groups = TaskGrouping.groups(from: [older, newer], doneSince: origin)

    #expect(groups[0].tasks.map(\.title) == ["newer", "older"])
}
