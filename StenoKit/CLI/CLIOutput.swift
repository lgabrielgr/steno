import Darwin
import Foundation

/// Where `CLIRunner` writes when nobody injected anything else.
///
/// **Injected everywhere else, so no test ever writes to the terminal.** The
/// headless bundle runs under the xctest runner (§9.4), and a type that reached
/// `FileHandle.standardOutput` directly would interleave its output with the
/// runner's own — which is how a passing suite starts looking like a failing
/// one.
///
/// A caseless `enum` for `StenoStore`'s reason: no instance state, so there is
/// nothing for strict concurrency to reason about.
public enum CLIOutput {
    /// One line to stdout, newline appended.
    ///
    /// `FileHandle.write` rather than `print`: `print` goes through Swift's own
    /// buffering, and the CLI exits with `exit()` rather than by returning from
    /// `main`, so a buffered line can be discarded on the way out. That is not
    /// hypothetical here — `StenoApp.init` already carries an `fflush(stdout)`
    /// for the same reason, because stdout is fully buffered when it is not a
    /// TTY, which is exactly how a script would run these commands.
    public static func standardOut(_ line: String) {
        write(line, to: FileHandle.standardOutput)
    }

    /// One line to stderr. §9.2 asks for failures here, not on stdout.
    public static func standardError(_ line: String) {
        write(line, to: FileHandle.standardError)
    }

    private static func write(_ line: String, to handle: FileHandle) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        // `try?`, not `try!`: a closed or broken pipe throws here — `steno
        // export | head -1` is enough to produce one — and a CLI that traps
        // because its reader went away would turn a successful export into a
        // crash report.
        try? handle.write(contentsOf: data)
    }
}
