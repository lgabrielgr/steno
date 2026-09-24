import Foundation

/// What a `steno` invocation asked for, as a value.
///
/// **A value, not a closure over the store.** Parsing happens before anything
/// opens a `ModelContainer`, so a usage error costs no store access at all —
/// which is what lets `steno --help`-shaped mistakes stay instant and, more
/// importantly, keeps a malformed command line from ever reaching the code that
/// writes files.
///
/// `ImportMode` is reused rather than redeclared. §10.5's CLI and the File menu
/// are two surfaces over one engine, and a second two-case enum here would be a
/// second place for `.replace` to mean something — free to drift in exactly the
/// direction M2.5-04's "must not fork their behavior" forbids.
public enum CLICommand: Equatable, Sendable {
    /// `steno export [--output PATH] [--include-cached]`.
    ///
    /// `output` is `nil` when the flag was absent; `CLIRunner` resolves that to
    /// §10.2's dated filename in the working directory. Resolution is
    /// deliberately not done here: it reads the clock and the filesystem, and a
    /// parser that did either could not be tested as a pure function.
    case export(output: URL?, includesCachedExternalData: Bool)

    /// `steno import --file PATH [--replace]`.
    case importFile(URL, mode: ImportMode)

    /// `steno keychain-selftest` — hidden, and absent from `CLIUsage.text`.
    ///
    /// **Carries no store.** It is handled before `CLIEntry` opens a
    /// `ModelContainer`, because verifying the Keychain has nothing to do with
    /// the event log and a harness that created the user's store as a side
    /// effect would be a worse tool than no harness. See `KeychainSelftest`.
    case keychainSelftest

    /// `steno models-selftest` — hidden, and absent from `CLIUsage.text`.
    ///
    /// **Carries no store either**, for `keychainSelftest`'s reason: fetching a
    /// provider's model list has nothing to do with the event log. It reads the
    /// stored credential and makes one `GET`, so it is the network twin of the
    /// Keychain harness. See `ModelsSelftest`.
    case modelsSelftest
}

/// A command line this build cannot act on.
///
/// Carries the text to print rather than a code to switch on: there is exactly
/// one consumer (`CLIEntry`), and the alternative — an enum of usage cases —
/// would put the wording of a usage message somewhere other than the type that
/// knows which flag was wrong.
public struct CLIUsageError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The text `steno` prints when it cannot act on a command line.
///
/// One string, used for every usage failure, so the reader always sees the
/// whole surface rather than the single flag they got wrong. The surface is
/// small enough (§10.5, "keep the flag surface small") that printing all of it
/// costs six lines.
public enum CLIUsage {
    public static let text = """
        usage: steno export [--output PATH] [--include-cached]
               steno import --file PATH [--replace]

          export           write the whole store to a JSON file (§10.2)
          --output PATH    file, or directory to write the dated filename into;
                           defaults to the working directory
          --include-cached include cached external summaries (bulky, re-fetchable)

          import           merge an export into this Mac's store (§10.1)
          --file PATH      the export to read
          --replace        replace the store with the file instead of merging;
                           writes a backup first, and cannot be undone
        """
}
