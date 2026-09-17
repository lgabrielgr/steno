import Foundation
import SwiftData

/// The seam between the app binary's `main()` and everything testable.
///
/// **The app target's share of the CLI is six lines, and that is the point.**
/// The test bundle is unhosted and links `StenoKit`, not the application
/// (D-010), so anything that lives in the app target is code no test can reach.
/// Both halves of the decision — "is this a CLI invocation?" and "what does it
/// do?" — therefore live here.
public enum CLIEntry {
    /// The environment variable that redirects the CLI's store.
    ///
    /// **Honoured on the CLI path only.** The GUI opens `StenoStore.defaultURL`
    /// and always has; a stray variable inherited from a shell must never
    /// redirect the real app's data. This exists so the subprocess test can run
    /// the real binary against a temp store rather than the developer's own, and
    /// it is a test seam rather than a supported way to run Steno.
    public static let storePathVariable = "STENO_STORE_PATH"

    /// Is this argv a `steno` subcommand rather than an app launch?
    ///
    /// **The rule: there is a second argument, and it does not begin with `-`.**
    ///
    /// This is what makes "a double-click never lands in CLI mode" true by
    /// construction rather than by hope. Every argument LaunchServices passes is
    /// dash-prefixed — the legacy `-psn_0_…` process serial number, and
    /// `-NSDocumentRevisionsDebugMode YES` when Xcode launches the app — so no
    /// launch path short of `open -a Steno --args export` can produce a bare
    /// first word, and that one is a deliberate act.
    ///
    /// It also decides what a typo does. `steno exprot` has a bare first word,
    /// so it is a CLI invocation with an unrecognised subcommand: usage on
    /// stderr, exit 2. Falling through to the GUI there would be the worse
    /// failure — a scripted export that silently opens a window and hangs the
    /// script on a run loop that never returns.
    public static func isCommandLineInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return !first.isEmpty && !first.hasPrefix("-")
    }

    /// Parse, open the store, run, and return the process's exit code.
    ///
    /// Never throws, for `CLIRunner.run`'s reason: an error escaping into
    /// `main()` would terminate with a backtrace where §9.2 asks for a message
    /// and a status.
    ///
    /// - Parameters:
    ///   - environment: injected so a test can exercise `STENO_STORE_PATH`
    ///     without mutating the process environment, which every other test in
    ///     the bundle shares.
    ///   - makeRunner: injected for the same reason the runner injects its own
    ///     collaborators — a test that let this build a real `CLIRunner` would
    ///     reach the developer's Application Support for a backup directory.
    ///   - isAnotherInstanceRunning: checked **before** the container is opened.
    ///     See the guard below.
    @MainActor
    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isAnotherInstanceRunning: () -> Bool = CLIInstanceCheck.anotherInstanceIsRunning,
        makeRunner: (ModelContainer) -> CLIRunner = { CLIRunner(container: $0) },
        err: (String) -> Void = CLIOutput.standardError
    ) -> Int32 {
        let command: CLICommand
        do {
            command = try CLIParser.parse(arguments)
        } catch let usage as CLIUsageError {
            err(usage.message)
            return CLIRunner.ExitCode.usage
        } catch {
            err("steno: \(error.localizedDescription)\n\n\(CLIUsage.text)")
            return CLIRunner.ExitCode.usage
        }

        // **Before the store is opened, not after.** `StenoStore.live` creates
        // the store directory and, on a fresh path, the store itself — so a
        // refusal raised further in had already written to disk, and could fail
        // on *opening* the store before it ever got to report the refusal the
        // user needed to see. Only `import` is gated: export is a pure read
        // (D-085) and must keep working while the app is open, which M2.5-05
        // depends on. Raised in review of PR #31.
        if case .importFile = command, isAnotherInstanceRunning() {
            err(CLIInstanceCheck.refusalMessage)
            return CLIRunner.ExitCode.failure
        }

        let container: ModelContainer
        do {
            container = try StenoStore.live(at: storeURL(in: environment))
        } catch {
            // The path, not just the error: §9.2 streams this to a terminal, and
            // "could not open the store" without saying which store is the same
            // unhelpful message `StoreFailureView` exists to avoid on screen.
            let path = (try? storeURL(in: environment)?.path ?? StenoStore.defaultURL.path)
            err(
                "steno: could not open the store at \(path ?? "<unknown>"). "
                    + error.localizedDescription)
            return CLIRunner.ExitCode.failure
        }

        return makeRunner(container).run(command)
    }

    /// `STENO_STORE_PATH` as a URL, or `nil` for `StenoStore.defaultURL`.
    ///
    /// An empty value is treated as unset: `STENO_STORE_PATH= steno export` is
    /// how a shell clears a variable, and resolving that to the working
    /// directory would open a store somewhere nobody asked for.
    ///
    /// Internal rather than `private` so it can be tested directly: the
    /// empty-value case resolves to `StenoStore.defaultURL`, and a test that
    /// exercised it through `run` would open the developer's real store.
    static func storeURL(in environment: [String: String]) -> URL? {
        guard let path = environment[storePathVariable], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
