import Foundation

/// One configured MCP server: what callers hold, and the lifecycle policy.
///
/// **Lazy** (D-237): nothing runs until the first request, and then the
/// process stays up until `stop()`, app quit, or a failure. A crash or a
/// timeout drops it back to idle and the next request starts a fresh one —
/// nothing restarts without a caller, so a broken server costs nothing while
/// nobody is asking it anything.
///
/// **A timeout ends the process, not just the request.** A server that missed
/// a deadline is either wedged or too slow to serve a refresh pass, and a
/// wedged one may have stopped reading stdin — leaving a write blocked behind
/// it that only killing the group releases (D-238). Requests in flight on the
/// same process fail with `.stopped`.
///
/// **Three failures inside the window and it stays down** until `restart()`.
/// A failed start, a crash and a timeout each count: a server that hangs every
/// time is the same problem as one that crashes every time, with a slower
/// symptom.
public actor MCPServer {
    public struct Configuration: Sendable {
        /// An `npx` cold start downloads and links before it answers.
        public var startupTimeout: Duration = .seconds(20)
        public var requestTimeout: Duration = .seconds(30)
        public var pingTimeout: Duration = .seconds(5)
        /// Each step of the stop escalation waits this long (D-235).
        public var terminateGrace: Duration = .seconds(1)
        public var failureLimit = 3
        public var failureWindow: Duration = .seconds(60)
        public var maximumMessageLength = JSONRPCFramer.maximumLineLength

        public init() {}
    }

    public enum Status: Equatable, Sendable {
        case idle, starting, ready, failed
    }

    public let definition: MCPServerDefinition
    private let configuration: Configuration
    private let ledger: ProcessLedger
    private let parentEnvironment: [String: String]
    private let stderr = StderrRing()

    private var state = State.idle
    private var failures: [ContinuousClock.Instant] = []
    /// Set by `MCPHost` when it lets go of this server — at quit, or when a
    /// changed definition replaces it. A caller may still hold the reference,
    /// and without this its next request would spawn a process the host no
    /// longer tracks: at quit, a leak; after a replacement, the old command.
    private var isClosed = false
    /// Teardowns started after a timeout and not waited for, so the caller
    /// gets its error at the deadline. `stop()` still owes its caller these:
    /// it reports success only once nothing this server started is running.
    private var teardowns: [UUID: Task<Bool, Never>] = [:]

    private enum State {
        case idle
        case starting(Task<MCPConnection, Error>)
        case ready(MCPConnection)
        case failed
    }

    init(
        definition: MCPServerDefinition, configuration: Configuration, ledger: ProcessLedger,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.definition = definition
        self.configuration = configuration
        self.ledger = ledger
        self.parentEnvironment = parentEnvironment
    }

    public var status: Status {
        switch state {
        case .idle: .idle
        case .starting: .starting
        case .ready: .ready
        case .failed: .failed
        }
    }

    /// The protocol version the running server agreed to, if one is running.
    public var negotiatedVersion: String? {
        get async {
            guard case .ready(let connection) = state else { return nil }
            return await connection.negotiatedVersion
        }
    }

    /// The tail of what the server wrote to stderr, across restarts — so it
    /// still holds the reason after a crash. Shown to the user by M5-02; never
    /// logged (§8).
    public nonisolated func recentStderr() -> String {
        stderr.text
    }

    // MARK: - Lifecycle

    /// Stop the process group, if one is running.
    ///
    /// - Returns: `true` once nothing this server started is still running.
    @discardableResult
    public func stop() async -> Bool {
        var stopped = await stopCurrent()
        let earlier = teardowns
        teardowns.removeAll()
        for teardown in earlier.values where await !teardown.value {
            stopped = false
        }
        return stopped
    }

    /// Stop, forget past failures, and let the next request start fresh —
    /// the way out of `.failed`. A closed server stays closed.
    public func restart() async {
        await stop()
        failures.removeAll()
        // Only out of `.failed`. `stop()` suspends while it tears down, and a
        // request in that window starts a new process; overwriting its
        // `.starting` or `.ready` would orphan that process with nobody to stop it.
        if case .failed = state { state = .idle }
    }

    /// Stop, and refuse every later request with `.stopped`.
    func close() async {
        isClosed = true
        await stop()
    }

    // MARK: - Internals

    private func stopCurrent() async -> Bool {
        switch state {
        case .idle, .failed:
            return true
        case .starting(let task):
            // Cancelled rather than left to run: a start can take the whole
            // startup deadline, which is longer than app quit's budget.
            // Cancelling ends the handshake at once; what is still awaited is
            // `launch()` tearing down its own process, which takes the same
            // escalation as any stop. One that finished first hands back a
            // connection that is ours to stop, because the starter sees the
            // state change and leaves it alone.
            state = .idle
            task.cancel()
            guard let connection = try? await task.value else { return true }
            return await shutdown(connection, crashed: false)
        case .ready(let connection):
            state = .idle
            return await shutdown(connection, crashed: false)
        }
    }

    private func perform(_ method: String, params: JSONValue?, timeout: Duration) async throws
        -> JSONValue
    {
        let started = ContinuousClock.now
        let connection = try await connection()
        do {
            let result = try await connection.request(method, params: params, timeout: timeout)
            log(method, since: started, outcome: "ok")
            return result
        } catch let error as MCPError {
            log(method, since: started, outcome: "\(error)")
            if error == .timedOut { drop(connection) }
            throw error
        }
    }

    /// The running connection, starting one if there is none.
    ///
    /// Requests that arrive while a start is under way await that start; they
    /// never spawn a second process.
    private func connection() async throws -> MCPConnection {
        if isClosed { throw MCPError.stopped }
        switch state {
        case .ready(let connection):
            return connection
        case .starting(let task):
            return try await task.value
        case .failed:
            throw MCPError.failedRepeatedly
        case .idle:
            let task = Task { try await self.launch() }
            state = .starting(task)
            let connection: MCPConnection
            do {
                connection = try await task.value
            } catch {
                guard case .starting(let current) = state, current == task else {
                    throw MCPError.stopped
                }
                state = .idle
                recordFailure()
                throw error
            }
            // `stop()` ran while this start was under way and owns teardown.
            guard case .starting(let current) = state, current == task else {
                throw MCPError.stopped
            }
            state = .ready(connection)
            watch(connection)
            return connection
        }
    }

    /// Spawn, record, handshake. On any failure the process is torn down
    /// before the error leaves, so a failed start never leaves a process.
    private func launch() async throws -> MCPConnection {
        guard
            let launch = ChildLaunch.resolve(definition, parentEnvironment: parentEnvironment)
        else { throw MCPError.commandNotFound }
        let process = try SpawnedProcess.spawn(launch)
        ledger.record(process.identity)
        Log.mcp.info(
            "spawned server \(self.definition.id, privacy: .public) as group \(process.pid, privacy: .public)"
        )

        let connection = MCPConnection(
            process: process, stderr: stderr,
            maximumMessageLength: configuration.maximumMessageLength)
        do {
            try await connection.initialize(timeout: configuration.startupTimeout)
            return connection
        } catch {
            // Every error, not only `MCPError`: `stop()` cancels a start, and
            // the `CancellationError` that produces must not skip the teardown.
            await connection.close(.stopped)
            if error as? MCPError == .crashed {
                _ = await teardown(process, crashed: true)
                throw MCPError.exitedDuringStartup(status: await process.exitStatus.value)
            }
            _ = await teardown(process, crashed: false)
            throw error
        }
    }

    /// Notice the connection closing on its own — a crash, or an oversized
    /// message — and clean up after it.
    private func watch(_ connection: MCPConnection) {
        Task { [weak self] in
            let reason = await connection.waitUntilClosed()
            await self?.connectionClosed(connection, reason: reason)
        }
    }

    private func connectionClosed(_ connection: MCPConnection, reason: MCPError) async {
        // Not the current connection: `stop()` or `drop` closed it, and is
        // already tearing it down.
        guard case .ready(let current) = state, current === connection else { return }
        state = .idle
        recordFailure()
        Log.mcp.error(
            "server \(self.definition.id, privacy: .public) closed: \(String(describing: reason), privacy: .public)"
        )
        _ = await teardown(connection.process, crashed: reason == .crashed)
    }

    /// Take a connection out of service after a timeout.
    ///
    /// **The teardown is not awaited.** It escalates through up to three
    /// graces, and awaiting it here would hand the caller its `.timedOut` that
    /// much past its deadline (D-238). `stop()` awaits it instead.
    private func drop(_ connection: MCPConnection) {
        guard case .ready(let current) = state, current === connection else { return }
        state = .idle
        recordFailure()
        let id = UUID()
        // Inherits this actor, so it cannot start before the entry exists.
        teardowns[id] = Task {
            let gone = await shutdown(connection, crashed: false)
            teardowns[id] = nil
            return gone
        }
    }

    private func shutdown(_ connection: MCPConnection, crashed: Bool) async -> Bool {
        await connection.close(.stopped)
        return await teardown(connection.process, crashed: crashed)
    }

    /// End the process group and, once it is confirmed empty, forget it.
    ///
    /// An unconfirmed group keeps its ledger entry, so the next launch reaps
    /// what this one could not.
    private func teardown(_ process: SpawnedProcess, crashed: Bool) async -> Bool {
        let gone =
            crashed
            ? await process.killGroup(timeout: configuration.terminateGrace)
            : await process.terminate(grace: configuration.terminateGrace)
        if gone { ledger.remove(process.identity) }
        return gone
    }

    private func recordFailure() {
        let now = ContinuousClock.now
        failures = failures.filter { now - $0 < configuration.failureWindow } + [now]
        if failures.count >= configuration.failureLimit {
            state = .failed
            Log.mcp.error(
                "server \(self.definition.id, privacy: .public) failed \(self.failures.count, privacy: .public) times; stopped until restart"
            )
        }
    }

    private func log(_ method: String, since started: ContinuousClock.Instant, outcome: String) {
        let elapsed = ContinuousClock.now - started
        Log.mcp.info(
            "\(self.definition.id, privacy: .public) \(method, privacy: .public) \(outcome, privacy: .public) in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)"
        )
    }
}

// MARK: - Requests

extension MCPServer {
    public func ping() async throws {
        _ = try await perform("ping", params: nil, timeout: configuration.pingTimeout)
    }

    public func listTools() async throws -> [MCPTool] {
        try await paginate("tools/list", key: "tools", MCPTool.init)
    }

    public func listResources() async throws -> [MCPResource] {
        try await paginate("resources/list", key: "resources", MCPResource.init)
    }

    public func callTool(
        _ name: String, arguments: [String: JSONValue] = [:], timeout: Duration? = nil
    ) async throws -> MCPToolResult {
        let result = try await perform(
            "tools/call",
            params: .object(["name": .string(name), "arguments": .object(arguments)]),
            timeout: timeout ?? configuration.requestTimeout)
        guard let toolResult = MCPToolResult(result) else {
            throw MCPError.protocolViolation(.malformedResult)
        }
        return toolResult
    }

    public func readResource(_ uri: String) async throws -> [MCPResourceContents] {
        let result = try await perform(
            "resources/read", params: .object(["uri": .string(uri)]),
            timeout: configuration.requestTimeout)
        guard let contents = result["contents"]?.arrayValue else {
            throw MCPError.protocolViolation(.malformedResult)
        }
        return contents.compactMap(MCPResourceContents.init)
    }

    private func paginate<Item>(
        _ method: String, key: String, _ make: (JSONValue) -> Item?
    ) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        for _ in 0..<MCPProtocol.maximumPages {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await perform(
                method, params: params, timeout: configuration.requestTimeout)
            guard let page = result[key]?.arrayValue else {
                throw MCPError.protocolViolation(.malformedResult)
            }
            items += page.compactMap(make)
            guard let next = result["nextCursor"]?.stringValue else { return items }
            cursor = next
        }
        throw MCPError.protocolViolation(.paginationRunaway)
    }
}
