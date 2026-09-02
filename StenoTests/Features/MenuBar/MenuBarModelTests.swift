import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

/// Filtered in memory, not in a `#Predicate`: a predicate comparing an
/// enum-typed property does not compile, in either spelling. Same helper shape
/// as `StatusServiceTests`.
@MainActor
private func statusEvents(_ context: ModelContext) throws -> [Event] {
    try context.fetch(FetchDescriptor<Event>()).filter { $0.kind == .statusChanged }
}

@MainActor
private func makeContext() throws -> ModelContext {
    ModelContext(try StenoStore.inMemory())
}

@discardableResult
@MainActor
private func seedProject(
    _ context: ModelContext, _ name: String, keys: [String] = [], order: Int = 0,
    archived: Bool = false
) throws -> Project {
    let project = Project(
        name: name, colorHex: "#3B82F6", jiraProjectKeys: keys, sortOrder: order,
        modifiedAt: origin)
    if archived { project.setArchived(true, at: origin) }
    context.insert(project)
    try context.save()
    return project
}

@discardableResult
@MainActor
private func seedTask(
    _ context: ModelContext, _ title: String, in project: Project,
    status: Status = .todo, at date: Date = origin, archived: Bool = false
) throws -> TaskItem {
    let task = TaskItem(title: title, projectID: project.id, createdAt: date)
    if status != .todo { task.setStatus(status, at: date) }
    if archived { task.setArchived(true, at: date) }
    context.insert(task)
    try context.save()
    return task
}

@MainActor
@Test("the list is every IN-PROGRESS task, across every project (D-037)")
func theListIsEveryInProgressTaskAcrossProjects() throws {
    let context = try makeContext()
    let payments = try seedProject(context, "Payments", order: 0)
    let hiring = try seedProject(context, "Hiring", order: 1)
    try seedTask(context, "not started", in: payments, status: .todo)
    try seedTask(context, "retry handler", in: payments, status: .inProgress)
    try seedTask(context, "screening loop", in: hiring, status: .inProgress)
    try seedTask(context, "blocked on legal", in: hiring, status: .blocked)
    try seedTask(context, "shipped", in: payments, status: .done)

    let model = MenuBarModel(context: context, now: { origin })

    #expect(Set(model.rows.map(\.title)) == ["retry handler", "screening loop"])
    // The row carries its project, so a cross-project list stays readable.
    #expect(Set(model.rows.map(\.projectName)) == ["Payments", "Hiring"])
    #expect(model.rows.allSatisfy { $0.colorHex == "#3B82F6" })
}

@MainActor
@Test("archived tasks and archived projects are both excluded")
func archivedWorkIsExcludedFromTheList() throws {
    let context = try makeContext()
    let live = try seedProject(context, "Payments", order: 0)
    let shelved = try seedProject(context, "Old", order: 1, archived: true)
    try seedTask(context, "current", in: live, status: .inProgress)
    try seedTask(context, "archived task", in: live, status: .inProgress, archived: true)
    try seedTask(context, "in an archived project", in: shelved, status: .inProgress)

    let model = MenuBarModel(context: context, now: { origin })

    #expect(model.rows.map(\.title) == ["current"])
}

@MainActor
@Test("the list is newest transition first")
func theListIsOrderedNewestTransitionFirst() throws {
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    try seedTask(context, "older", in: project, status: .inProgress, at: origin)
    try seedTask(
        context, "newer", in: project, status: .inProgress, at: origin.addingTimeInterval(60))

    let model = MenuBarModel(context: context, now: { origin })

    #expect(model.rows.map(\.title) == ["newer", "older"])
}

@MainActor
@Test("preparing for show refetches and gives the field a new identity")
func preparingForShowRefetchesAndCountsTheOpen() throws {
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    let model = MenuBarModel(context: context, now: { origin })
    #expect(model.rows.isEmpty)
    #expect(model.showCount == 0)

    // Written behind the model's back, the way another surface would.
    try seedTask(context, "started elsewhere", in: project, status: .inProgress)
    model.prepareForShow()

    #expect(model.rows.map(\.title) == ["started elsewhere"])
    #expect(model.showCount == 1)
    model.prepareForShow()
    #expect(model.showCount == 2)
}

@MainActor
@Test("a write from another surface refreshes the list")
func aWriteFromAnotherSurfaceRefreshesTheList() throws {
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    let task = try seedTask(context, "retry handler", in: project, status: .todo)
    let model = MenuBarModel(context: context, now: { origin })
    #expect(model.rows.isEmpty)

    // Not through the model: this is the main window's path, and the point is
    // that the popover hears about it without either type knowing the other.
    try StatusService(context: context, now: { origin }).setStatus(.inProgress, on: task)

    #expect(model.rows.map(\.title) == ["retry handler"])
}

@MainActor
@Test("setting a status appends its event and drops the row")
func settingStatusAppendsItsEventAndDropsTheRow() throws {
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    let task = try seedTask(context, "retry handler", in: project, status: .inProgress)
    let model = MenuBarModel(context: context, now: { origin })
    #expect(model.rows.count == 1)

    model.setStatus(.done, on: task.id)

    #expect(task.status == .done)
    #expect(model.rows.isEmpty)
    #expect(model.writeError == nil)
    #expect(try statusEvents(context).count == 1)
}

@MainActor
@Test("setting the status a task already has writes nothing")
func aNoOpTransitionFromThePopoverWritesNothing() throws {
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    let task = try seedTask(context, "retry handler", in: project, status: .inProgress)
    let model = MenuBarModel(context: context, now: { origin })

    // Written behind the model's back, with no prepareForShow() or
    // .stenoDidWrite in between — the model has no legitimate reason to have
    // seen this. Only an unwarranted reload would surface it.
    try seedTask(context, "started elsewhere", in: project, status: .inProgress)

    model.setStatus(.inProgress, on: task.id)

    #expect(model.rows.map(\.title) == ["retry handler"])
    #expect(try statusEvents(context).isEmpty)
}

@MainActor
@Test("a failed status save is reported and the row is refetched")
func aFailedStatusSaveIsReportedAndRefetched() throws {
    struct SaveFailure: Error {}
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    let task = try seedTask(context, "retry handler", in: project, status: .inProgress)
    let model = MenuBarModel(
        context: context, now: { origin }, save: { _ in throw SaveFailure() })

    // Written behind the model's back, with no prepareForShow() or
    // .stenoDidWrite in between — the failing setStatus call never posts
    // .stenoDidWrite, so only the catch block's own reload() can surface this.
    try seedTask(context, "started elsewhere", in: project, status: .inProgress)

    model.setStatus(.done, on: task.id)

    #expect(model.writeError == "Could not change the status. Your change was not saved.")
    // The rollback restores the store; this is the fetch that restores the row
    // — and surfaces the task seeded behind the model's back, which only a
    // reload can find.
    #expect(Set(model.rows.map(\.title)) == ["retry handler", "started elsewhere"])
    #expect(model.rows.first(where: { $0.title == "retry handler" })?.status == .inProgress)
}

/// The popover has no Dismiss control, so reopening it is the only gesture
/// that can clear a stale `writeError`. Without the clear in
/// `prepareForShow()` a transient failure is on screen until the next
/// *successful* status change — which, for a user who reacts by closing the
/// popover and opening it again, looks like the app is stuck reporting an
/// error that is over.
///
/// `writeError` is cleared at the top of `prepareForShow()`, before its
/// `reload()` — that reload owns `readError` alone, so this test does not
/// depend on the two clears racing.
@MainActor
@Test("reopening the popover clears a stale error")
func reopeningThePopoverClearsAStaleError() throws {
    struct SaveFailure: Error {}
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    let task = try seedTask(context, "retry handler", in: project, status: .inProgress)
    let model = MenuBarModel(
        context: context, now: { origin }, save: { _ in throw SaveFailure() })

    model.setStatus(.done, on: task.id)
    #expect(model.writeError != nil, "the failing save should have reported")

    model.prepareForShow()

    #expect(model.writeError == nil)
    // The reload inside prepareForShow() still ran: the rolled-back task is
    // still listed, so the clear did not cost the refetch.
    #expect(model.rows.map(\.title) == ["retry handler"])
}

/// Pins the split from a single `lastError` to `readError`/`writeError`: a
/// read failure must not survive a `reload()` that goes on to succeed.
/// `failFetch` is the seam that makes a fetch throw without a store that can
/// actually fail — see its doc comment on `MenuBarModel.init`.
@MainActor
@Test("a failed read is cleared by the next successful reload")
func aFailedReadIsClearedByTheNextSuccessfulReload() throws {
    struct ReadFailure: Error {}
    final class FailSwitch {
        var shouldFail = false
    }
    let context = try makeContext()
    let project = try seedProject(context, "Payments")
    try seedTask(context, "retry handler", in: project, status: .inProgress)
    let failSwitch = FailSwitch()
    let model = MenuBarModel(
        context: context, now: { origin },
        failFetch: {
            if failSwitch.shouldFail { throw ReadFailure() }
        })
    #expect(model.rows.map(\.title) == ["retry handler"])
    #expect(model.readError == nil)

    failSwitch.shouldFail = true
    model.reload()
    #expect(model.readError != nil, "the injected failure should have reported")

    failSwitch.shouldFail = false
    model.reload()

    #expect(model.readError == nil)
    #expect(model.rows.map(\.title) == ["retry handler"])
}

@MainActor
@Test("a capture through the popover routes on the ticket key, like every other surface")
func capturingThroughThePopoverRoutesByTicketKey() throws {
    let context = try makeContext()
    try seedProject(context, "Hiring", keys: ["HIR"], order: 0)
    let payments = try seedProject(context, "Payments", keys: ["PAY"], order: 1)
    let model = MenuBarModel(context: context, now: { origin })

    model.prepareForShow()
    model.field.text = "PAY-421 fix the retry handler"
    #expect(model.field.chip?.projectName == "Payments")
    model.field.commit()

    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    #expect(tasks.first?.projectID == payments.id)
}

/// The gap the keystroke-driven chip refresh leaves: the draft outlives the
/// dismissal, so a project created while the popover was hidden changes what
/// `CaptureService` will route with — but nothing types a character to
/// re-derive the chip. Without an explicit refresh the popover shows no chip
/// while the write routes to Payments, which is FR-1.4's promise breaking
/// silently. Note the ordering: the draft is typed BEFORE the project exists.
/// Ports `QuickCaptureModelTests.prepareForShowRefreshesTheChipForAnExistingDraft`.
@MainActor
@Test("preparing to show re-derives the chip for a draft typed before the project existed")
func preparingForShowRefreshesTheChipForAnExistingDraft() throws {
    let context = try makeContext()
    let model = MenuBarModel(context: context, now: { origin })
    model.prepareForShow()

    model.field.text = "PAY-421 fix the retry handler"
    #expect(model.field.chip == nil, "no Payments project exists yet")

    // Written behind the model's back, the way another surface would.
    try seedProject(context, "Payments", keys: ["PAY"], order: 0)

    // No keystroke — this is the whole point.
    model.prepareForShow()

    let chip = try #require(model.field.chip)
    #expect(chip.projectName == "Payments")
}
