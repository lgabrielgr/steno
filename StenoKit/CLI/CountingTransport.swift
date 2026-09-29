import Foundation

/// Records the method of every request that passes through, for both selftests'
/// read-only claim (D-197).
///
/// **Shared by the Jira and Confluence harnesses**, for D-202's reason: a second copy
/// is how a fix lands on one and not the other. Its own type rather than a closure,
/// because it has to be `Sendable` and hold state — several requests run concurrently,
/// and an unsynchronized recorder does not merely race, it makes the harness lie about
/// what the code did.
final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let wrapped: any HTTPTransport
    private let lock = NSLock()
    private var recorded: [String] = []

    init(wrapping wrapped: any HTTPTransport) {
        self.wrapped = wrapped
    }

    var methods: [String] { lock.withLock { recorded } }

    /// Whether everything that went out was a read (D5).
    ///
    /// **A separately testable predicate, for `ReadOnlyTransport.isAllowed`'s reason.**
    /// Nothing a test can do will make a connector emit a non-GET — `ReadOnlyTransport`
    /// traps first — so the only way this rule stays verified is to assert the rule
    /// itself rather than the situation it exists to catch. What it guards against is a
    /// *live* run: a future endpoint reaching for `POST /users-bulk` (D-201) would show
    /// up here, in front of a human, rather than in nobody's assertions.
    static func isReadOnly(_ methods: [String]) -> Bool {
        methods.allSatisfy { $0 == "GET" }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request.method.rawValue) }
        return try await wrapped.send(request)
    }
}
