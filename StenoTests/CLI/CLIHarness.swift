import Foundation
import SwiftData

@testable import StenoKit

/// A `steno` invocation under test: the store, the injected world, and
/// everything the process wrote.
///
/// **Nothing here reaches the real machine.** The store is in-memory — or, for
/// the tests that need a store path, a SQLite file inside this harness's own
/// scratch directory — the working directory and backup directory are both
/// per-test temp directories, and
/// both output sinks are arrays. A CLI test that wrote to the terminal would
/// interleave with the xctest runner's own output (§9.4), and one that wrote to
/// `~/Library/Application Support` would touch the developer's data.
@MainActor
final class CLIHarness {
    /// 2023-11-14 22:13:20 UTC, matching `ExportFixture.origin` so a fixture
    /// built there and a CLI run here agree about "now".
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    let container: ModelContainer

    /// A context of the test's own, separate from the one `CLIRunner` builds.
    ///
    /// Deliberately separate: a fetch on the *same* context returns the object
    /// already held rather than re-reading the store, so an assertion made
    /// through the runner's context could not see a write that never landed.
    let context: ModelContext

    /// Where a bare `steno export` lands, and where these tests look for it.
    let workingDirectory: URL
    let backupDirectory: URL

    /// What `CLIInstanceCheck` would answer. Flipped by the tests that care.
    var appIsRunning = false

    /// Scripted answers, consumed one per call, falling back to `appIsRunning`
    /// when exhausted.
    ///
    /// Exists for one property: the import path checks the running app more than
    /// once, and the check that matters is the **last** one, immediately before
    /// the transaction. A single boolean cannot tell those apart — it makes
    /// every check look equally load-bearing — so removing the last one survived
    /// mutation until this existed.
    var appIsRunningAnswers: [Bool] = []

    private func nextInstanceAnswer() -> Bool {
        guard !appIsRunningAnswers.isEmpty else { return appIsRunning }
        return appIsRunningAnswers.removeFirst()
    }

    /// Injected so "the backup could not be written" is testable without
    /// contriving a read-only filesystem — `BackupWriter`'s own reason.
    var backupWrite: ((Data, URL) throws -> Void)?

    /// Where the store lives, for the tests that need to name it. `nil` for the
    /// in-memory default.
    let storeURL: URL?

    private(set) var out: [String] = []
    private(set) var err: [String] = []

    /// - Parameter fileBacked: opens a real SQLite store inside this harness's
    ///   scratch directory instead of an in-memory one. Only the tests that need
    ///   a store *path* — the guard against exporting over it — pass `true`; an
    ///   in-memory container reports `/dev/null` as its url, which would make
    ///   that assertion pass for the wrong reason.
    init(fileBacked: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-cli-tests-\(UUID().uuidString)", isDirectory: true)
        workingDirectory = root.appendingPathComponent("cwd", isDirectory: true)
        backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true)

        storeURL = fileBacked ? workingDirectory.appendingPathComponent("Steno.store") : nil
        container = try fileBacked ? StenoStore.live(at: storeURL) : StenoStore.inMemory()
        context = ModelContext(container)
    }

    /// Run one command line, exactly as `CLIEntry` would after parsing.
    ///
    /// Takes the arguments **without** the executable path and prepends one, so
    /// a test reads as the command a person would type while the parser still
    /// sees the `argv` shape it gets in production.
    func run(_ arguments: [String]) throws -> CLIResult {
        out = []
        err = []
        let command = try CLIParser.parse(["steno"] + arguments)
        let code = runner().run(command)
        return CLIResult(code: code, out: out, err: err)
    }

    private func runner() -> CLIRunner {
        CLIRunner(
            container: container,
            now: { Self.now },
            // Passed rather than defaulted for D-010's reason: the test bundle
            // is unhosted, so `Bundle.main` here is the xctest runner.
            exportedBy: "steno/test (macOS)",
            isAnotherInstanceRunning: { self.nextInstanceAnswer() },
            makeBackupWriter: { context in
                try BackupWriter(
                    context: context,
                    directory: self.backupDirectory,
                    now: { Self.now },
                    write: self.backupWrite ?? { try $0.write(to: $1, options: .atomic) })
            },
            workingDirectory: workingDirectory,
            out: { self.out.append($0) },
            err: { self.err.append($0) })
    }

    /// The whole store at wire precision — the shape "nothing was changed" is
    /// actually a statement about.
    func wholeStore() throws -> MergedStore {
        try MergedStore(
            try ExportEncoder(
                context: context, includesCachedExternalData: true,
                exportedBy: "steno/test (macOS)"
            ).snapshot()
        ).wireNormalized()
    }

    /// A file in this harness's working directory.
    func path(_ name: String) -> URL {
        workingDirectory.appendingPathComponent(name)
    }
}

/// What one `steno` invocation produced.
///
/// A named type rather than a three-member tuple, which SwiftLint's
/// `large_tuple` rejects under `--strict`.
struct CLIResult {
    let code: Int32
    let out: [String]
    let err: [String]

    /// Everything the run printed to stdout, so a test can ask about the
    /// preview as one string rather than by index — the line count changes when
    /// §10.4 omits a category, and indexing would make those tests brittle for a
    /// reason unrelated to what they assert.
    var stdout: String { out.joined(separator: "\n") }
    var stderr: String { err.joined(separator: "\n") }
}
