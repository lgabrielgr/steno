import Foundation
import Testing

@testable import StenoKit

/// The harness's *sequence and its reporting*, tested against the double.
///
/// `make verify-models` runs this same logic against the live API on a signed
/// build; what a unit test can settle is that it reports honestly — a harness
/// that printed PASS for an empty list, or that leaked a payload while
/// reporting a failure, would be worse than no harness at all.

/// Collects `out` lines from whatever executor the harness runs on.
///
/// A lock rather than a plain array: `run` is `nonisolated async`, so its
/// closure is `@Sendable` and a captured `var` would not compile under Swift 6.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var contents: [String] { lock.withLock { lines } }
    var joined: String { contents.joined(separator: "\n") }
}

/// An error that describes itself with something that must never be printed.
///
/// `AIProvider`'s contract is that only `AIError` escapes — which carries no
/// free-form string by construction (D-132) — so anything else could be a
/// `DecodingError` quoting a response body. This is that case, made concrete.
private struct LeakyDefect: Error, CustomStringConvertible {
    var description = #"response body: {"api_key":"sk-ant-secret-value"}"#
}

private struct DefectiveProvider: AIProvider {
    let id = "defective"
    let displayName = "Defective"

    func availableModels() async throws -> [AIModel] { throw LeakyDefect() }
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        throw LeakyDefect()
    }
    func testConnection() async throws { throw LeakyDefect() }
}

private let sonnet = AIModel(id: "claude-sonnet-9", displayName: "Claude Sonnet 9")
private let haiku = AIModel(id: "claude-haiku-9", displayName: "Claude Haiku 9")

@Test("a ranked list passes, and element zero is marked as the default")
func aRankedListPasses() async throws {
    let lines = LineCollector()
    let provider = StubAIProvider(models: .success([sonnet, haiku]))

    let code = await ModelsSelftest.run(provider: provider, out: { lines.append($0) })

    #expect(code == 0)
    #expect(lines.joined.contains("PASS"))
    #expect(lines.joined.contains(sonnet.id))
    #expect(lines.joined.contains(haiku.id))
    // The whole point of printing the list is reading D-141's ordering against
    // the live API, and an unmarked list makes the reader count rows.
    let defaultLine = try #require(lines.contents.first { $0.contains("[default]") })
    #expect(defaultLine.contains(sonnet.id))
    #expect(lines.contents.filter { $0.contains("[default]") }.count == 1)
}

/// An empty list is legitimate for the *protocol* (§7.1: "a key with access to
/// nothing") and useless for this harness: nothing about the wire shape was
/// verified, so it must not print PASS.
@Test("an empty list is reported as a failure, not as a pass")
func anEmptyListFails() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(
        provider: StubAIProvider(models: .success([])), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("PASS") == false)
    #expect(lines.joined.contains("no models"))
}

/// The ordinary state of a machine where nobody has set a key. The message is
/// the instruction — and it is still exit 1, because nothing was verified.
@Test("a missing key prints what to do about it")
func aMissingKeyIsExplained() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(
        provider: StubAIProvider(models: .failure(.notConfigured)), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("no key is stored"))
    #expect(lines.joined.contains("Settings"))
    #expect(lines.joined.contains("FAIL") == false)
}

@Test("a rejected key fails with the reason and its metrics label")
func aRejectedKeyFails() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(
        provider: StubAIProvider(models: .failure(.invalidCredential)), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("FAIL"))
    #expect(lines.joined.contains("invalidCredential"))
}

/// §8: a harness that dumped an arbitrary error's description would write a
/// response body — and, on the wrong day, a credential — to a terminal and its
/// scrollback.
@Test("an unexpected error is reported by type, never by description")
func anUnexpectedErrorIsNotQuoted() async {
    let lines = LineCollector()

    let code = await ModelsSelftest.run(provider: DefectiveProvider(), out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined.contains("sk-ant-secret-value") == false)
    #expect(lines.joined.contains("api_key") == false)
    #expect(lines.joined.contains("LeakyDefect"))
}

/// The bridge `CLIEntry` uses, exercised from the isolation production uses.
///
/// **`@MainActor` is load-bearing, not decoration.** `CLIEntry.run` is
/// `@MainActor` and blocks the main thread on the semaphore while `run`
/// proceeds on the cooperative pool. Without this attribute the test would
/// block a pool thread instead, leaving the main thread free — so a
/// `ModelsSelftest.run` that acquired `@MainActor` isolation would pass here
/// and deadlock in production. With it, that mistake hangs this test, which is
/// the loudest signal available for it.
@Test("the synchronous bridge returns the same code as the async run")
@MainActor
func theSynchronousBridgeAgrees() {
    let lines = LineCollector()

    let code = ModelsSelftest.runSynchronously(
        provider: StubAIProvider(models: .success([sonnet])), out: { lines.append($0) })

    #expect(code == 0)
    #expect(lines.joined.contains(sonnet.id))
}
