import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// Two triggers at once (D-181, D-183).
///
/// Split from `SourceRefreshServiceTests` for `file_length`, along the seam the
/// subject already has: everything here is about what happens when the launch pass
/// and a Prepare pass overlap, where that file covers one pass at a time.

@MainActor
@Test("D-183: two triggers firing together are serialized, so the second sees the first's write")
func overlappingTriggersAreSerialized() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let taskID = task.id

    // §5.5's launch pass is fire-and-forget and the user can press Prepare while it
    // is in flight, so two services run over one context. Sharing one gate is what
    // the running app does — `SourceRefreshService` defaults to `.shared`.
    let gate = SourceRefreshGate()
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .slow(.stub(summary: "In Review"), .milliseconds(80))])
    let launch = fixture.service(connectors: [connector], nowOffset: 60, gate: gate)
    let prepare = fixture.service(connectors: [connector], nowOffset: 120, gate: gate)

    async let launchPass = launch.refresh(taskIDs: [taskID])
    async let preparePass = prepare.refresh(taskIDs: [taskID])
    let outcomes = await [launchPass, preparePass]

    // One event, because the second pass reads the row *after* the first wrote it:
    // it is no longer a first observation, and the stub reports no changes. Both
    // passes still fetched and cached, and nothing was superseded — which is the
    // point. Before D-183 both snapshotted the same `since` and one result had to be
    // thrown away, which could lose a real change (Copilot, PR #42).
    #expect(try fixture.eventsInStore(kind: .externalUpdate).count == 1)
    #expect(outcomes.map(\.changed).reduce(0, +) == 1)
    #expect(outcomes.map(\.cached).reduce(0, +) == 2)
    #expect(outcomes.map(\.superseded).reduce(0, +) == 0)
    #expect(outcomes.map(\.attempted).reduce(0, +) == 2)

    // The second pass was told to look for changes since the first pass's stamp, not
    // since nil — the observable evidence that it read fresh rows.
    #expect(connector.asked.compactMap(\.since).count == 1)
}

@MainActor
@Test("D-181: a pass that bypasses the gate still cannot clobber a newer write")
func aPassThatBypassesTheGateIsSuperseded() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let taskID = task.id

    // Separate gates, so the two passes genuinely overlap — the state D-183 exists
    // to prevent, kept under test because the write-phase guard is the defence if
    // any future trigger is built with its own gate.
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .slow(.stub(summary: "In Review"), .milliseconds(80))])
    let first = fixture.service(connectors: [connector], nowOffset: 60)
    let second = fixture.service(connectors: [connector], nowOffset: 120)

    async let firstPass = first.refresh(taskIDs: [taskID])
    async let secondPass = second.refresh(taskIDs: [taskID])
    let outcomes = await [firstPass, secondPass]

    // Exactly one applied; the other is superseded rather than writing a second
    // first-observation event and stamping an older read over a newer one.
    #expect(try fixture.eventsInStore(kind: .externalUpdate).count == 1)
    #expect(outcomes.map(\.cached).reduce(0, +) == 1)
    #expect(outcomes.map(\.superseded).reduce(0, +) == 1)
}

@MainActor
@Test("D-183: the launch pass and a Prepare pass are serialized against each other")
func theLaunchPassAndPrepareAreSerialized() async throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("ship payments")
    try fixture.ref("PAY-421", on: task)
    let taskID = task.id

    // **The production pairing**, and the one that goes wrong: `refreshDue` is fired
    // and forgotten at launch, and `refresh(taskIDs:)` runs when the user presses
    // Prepare — which they can do while the first is still on the network. Both
    // entry points have to be gated; a mutation that routed only `refresh(taskIDs:)`
    // through the gate survived until this test existed.
    let gate = SourceRefreshGate()
    let connector = StubSourceConnector(
        scripts: ["PAY-421": .slow(.stub(summary: "In Review"), .milliseconds(80))])
    let launch = fixture.service(connectors: [connector], nowOffset: 60, gate: gate)
    let prepare = fixture.service(connectors: [connector], nowOffset: 120, gate: gate)

    async let launchPass = launch.refreshDue()
    async let preparePass = prepare.refresh(taskIDs: [taskID])
    let outcomes = await [launchPass, preparePass]

    #expect(outcomes.map(\.attempted).reduce(0, +) == 2)
    #expect(outcomes.map(\.cached).reduce(0, +) == 2)
    // Nothing thrown away means nothing that could have carried a lost change.
    #expect(outcomes.map(\.superseded).reduce(0, +) == 0)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).count == 1)
}
