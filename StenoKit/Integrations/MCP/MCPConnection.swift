import Foundation

/// One live server process and the JSON-RPC session over its pipes.
///
/// **Every request waits on a continuation, never on a file descriptor**
/// (D-238). `withDeadline` cannot return while its operation ignores
/// cancellation (D-146), and a blocking `read` ignores it — so a design that
/// read the reply inline would let one wedged server hold a refresh pass past
/// any deadline. Here a reader thread feeds `consume()`, `consume()` resolves
/// continuations by id, and a deadline resolves the same continuation from the
/// other side. Whichever arrives first wins; the loser finds nothing to resume.
///
/// **A closed connection stays closed.** The first failure — exit, oversized
/// message, an explicit close — fails every pending request with that reason
/// and every later one immediately. `MCPServer` decides what happens to the
/// process; this type only stops talking to it.
actor MCPConnection {
    let process: SpawnedProcess
    private(set) var negotiatedVersion: String?

    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var closeReason: MCPError?
    private var hasExited = false
    private var standardOutputEnded = false
    private let maximumMessageLength: Int
    private let closed: AsyncStream<MCPError>
    private let closedContinuation: AsyncStream<MCPError>.Continuation

    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
    }

    init(process: SpawnedProcess, stderr: StderrRing, maximumMessageLength: Int) {
        self.process = process
        self.maximumMessageLength = maximumMessageLength
        (closed, closedContinuation) = AsyncStream<MCPError>.makeStream()

        Task { [process] in
            for await chunk in process.standardError { stderr.append(chunk) }
        }
        Task { [weak self, process] in
            _ = await process.exitStatus.value
            await self?.processExited()
        }
        Task { [weak self] in await self?.consume() }
    }

    /// Why this connection closed, once it has.
    func waitUntilClosed() async -> MCPError {
        for await reason in closed { return reason }
        return closeReason ?? .stopped
    }

    /// The `initialize` handshake: request, version check, `initialized`.
    ///
    /// Empty `capabilities`: Steno offers the server no sampling, no roots and
    /// no elicitation, so a server never has a reason to ask for them.
    func initialize(timeout: Duration) async throws {
        let params: JSONValue = .object([
            "protocolVersion": .string(MCPProtocol.requestedVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("steno"),
                "version": .string(Self.clientVersion),
            ]),
        ])
        let result = try await request("initialize", params: params, timeout: timeout)
        guard let version = result["protocolVersion"]?.stringValue else {
            throw MCPError.protocolViolation(.malformedResult)
        }
        guard MCPProtocol.supportedVersions.contains(version) else {
            throw MCPError.unsupportedProtocolVersion
        }
        negotiatedVersion = version
        try send(.notification(method: "notifications/initialized", params: nil))
    }

    /// Send a request and wait for its reply, its deadline, or the connection
    /// closing — whichever is first.
    ///
    /// - Throws: `MCPError`, or `CancellationError` when the calling task is
    ///   cancelled.
    func request(_ method: String, params: JSONValue?, timeout: Duration) async throws
        -> JSONValue
    {
        if let closeReason { throw closeReason }
        let id = nextID
        nextID += 1
        let line = try Self.encode(.request(id: id, method: method, params: params))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // This closure runs on the actor without suspending, and replies
                // are resolved on the actor too — so even a reply that arrives
                // before `write` returns waits until this entry exists. The
                // order of the two lines below is therefore not load-bearing.
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolve(id, with: .failure(MCPError.timedOut))
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                // A refused write closes the connection, not just this request:
                // a server whose stdin is gone can never be asked anything
                // again, and it may still be running — so the exit watcher
                // would never notice, and the server would sit `.ready`,
                // failing every request without counting a single failure.
                process.write(line) { [weak self] accepted in
                    guard !accepted else { return }
                    Task { await self?.close(.crashed) }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.resolve(id, with: .failure(CancellationError())) }
        }
    }

    /// Fail everything pending with `reason` and refuse anything new.
    func close(_ reason: MCPError) {
        guard closeReason == nil else { return }
        closeReason = reason
        let waiting = pending
        pending.removeAll()
        for entry in waiting.values {
            entry.timer.cancel()
            entry.continuation.resume(throwing: reason)
        }
        closedContinuation.yield(reason)
        closedContinuation.finish()
    }

    // MARK: - Inbound

    private func consume() async {
        var framer = JSONRPCFramer(limit: maximumMessageLength)
        var discarding = false
        // After an oversized message, keep reading and throw it away rather
        // than returning: the reader thread buffers whatever is not consumed,
        // so a server writing without end would grow that buffer for as long
        // as its teardown takes — the very exhaustion the cap exists to stop.
        for await chunk in process.standardOutput where !discarding {
            for output in framer.append(chunk) {
                guard case .line(let line) = output else {
                    close(.protocolViolation(.oversizedMessage))
                    discarding = true
                    break
                }
                handle(line)
            }
        }
        standardOutputEnded = true
        if hasExited { close(.crashed) }
    }

    /// The leader exited. **Close once its last output is read, not at once:**
    /// a server that writes a reply and then exits has its exit reaped on one
    /// thread while the reply is still in the pipe on another, and closing on
    /// the exit alone would fail a request whose answer had already arrived.
    ///
    /// Bounded, because a grandchild holding stdout open — `npx`'s `node`
    /// child, outliving `npx` — means EOF may never come.
    private func processExited() {
        hasExited = true
        if standardOutputEnded {
            close(.crashed)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.close(.crashed)
        }
    }

    private func handle(_ line: Data) {
        switch JSONRPCMessage.decode(line: line) {
        case .response(let id, let result):
            resolve(id, with: .success(result))
        case .errorResponse(let id, let code):
            resolve(id, with: .failure(MCPError.serverError(code: code)))
        case .serverRequest(let id, let method):
            try? send(.serverRequest(id: id, method: method))
        case .notification, .request:
            // Logging, progress and `list_changed` notifications: nothing in
            // M5 acts on them, and a caller re-lists when it needs to.
            break
        case nil:
            // By length only. The line is server output, and §8 keeps server
            // output out of the log.
            Log.mcp.debug("dropped an unparseable line of \(line.count, privacy: .public) bytes")
        }
    }

    /// Resume the request `id` once. A late reply to a request that already
    /// timed out finds no entry and is dropped.
    private func resolve(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(with: result)
    }

    private func send(_ message: JSONRPCMessage) throws {
        process.write(try Self.encode(message)) { _ in }
    }

    private static func encode(_ message: JSONRPCMessage) throws -> Data {
        do {
            return try message.encodedLine()
        } catch {
            // Only a non-finite `Double` in caller-supplied params gets here.
            throw MCPError.protocolViolation(.unencodableRequest)
        }
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }
}
