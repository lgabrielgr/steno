import Darwin
import Foundation
import Testing

@testable import StenoKit

/// Acceptance criteria 2 and 3: a crash is detected and contained, and a hang
/// hits a timeout — and in both cases no process is left behind.
@Suite(.timeLimit(.minutes(1))) struct MCPServerFailureTests {
    @Test("a crash is reported, and the next request starts a fresh process")
    func crashThenRestart() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition(), ledger: ledger)
        try await bounded { try await server.ping() }
        let first = try #require(ledger.entries.first?.leader.pid)

        let error = await thrown { _ = try await server.callTool("crash") }
        #expect(error as? MCPError == .crashed)
        #expect(await eventually { ledger.entries.isEmpty })
        #expect(await server.status == .idle)

        try await bounded { try await server.ping() }
        let second = try #require(ledger.entries.first?.leader.pid)
        #expect(second != first)
        await server.stop()
    }

    @Test("three failures in the window and it stays down until restart")
    func failsRepeatedly() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition(), ledger: ledger)
        for _ in 0..<3 {
            _ = await thrown { _ = try await server.callTool("crash") }
            // The crash is noticed by the exit watcher; wait for it to land.
            _ = await eventually { ledger.entries.isEmpty }
        }
        #expect(await eventually { await server.status == .failed })

        let refused = await thrown { try await server.ping() }
        #expect(refused as? MCPError == .failedRepeatedly)
        #expect(ledger.entries.isEmpty)

        await server.restart()
        try await bounded { try await server.ping() }
        await server.stop()
    }

    @Test("failures older than the window do not count")
    func failuresExpire() async throws {
        let ledger = MCPStub.ledger()
        var configuration = MCPStub.fast
        configuration.failureWindow = .milliseconds(200)
        let server = MCPStub.server(
            try MCPStub.definition(), ledger: ledger, configuration: configuration)
        for _ in 0..<3 {
            _ = await thrown { _ = try await server.callTool("crash") }
            _ = await eventually { ledger.entries.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(await server.status == .idle)
        try await bounded { try await server.ping() }
        await server.stop()
    }

    @Test("an exit before initialize carries the exit status")
    func exitBeforeInitialize() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition("exit-before-init"), ledger: ledger)
        let error = await thrown { try await server.ping() }
        // A raw `waitpid` status: exit code 3 in the high byte.
        #expect(error as? MCPError == .exitedDuringStartup(status: 3 << 8))
        #expect(ledger.entries.isEmpty)
    }

    @Test("a command that resolves nowhere is commandNotFound")
    func commandNotFound() async throws {
        let server = MCPStub.server(
            MCPServerDefinition(id: "missing", command: "no-such-server-xyz"))
        let error = await thrown { try await server.ping() }
        #expect(error as? MCPError == .commandNotFound)
    }

    @Test("a server that never answers initialize times out, and is gone")
    func hangOnInitialize() async throws {
        let ledger = MCPStub.ledger()
        var configuration = MCPStub.fast
        configuration.startupTimeout = .milliseconds(300)
        let server = MCPStub.server(
            try MCPStub.definition("hang-on-init"), ledger: ledger, configuration: configuration)

        let started = ContinuousClock.now
        let error = await thrown { try await server.ping() }
        #expect(error as? MCPError == .timedOut)
        // Generous: this bounds "did not hang", not performance.
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(ledger.entries.isEmpty)
    }

    @Test("stop during a start does not wait out the startup deadline")
    func stopDuringStart() async throws {
        let ledger = MCPStub.ledger()
        // A ten-second startup deadline; app quit's whole budget is three.
        let server = MCPStub.server(try MCPStub.definition("hang-on-init"), ledger: ledger)
        let request = Task { try await server.ping() }
        #expect(await eventually { await server.status == .starting })
        #expect(await eventually { !ledger.entries.isEmpty })

        let started = ContinuousClock.now
        #expect(try await bounded { await server.stop() })
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await request.result.error as? MCPError == .stopped)
        #expect(ledger.entries.isEmpty)
    }

    @Test("a tool that hangs times out, and the process is ended")
    func hangOnCall() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition(), ledger: ledger)
        try await bounded { try await server.ping() }
        let leader = try #require(ledger.entries.first?.leader.pid)

        let started = ContinuousClock.now
        let error = await thrown {
            _ = try await server.callTool("hang", timeout: .milliseconds(300))
        }
        #expect(error as? MCPError == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await server.status == .idle)
        #expect(await eventually { !processExists(leader) })
        // The teardown runs after the caller has its error (D-238).
        #expect(await eventually { ledger.entries.isEmpty })
    }

    @Test("a timeout reaches the caller at its deadline, not after the teardown")
    func timeoutDoesNotWaitForTeardown() async throws {
        let ledger = MCPStub.ledger()
        var configuration = MCPStub.fast
        // Stopping this server takes about two graces: EOF and SIGTERM are
        // both ignored, so only the SIGKILL ends it.
        configuration.terminateGrace = .seconds(1)
        let server = MCPStub.server(
            try MCPStub.definition("ignore-eof", "ignore-term"), ledger: ledger,
            configuration: configuration)
        try await bounded { try await server.ping() }

        let started = ContinuousClock.now
        let error = await thrown {
            _ = try await server.callTool("hang", timeout: .milliseconds(300))
        }
        #expect(error as? MCPError == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(1))

        // The teardown still happens, and `stop()` waits for it.
        #expect(try await bounded { await server.stop() })
        #expect(ledger.entries.isEmpty)
    }

    @Test("a server that closes its stdin but keeps running is taken down")
    func deadStdinDropsServer() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition("close-stdin"), ledger: ledger)
        try await bounded { try await server.ping() }
        let leader = try #require(ledger.entries.first?.leader.pid)

        let error = await thrown { _ = try await server.callTool("echo") }
        #expect(error as? MCPError == .crashed)
        // Not `.ready`, failing every later request without counting any.
        #expect(await eventually { await server.status == .idle })
        #expect(await eventually { !processExists(leader) })
        #expect(await eventually { ledger.entries.isEmpty })
    }

    @Test("restart does not orphan a server started while it was stopping")
    func restartKeepsAConcurrentStart() async throws {
        let ledger = MCPStub.ledger()
        var configuration = MCPStub.fast
        // A stop of about two seconds: a window for a request to start a
        // new process while `restart()` is suspended in it.
        configuration.terminateGrace = .seconds(1)
        let server = MCPStub.server(
            try MCPStub.definition("ignore-eof", "ignore-term"), ledger: ledger,
            configuration: configuration)
        try await bounded { try await server.ping() }

        let restart = Task { await server.restart() }
        #expect(await eventually { await server.status == .idle })
        try await bounded { try await server.ping() }
        await restart.value

        // The process the ping started is still the server's, and stoppable.
        #expect(await server.status == .ready)
        #expect(try await bounded { await server.stop() })
        #expect(ledger.entries.isEmpty)
    }

    @Test("a server that stops reading stdin cannot block a write past its deadline")
    func blockedWrite() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition("stop-reading-stdin"), ledger: ledger)
        try await bounded { try await server.ping() }
        let leader = try #require(ledger.entries.first?.leader.pid)

        // 1 MB is sixteen times a pipe's buffer: the write cannot complete.
        let payload = String(repeating: "x", count: 1024 * 1024)
        let error = await thrown {
            _ = try await server.callTool(
                "echo", arguments: ["text": .string(payload)], timeout: .milliseconds(300))
        }
        #expect(error as? MCPError == .timedOut)
        // Killing the group is what releases the blocked writer.
        #expect(await eventually { !processExists(leader) })
        // The teardown runs after the caller has its error (D-238).
        #expect(await eventually { ledger.entries.isEmpty })
    }

    @Test("an unsupported protocol version is refused, and the process is ended")
    func badVersion() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition("bad-version"), ledger: ledger)
        let error = await thrown { try await server.ping() }
        #expect(error as? MCPError == .unsupportedProtocolVersion)
        #expect(ledger.entries.isEmpty)
    }

    @Test("a message over the cap ends the connection")
    func oversizedMessage() async throws {
        var configuration = MCPStub.fast
        configuration.maximumMessageLength = 4 * 1024
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(
            try MCPStub.definition(), ledger: ledger, configuration: configuration)
        let error = await thrown { _ = try await server.callTool("big") }
        #expect(error as? MCPError == .protocolViolation(.oversizedMessage))
        #expect(await eventually { ledger.entries.isEmpty })
    }

    @Test("a list that never stops paginating is cut off")
    func paginationRunaway() async throws {
        let server = MCPStub.server(try MCPStub.definition("paginate-forever"))
        let error = await thrown { _ = try await server.listTools() }
        #expect(error as? MCPError == .protocolViolation(.paginationRunaway))
        await server.stop()
    }

    @Test("cancelling the caller ends its wait")
    func cancellation() async throws {
        let server = MCPStub.server(try MCPStub.definition())
        try await bounded { try await server.ping() }
        let call = Task { try await server.callTool("hang") }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()
        // Not through `bounded`: `withDeadline` turns a `CancellationError`
        // into its own timeout error by design (D-146), which would hide the
        // very error this test looks for. The suite's time limit bounds it.
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        await server.stop()
    }
}
