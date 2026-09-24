import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// `CLIEntry`: the store seam, and the order in which failures happen.
@Suite @MainActor struct CLIEntryTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-cli-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("STENO_STORE_PATH selects the store")
    func storePathIsHonoured() throws {
        let path = "/tmp/steno-test/Steno.store"
        #expect(
            CLIEntry.storeURL(in: [CLIEntry.storePathVariable: path])
                == URL(fileURLWithPath: path))
    }

    /// **An unset or empty variable means the default store, not the working
    /// directory.** `STENO_STORE_PATH= steno export` is how a shell clears a
    /// variable, and `URL(fileURLWithPath: "")` resolves to the current
    /// directory — which would put a store somewhere nobody asked for.
    @Test("an unset or empty variable falls back to the default store")
    func storePathFallsBack() {
        #expect(CLIEntry.storeURL(in: [:]) == nil)
        #expect(CLIEntry.storeURL(in: [CLIEntry.storePathVariable: ""]) == nil)
    }

    /// **A usage error costs no store access.** Parsing happens first, so a
    /// mistyped command line never opens a `ModelContainer` — which is what
    /// keeps `steno exprot` instant and, more usefully, keeps a malformed
    /// command line away from the code that writes files.
    @Test("a usage error exits 2 without opening a store")
    func usageDoesNotOpenAStore() throws {
        let directory = try scratch()
        let store = directory.appendingPathComponent("Steno.store")
        var messages: [String] = []

        let code = CLIEntry.run(
            ["steno", "exprot"],
            environment: [CLIEntry.storePathVariable: store.path],
            makeRunner: { container in
                Issue.record("a usage error must not reach the runner")
                return CLIRunner(container: container)
            },
            err: { messages.append($0) })

        #expect(code == 2)
        #expect(messages.joined().contains("unknown subcommand"))
        #expect(FileManager.default.fileExists(atPath: store.path) == false)
    }

    @Test("a valid command opens the store named by the environment")
    func opensTheNamedStore() throws {
        let directory = try scratch()
        let store = directory.appendingPathComponent("Steno.store")
        var ran = false

        let code = CLIEntry.run(
            ["steno", "export", "--output", directory.appendingPathComponent("o.json").path],
            environment: [CLIEntry.storePathVariable: store.path],
            makeRunner: { container in
                ran = true
                return CLIRunner(
                    container: container,
                    now: { CLIHarness.now },
                    exportedBy: "steno/test (macOS)",
                    isAnotherInstanceRunning: { false },
                    workingDirectory: directory,
                    out: { _ in },
                    err: { _ in })
            },
            err: { _ in })

        #expect(code == 0)
        #expect(ran)
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    /// **The running-instance guard runs before the store is opened.**
    ///
    /// `StenoStore.live` creates the store directory and, on a fresh path, the
    /// store itself — so a refusal raised only inside `CLIRunner` had already
    /// written to disk, and could fail on *opening* the store before it ever got
    /// to report the refusal the user needed. The assertion that catches that is
    /// the absence of the directory, not the exit code. Raised in review of
    /// PR #31.
    @Test("import while the app is running touches no store at all")
    func importRefusedBeforeOpeningTheStore() throws {
        let directory = try scratch()
        let store = directory.appendingPathComponent("fresh/Steno.store")
        var messages: [String] = []

        let code = CLIEntry.run(
            ["steno", "import", "--file", directory.appendingPathComponent("x.json").path],
            environment: [CLIEntry.storePathVariable: store.path],
            isAnotherInstanceRunning: { true },
            makeRunner: { container in
                Issue.record("the guard must fire before a container is built")
                return CLIRunner(container: container)
            },
            err: { messages.append($0) })

        #expect(code == 1)
        #expect(messages.joined() == CLIInstanceCheck.refusalMessage)
        #expect(
            FileManager.default.fileExists(
                atPath: store.deletingLastPathComponent().path) == false)
    }

    /// Export is a pure read (D-085) and is deliberately *not* gated — M2.5-05
    /// auto-exports from a machine where Steno is by definition running. Without
    /// this, the guard above could be widened to every command and nothing would
    /// notice.
    @Test("export while the app is running still opens the store and runs")
    func exportNotGatedByTheGuard() throws {
        let directory = try scratch()
        let store = directory.appendingPathComponent("Steno.store")
        var ran = false

        let code = CLIEntry.run(
            ["steno", "export", "--output", directory.appendingPathComponent("o.json").path],
            environment: [CLIEntry.storePathVariable: store.path],
            isAnotherInstanceRunning: { true },
            makeRunner: { container in
                ran = true
                return CLIRunner(
                    container: container,
                    now: { CLIHarness.now },
                    exportedBy: "steno/test (macOS)",
                    isAnotherInstanceRunning: { true },
                    workingDirectory: directory,
                    out: { _ in },
                    err: { _ in })
            },
            err: { _ in })

        #expect(code == 0)
        #expect(ran)
    }

    /// A store that cannot be opened is exit 1 with the path in the message —
    /// the same information `StoreFailureView` puts on screen, because "could
    /// not open the store" without saying which store sends the reader nowhere.
    @Test("an unopenable store exits 1 and names the path")
    func unopenableStore() throws {
        let directory = try scratch()
        // A directory where the store file must go: `ModelContainer` cannot
        // open it, and nothing about the command line is wrong.
        let store = directory.appendingPathComponent("Steno.store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        var messages: [String] = []

        let code = CLIEntry.run(
            ["steno", "export"],
            environment: [CLIEntry.storePathVariable: store.path],
            makeRunner: { container in
                Issue.record("a store that cannot be opened must not reach the runner")
                return CLIRunner(container: container)
            },
            err: { messages.append($0) })

        #expect(code == 1)
        #expect(messages.joined().contains(store.path))
    }
}

/// The other half of the selftest routing rule.
///
/// `CLIEntry` answers both harnesses before a `ModelContainer` is ever opened,
/// so a runner — which exists to act on the store — should never be handed one.
/// That claim is asserted here rather than assumed: the arm reports the
/// misrouting and exits, and it names the subcommand that got there, because
/// with two harnesses sharing it a message naming only the first would send
/// whoever hit it to the wrong code.
///
/// `CLIEntry.run`'s own selftest branches are deliberately not exercised: they
/// build the real `KeychainCredentialStore` and the real `AnthropicProvider`,
/// which would write into the developer's login keychain and reach the network
/// that §9.4 denies. That is what `make verify-keychain` and `make
/// verify-models` are for.
@Suite @MainActor struct CLISelftestRoutingTests {
    @Test(
        "a selftest handed to the runner is refused, and says which one",
        arguments: ["keychain-selftest", "models-selftest"])
    func misroutedSelftestIsRefused(_ subcommand: String) throws {
        let harness = try CLIHarness()

        let result = try harness.run([subcommand])

        #expect(result.code == 1)
        #expect(result.err.joined().contains("\(subcommand) is handled before the store opens"))
        #expect(result.out.isEmpty)
    }
}
