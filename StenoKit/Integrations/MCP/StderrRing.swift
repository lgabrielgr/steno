import Foundation

/// The last 64 KB a server wrote to stderr, held in memory and never logged.
///
/// **It is drained because an undrained pipe is a hang** (D-238). A server
/// that writes to stderr faster than anyone reads fills the pipe's buffer and
/// blocks inside that write — no longer answering requests, for a reason
/// unrelated to the request. Draining is the fix; keeping the tail is what
/// makes the drained bytes useful to M5-02's connection test, which can show
/// the user why their server would not start.
///
/// **Never logged** (§8): a server's stderr is where a token in its own
/// environment is most likely to be echoed back.
final class StderrRing: @unchecked Sendable {
    static let capacity = 64 * 1024

    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(chunk)
        if bytes.count > Self.capacity {
            bytes = Data(bytes.suffix(Self.capacity))
        }
    }

    /// Lossy UTF-8, deliberately: the tail may begin mid-character, and the
    /// failable initializer the lint rule prefers would turn that one cut
    /// character into no text at all.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }
}
