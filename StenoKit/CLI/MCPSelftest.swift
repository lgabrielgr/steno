import Foundation

/// The only thing that runs M5-01's client against a real MCP server.
///
/// **It exists because `make test` can only meet the stub.** The suite denies
/// outbound networking (§9.4, D-012), and an off-the-shelf server — the shape
/// §5.4 actually depends on — arrives through `npx`, which downloads before it
/// runs. Whether a real server agrees to `MCPProtocol.requestedVersion`, and
/// whether stopping it leaves `npx`'s `node` child behind, are facts about the
/// outside world that no stub can establish.
///
/// **It uses a scratch ledger, not the app's.** It needs to read its own entry
/// to learn the process group it then checks is empty, and a scratch file
/// keeps that read from seeing — or a reap from touching — the app's servers.
///
/// **It never prints the server's stderr.** It prints how many bytes there
/// were. A server's stderr is where a token from its environment would be
/// echoed (§8), and this output is the kind people paste into a PR.
enum MCPSelftest {
    static func runSynchronously(command: String, arguments: [String]) -> Int32 {
        CLISync.runSynchronously {
            await run(command: command, arguments: arguments)
        }
    }

    static func run(
        command: String, arguments: [String],
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let ledger = ProcessLedger(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "steno-mcp-selftest-\(UUID().uuidString).json"))
        // Scratch: no later run reads it, so it goes whatever the outcome.
        defer { try? FileManager.default.removeItem(at: ledger.fileURL) }
        let host = MCPHost(ledger: ledger, configuration: MCPServer.Configuration())
        let server = await host.server(
            for: MCPServerDefinition(id: "selftest", command: command, arguments: arguments))

        out("mcp-selftest: \(command) \(arguments.joined(separator: " "))")
        let started = ContinuousClock.now
        do {
            try await server.ping()
        } catch {
            out("mcp-selftest: FAIL — start: \(String(describing: error))")
            if error as? MCPError == .commandNotFound {
                out("  the app resolves commands on PATH=\(ChildLaunch.basePath)")
                out("  pass an absolute path, e.g. \"$(which npx)\"")
            }
            out("  stderr    \(server.recentStderr().utf8.count) bytes (not shown, §8)")
            await host.shutdownAll()
            return 1
        }
        out("  started   \(milliseconds(since: started)) ms")
        out("  version   \(await server.negotiatedVersion ?? "?")")
        guard let group = ledger.entries.first?.leader.pid else {
            out("mcp-selftest: FAIL — the server is running but the ledger has no entry")
            await host.shutdownAll()
            return 1
        }

        do {
            let tools = try await server.listTools()
            out("  tools     \(tools.count): \(tools.map(\.name).joined(separator: ", "))")
        } catch {
            out("mcp-selftest: FAIL — tools/list: \(String(describing: error))")
            await host.shutdownAll()
            return 1
        }
        // Resources are optional in MCP: a server without them answers -32601.
        do {
            out("  resources \(try await server.listResources().count)")
        } catch {
            out("  resources not offered (\(String(describing: error)))")
        }

        let stopping = ContinuousClock.now
        let stopped = await server.stop()
        out("  stopped   \(milliseconds(since: stopping)) ms")
        // The check the stub cannot make: a real `npx` group, grandchild and all.
        guard stopped, !ProcessGroup.hasMembers(group), ledger.entries.isEmpty else {
            out("mcp-selftest: FAIL — process group \(group) still has members after stop")
            return 1
        }
        out("mcp-selftest: PASS — group \(group) is empty")
        return 0
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = ContinuousClock.now - start
        return elapsed.components.seconds * 1000 + elapsed.components.attoseconds
            / 1_000_000_000_000_000
    }
}
