import Foundation

/// One JSON-RPC 2.0 message, in either direction.
///
/// MCP's stdio transport is newline-delimited JSON-RPC: one message per line,
/// no embedded newlines. `JSONEncoder` never emits a raw newline (it escapes
/// them inside strings), so `encodedLine()` cannot produce a line that splits.
enum JSONRPCMessage: Equatable, Sendable {
    case request(id: Int, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: Int, result: JSONValue)
    case errorResponse(id: Int, code: Int)

    /// A request the *server* sent, whose id may be a string.
    ///
    /// Kept apart from `.request` because its id is echoed back verbatim and
    /// never matched against the pending table: JSON-RPC lets each side choose
    /// its own ids, so a server's `1` and ours are unrelated.
    case serverRequest(id: JSONValue, method: String)

    /// The message as one line, newline included.
    func encodedLine() throws -> Data {
        var data = try Self.encoder.encode(envelope())
        data.append(0x0A)
        return data
    }

    /// The reply to a server request: `{}` for `ping`, which MCP requires the
    /// receiving side to answer, and `-32601 method not found` for everything
    /// else, since this client declares no capabilities.
    static func reply(toServerRequest id: JSONValue, method: String) -> JSONValue {
        if method == "ping" {
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
        }
        return .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object([
                "code": .integer(methodNotFound), "message": .string("Method not found"),
            ]),
        ])
    }

    static let methodNotFound = -32_601

    /// Classify one decoded line, or `nil` for anything that is not a message
    /// this client can act on.
    ///
    /// A response whose id is not an integer is unclassifiable rather than an
    /// error: this client only ever sends integer ids, so no pending request
    /// could match it.
    static func classify(_ value: JSONValue) -> JSONRPCMessage? {
        let method = value["method"]?.stringValue
        switch (value["id"], method) {
        case (.some(let id), .some(let method)) where id != .null:
            return .serverRequest(id: id, method: method)
        case (nil, .some(let method)):
            return .notification(method: method, params: value["params"])
        case (.some(.integer(let id)), nil):
            if let error = value["error"] {
                guard case .integer(let code) = error["code"] else { return nil }
                return .errorResponse(id: id, code: code)
            }
            guard let result = value["result"] else { return nil }
            return .response(id: id, result: result)
        default:
            return nil
        }
    }

    static func decode(line: Data) -> JSONRPCMessage? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            return nil
        }
        return classify(value)
    }

    private func envelope() -> JSONValue {
        var members: [String: JSONValue] = ["jsonrpc": .string("2.0")]
        switch self {
        case .request(let id, let method, let params):
            members["id"] = .integer(id)
            members["method"] = .string(method)
            if let params { members["params"] = params }
        case .notification(let method, let params):
            members["method"] = .string(method)
            if let params { members["params"] = params }
        case .response(let id, let result):
            members["id"] = .integer(id)
            members["result"] = result
        case .errorResponse(let id, let code):
            members["id"] = .integer(id)
            members["error"] = .object(["code": .integer(code), "message": .string("")])
        case .serverRequest(let id, let method):
            return Self.reply(toServerRequest: id, method: method)
        }
        return .object(members)
    }

    /// `.sortedKeys` so a message's bytes are a function of its content — a test
    /// can compare lines, and nothing depends on dictionary hash order, which
    /// differs between processes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// Splits a byte stream into lines, refusing any line longer than the cap.
///
/// **The cap is what keeps a runaway server from exhausting memory.** Without
/// it, a server that writes without ever writing a newline grows this buffer
/// until the app is killed — which is the "takes the app with it" failure the
/// task's second criterion forbids.
struct JSONRPCFramer {
    /// 8 MB. A resource body is the largest thing that legitimately arrives in
    /// one message; this is far beyond any page or calendar a stand-up needs.
    static let maximumLineLength = 8 * 1024 * 1024

    private var buffer = Data()
    private let limit: Int

    init(limit: Int = maximumLineLength) {
        self.limit = limit
    }

    enum Output: Equatable {
        case line(Data)
        case oversized
    }

    /// Append a chunk and return every complete line it finished.
    ///
    /// After `.oversized` the framer is spent: the stream has no reliable
    /// boundary to resynchronize on, so the connection ends.
    ///
    /// **Only the new bytes are searched.** What was buffered before this chunk
    /// held no newline, so rescanning it would make a large message arriving in
    /// pipe-sized chunks quadratic: an 8 MB line in 64 KB reads is 128 scans of
    /// a growing buffer.
    mutating func append(_ chunk: Data) -> [Output] {
        var searchFrom = buffer.endIndex
        buffer.append(chunk)
        var lineStart = buffer.startIndex
        var lines: [Output] = []
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            var line = buffer[lineStart..<newline]
            lineStart = buffer.index(after: newline)
            searchFrom = lineStart
            if line.last == 0x0D { line = line.dropLast() }
            guard line.count <= limit else { return lines + [.oversized] }
            if !line.isEmpty { lines.append(.line(Data(line))) }
        }
        if lineStart != buffer.startIndex { buffer = Data(buffer[lineStart...]) }
        if buffer.count > limit { lines.append(.oversized) }
        return lines
    }
}
