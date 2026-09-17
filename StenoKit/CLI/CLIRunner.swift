import Foundation
import SwiftData

/// §10.5's CLI, over exactly the engine the File menu uses.
///
/// **This type adds no export or import semantics.** `ExportEncoder`,
/// `ImportService.plan`/`apply`, `ImportPreviewSummary` and `BackupWriter` are
/// called the way `MainWindowModel+Portability` calls them; what is new here is
/// destination resolution, an exit code, and two output sinks. A behaviour that
/// differs between `steno import` and `File ▸ Import…` is a defect, not a
/// feature — M2.5-04's "must not fork their behavior".
///
/// **`run` returns an exit code and never throws.** An error escaping into
/// `main()` terminates the process with a backtrace, where §9.2 asks for a
/// message on stderr and a non-zero status.
///
/// `@MainActor` because `ModelContext` is not `Sendable`, for the reason every
/// service in this app records.
@MainActor
public struct CLIRunner {
    /// `0` success · `1` the operation failed · `2` the command line was wrong.
    ///
    /// Three codes, not a taxonomy. A script needs to know whether to retry,
    /// whether to alert, and whether it invoked the tool wrongly;
    /// `ImportError.message` on stderr carries everything finer than that, and a
    /// numbered code per error case would be a second description of the same
    /// failure, free to drift from the first.
    public enum ExitCode {
        public static let success: Int32 = 0
        public static let failure: Int32 = 1
        public static let usage: Int32 = 2
    }

    // Internal, not `private`: `private` is file-scoped, and the two command
    // implementations live in `CLIRunner+Export.swift` and
    // `CLIRunner+Import.swift` — which is where they can be read beside the
    // §10 rules they implement rather than buried under this initializer.
    let context: ModelContext
    let now: () -> Date
    let exportedBy: String
    let isAnotherInstanceRunning: @MainActor () -> Bool
    let makeBackupWriter: @MainActor (ModelContext) throws -> BackupWriter
    let workingDirectory: URL
    let out: @MainActor (String) -> Void
    let err: @MainActor (String) -> Void

    /// - Parameters:
    ///   - now: injected so `exportedAt` and the dated filename are assertable,
    ///     for the reason `ExportEncoder` and `BackupWriter` both record.
    ///   - exportedBy: passed rather than defaulted for D-010's reason — the
    ///     test bundle is unhosted, so `Bundle.main` there is the xctest runner,
    ///     and a defaulted user agent would put the runner's version into a file
    ///     a test then asserts on and pass anyway.
    ///   - isAnotherInstanceRunning: injected so both answers are testable
    ///     without a second process. See `CLIInstanceCheck`.
    ///   - makeBackupWriter: a factory rather than a writer, for
    ///     `MainWindowModel`'s reason: its initializer throws, and tests point it
    ///     at a temp directory so the suite never writes into the developer's
    ///     Application Support.
    ///   - workingDirectory: where a bare `--output`-less export lands.
    ///     Injected because the xctest runner's working directory is not this
    ///     repo and a test must not write into whatever it happens to be.
    public init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        exportedBy: String = ExportDocument.userAgent(),
        isAnotherInstanceRunning: @escaping @MainActor () -> Bool =
            CLIInstanceCheck.anotherInstanceIsRunning,
        makeBackupWriter: @escaping @MainActor (ModelContext) throws -> BackupWriter = {
            try BackupWriter(context: $0)
        },
        workingDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        out: @escaping @MainActor (String) -> Void = CLIOutput.standardOut,
        err: @escaping @MainActor (String) -> Void = CLIOutput.standardError
    ) {
        // A context of this runner's own, never `container.mainContext`: that
        // property does not retain its container, and nothing in a CLI process
        // holds the container for the lifetime an App's stored property would.
        self.context = ModelContext(container)
        self.now = now
        self.exportedBy = exportedBy
        self.isAnotherInstanceRunning = isAnotherInstanceRunning
        self.makeBackupWriter = makeBackupWriter
        self.workingDirectory = workingDirectory
        self.out = out
        self.err = err
    }

    public func run(_ command: CLICommand) -> Int32 {
        switch command {
        case .export(let output, let includesCached):
            export(to: output, includingCachedData: includesCached)
        case .importFile(let url, let mode):
            importFile(url, mode: mode)
        }
    }
}
