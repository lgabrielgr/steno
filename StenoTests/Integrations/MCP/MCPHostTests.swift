import Darwin
import Foundation
import Testing

@testable import StenoKit

/// The app's two lifecycle edges: reap at launch, stop at quit.
@Suite(.timeLimit(.minutes(1))) struct MCPHostTests {
    @Test("shutdownAll stops every server")
    func shutdownStopsEverything() async throws {
        let ledger = MCPStub.ledger()
        let host = MCPHost(ledger: ledger, configuration: MCPStub.fast)
        for id in ["a", "b"] {
            let definition = MCPServerDefinition(
                id: id, command: try MCPStub.path, arguments: ["--mode", "ignore-eof"])
            let server = await host.server(for: definition)
            try await bounded { try await server.ping() }
        }
        let leaders = ledger.entries.map(\.leader.pid)
        #expect(leaders.count == 2)

        try await bounded { await host.shutdownAll() }
        #expect(ledger.entries.isEmpty)
        for pid in leaders {
            #expect(await eventually { !processExists(pid) })
        }
    }

    @Test("a server held past shutdownAll refuses instead of respawning")
    func heldServerAfterShutdown() async throws {
        let ledger = MCPStub.ledger()
        let host = MCPHost(ledger: ledger, configuration: MCPStub.fast)
        let server = await host.server(for: try MCPStub.definition())
        try await bounded { try await server.ping() }

        try await bounded { await host.shutdownAll() }
        // A refresh pass still running at quit holds exactly this reference.
        #expect(await thrown { try await server.ping() } as? MCPError == .stopped)
        #expect(ledger.entries.isEmpty)
    }

    @Test("shutdownAll returns at its budget even when a stop takes longer")
    func shutdownIsBounded() async throws {
        var configuration = MCPStub.fast
        configuration.terminateGrace = .seconds(2)
        let ledger = MCPStub.ledger()
        let host = MCPHost(ledger: ledger, configuration: configuration)
        let server = await host.server(
            for: try MCPStub.definition("ignore-eof", "ignore-term"))
        try await bounded { try await server.ping() }

        // Stopping this server takes three graces — six seconds.
        let started = ContinuousClock.now
        try await bounded { await host.shutdownAll(budget: .milliseconds(300)) }
        #expect(ContinuousClock.now - started < .seconds(3))
        _ = await server.stop()
    }

    @Test("the same definition gets the same server; a changed one replaces it")
    func serverIdentity() async throws {
        let ledger = MCPStub.ledger()
        let host = MCPHost(ledger: ledger, configuration: MCPStub.fast)
        let definition = try MCPStub.definition()
        let first = await host.server(for: definition)
        #expect(await host.server(for: definition) === first)

        try await bounded { try await first.ping() }
        let changed = MCPServerDefinition(
            id: definition.id, command: definition.command, arguments: ["--mode", "garbage-stdout"])
        let second = await host.server(for: changed)
        #expect(second !== first)
        // The replaced server was stopped, not abandoned — and a caller still
        // holding it cannot bring the old command back.
        #expect(await first.status == .idle)
        #expect(ledger.entries.isEmpty)
        #expect(await thrown { try await first.ping() } as? MCPError == .stopped)
        #expect(ledger.entries.isEmpty)
        await host.shutdownAll()
    }

    @Test("a server asked for after shutdownAll is already closed")
    func serverAfterShutdown() async throws {
        let ledger = MCPStub.ledger()
        let host = MCPHost(ledger: ledger, configuration: MCPStub.fast)
        await host.shutdownAll()

        // A refresh pass still running at quit, asking for the first time.
        let server = await host.server(for: try MCPStub.definition())
        #expect(await thrown { try await server.ping() } as? MCPError == .stopped)
        #expect(ledger.entries.isEmpty)
    }

    @Test("two callers replacing the same server at once get one server")
    func concurrentReplacement() async throws {
        let ledger = MCPStub.ledger()
        let host = MCPHost(ledger: ledger, configuration: MCPStub.fast)
        // Ignores EOF, so closing it takes a grace: both callers suspend there.
        let old = await host.server(for: try MCPStub.definition("ignore-eof"))
        try await bounded { try await old.ping() }

        let changed = try MCPStub.definition()
        async let first = host.server(for: changed)
        async let second = host.server(for: changed)
        let (one, two) = await (first, second)
        // Two would mean one of them is in nothing `shutdownAll` stops.
        #expect(one === two)

        try await bounded { try await one.ping() }
        try await bounded { await host.shutdownAll() }
        #expect(ledger.entries.isEmpty)
    }

    @Test("the launch reap finishes before any server is handed out")
    func reapsBeforeServing() async throws {
        let previous = MCPStub.ledger(owner: MCPStub.deadOwner)
        let launch = try MCPStub.launch("ignore-eof")
        let orphan = try SpawnedProcess.spawn(launch)
        previous.record(orphan.identity)

        let host = MCPHost(
            ledger: ProcessLedger(fileURL: previous.fileURL), configuration: MCPStub.fast)
        _ = await host.server(for: try MCPStub.definition())
        // No waiting here: `server(for:)` returning is the claim.
        #expect(!ProcessGroup.hasMembers(orphan.pid))
        #expect(await host.reapCompleted().killed == 1)
    }
}
