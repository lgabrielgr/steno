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

/// Captures `title` the way production does — through `CaptureService`,
/// using this window's own context as `preferred` (FR-1.4 rung 2) — and
/// reloads the model so `groups`/`projects` reflect the write.
///
/// `MainWindowModel.createTask(titled:)` used to be this fixture's job, but
/// it had zero production callers (`CaptureFieldView` drives
/// `CaptureFieldModel` instead) and was deleted per D15: a second capture
/// entry point on the main window model is exactly the divergent code path
/// D15 exists to prevent. These tests only ever needed a task in the store
/// to assert grouping, selection scoping, or the timeline against — this
/// helper gets them one via the one real write path instead.
@MainActor
@discardableResult
private func createTask(_ model: MainWindowModel, titled title: String) throws -> TaskItem? {
    let task = try model.captureService().capture(
        text: title, preferred: model.preferredProjectIDForCapture)
    model.reload()
    return task
}

/// The id of the task with `title`, for tests that juggle two of them.
/// Not named `taskID`: a local `let taskID` elsewhere in this file would
/// shadow it, and Swift 6 reports that as "failed to produce diagnostic for
/// expression" rather than as the shadowing it is.
@MainActor
private func idOfTask(in model: MainWindowModel, titled title: String) -> UUID? {
    model.groups.flatMap(\.tasks).first { $0.title == title }?.id
}

/// Refetched from the store, never read off objects the model still holds:
/// what a rollback leaves in memory is not dependable (see
/// `MainWindowModel+Notes`), so only the store settles who owns a note.
@MainActor
private func notes(_ context: ModelContext, on subject: UUID) throws -> [Event] {
    try context.fetch(EventQueries.timeline(forTaskID: subject)).filter { $0.kind == .note }
}

@MainActor
@Test("a new task lands in the TODO group")
func createdTaskIsTodo() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")

    try createTask(model, titled: "Fix the retry handler")

    #expect(model.groups.map(\.status) == [.todo])
    #expect(model.groups[0].tasks.map(\.title) == ["Fix the retry handler"])
}

@MainActor
@Test("creating a task appends exactly one created event (§3.3)")
func createTaskAppendsCreatedEvent() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let task = try createTask(model, titled: "Fix the retry handler")

    let taskID = try #require(task?.id)
    // `MainWindowModel.events(forTaskID:)` was deleted alongside `createTask`
    // — zero production callers (`TaskDetailView` reads `selectedTaskEvents`,
    // not a per-ID fetch), so this drives the same redaction-filtering
    // `fetchEvents` through the surface production actually uses.
    model.selectedTaskID = taskID

    #expect(model.selectedTaskEvents.count == 1)
    #expect(model.selectedTaskEvents.first?.kind == .created)
    #expect(model.selectedTaskEvents.first?.taskID == taskID)
}

@MainActor
@Test("with no projects, capturing stores nothing and throws")
func createTaskWithoutProjectsExplainsItself() throws {
    let (model, context) = try makeModel()

    // `MainWindowModel.createTask` used to translate this into `lastError`,
    // but production never reaches that translation: `newTask()` gates the
    // sheet on `canCreateTask`, which is already false here. What remains
    // worth asserting is the write-path invariant — the surface a real
    // capture goes through refuses cleanly rather than writing a partial
    // task.
    #expect(throws: CaptureError.noProjectAvailable) {
        try createTask(model, titled: "orphan")
    }

    #expect(model.groups.isEmpty)
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
}

@MainActor
@Test("blank titles are refused")
func blankTitleRefused() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")

    try createTask(model, titled: "   ")

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
    try createTask(model, titled: "one")
    model.selection = .project(ids[1])
    try createTask(model, titled: "two")

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
    try createTask(model, titled: "one")

    model.selection = .project(ids[1])

    #expect(model.groups.isEmpty)
}

@MainActor
@Test("archiving a project also hides its tasks from All")
func archivedProjectsTasksAreHidden() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)
    model.selection = .project(ids[1])
    try createTask(model, titled: "hide me")

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
    try createTask(model, titled: "one")

    model.selection = .project(id)

    #expect(model.groups[0].tasks.count == 1)
}

@MainActor
@Test("selecting a task publishes its timeline; deselecting clears it")
func selectingATaskPublishesItsTimeline() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    try createTask(model, titled: "Fix the retry handler")
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
    try createTask(model, titled: "Fix the retry handler")
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
    try createTask(model, titled: "Fix the retry handler")
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
    try createTask(model, titled: "Fix the retry handler")
    model.selectedTaskID = try #require(model.groups.first?.tasks.first?.id)

    model.selectedTaskID = nil

    // Empty because nothing is selected, not because a read failed — the pane
    // renders different copy for each, so the distinction has to hold.
    #expect(model.selectedTaskEvents.isEmpty)
    #expect(!model.selectedTaskTimelineFailed)
}

@MainActor
@Test("switching tasks discards a pending draft instead of filing it elsewhere")
func switchingTasksDiscardsThePendingDraft() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    try createTask(model, titled: "Fix the retry handler")
    try createTask(model, titled: "Chase the flaky test")
    let author = try #require(idOfTask(in: model, titled: "Fix the retry handler"))
    let bystander = try #require(idOfTask(in: model, titled: "Chase the flaky test"))

    model.selectedTaskID = author
    model.noteComposer.text = "Repro'd the race"
    model.selectedTaskID = bystander
    model.commitNote()

    // The composer holds no task of its own, so a draft that survived the
    // selection change would be filed against whatever is selected at ⌘↩.
    #expect(try notes(context, on: bystander).isEmpty)
    #expect(try notes(context, on: author).isEmpty)
    #expect(model.noteComposer.text.isEmpty)
}

@MainActor
@Test("switching tasks mid-correction files nothing on the newly selected task")
func switchingTasksMidCorrectionFilesNothing() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    try createTask(model, titled: "Fix the retry handler")
    try createTask(model, titled: "Chase the flaky test")
    let author = try #require(idOfTask(in: model, titled: "Fix the retry handler"))
    let bystander = try #require(idOfTask(in: model, titled: "Chase the flaky test"))

    model.selectedTaskID = author
    model.noteComposer.text = "Repro'd the race"
    model.commitNote()
    let note = try #require(model.selectedTaskEvents.first { $0.kind == .note })
    model.beginNoteCorrection(of: note.id)
    model.noteComposer.text = "Repro'd the race, it's in the retry handler"

    model.selectedTaskID = bystander

    // Two presses, because a correction carried across the change is worse
    // than a plain draft: the first ⌘↩ cannot find the event in this task's
    // timeline and drops to adding, and the second files the other task's
    // corrected prose here as a new note.
    model.commitNote()
    model.commitNote()

    #expect(try notes(context, on: bystander).isEmpty)
    #expect(try notes(context, on: author).map(\.body) == ["Repro'd the race"])
    #expect(model.noteComposer.mode == .adding)
}
