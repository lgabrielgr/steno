import Foundation
import SwiftData
import Testing

@testable import StenoKit

// D-148: the sheet opens on M2-02's raw report and upgrades in place, but only
// while the user has not touched it.

/// A string the renderer would never produce, so "the user's edit wins" cannot
/// pass against an implementation that re-renders or re-installs.
private let editedDraft = "the user rewrote every word of this by hand"

/// A draft sheet whose §7.3 call answers with `result`.
@MainActor
private func draftBeingPolished(
    _ fixture: ReportFixture, answering result: SummarizedStandup
) throws -> (model: StandupDraftModel, window: GatheredWindow) {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900),
        undoService: fixture.standupUndoService(),
        polish: { _ in result })
    model.begin(window: window, text: "generated text")
    return (model, window)
}

/// Let the polish task run to completion.
///
/// Bounded rather than `while model.isPolishing`: a defect that leaves the flag
/// set should fail the assertion that follows, not hang the suite.
@MainActor
private func settle(_ model: StandupDraftModel) async {
    for _ in 0..<1000 {
        if !model.isPolishing { return }
        await Task.yield()
    }
}

@MainActor
@Test("the AI draft replaces the raw one when the user has not typed")
func thePolishInstallsOverAnUntouchedDraft() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))

    // The sheet is usable from the first frame — §7.4's guarantee is that the
    // user is never holding nothing while a network call decides.
    #expect(model.text == "generated text")
    #expect(model.canCopy)

    await settle(model)

    #expect(model.text == "polished")
    #expect(model.aiModelUsed == "model-x")
    #expect(model.phase == .editing)
}

@MainActor
@Test("a draft the user has started editing is never overwritten")
func thePolishYieldsToTheUser() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))

    // FR-4 step 6 and §7.3: the user's phrasing is the final word. Text
    // replaced under a cursor would violate both.
    model.text = editedDraft
    await settle(model)

    #expect(model.text == editedDraft)
    #expect(model.aiModelUsed == nil, "an AI draft that was discarded did not produce this report")
}

@MainActor
@Test("a fallback result leaves the raw draft and the flag alone")
func aFallbackChangesNothing() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "some other text", modelUsed: nil))

    await settle(model)

    // Nothing is installed when `modelUsed` is nil. In production the fallback
    // markdown is byte-identical to what `begin` installed; the answer here is
    // deliberately different, so a version that assigned it would be caught.
    #expect(model.text == "generated text")
    #expect(model.aiModelUsed == nil)
}

@MainActor
@Test("copying marks the report with the model that wrote it")
func theCommittedReportRecordsTheModel() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))
    await settle(model)

    #expect(model.commit(to: fixture.alpha))

    let report = try #require(fixture.reportsInStore().first)
    #expect(report.markdownBody == "polished")
    #expect(report.wasAIGenerated)
    #expect(report.modelUsed == "model-x")
}

@MainActor
@Test("a report from the raw draft is not marked AI-generated")
func aRawReportIsNotMarkedAIGenerated() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "unused", modelUsed: nil))
    await settle(model)

    #expect(model.commit(to: fixture.alpha))

    let report = try #require(fixture.reportsInStore().first)
    #expect(report.wasAIGenerated == false)
    #expect(report.modelUsed == nil)
}

@MainActor
@Test("editing the AI's words keeps the report marked AI-generated")
func editingAfterThePolishKeepsTheFlag() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))
    await settle(model)

    // The report *was* AI-generated and the user polished it, which is what
    // FR-4 step 6 intends. A flag that flipped on the first keystroke would
    // mark nearly every real AI report as a fallback.
    model.text = editedDraft
    #expect(model.commit(to: fixture.alpha))

    let report = try #require(fixture.reportsInStore().first)
    #expect(report.markdownBody == editedDraft)
    #expect(report.wasAIGenerated)
    #expect(report.modelUsed == "model-x")
}

@MainActor
@Test("dismissing stops the polish and forgets the model")
func dismissEndsThePolish() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))

    model.dismiss()
    await settle(model)

    #expect(model.isPolishing == false)
    #expect(model.aiModelUsed == nil)
    #expect(model.text == "")
}

// MARK: - A superseded polish (PR #37 review)

/// Holds a polish open until the test lets it finish.
///
/// Cancellation is cooperative, so "the first call is still suspended when the
/// second begins" is the state that needs reproducing, and a closure that
/// returns immediately can never reproduce it.
@MainActor
private final class PolishGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Whether a call has actually reached this gate.
    ///
    /// **Load-bearing.** `begin` creates a `Task` and returns; the task body has
    /// not run yet. A test that dismissed immediately would cancel a call that
    /// never entered `polish`, never reproduce "an earlier call is still
    /// suspended", and pass against the defect it was written for — which is
    /// exactly what the first version of this test did, and what the mutation
    /// sweep caught.
    var isHolding: Bool { !waiting.isEmpty }

    func wait() async {
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        let held = waiting
        waiting = []
        held.forEach { $0.resume() }
    }
}

/// Yield until `gate` is holding a call, or give up and let the assertion say so.
@MainActor
private func untilHolding(_ gate: PolishGate) async {
    for _ in 0..<1000 {
        if gate.isHolding { return }
        await Task.yield()
    }
}

@MainActor
@Test("a superseded polish does not clear the next one's in-flight state")
func aStalePolishLeavesTheNewOneAlone() async throws {
    let fixture = try ReportFixture()
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    let first = PolishGate()
    let second = PolishGate()
    var call = 0
    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900),
        undoService: fixture.standupUndoService(),
        polish: { _ in
            call += 1
            await (call == 1 ? first : second).wait()
            return SummarizedStandup(markdown: "polished", modelUsed: "model-x")
        })

    model.begin(window: window, text: "generated text")
    await untilHolding(first)
    #expect(first.isHolding, "precondition: the first call reached the network")

    model.dismiss()
    model.begin(window: window, text: "a second draft")
    await untilHolding(second)
    #expect(second.isHolding, "precondition: the second call reached the network")
    #expect(model.isPolishing, "precondition: the second call is in flight")

    // The first call resumes now — after its sheet is gone and a new one is
    // waiting. It must touch nothing.
    first.release()
    for _ in 0..<50 { await Task.yield() }

    #expect(model.isPolishing, "a call from a dismissed sheet hid the live one's progress")
    #expect(model.text == "a second draft")

    // And the live call still lands when it answers.
    second.release()
    for _ in 0..<50 { await Task.yield() }
    #expect(model.isPolishing == false)
    #expect(model.text == "polished")
}
