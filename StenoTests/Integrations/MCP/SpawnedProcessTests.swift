import Darwin
import Foundation
import Testing

@testable import StenoKit

/// The spawner on its own, below any protocol (D-235).
@Suite(.timeLimit(.minutes(1))) struct SpawnedProcessTests {
    @Test("writing to a process that has exited fails instead of raising SIGPIPE")
    func noSigpipe() async throws {
        let launch = ChildLaunch(
            executable: "/usr/bin/true", arguments: [], environment: [:])
        let process = try SpawnedProcess.spawn(launch)
        _ = await process.exitStatus.value
        // Default SIGPIPE disposition terminates the writer — the test runner
        // here, the app in production. Surviving to see `false` is the test.
        let accepted = await withCheckedContinuation { continuation in
            process.write(Data("x\n".utf8)) { continuation.resume(returning: $0) }
        }
        #expect(accepted == false)
    }

    @Test("terminate empties the group, grandchild included")
    func terminateEmptiesTheGroup() async throws {
        let process = try SpawnedProcess.spawn(
            try MCPStub.launch("ignore-eof", "ignore-term", "spawn-grandchild"))
        #expect(await eventually { ProcessGroup.hasMembers(process.pid) })
        // Every escalation step is needed: EOF and SIGTERM are both ignored.
        #expect(try await bounded { await process.terminate(grace: .milliseconds(300)) })
        #expect(!ProcessGroup.hasMembers(process.pid))
    }

    @Test("a missing executable is commandNotFound, not a crash")
    func spawnFailure() {
        let launch = ChildLaunch(
            executable: "/nonexistent/server", arguments: [], environment: [:])
        #expect(throws: MCPError.commandNotFound) { try SpawnedProcess.spawn(launch) }
    }
}
