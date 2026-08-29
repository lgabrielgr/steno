import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeModelWithTask() throws -> (MainWindowModel, TaskItem) {
    let context = ModelContext(try StenoStore.inMemory())
    let model = MainWindowModel(context: context, now: { origin })
    model.createProject(named: "Payments")
    let task = try #require(
        try model.captureService().capture(
            text: "Fix the retry handler", preferred: model.preferredProjectIDForCapture))
    model.reload()
    model.selectedTaskID = task.id
    return (model, task)
}

@MainActor
@Test("status actions are disabled until a task is selected")
func canChangeStatusTracksTheSelection() throws {
    let (model, _) = try makeModelWithTask()
    #expect(model.canChangeStatus)

    model.selectedTaskID = nil
    #expect(!model.canChangeStatus)
}

@MainActor
@Test("cycling walks TODO, IN-PROGRESS, DONE and never lands on BLOCKED")
func cyclingWalksTheCycle() throws {
    let (model, task) = try makeModelWithTask()

    model.cycleStatusOnSelection()
    #expect(task.status == .inProgress)

    model.cycleStatusOnSelection()
    #expect(task.status == .done)

    model.cycleStatusOnSelection()
    #expect(task.status == .todo)
}

@MainActor
@Test("cycling with nothing selected does nothing")
func cyclingWithoutSelectionIsANoOp() throws {
    let (model, task) = try makeModelWithTask()
    model.selectedTaskID = nil

    model.cycleStatusOnSelection()

    #expect(task.status == .todo)
    #expect(model.lastError == nil)
}

@MainActor
@Test("marking blocked transitions and then offers the reason sheet")
func markingBlockedOffersTheReasonSheet() throws {
    let (model, task) = try makeModelWithTask()

    model.markSelectionBlocked()

    #expect(task.status == .blocked)
    #expect(model.activeSheet == .blockedReason(task.id))
}

@MainActor
@Test("marking a task blocked when it already is offers no sheet")
func blockingAnAlreadyBlockedTaskOffersNoSheet() throws {
    let (model, task) = try makeModelWithTask()
    model.markSelectionBlocked()
    model.activeSheet = nil

    model.markSelectionBlocked()

    #expect(task.status == .blocked)
    // No transition happened, so there is no event for a reason to annotate.
    #expect(model.activeSheet == nil)
}

@MainActor
@Test("the reason lands on the timeline of the selected task")
func blockedReasonReachesTheTimeline() throws {
    let (model, task) = try makeModelWithTask()
    model.markSelectionBlocked()

    model.addBlockedReason("Waiting on infra", to: task.id)

    #expect(
        model.selectedTaskEvents.contains { event in
            event.kind == .blockedReason && event.body == "Waiting on infra"
        })
}

@MainActor
@Test("a failed save surfaces an error and leaves the group alone")
func failedStatusSaveSurfacesAnError() throws {
    struct SaveFailure: Error {}
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)

    // Built with a working save so the fixture exists, then re-made with a
    // failing one — a real ModelContext cannot be made to fail on demand.
    let seed = MainWindowModel(context: context, now: { origin })
    seed.createProject(named: "Payments")
    try seed.captureService().capture(
        text: "Fix the retry handler", preferred: seed.preferredProjectIDForCapture)

    let model = MainWindowModel(
        context: context, now: { origin }, save: { _ in throw SaveFailure() })
    let taskID = try #require(model.groups.first?.tasks.first?.id)
    model.selectedTaskID = taskID

    model.cycleStatusOnSelection()

    #expect(model.lastError != nil)
    #expect(model.groups.map(\.status) == [.todo])
}
