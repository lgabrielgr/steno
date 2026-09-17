import Foundation
import Testing

@testable import StenoKit

/// The argv rule and the flag surface, as pure functions.
///
/// **These four dash cases are M2.5-04's double-click acceptance criterion.**
/// "Running a subcommand does not open a window" cannot be automated end to end
/// — nobody can click the app — but the property it rests on can: every argument
/// LaunchServices passes is dash-prefixed, so a rule that refuses dash-prefixed
/// first words cannot be reached by a launch.
@Suite struct CLIArgvRuleTests {
    @Test("a bare argv is an app launch, not a command")
    func bareArgv() {
        #expect(CLIEntry.isCommandLineInvocation(["/Applications/Steno.app/…/Steno"]) == false)
    }

    @Test(
        "LaunchServices arguments are app launches",
        arguments: ["-psn_0_123456", "-NSDocumentRevisionsDebugMode", "-AppleLanguages"])
    func launchServicesArguments(_ argument: String) {
        #expect(CLIEntry.isCommandLineInvocation(["steno", argument]) == false)
    }

    @Test("an empty first argument is an app launch")
    func emptyArgument() {
        #expect(CLIEntry.isCommandLineInvocation(["steno", ""]) == false)
    }

    @Test(
        "a bare first word is a command, including a typo",
        arguments: ["export", "import", "exprot"])
    func bareWord(_ argument: String) {
        #expect(CLIEntry.isCommandLineInvocation(["steno", argument]))
    }
}

@Suite struct CLIParserTests {
    private func parse(_ arguments: [String]) throws -> CLICommand {
        try CLIParser.parse(["steno"] + arguments)
    }

    // MARK: - export

    @Test("export with no flags takes no output and no cached data")
    func bareExport() throws {
        #expect(
            try parse(["export"]) == .export(output: nil, includesCachedExternalData: false))
    }

    @Test("--output becomes a file URL")
    func exportOutput() throws {
        let command = try parse(["export", "--output", "/tmp/steno/out.json"])
        #expect(
            command
                == .export(
                    output: URL(fileURLWithPath: "/tmp/steno/out.json"),
                    includesCachedExternalData: false))
    }

    @Test("--include-cached sets §10.2's opt-in")
    func exportIncludeCached() throws {
        #expect(
            try parse(["export", "--include-cached"])
                == .export(output: nil, includesCachedExternalData: true))
    }

    @Test("flags compose in either order")
    func exportFlagOrder() throws {
        let one = try parse(["export", "--include-cached", "--output", "/tmp/a.json"])
        let two = try parse(["export", "--output", "/tmp/a.json", "--include-cached"])
        #expect(one == two)
    }

    // MARK: - import

    @Test("import defaults to §10.1's merge")
    func importDefaultsToMerge() throws {
        #expect(
            try parse(["import", "--file", "/tmp/in.json"])
                == .importFile(URL(fileURLWithPath: "/tmp/in.json"), mode: .merge))
    }

    @Test("--replace selects the break-glass mode")
    func importReplace() throws {
        #expect(
            try parse(["import", "--file", "/tmp/in.json", "--replace"])
                == .importFile(URL(fileURLWithPath: "/tmp/in.json"), mode: .replace))
    }

    // MARK: - usage failures

    @Test("no subcommand is a usage error")
    func noSubcommand() {
        #expect(throws: CLIUsageError.self) { try CLIParser.parse(["steno"]) }
    }

    @Test("an unknown subcommand names the word that was wrong")
    func unknownSubcommand() throws {
        let error = try #require(throws: CLIUsageError.self) { try parse(["exprot"]) }
        #expect(error.message.contains("exprot"))
        #expect(error.message.contains(CLIUsage.text))
    }

    @Test("import without --file is refused")
    func importWithoutFile() throws {
        let error = try #require(throws: CLIUsageError.self) { try parse(["import"]) }
        #expect(error.message.contains("--file is required"))
    }

    @Test(
        "a flag that needs a path and has none is refused",
        arguments: [["export", "--output"], ["import", "--file"]])
    func flagWithoutValue(_ arguments: [String]) throws {
        let error = try #require(throws: CLIUsageError.self) { try parse(arguments) }
        #expect(error.message.contains("needs a path"))
    }

    @Test(
        "an empty path is refused rather than resolving to the working directory",
        arguments: [["export", "--output", ""], ["import", "--file", ""]])
    func emptyPath(_ arguments: [String]) throws {
        let error = try #require(throws: CLIUsageError.self) { try parse(arguments) }
        #expect(error.message.contains("needs a path"))
    }

    /// **A positional argument is a usage error, not something to ignore.**
    /// `steno export out.json` is a plausible typo for `--output out.json`, and
    /// accepting it silently would write the export to the dated filename
    /// instead of the path the user named.
    @Test(
        "a positional argument is refused",
        arguments: [["export", "out.json"], ["import", "--file", "a.json", "b.json"]])
    func positionalArgument(_ arguments: [String]) throws {
        let error = try #require(throws: CLIUsageError.self) { try parse(arguments) }
        #expect(error.message.contains("unexpected argument"))
    }

    @Test("an unknown flag is refused")
    func unknownFlag() throws {
        let error = try #require(throws: CLIUsageError.self) {
            try parse(["export", "--compress"])
        }
        #expect(error.message.contains("--compress"))
    }
}
