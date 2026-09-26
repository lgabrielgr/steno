import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 step 4 inside the draft sheet: the refresh stage, and the window
/// replacement rule (D-175).

/// A string the renderer would never produce, so "the user's text survives"
/// cannot pass against an implementation that re-renders unconditionally.
private let typedByHand = "the user rewrote every word of this by hand"

/// A refresh stage the test drives: it suspends until released, so "is the sheet
/// still refreshing?" is a real question rather than a race.
///
/// `@MainActor` because it is called on the main actor and mutates its own state
/// from there.
@MainActor
private final class ScriptedRefresh {
    private(set) var calls = 0
    private(set) var polishedWindows: [GatheredWindow] = []
    private var release: CheckedContinuation<Void, Never>?

    /// What the stage answers with once released.
    var result: (GatheredWindow) -> RefreshedWindow = {
        RefreshedWindow(window: $0, outcome: .idle)
    }

    /// The closure `StandupDraftModel` takes.
    func stage() -> @MainActor (GatheredWindow) async -> RefreshedWindow {
        { [self] window in
            calls += 1
            await withCheckedContinuation { continuation in release = continuation }
            return result(window)
        }
    }

    /// The polish closure, recording which window it was handed.
    func polish() -> @MainActor (GatheredWindow) async -> SummarizedStandup {
        { [self] window in
            polishedWindows.append(window)
            return SummarizedStandup(
                markdown: StandupSummarizer.rawMarkdown(for: window), modelUsed: nil)
        }
    }

    /// Let the refresh finish, then yield until the chain has moved on.
    ///
    /// **The yields matter.** A `Task` has not started when `begin` returns and
    /// cancellation is cooperative, so a test that asserted immediately after
    /// resuming would be asserting against a stage that had not run yet.
    func finish() async {
        while release == nil { await Task.yield() }
        release?.resume()
        release = nil
        for _ in 0..<8 { await Task.yield() }
    }

    /// Wait until the stage has suspended, without releasing it.
    func waitUntilRefreshing() async {
        while release == nil { await Task.yield() }
    }
}

@MainActor
private func draft(
    _ fixture: ReportFixture, _ scripted: ScriptedRefresh, now: TimeInterval = 300
) throws -> (model: StandupDraftModel, window: GatheredWindow) {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: now).gather(for: fixture.alpha)

    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900),
        undoService: fixture.standupUndoService(),
        polish: scripted.polish(),
        refresh: scripted.stage(),
        now: { ReportFixture.origin.addingTimeInterval(now) })
    model.begin(window: window, text: "generated text")
    return (model, window)
}

/// A window that differs from the one `begin` was given, standing in for the
/// re-gather after a pass appended events.
private func regathered(from window: GatheredWindow) -> GatheredWindow {
    GatheredWindow(
        projectID: window.projectID, cadence: window.cadence, start: window.start,
        end: window.end.addingTimeInterval(60),
        tasks: window.tasks.map { task in
            GatheredTask(
                id: task.id, title: task.title, status: task.status,
                ticketKeys: task.ticketKeys, blockedReason: task.blockedReason,
                events: task.events + [
                    GatheredEvent(
                        timestamp: window.end, kind: .externalUpdate,
                        body: "PAY-421: moved to In Review")
                ])
        })
}

@MainActor
@Test("FR-4 step 4: the sheet is refreshing before it is polishing, and Copy stays live")
func theRefreshIsVisibleAndNonBlocking() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, _) = try draft(fixture, scripted)

    await scripted.waitUntilRefreshing()

    #expect(model.isRefreshing)
    // The raw report is already on screen and committable: §7.4's promise is that
    // the user is never left holding nothing while a network call decides.
    #expect(model.text == "generated text")
    #expect(model.canCopy)
    #expect(scripted.polishedWindows.isEmpty)

    await scripted.finish()

    #expect(!model.isRefreshing)
    #expect(scripted.polishedWindows.count == 1)
}

@MainActor
@Test("D-175: a pass that wrote something replaces the window and re-renders the draft")
func aWritingPassReplacesTheWindow() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, window) = try draft(fixture, scripted)
    let updated = regathered(from: window)
    scripted.result = { _ in
        RefreshedWindow(
            window: updated, outcome: RefreshOutcome(attempted: 1, cached: 1, changed: 1))
    }

    await scripted.finish()

    #expect(model.window == updated)
    // The re-render is the same two pure functions `prepareStandup` uses, so the
    // externalUpdate event the pass appended is now in the text the user reads.
    #expect(model.text.contains("moved to In Review"))
    // And the polish ran on the replaced window, not the stale one.
    #expect(scripted.polishedWindows == [updated])
}

@MainActor
@Test("D-175: a typed draft keeps its own text and its original window")
func aTypedDraftIsNotOverwritten() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, window) = try draft(fixture, scripted)
    let updated = regathered(from: window)
    scripted.result = { _ in
        RefreshedWindow(
            window: updated, outcome: RefreshOutcome(attempted: 1, cached: 1, changed: 1))
    }

    await scripted.waitUntilRefreshing()
    model.text = typedByHand
    await scripted.finish()

    // Both directions. Replacing the window under a typed draft would advance
    // `lastStandupAt` past events the user's text never mentions — consuming them
    // from the window and losing them from recall (D-076's harm).
    #expect(model.text == typedByHand)
    #expect(model.window == window)
    #expect(scripted.polishedWindows == [window])
}

@MainActor
@Test("D-175: a pass that wrote nothing leaves the window and the text alone")
func anIdlePassChangesNothing() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, window) = try draft(fixture, scripted)
    scripted.result = { RefreshedWindow(window: $0, outcome: RefreshOutcome(attempted: 2)) }

    await scripted.finish()

    #expect(model.window == window)
    #expect(model.text == "generated text")
    #expect(model.sourceNotice == nil)
}

@MainActor
@Test("§5.2: the staleness label reaches the sheet and never the clipboard")
func theStalenessLabelIsAppSideOnly() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, window) = try draft(fixture, scripted)
    scripted.result = {
        RefreshedWindow(
            window: $0,
            outcome: RefreshOutcome(
                attempted: 1,
                failures: [
                    RefreshOutcome.Failure(
                        connectorID: "jira", displayName: "Jira", error: .network,
                        cachedAt: window.end.addingTimeInterval(-2 * 86400))
                ]))
    }

    await scripted.finish()

    #expect(model.sourceNotice == "Couldn't reach Jira — using 2 days old data.")
    // D-176: the copied markdown is untouched. The label is for the user deciding
    // how much to trust the draft, not for the audience of the stand-up.
    #expect(!model.text.contains("Jira"))
    #expect(model.commit(to: fixture.alpha))
    #expect(try fixture.reportsInStore().first?.markdownBody == model.text)
}

@MainActor
@Test("dismissing during a refresh touches no state, and skips the polish entirely")
func dismissDuringRefreshIsInert() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, window) = try draft(fixture, scripted)
    let updated = regathered(from: window)
    scripted.result = { _ in
        RefreshedWindow(
            window: updated, outcome: RefreshOutcome(attempted: 1, cached: 1, changed: 1))
    }

    // Wait for the stage to actually suspend before dismissing: a `Task` has not
    // started when `begin` returns, so dismissing immediately would test nothing.
    await scripted.waitUntilRefreshing()
    model.dismiss()
    await scripted.finish()

    #expect(model.window == nil)
    #expect(model.text.isEmpty)
    #expect(!model.isRefreshing)
    #expect(model.sourceNotice == nil)
    // The superseded refresh must not start a polish for a sheet that is gone.
    #expect(scripted.polishedWindows.isEmpty)
}

@MainActor
@Test("preparing a second window supersedes the first refresh")
func asecondPrepareSupersedesTheFirst() async throws {
    let fixture = try ReportFixture()
    let scripted = ScriptedRefresh()
    let (model, window) = try draft(fixture, scripted)
    let updated = regathered(from: window)
    scripted.result = { _ in
        RefreshedWindow(
            window: updated, outcome: RefreshOutcome(attempted: 1, cached: 1, changed: 1))
    }

    await scripted.waitUntilRefreshing()
    model.begin(window: window, text: "second draft")
    await scripted.finish()

    // The first stage's answer is discarded: its generation has moved on, so it
    // must not replace the window of a draft it was never about.
    #expect(model.text == "second draft")
    #expect(model.window == window)
}
