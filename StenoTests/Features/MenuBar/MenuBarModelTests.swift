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
