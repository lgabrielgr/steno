import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 steps 1–6 through the main window, and the DONE window it moves.

private let origin = Date(timeIntervalSince1970: 1_000_000)

/// A model over a store holding one project with one in-progress, noted task.
///
/// `copy` is injected all the way down so the headless bundle never reaches the
/// real pasteboard — a test that did would mutate the developer's clipboard and
/// be order-dependent on anything else in the process that copies (§9.4).
@MainActor
private func modelWithReportableWork(
    now: @escaping () -> Date = { origin },
    copy: @escaping (String) -> Bool = { _ in true }
) throws -> (MainWindowModel, Project) {
    let container = try StenoStore.inMemory()
    // `ModelContext(container)` retains its container; `container.mainContext`
    // does not, and dangles the moment the container goes out of scope.
    let context = ModelContext(container)
    let project = Project(name: "Alpha", colorHex: "#112233", modifiedAt: origin)
    context.insert(project)
    let task = TaskItem(
        title: "ship the thing", projectID: project.id,
        createdAt: origin.addingTimeInterval(-3600))
    context.insert(task)
    task.setStatus(.inProgress, at: origin.addingTimeInterval(-3600))
    context.insert(
        Event(
            taskID: task.id, timestamp: origin.addingTimeInterval(-1800),
            kind: .note, body: "found the race in setUp"))
    try context.save()

    let model = MainWindowModel(context: context, now: now, copy: copy)
    model.selection = .project(project.id)
    return (model, project)
}

@MainActor
@Test("FR-4: generating a preview repeatedly writes nothing at all")
func generatingIsFreeOfSideEffects() throws {
    let (model, project) = try modelWithReportableWork()
    let counter = WriteCounter()

    // "The user can generate repeatedly, close the sheet, and their window is
    // untouched." Three times, because a side effect that only fires on the
    // first call would pass a single-call test.
    for _ in 0..<3 {
        model.prepareStandup()
        model.dismissStandupDraft()
    }

    #expect(counter.posts == 0)
    #expect(project.lastStandupAt == nil, "the clock only advances on Copy, never on generate")
    #expect(model.lastError == nil)
}

@MainActor
@Test("preparing a stand-up opens the sheet with the rendered draft")
func prepareOpensTheSheetWithADraft() throws {
    let (model, _) = try modelWithReportableWork()

    model.prepareStandup()

    #expect(model.activeSheet == .standupDraft)
    #expect(model.standupDraft.window != nil)
    // The §7.4 renderer's output, not a placeholder: D-073's headings are
    // `*bold*` because Slack `mrkdwn` has no heading syntax.
    #expect(model.standupDraft.text.contains("*Since last stand-up*"))
    #expect(model.standupDraft.text.contains("found the race in setUp"))
}

@MainActor
@Test("D16: the stand-up action is unavailable under the All pseudo-project")
func allPseudoProjectCannotPrepare() throws {
    let (model, _) = try modelWithReportableWork()

    model.selection = .all

    #expect(model.canPrepareStandup == false)
    model.prepareStandup()
    #expect(model.activeSheet == nil, "there is no single window to compute or clock to advance")
}

@MainActor
@Test("Copy advances the clock and appends the event, through the window")
func copyThroughTheWindowCommits() throws {
    let (model, project) = try modelWithReportableWork()
    model.prepareStandup()
    let generatedWindowEnd = model.standupDraft.window?.end

    model.copyStandup()

    #expect(model.standupDraft.phase == .copied)
    #expect(project.lastStandupAt == generatedWindowEnd)
    #expect(model.activeSheet == .standupDraft, "the sheet stays up so M2-04's undo has a home")
}

@MainActor
@Test("FR-3: copying moves the DONE window, so older completions drop out")
func copyMovesTheDoneWindow() throws {
    // A task finished 12 hours ago: inside the 24h first-run window, and
    // outside the window that Copy leaves behind.
    let (model, project) = try modelWithReportableWork()
    let finished = TaskItem(
        title: "finished earlier", projectID: project.id,
        createdAt: origin.addingTimeInterval(-13 * 3600))
    model.context.insert(finished)
    finished.setStatus(.done, at: origin.addingTimeInterval(-12 * 3600))
    try model.context.save()
    model.reload()

    #expect(
        model.groups.contains { $0.status == .done },
        "precondition: the first-run 24h window includes it")

    model.prepareStandup()
    model.copyStandup()

    // `lastStandupAt` is now `origin`, so FR-3's "current report window" is
    // `[origin, origin]` — and a task completed 12 hours ago is no longer in
    // it. Before D-077 this section was pinned to a hardcoded 24 hours and
    // would still have shown it.
    #expect(!model.groups.contains { $0.status == .done })
}
