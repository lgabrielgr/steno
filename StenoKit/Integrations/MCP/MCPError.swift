import Foundation

/// The only error the MCP client throws (D-240).
///
/// **No case carries a `String`.** Everything a server can say — a JSON-RPC
/// error message, a line on stderr — is text the server wrote, and a server's
/// text can contain whatever a tool returned: ticket titles, calendar entries,
/// a token echoed from its own environment. `SourceError` made the same choice
/// for the same reason (D-165); keeping it here makes "an `MCPError` is always
/// safe to log" a property of the type rather than of every call site.
///
/// **A tool that reports failure is not an `MCPError`.** A `tools/call` result
/// with `isError: true` means the transport worked and the tool said no; it is
/// returned in `MCPToolResult.isError`. These cases are the transport failing.
public enum MCPError: Error, Equatable, Sendable {
    /// The command is not on the child's `PATH`, or is not executable.
    case commandNotFound

    /// `posix_spawn` refused for any other reason.
    case launchFailed(errno: Int32)

    /// The process exited before it answered `initialize`.
    ///
    /// `status` is the raw `waitpid` status: a server that prints usage and
    /// exits 1 and one that was killed by a signal both land here, and M5-02's
    /// connection test is what tells them apart for the user.
    case exitedDuringStartup(status: Int32)

    /// The process exited while it was serving.
    case crashed

    /// Three failures — crashes or timeouts — inside the failure window (D-237).
    ///
    /// Every request throws this until `MCPServer.restart()`. **Not named for
    /// crashes alone,** because a server that hangs every time is the same
    /// problem with a slower symptom, and it counts the same way.
    case failedRepeatedly

    /// The startup or request deadline passed.
    case timedOut

    /// The server negotiated a protocol version this client does not speak.
    case unsupportedProtocolVersion

    /// A JSON-RPC error response. The server's message is discarded.
    case serverError(code: Int)

    /// The server broke the protocol in a way this client will not work around.
    case protocolViolation(ProtocolViolation)

    /// The server was stopped — by `stop()`, by app quit, or because another
    /// request on the same connection timed out — while this request waited.
    case stopped

    public enum ProtocolViolation: Equatable, Sendable {
        /// A single line exceeded `JSONRPCFramer.maximumLineLength`.
        case oversizedMessage
        /// A result was missing a field the protocol requires.
        case malformedResult
        /// A list kept returning `nextCursor` past `MCPProtocol.maximumPages`.
        case paginationRunaway
        /// The caller's params could not be encoded — a non-finite number.
        case unencodableRequest
    }
}
