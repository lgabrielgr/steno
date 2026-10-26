import Darwin
import Foundation
import Testing

@testable import StenoKit

/// Acceptance criterion 5: subprocesses do not leak across app restarts — and
/// the reap that guarantees it never kills something that is not ours (D-236).
///
/// A "previous app run" is a ledger whose owner is dead: `MCPStub.deadOwner`.
/// The reaping ledger reads the same file, as the next launch would.
@Suite(.timeLimit(.minutes(1))) struct ProcessLedgerTests {
    /// Spawn the stub, wait until it has answered once — so a grandchild it
    /// starts at launch exists — and record it under `ledger`.
    private func spawnRecorded(
        in ledger: ProcessLedger, _ modes: String...
    ) async throws -> SpawnedProcess {
        let arguments = modes.isEmpty ? [] : ["--mode", modes.joined(separator: ",")]
        let launch = ChildLaunch(
            executable: try MCPStub.path, arguments: arguments, environment: [:])
        let process = try SpawnedProcess.spawn(launch)
        ledger.record(process.identity)
        process.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8 + [0x0A])) { _ in }
        let answered = try await bounded {
            for await chunk in process.standardOutput where !chunk.isEmpty { return true }
            return false
        }
        #expect(answered)
        return process
    }

    @Test("an orphan of a dead owner is killed, grandchild included")
    func reapsOrphan() async throws {
        let previous = MCPStub.ledger(owner: MCPStub.deadOwner)
        let process = try await spawnRecorded(in: previous, "ignore-eof", "spawn-grandchild")
        #expect(ProcessGroup.hasMembers(process.pid))

        let next = ProcessLedger(fileURL: previous.fileURL)
        let report = try await bounded { await next.reapOrphans(grace: .milliseconds(300)) }
        #expect(report.killed == 1)
        #expect(await eventually { !ProcessGroup.hasMembers(process.pid) })
        #expect(next.entries.isEmpty)
    }

    @Test("an entry whose owner is alive is left alone")
    func liveOwnerIsNotReaped() async throws {
        let ledger = MCPStub.ledger()
        let process = try await spawnRecorded(in: ledger)

        let report = try await bounded { await ledger.reapOrphans(grace: .milliseconds(300)) }
        #expect(report == ProcessLedger.Report())
        #expect(processExists(process.pid))
        #expect(ledger.entries.count == 1)
        _ = await process.terminate(grace: .milliseconds(300))
    }

    @Test("a reused pid — same pid, different start time — is never signalled")
    func reusedPidIsSpared() async throws {
        let scratch = MCPStub.ledger()
        let process = try await spawnRecorded(in: scratch)
        // A group leader we own, standing in for the stranger who now holds
        // the pid: if the start-time check were gone, this is what dies.
        let stale = ProcessIdentity(
            pid: process.pid, startSeconds: process.identity.startSeconds - 1,
            startMicroseconds: 0)
        let previous = ProcessLedger(fileURL: scratch.fileURL, owner: MCPStub.deadOwner)
        scratch.remove(process.identity)
        previous.record(stale)

        let next = ProcessLedger(fileURL: scratch.fileURL)
        let report = try await bounded { await next.reapOrphans(grace: .milliseconds(300)) }
        #expect(report.reused == 1)
        #expect(report.killed == 0)
        #expect(processExists(process.pid))
        #expect(next.entries.isEmpty)
        _ = await process.terminate(grace: .milliseconds(300))
    }

    @Test("a dead leader's surviving group members are still reaped")
    func deadLeaderLiveMembers() async throws {
        let previous = MCPStub.ledger(owner: MCPStub.deadOwner)
        let process = try await spawnRecorded(in: previous, "ignore-eof", "spawn-grandchild")
        // The `npx`-exited, `node`-lingering shape.
        kill(process.pid, SIGKILL)
        _ = await process.exitStatus.value
        #expect(ProcessIdentity.current(of: process.pid) == nil)
        #expect(ProcessGroup.hasMembers(process.pid))

        let next = ProcessLedger(fileURL: previous.fileURL)
        let report = try await bounded { await next.reapOrphans(grace: .milliseconds(300)) }
        #expect(report.killed == 1)
        #expect(await eventually { !ProcessGroup.hasMembers(process.pid) })
    }

    @Test("an entry for a group that is already gone is dropped")
    func alreadyGone() async throws {
        let previous = MCPStub.ledger(owner: MCPStub.deadOwner)
        let process = try await spawnRecorded(in: previous)
        _ = await process.terminate(grace: .milliseconds(300))

        let next = ProcessLedger(fileURL: previous.fileURL)
        let report = try await bounded { await next.reapOrphans(grace: .milliseconds(300)) }
        #expect(report.alreadyGone == 1)
        #expect(next.entries.isEmpty)
    }
}
