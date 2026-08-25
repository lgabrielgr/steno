import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeModel() throws -> (MainWindowModel, ModelContext) {
    let container = try StenoStore.inMemory()
    // `ModelContext(container)` retains its container. `container.mainContext`
    // does NOT — so returning the main context from a helper leaves it
    // dangling the moment the container goes out of scope, and the next
    // insert/save traps inside SwiftData with EXC_BREAKPOINT. Every other
    // test in this repo already uses this form; match it.
    let context = ModelContext(container)
    return (MainWindowModel(context: context, now: { origin }), context)
}

@MainActor
@Test("a new task lands in the TODO group")
func createdTaskIsTodo() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")

    model.createTask(titled: "Fix the retry handler")

    #expect(model.groups.map(\.status) == [.todo])
    #expect(model.groups[0].tasks.map(\.title) == ["Fix the retry handler"])
}

@MainActor
@Test("creating a task appends exactly one created event (§3.3)")
func createTaskAppendsCreatedEvent() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createTask(titled: "Fix the retry handler")

    let taskID = try #require(model.groups.first?.tasks.first?.id)
    let events = model.events(forTaskID: taskID)

    #expect(events.count == 1)
    #expect(events.first?.kind == .created)
    #expect(events.first?.taskID == taskID)
}

@MainActor
@Test("with no projects, creating a task is a no-op and stores nothing")
func createTaskWithoutProjectsIsNoOp() throws {
    let (model, context) = try makeModel()

    model.createTask(titled: "orphan")

    #expect(model.groups.isEmpty)
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
}

@MainActor
@Test("blank titles are refused")
func blankTitleRefused() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")

    model.createTask(titled: "   ")

    #expect(model.groups.isEmpty)
}

@MainActor
@Test("the All pseudo-project shows tasks across every project")
func allSpansProjects() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)

    model.selection = .project(ids[0])
    model.createTask(titled: "one")
    model.selection = .project(ids[1])
    model.createTask(titled: "two")

    model.selection = .all

    #expect(model.groups[0].tasks.count == 2)
}

@MainActor
@Test("selecting a project scopes the list to that project")
func selectionScopesTheList() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)
    model.selection = .project(ids[0])
    model.createTask(titled: "one")

    model.selection = .project(ids[1])

    #expect(model.groups.isEmpty)
}

@MainActor
@Test("under All, a new task goes to the first project by sortOrder")
func allTargetsFirstProject() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let first = try #require(model.projects.first?.id)
    model.selection = .all

    model.createTask(titled: "where does this go")

    #expect(model.groups[0].tasks.first?.projectID == first)
}

@MainActor
@Test("archiving a project also hides its tasks from All")
func archivedProjectsTasksAreHidden() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)
    model.selection = .project(ids[1])
    model.createTask(titled: "hide me")

    model.archive(projectID: ids[1])
    model.selection = .all

    #expect(model.groups.flatMap(\.tasks).isEmpty)
}

@MainActor
@Test("DONE is scoped to the last 24 hours")
func doneWindowIsTwentyFourHours() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    let projectID = try #require(model.projects.first?.id)

    let recent = TaskItem(title: "just finished", projectID: projectID, createdAt: origin)
    recent.setStatus(.done, at: origin.addingTimeInterval(-3600))
    let ancient = TaskItem(title: "ancient", projectID: projectID, createdAt: origin)
    ancient.setStatus(.done, at: origin.addingTimeInterval(-30 * 3600))
    context.insert(recent)
    context.insert(ancient)
    try context.save()

    model.reload()

    let done = try #require(model.groups.first { $0.status == .done })
    #expect(done.tasks.map(\.title) == ["just finished"])
}

@MainActor
@Test("changing selection reloads the list")
func selectionChangeReloads() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    let id = try #require(model.projects.first?.id)
    model.createTask(titled: "one")

    model.selection = .project(id)

    #expect(model.groups[0].tasks.count == 1)
}

@MainActor
@Test("selecting a task publishes its timeline; deselecting clears it")
func selectingATaskPublishesItsTimeline() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createTask(titled: "Fix the retry handler")
    let taskID = try #require(model.groups.first?.tasks.first?.id)

    #expect(model.selectedTaskEvents.isEmpty)

    model.selectedTaskID = taskID

    // The detail pane reads this array; it must never have to fetch during a
    // render pass, where a failed read would mutate observed state.
    #expect(model.selectedTaskEvents.map(\.kind) == [.created])

    model.selectedTaskID = nil

    #expect(model.selectedTaskEvents.isEmpty)
}

@MainActor
@Test("a reload refreshes the selected task's timeline in place")
func reloadRefreshesTheSelectedTimeline() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    model.createTask(titled: "Fix the retry handler")
    let taskID = try #require(model.groups.first?.tasks.first?.id)
    model.selectedTaskID = taskID
    #expect(model.selectedTaskEvents.count == 1)

    // Appended behind the model's back, the way M1-06's note service will.
    context.insert(
        Event(taskID: taskID, timestamp: origin, kind: .note, body: "Repro'd it")
    )
    try context.save()

    model.reload()

    // Selection is unchanged, so this only passes if reload() refreshes the
    // timeline unconditionally rather than on selection change alone.
    #expect(model.selectedTaskEvents.count == 2)
}

@MainActor
@Test("a populated timeline is not reported as failed")
func timelineFailureFlagStaysClearOnSuccess() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createTask(titled: "Fix the retry handler")
    let taskID = try #require(model.groups.first?.tasks.first?.id)

    model.selectedTaskID = taskID

    #expect(model.selectedTaskEvents.count == 1)
    #expect(!model.selectedTaskTimelineFailed)
}

@MainActor
@Test("deselecting clears the timeline without claiming a failure")
func deselectingClearsWithoutFailure() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createTask(titled: "Fix the retry handler")
    model.selectedTaskID = try #require(model.groups.first?.tasks.first?.id)

    model.selectedTaskID = nil

    // Empty because nothing is selected, not because a read failed — the pane
    // renders different copy for each, so the distinction has to hold.
    #expect(model.selectedTaskEvents.isEmpty)
    #expect(!model.selectedTaskTimelineFailed)
}
