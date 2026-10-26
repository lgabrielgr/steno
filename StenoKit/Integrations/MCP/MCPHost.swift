import Foundation

/// Every MCP server this process runs, and the two lifecycle edges of the app.
///
/// **Reaping comes first, structurally** (D-236). The orphan reap starts in
/// `init`, and `server(for:)` awaits it before handing anything out — so no
/// server this process starts can ever be mistaken for, or raced by, the reap
/// of the last process's leftovers.
public actor MCPHost {
    /// The app's host. `AppDelegate` touches it at launch, which starts the
    /// reap, and stops it at quit. Tests build their own with a scratch ledger;
    /// nothing in the test bundle may touch this one.
    public static let shared = MCPHost()

    private let ledger: ProcessLedger
    private let configuration: MCPServer.Configuration
    private let reap: Task<ProcessLedger.Report, Never>
    private var servers: [String: MCPServer] = [:]

    public init() {
        // A home directory Application Support cannot be resolved under is
        // not a real configuration; the temporary directory keeps the ledger
        // working rather than turning that into a refusal to run servers.
        let url =
            (try? ProcessLedger.defaultURL)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "steno-mcp-processes.json")
        self.init(ledger: ProcessLedger(fileURL: url), configuration: .init())
    }

    init(ledger: ProcessLedger, configuration: MCPServer.Configuration) {
        self.ledger = ledger
        self.configuration = configuration
        reap = Task {
            let report = await ledger.reapOrphans()
            if report != ProcessLedger.Report() {
                Log.mcp.info(
                    "reaped orphans: \(report.killed, privacy: .public) killed, \(report.reused, privacy: .public) pid reused, \(report.alreadyGone, privacy: .public) already gone"
                )
            }
            return report
        }
    }

    /// Wait for the launch reap to finish.
    @discardableResult
    func reapCompleted() async -> ProcessLedger.Report {
        await reap.value
    }

    /// The server for `definition`, created on first use.
    ///
    /// A changed definition under the same id replaces the old server, which
    /// is closed first: its process was started from a command that no longer
    /// describes it, and a caller still holding it must not start another.
    public func server(for definition: MCPServerDefinition) async -> MCPServer {
        await reap.value
        if let existing = servers[definition.id] {
            if existing.definition == definition { return existing }
            await existing.close()
        }
        let server = MCPServer(
            definition: definition, configuration: configuration, ledger: ledger)
        servers[definition.id] = server
        return server
    }

    /// Stop every server in parallel, returning when all are stopped or when
    /// `budget` runs out — whichever is first.
    ///
    /// **Bounded, because app quit waits on it.** A stop that outlives the
    /// budget keeps running until the process exits; its ledger entry is
    /// removed only on a confirmed stop, so the next launch reaps anything it
    /// did not finish.
    public func shutdownAll(budget: Duration = .seconds(3)) async {
        let running = Array(servers.values)
        servers.removeAll()
        guard !running.isEmpty else { return }

        let stops = Task {
            await withTaskGroup(of: Void.self) { group in
                for server in running {
                    group.addTask { await server.close() }
                }
            }
        }
        // Not a timer inside the task group: a group waits for all of its
        // children, so a budget child would make every quick shutdown wait out
        // the whole budget.
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await stops.value
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: budget)
                if once.claim() { continuation.resume() }
            }
        }
    }
}

/// `true` exactly once, from whichever thread asks first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
