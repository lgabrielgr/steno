import Darwin
import Foundation
import Testing

@testable import StenoKit

/// The stub server and the scratch state every MCP test needs.
enum MCPStub {
    /// `MCPStubServer` sits beside the test bundle: the bundle depends on it,
    /// so it is built first into the same products directory (D-241).
    ///
    /// **Missing fails rather than skips**, for `CLIBinaryTests`' reason: a
    /// skipped process test is a test that cannot fail.
    static var path: String {
        get throws {
            let path = Bundle(for: MCPBundleAnchor.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("MCPStubServer").path
            guard FileManager.default.isExecutableFile(atPath: path) else {
                Issue.record("No MCPStubServer at \(path) — fix the path, do not skip.")
                throw MCPStubMissing()
            }
            return path
        }
    }

    static func definition(_ modes: String...) throws -> MCPServerDefinition {
        let arguments = modes.isEmpty ? [] : ["--mode", modes.joined(separator: ",")]
        return MCPServerDefinition(id: "stub", command: try path, arguments: arguments)
    }

    static func launch(_ modes: String...) throws -> ChildLaunch {
        let arguments = modes.isEmpty ? [] : ["--mode", modes.joined(separator: ",")]
        let definition = MCPServerDefinition(id: "stub", command: try path, arguments: arguments)
        return try #require(ChildLaunch.resolve(definition))
    }

    /// An owner that is not alive: this process's pid with a start time it
    /// never had. Entries recorded under it look like a crashed app's.
    static let deadOwner = ProcessIdentity(
        pid: getpid(), startSeconds: 1, startMicroseconds: 0)

}

private struct MCPStubMissing: Error {}
private final class MCPBundleAnchor {}

/// The bound every awaiting MCP test runs under.
///
/// **Every wait is bounded** because a mutation that deletes a `resume` makes
/// an unbounded test hang instead of fail — and a hung suite reads as slow CI,
/// not as a red test.
struct TestBoundExceeded: Error {}

func bounded<T: Sendable>(
    _ duration: Duration = .seconds(20), _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withDeadline(duration, throwing: TestBoundExceeded(), operation: operation)
}

/// The error `operation` threw, or `nil` if it returned.
func thrown(_ operation: @escaping @Sendable () async throws -> Void) async -> Error? {
    do {
        try await bounded(.seconds(20), operation)
        return nil
    } catch {
        return error
    }
}

/// Does `pid` name a process — including a zombie awaiting its reaper?
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Poll `condition` until it holds or `timeout` passes.
func eventually(
    _ timeout: Duration = .seconds(5), _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

extension MCPToolResult {
    /// The first text block, which is all the stub ever returns.
    var text: String? { content.first?["text"]?.stringValue }
}

extension Result {
    var error: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
