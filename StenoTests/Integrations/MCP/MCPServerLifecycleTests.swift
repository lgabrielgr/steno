import Darwin
import Foundation
import Testing

@testable import StenoKit

/// Acceptance criterion 1: a local server starts, responds, and shuts down
/// cleanly — including the `npx` shape, where the server is a grandchild.
@Suite(.timeLimit(.minutes(1))) struct MCPServerLifecycleTests {
    @Test("nothing runs until the first request; then it is ready and negotiated")
    func startsLazily() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition(), ledger: ledger)
        #expect(await server.status == .idle)
        #expect(ledger.entries.isEmpty)

        try await bounded { try await server.ping() }
        #expect(await server.status == .ready)
        #expect(await server.negotiatedVersion == MCPProtocol.requestedVersion)
        #expect(ledger.entries.count == 1)
        await server.stop()
    }

    @Test("tools page through nextCursor; calls, tool errors and resources work")
    func toolsAndResources() async throws {
        let server = MCPStub.server(try MCPStub.definition())
        let tools = try await bounded { try await server.listTools() }
        // Page one holds `echo`, page two the other ten: a client that
        // stopped at the first page would see one tool.
        #expect(tools.map(\.name).first == "echo")
        #expect(tools.count == 11)

        let echo = try await bounded {
            try await server.callTool("echo", arguments: ["text": .string("hi")])
        }
        #expect(echo.text == "hi")
        #expect(echo.isError == false)

        // The tool reported failure; the transport did not. A result, not a throw.
        let failed = try await bounded { try await server.callTool("fail") }
        #expect(failed.isError)

        let resources = try await bounded { try await server.listResources() }
        #expect(resources.map(\.uri) == ["stub://readme"])
        let contents = try await bounded { try await server.readResource("stub://readme") }
        #expect(contents.first?.text == "hello")
        await server.stop()
    }

    @Test("a JSON-RPC error is serverError with its code and nothing else")
    func serverErrorKeepsOnlyTheCode() async throws {
        let server = MCPStub.server(try MCPStub.definition())
        let error = await thrown { _ = try await server.callTool("no-such-tool") }
        #expect(error as? MCPError == .serverError(code: -32_602))
        await server.stop()
    }

    @Test("stop ends the grandchild too, even when the server ignores EOF")
    func stopEndsTheWholeGroup() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(
            try MCPStub.definition("ignore-eof", "spawn-grandchild"), ledger: ledger)
        let reply = try await bounded { try await server.callTool("grandchild") }
        let grandchild = try #require(Int32(reply.text ?? ""))
        let leader = try #require(ledger.entries.first?.leader.pid)
        #expect(grandchild > 0 && processExists(grandchild))

        #expect(try await bounded { await server.stop() })
        // The grandchild is reparented to launchd and reaped there, so give it
        // a moment to vanish; the leader is reaped by our own waiter.
        #expect(await eventually { !processExists(grandchild) })
        #expect(await eventually { !processExists(leader) })
        #expect(ledger.entries.isEmpty)
    }

    @Test("a server that ignores EOF and SIGTERM is killed")
    func stopEscalatesToKill() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(
            try MCPStub.definition("ignore-eof", "ignore-term"), ledger: ledger)
        try await bounded { try await server.ping() }
        let leader = try #require(ledger.entries.first?.leader.pid)

        #expect(try await bounded { await server.stop() })
        #expect(await eventually { !processExists(leader) })
        #expect(ledger.entries.isEmpty)
    }

    @Test("a server's own requests: ping is answered, sampling is refused")
    func answersServerRequests() async throws {
        let server = MCPStub.server(try MCPStub.definition())
        let sampling = try await bounded { try await server.callTool("ask-client") }
        #expect(sampling.text == "error -32601")
        let ping = try await bounded { try await server.callTool("ping-client") }
        #expect(ping.text == "result")
        await server.stop()
    }

    @Test("a second reply to the same id is dropped, and the connection carries on")
    func duplicateReplyIsDropped() async throws {
        let server = MCPStub.server(try MCPStub.definition())
        let first = try await bounded { try await server.callTool("reply-twice") }
        #expect(first.text == "once")
        // The stray "twice" arrives for an id nothing waits on. The next
        // request must get its own reply, not the leftover.
        let echo = try await bounded {
            try await server.callTool("echo", arguments: ["text": .string("next")])
        }
        #expect(echo.text == "next")
        await server.stop()
    }

    @Test("a non-JSON line on stdout is dropped, not fatal")
    func survivesGarbage() async throws {
        let server = MCPStub.server(try MCPStub.definition("garbage-stdout"))
        let echo = try await bounded {
            try await server.callTool("echo", arguments: ["text": .string("still here")])
        }
        #expect(echo.text == "still here")
        await server.stop()
    }

    @Test("a server flooding stderr keeps answering, and only the tail is kept")
    func drainsStderr() async throws {
        let server = MCPStub.server(try MCPStub.definition("flood-stderr"))
        // Each reply is preceded by 256 KB of stderr — four times a pipe's
        // buffer. Undrained, the stub blocks in that write and never answers.
        for _ in 0..<3 {
            try await bounded { try await server.ping() }
        }
        let tail = server.recentStderr()
        #expect(!tail.isEmpty)
        #expect(tail.utf8.count <= StderrRing.capacity)
        await server.stop()
    }

    @Test("the server holds stdin, stdout and stderr, and nothing else of ours")
    func inheritsOnlyStandardDescriptors() async throws {
        // A descriptor this process holds open without close-on-exec — the
        // kind a store file or another library's socket would be.
        let held = open("/dev/null", O_RDONLY)
        defer { close(held) }
        #expect(held > 2)

        let server = MCPStub.server(try MCPStub.definition())
        let reply = try await bounded { try await server.callTool("open-fds") }
        #expect(reply.text == "0,1,2")
        await server.stop()
    }

    @Test("a reply written just before exit still arrives")
    func replyBeforeExit() async throws {
        let server = MCPStub.server(try MCPStub.definition())
        // A megabyte, so the reader is still draining the pipe when the exit
        // is reaped: closing on the exit alone would fail this request.
        let reply = try await bounded { try await server.callTool("reply-then-exit") }
        #expect(reply.text?.count == 1024 * 1024)
        await server.stop()
    }

    @Test("concurrent first requests share one start")
    func oneStartForConcurrentRequests() async throws {
        let ledger = MCPStub.ledger()
        let server = MCPStub.server(try MCPStub.definition(), ledger: ledger)
        try await bounded {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask { try await server.ping() }
                }
                try await group.waitForAll()
            }
        }
        #expect(ledger.entries.count == 1)
        await server.stop()
    }
}
