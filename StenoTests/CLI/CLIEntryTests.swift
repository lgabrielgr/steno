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
