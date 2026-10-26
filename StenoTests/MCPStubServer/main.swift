import Darwin
import Foundation

// A deliberately badly behaved MCP server, for M5-01's tests (D-241).
//
// A real subprocess rather than an in-process double, because what M5-01 has to
// get right is process behaviour — pipes, groups, signals, exit — and a double
// that never spawned anything could not fail on any of it.
//
// Per-server behaviour is chosen at launch with `--mode a,b,…`; per-call
// behaviour by which tool is called. Modes:
//
//   exit-before-init   exit 3 before reading anything
//   hang-on-init       read `initialize`, never answer
//   bad-version        answer `initialize` with a version no client speaks
//   garbage-stdout     write a non-JSON line before every reply
//   flood-stderr       write 256 KB to stderr before every reply
//   ignore-eof         on stdin EOF, keep running
//   ignore-term        ignore SIGTERM
//   spawn-grandchild   start `/bin/sleep 600` in this process group at launch
//   paginate-forever   every `tools/list` page has a `nextCursor`
//   stop-reading-stdin after answering a `ping`, never read stdin again
//   close-stdin        on a `ping`, close stdin, answer, and keep running
//
// Tools: echo, fail (isError), crash (exit 1), hang, grandchild (its pid),
// big (a 64 KB reply), ask-client (sends `sampling/createMessage` to the client
// and reports the reply), ping-client (sends `ping` and reports the reply),
// open-fds (which descriptors this process holds), reply-then-exit (a 1 MB
// reply, then exit 0), reply-twice (the same reply, sent twice).

let modes: Set<String> = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count else {
        return []
    }
    return Set(arguments[index + 1].split(separator: ",").map(String.init))
}()

func emit(_ object: [String: Any]) {
    if modes.contains("flood-stderr") {
        FileHandle.standardError.write(Data(repeating: 0x45, count: 256 * 1024))
    }
    if modes.contains("garbage-stdout") {
        FileHandle.standardOutput.write(Data("this is not json\n".utf8))
    }
    var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: Any, _ result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func fail(_ id: Any, code: Int) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": "stub error"]])
}

func text(_ value: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": value]], "isError": isError]
}

func hangForever() -> Never {
    while true { sleep(60) }
}

var grandchild: pid_t = 0

@MainActor func spawnGrandchild() {
    // No `POSIX_SPAWN_SETPGROUP` and default descriptors: like `npx`'s `node`,
    // the grandchild shares this group and holds this process's stdout open.
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("600"), nil]
    defer {
        for pointer in argv { free(pointer) }
    }
    posix_spawn(&grandchild, "/bin/sleep", nil, nil, argv, environ)
}

func nextMessage() -> [String: Any]? {
    guard let line = Swift.readLine(strippingNewline: true) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

/// Ask the client something and return its reply, for the two tools that
/// exercise server-to-client requests.
func askClient(_ method: String) -> String {
    emit(["jsonrpc": "2.0", "id": "stub-1", "method": method, "params": [:]])
    guard let answer = nextMessage() else { return "no answer" }
    if let error = answer["error"] as? [String: Any], let code = error["code"] as? Int {
        return "error \(code)"
    }
    return answer["result"] != nil ? "result" : "neither"
}

let toolPages: [[[String: Any]]] = [
    [["name": "echo", "inputSchema": ["type": "object"]]],
    [
        "fail", "crash", "hang", "grandchild", "big", "ask-client", "ping-client", "open-fds",
        "reply-then-exit", "reply-twice",
    ].map {
        ["name": $0, "inputSchema": ["type": "object"]]
    },
]

@MainActor func listTools(_ id: Any, cursor: String?) {
    if modes.contains("paginate-forever") {
        reply(id, ["tools": toolPages[0], "nextCursor": UUID().uuidString])
    } else if cursor == "page-2" {
        reply(id, ["tools": toolPages[1]])
    } else {
        reply(id, ["tools": toolPages[0], "nextCursor": "page-2"])
    }
}

@MainActor func callTool(_ id: Any, name: String, arguments: [String: Any]) {
    switch name {
    case "echo": reply(id, text(arguments["text"] as? String ?? ""))
    case "fail": reply(id, text("the tool failed", isError: true))
    case "crash": exit(1)
    case "hang": hangForever()
    case "grandchild": reply(id, text("\(grandchild)"))
    case "big": reply(id, text(String(repeating: "x", count: 64 * 1024)))
    case "ask-client": reply(id, text(askClient("sampling/createMessage")))
    case "ping-client": reply(id, text(askClient("ping")))
    default: callProcessTool(id, name: name)
    }
}

/// The tools about the process and its pipes rather than the protocol.
func callProcessTool(_ id: Any, name: String) {
    switch name {
    case "open-fds":
        let open = (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }
        reply(id, text(open.map(String.init).joined(separator: ",")))
    case "reply-twice":
        reply(id, text("once"))
        reply(id, text("twice"))
    case "reply-then-exit":
        reply(id, text(String(repeating: "y", count: 1024 * 1024)))
        exit(0)
    default: fail(id, code: -32_602)
    }
}

if modes.contains("exit-before-init") { exit(3) }
if modes.contains("ignore-term") { signal(SIGTERM, SIG_IGN) }
if modes.contains("spawn-grandchild") { spawnGrandchild() }

let supported: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

while let message = nextMessage() {
    let id = message["id"]
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        if modes.contains("hang-on-init") { hangForever() }
        let asked = params["protocolVersion"] as? String ?? ""
        let version =
            modes.contains("bad-version")
            ? "1999-01-01" : (supported.contains(asked) ? asked : "2025-11-25")
        reply(
            id ?? 0,
            [
                "protocolVersion": version,
                "capabilities": ["tools": [:], "resources": [:]],
                "serverInfo": ["name": "stub", "version": "1"],
            ])
    case "ping":
        // Closed before the reply, so a client that has the reply knows
        // stdin is already gone.
        if modes.contains("close-stdin") { close(0) }
        reply(id ?? 0, [:])
        if modes.contains("stop-reading-stdin") || modes.contains("close-stdin") { hangForever() }
    case "tools/list":
        listTools(id ?? 0, cursor: params["cursor"] as? String)
    case "tools/call":
        callTool(
            id ?? 0, name: params["name"] as? String ?? "",
            arguments: params["arguments"] as? [String: Any] ?? [:])
    case "resources/list":
        reply(id ?? 0, ["resources": [["uri": "stub://readme", "name": "readme"]]])
    case "resources/read":
        reply(
            id ?? 0,
            ["contents": [["uri": params["uri"] as? String ?? "", "text": "hello"]]])
    default:
        if let id { fail(id, code: -32_601) }
    }
}

if modes.contains("ignore-eof") { hangForever() }
exit(0)
