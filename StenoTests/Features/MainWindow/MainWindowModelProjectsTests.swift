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
@Test("a new model on an empty store lists nothing and cannot create a task")
func emptyStore() throws {
    let (model, _) = try makeModel()

    #expect(model.projects.isEmpty)
    #expect(!model.canCreateTask)
    #expect(model.lastError == nil)
}

@MainActor
@Test("creating a project persists it and shows it in the sidebar list")
func createProjectPersists() throws {
    let (model, context) = try makeModel()

    model.createProject(named: "Payments Platform")

    #expect(model.projects.map(\.name) == ["Payments Platform"])
    // Persisted, not merely held in memory: a fresh fetch sees it.
    let stored = try context.fetch(FetchDescriptor<Project>())
    #expect(stored.count == 1)
}

@MainActor
@Test("project names are trimmed and blank names are refused")
func createProjectTrimsAndRefusesBlanks() throws {
    let (model, _) = try makeModel()

    model.createProject(named: "  EM — Hiring  ")
    model.createProject(named: "   ")
    model.createProject(named: "")

    #expect(model.projects.map(\.name) == ["EM — Hiring"])
}

@MainActor
@Test("projects get increasing sortOrder and distinguishable colours")
func createProjectAssignsOrderAndColour() throws {
    let (model, _) = try makeModel()

    model.createProject(named: "First")
    model.createProject(named: "Second")

    #expect(model.projects.map(\.sortOrder) == [0, 1])
    #expect(model.projects[0].colorHex == ProjectPalette.hex(forIndex: 0))
    #expect(model.projects[1].colorHex == ProjectPalette.hex(forIndex: 1))
}

@MainActor
@Test("archiving hides a project from the sidebar but does not delete the row")
func archiveHidesButKeeps() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)

    model.archive(projectID: id)

    #expect(model.projects.isEmpty)
    let stored = try context.fetch(FetchDescriptor<Project>())
    #expect(stored.count == 1)
    #expect(stored.first?.isArchived == true)
}

@MainActor
@Test("archiving the selected project falls back to All")
func archivingSelectedFallsBackToAll() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)
    model.selection = .project(id)

    model.archive(projectID: id)

    #expect(model.selection == .all)
}

@MainActor
@Test("the menu actions move the selection through the sidebar")
func actionsCycleSelection() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)

    model.selectNextProject()
    #expect(model.selection == .project(ids[0]))

    model.selectPreviousProject()
    #expect(model.selection == .all)
}

@MainActor
@Test("newProject raises the sheet rather than creating anything itself")
func newProjectOnlyPresents() throws {
    let (model, _) = try makeModel()

    model.newProject()

    #expect(model.activeSheet == .newProject)
    #expect(model.projects.isEmpty)
}

private struct SaveFailure: Error {}

@MainActor
@Test("a failed createProject leaves the store untouched and surfaces the error")
func createProjectRollsBackOnSaveFailure() throws {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let model = MainWindowModel(
        context: context,
        now: { origin },
        save: { _ in throw SaveFailure() }
    )

    model.createProject(named: "Payments")

    // The rollback discarded the insert — nothing in memory, nothing on disk.
    #expect(model.projects.isEmpty)
    #expect(model.lastError != nil)
    let stored = try context.fetch(FetchDescriptor<Project>())
    #expect(stored.isEmpty)
}

@MainActor
@Test("archiving does not move the selection when the save fails")
func archiveDoesNotMoveSelectionOnSaveFailure() throws {
    let container = try StenoStore.inMemory()

    // Create the project with a working save first.
    let workingContext = ModelContext(container)
    let workingModel = MainWindowModel(context: workingContext, now: { origin })
    workingModel.createProject(named: "Payments")
    let id = try #require(workingModel.projects.first?.id)

    // A second model over the same container, whose save always throws —
    // a real ModelContext cannot be made to fail its save on demand, so this
    // injected `save` is the only way to exercise the rollback path.
    let failingContext = ModelContext(container)
    let failingModel = MainWindowModel(
        context: failingContext,
        now: { origin },
        save: { _ in throw SaveFailure() }
    )
    failingModel.selection = .project(id)

    failingModel.archive(projectID: id)

    // `perform` returned false, so the guard commit 05515b0 added must have
    // kept the selection on the project rather than falling back to All.
    #expect(failingModel.selection == .project(id))
    #expect(failingModel.lastError != nil)
    let stored = try workingContext.fetch(FetchDescriptor<Project>())
    #expect(stored.first?.isArchived == false)
}

@MainActor
@Test("editing a project stores its name and Jira keys")
func editingAProjectStoresNameAndKeys() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)

    model.updateProject(id: id, name: "Payments Platform", jiraKeys: "PAY, BILL")

    let project = try #require(model.project(withID: id))
    #expect(project.name == "Payments Platform")
    #expect(project.jiraProjectKeys == ["PAY", "BILL"])
}

@MainActor
@Test("keys are uppercased, trimmed, de-duplicated, and emptied")
func keysAreNormalised() {
    #expect(MainWindowModel.normalisedKeys(" pay , BILL,pay,, ") == ["PAY", "BILL"])
    #expect(MainWindowModel.normalisedKeys("") == [])
    #expect(MainWindowModel.normalisedKeys("   ") == [])
}

@MainActor
@Test("a project cannot be renamed to nothing")
func blankProjectNameIsRefused() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)

    model.updateProject(id: id, name: "   ", jiraKeys: "PAY")

    let project = try #require(model.project(withID: id))
    #expect(project.name == "Payments")
    #expect(project.jiraProjectKeys.isEmpty)
}

@MainActor
@Test("editing keys makes auto-routing reachable end to end")
func editedKeysRouteACapture() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createProject(named: "EM — Hiring")
    let payments = try #require(model.projects.first?.id)
    let hiring = try #require(model.projects.last?.id)
    model.updateProject(id: payments, name: "Payments", jiraKeys: "PAY")

    model.selection = .project(hiring)

    // **Drives the live path deliberately.** This is the same
    // `CaptureFieldModel` wiring `NewTaskSheet` builds — not
    // `MainWindowModel.createTask`, which production no longer calls. An
    // end-to-end claim has to travel the route the user's keystrokes take,
    // or it is an end-to-end claim about nothing.
    let field = CaptureFieldModel(
        service: model.captureService(),
        projects: { model.projects },
        preferred: { model.preferredProjectIDForCapture },
        onCaptured: { _ in model.reload() }
    )
    field.text = "PAY-421 fix the retry handler"

    // The chip is the user-visible half of the same routing decision, and
    // it is the thing the editor exists to make reachable at all.
    #expect(field.chip?.projectID == payments)

    field.commit()

    // Under All, because the key routed the task away from the selection and
    // `groups` only ever holds the selected project's tasks.
    model.selection = .all

    // The whole point of the editor: without it every project holds [] and
    // this assertion cannot be made to pass by any user action.
    let landed = try #require(model.groups.flatMap(\.tasks).first)
    #expect(landed.projectID == payments)
}
