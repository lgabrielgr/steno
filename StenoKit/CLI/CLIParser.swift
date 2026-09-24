import Foundation

/// `argv` to a `CLICommand`, or a usage error.
///
/// **Reached only for an invocation `CLIEntry.isCommandLineInvocation` has
/// already accepted.** That split is deliberate: "is this the GUI launching?"
/// is asked in exactly one place, and this type has one job. A parser that also
/// returned `nil` for "not a CLI invocation" would put the double-click rule in
/// two files, and the one that got it wrong would be the one nobody tested.
///
/// Hand-written, with no argument-parsing dependency. The surface is two
/// subcommands and three flags, and §9.1's toolchain list is short on purpose.
public enum CLIParser {
    /// - Parameter arguments: `CommandLine.arguments`, executable path included.
    /// - Throws: `CLIUsageError`, carrying the text to print to stderr.
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        let rest = Array(arguments.dropFirst())
        guard let subcommand = rest.first else {
            throw CLIUsageError("steno: no subcommand given.\n\n\(CLIUsage.text)")
        }

        switch subcommand {
        case "export":
            return try parseExport(Array(rest.dropFirst()))
        case "import":
            return try parseImport(Array(rest.dropFirst()))
        case "keychain-selftest":
            // Takes no flags. Accepting and ignoring them would let
            // `keychain-selftest --replace` look like it did something.
            guard rest.count == 1 else {
                throw unexpected(rest[1], of: "keychain-selftest")
            }
            return .keychainSelftest
        case "models-selftest":
            // Takes no flags, for `keychain-selftest`'s reason: accepting and
            // ignoring them would let `models-selftest --replace` look like it
            // did something.
            guard rest.count == 1 else {
                throw unexpected(rest[1], of: "models-selftest")
            }
            return .modelsSelftest
        default:
            throw CLIUsageError(
                "steno: unknown subcommand \"\(subcommand)\".\n\n\(CLIUsage.text)")
        }
    }

    private static func parseExport(_ flags: [String]) throws -> CLICommand {
        var output: URL?
        var includesCached = false
        var index = 0

        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--output":
                output = URL(fileURLWithPath: try value(after: flag, in: flags, at: &index))
            case "--include-cached":
                includesCached = true
            default:
                throw unexpected(flag, of: "export")
            }
            index += 1
        }

        return .export(output: output, includesCachedExternalData: includesCached)
    }

    private static func parseImport(_ flags: [String]) throws -> CLICommand {
        var file: URL?
        var mode = ImportMode.merge
        var index = 0

        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--file":
                file = URL(fileURLWithPath: try value(after: flag, in: flags, at: &index))
            case "--replace":
                mode = .replace
            default:
                throw unexpected(flag, of: "import")
            }
            index += 1
        }

        guard let file else {
            throw CLIUsageError("steno import: --file is required.\n\n\(CLIUsage.text)")
        }
        return .importFile(file, mode: mode)
    }

    /// The argument after `flag`, advancing past it.
    ///
    /// **An empty value is refused.** `--output ""` would otherwise become
    /// `URL(fileURLWithPath: "")`, which resolves to the working directory
    /// itself — so an export would silently land on the dated filename rather
    /// than reporting that the path was empty.
    ///
    /// **A dash-prefixed value is refused too**, and that one is not
    /// hypothetical: `steno import --file --replace` read a file literally named
    /// `--replace` *in merge mode*, and `steno export --output --include-cached`
    /// silently swallowed the flag it was meant to set. Both are a missing value
    /// wearing the next flag's clothes, and both failed in a direction the user
    /// could not see. Raised in review of PR #31.
    ///
    /// The cost is that a path genuinely beginning with `-` needs `./-name`.
    /// That is the conventional trade, and this tool takes exactly two paths.
    private static func value(
        after flag: String, in flags: [String], at index: inout Int
    ) throws -> String {
        let next = index + 1
        guard next < flags.count, !flags[next].isEmpty else {
            throw CLIUsageError("steno: \(flag) needs a path.\n\n\(CLIUsage.text)")
        }
        guard !flags[next].hasPrefix("-") else {
            throw CLIUsageError(
                """
                steno: \(flag) needs a path, and "\(flags[next])" looks like a flag. \
                For a path that really starts with a dash, write ./\(flags[next]).

                \(CLIUsage.text)
                """)
        }
        index = next
        return flags[next]
    }

    /// **Positional arguments land here too, and that is intended.** `steno
    /// export out.json` is a plausible typo for `--output out.json`, and
    /// silently ignoring the word would write the export somewhere the user did
    /// not name.
    private static func unexpected(_ flag: String, of subcommand: String) -> CLIUsageError {
        CLIUsageError(
            "steno \(subcommand): unexpected argument \"\(flag)\".\n\n\(CLIUsage.text)")
    }
}
