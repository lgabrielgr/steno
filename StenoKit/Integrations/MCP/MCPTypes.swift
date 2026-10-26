import Foundation

/// Protocol constants, written once.
public enum MCPProtocol {
    /// The version this client asks for.
    ///
    /// **Measured, not remembered** (spec, D-234). Against
    /// `@modelcontextprotocol/server-everything` 2.0.0 on 2026-10-09, a server
    /// echoes any version it supports and answers an unknown one with its own
    /// latest — so asking for the newest version is what lets a current server
    /// agree, and an older server answers with the older version it speaks.
    public static let requestedVersion = "2025-11-25"

    /// Every version whose `initialize`, `ping`, `tools/*` and `resources/*`
    /// shapes this client reads correctly.
    ///
    /// The four differ in what they *add* — structured tool output, resource
    /// links, tasks — and those additions arrive inside `JSONValue` fields this
    /// layer passes through rather than decodes, so none of them can break it.
    public static let supportedVersions: Set<String> = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]

    /// `tools/list` and `resources/list` stop following `nextCursor` here.
    ///
    /// A server that always returns a cursor would otherwise keep a refresh
    /// pass busy forever. Twenty pages is several hundred tools.
    public static let maximumPages = 20
}

/// One tool a server offers (`tools/list`).
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String?
    /// A JSON Schema, passed through for M5-03's AI exposure.
    public let inputSchema: JSONValue

    init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue else { return nil }
        self.name = name
        title = value["title"]?.stringValue
        description = value["description"]?.stringValue
        inputSchema = value["inputSchema"] ?? .object([:])
    }
}

/// One resource a server offers (`resources/list`).
public struct MCPResource: Sendable, Equatable {
    public let uri: String
    public let name: String
    public let title: String?
    public let description: String?
    public let mimeType: String?

    init?(_ value: JSONValue) {
        guard let uri = value["uri"]?.stringValue, let name = value["name"]?.stringValue
        else { return nil }
        self.uri = uri
        self.name = name
        title = value["title"]?.stringValue
        description = value["description"]?.stringValue
        mimeType = value["mimeType"]?.stringValue
    }
}

/// The result of `tools/call`.
///
/// `isError` is the *tool's* verdict, not the transport's (D-240): the call
/// arrived and the tool reported failure, so it is a result, not a throw.
public struct MCPToolResult: Sendable, Equatable {
    /// Content blocks, passed through: text, image, audio, resource links and
    /// embedded resources are M5-03's to interpret.
    public let content: [JSONValue]
    public let structuredContent: JSONValue?
    public let isError: Bool

    init?(_ value: JSONValue) {
        guard let content = value["content"]?.arrayValue else { return nil }
        self.content = content
        structuredContent = value["structuredContent"]
        isError = value["isError"]?.boolValue ?? false
    }
}

/// One entry of a `resources/read` result. Exactly one of `text` and `blob`
/// (base64) is set by a conforming server.
public struct MCPResourceContents: Sendable, Equatable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: String?

    init?(_ value: JSONValue) {
        guard let uri = value["uri"]?.stringValue else { return nil }
        self.uri = uri
        mimeType = value["mimeType"]?.stringValue
        text = value["text"]?.stringValue
        blob = value["blob"]?.stringValue
    }
}
