import Foundation
import Testing

@testable import StenoKit

/// The real binary, in a real process.
///
/// **This is the only test that can speak to "running a subcommand does not open
/// a window or require a GUI session".** Everything else in this directory calls
/// `CLIRunner` in-process, which proves the logic and says nothing about the
/// `@main` shim, the `MainActor.assumeIsolated` hop, or whether `NSApplication`
/// gets started on the way. A process that runs the command and *exits* is the
/// observable form of that criterion: an app that reached SwiftUI's `main` would
/// enter a run loop and never return.
///
/// `STENO_STORE_PATH` is what keeps this off the developer's own store. It is a
/// test seam, documented as one on `CLIEntry.storePathVariable`, and the GUI
/// path ignores it.
@Suite struct CLIBinaryTests {
    /// `Steno.app` sits beside the test bundle in DerivedData, because the
    /// scheme builds the app for testing.
    ///
    /// **A missing binary fails rather than skips.** A skipped test is a test
    /// that cannot fail, and this is the only automated evidence that the shim
    /// works at all.
    private static func binary() throws -> URL {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        let binary =
            products
            .appendingPathComponent("Steno.app/Contents/MacOS/Steno")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            Issue.record(
                """
                No Steno binary at \(binary.path). The scheme builds the app for testing, so \
                this means the products directory moved — fix the path, do not skip the test.
                """)
            throw CLIBinaryError.notBuilt
        }
        return binary
    }

    private enum CLIBinaryError: Error { case notBuilt }

    /// What one run of the real binary produced.
    ///
    /// A named type rather than a three-member tuple, which SwiftLint's
    /// `large_tuple` rejects under `--strict`.
    struct ProcessResult {
        let code: Int32
        let out: String
        let err: String
    }

    /// One run of the real binary in a scratch directory of its own.
    private static func run(_ arguments: [String], in directory: URL) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment(storedAt: directory)

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before `waitUntilExit`: a pipe whose buffer fills blocks the
        // child, and a child that blocks never exits — the classic deadlock in
        // this shape of test.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `String(bytes:encoding:)`, not `String(decoding:as:)`: SwiftLint's
        // `optional_data_string_conversion` rejects the latter under --strict.
        // The `?? ""` is unreachable for output this binary produces, and an
        // empty string is also the right answer for a stream that produced
        // nothing decodable.
        return ProcessResult(
            code: process.terminationStatus,
            out: String(bytes: outData, encoding: .utf8) ?? "",
            err: String(bytes: errData, encoding: .utf8) ?? "")
    }

    /// A deliberately minimal environment, **not** the test runner's own.
    ///
    /// Inheriting `ProcessInfo.processInfo.environment` made this suite fail in
    /// a way worth recording: xctest runs under `OS_ACTIVITY_DT_MODE=YES`, which
    /// makes `os.Logger` mirror every line to **stderr** as well as to the
    /// unified log. `Log.app.info("cli export written to …")` therefore landed
    /// on stderr, and "a successful export prints nothing to stderr" — true of
    /// the binary as a person or a script runs it — was false of the binary as
    /// the test ran it.
    ///
    /// Stripping the variable alone would have fixed that one symptom. Passing a
    /// minimal environment fixes the class: the child no longer inherits
    /// `DYLD_FRAMEWORK_PATH` and friends either, so it loads the frameworks
    /// embedded in its own bundle by `@rpath` exactly as a shipped app does.
    /// `HOME` and `PATH` are kept because a process with neither is not a
    /// realistic environment; `TMPDIR` because `FileManager.temporaryDirectory`
    /// reads it.
    private static func environment(storedAt directory: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME", "PATH", "TMPDIR"].reduce(into: [String: String]()) {
            $0[$1] = inherited[$1]
        }
        environment[CLIEntry.storePathVariable] =
            directory.appendingPathComponent("Steno.store").path
        return environment
    }

    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-cli-binary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("the binary exports headlessly and exits 0")
    func exportsHeadlessly() throws {
        let directory = try Self.scratch()
        let destination = directory.appendingPathComponent("out.json")

        let result = try Self.run(["export", "--output", destination.path], in: directory)
        #expect(result.code == 0)
        // Nothing on stderr: §9.2 puts failures there, so a successful run that
        // wrote to it would make a script's error check fire on a success.
        #expect(result.err.isEmpty, "stderr was: \(result.err)")
        #expect(result.out.contains(destination.path))

        // A decodable envelope, not merely a file: an export that wrote zero
        // bytes would satisfy `fileExists` and nothing else.
        let document = try ImportReader.read(Data(contentsOf: destination))
        #expect(document.schemaVersion == ExportDocument.currentSchemaVersion)
        // `Bundle.main` in the real binary is the app bundle, which is what
        // makes this the version string a GUI export would carry.
        #expect(document.exportedBy.hasPrefix("steno/"))
        #expect(document.exportedBy.hasSuffix("(macOS)"))
    }

    /// The store seam is doing what it claims: the export landed in the temp
    /// store, and the process never opened `~/Library/Application Support`.
    @Test("STENO_STORE_PATH is where the store goes")
    func honoursTheStoreSeam() throws {
        let directory = try Self.scratch()
        #expect(
            try Self.run(
                ["export", "--output", directory.appendingPathComponent("o.json").path],
                in: directory
            ).code == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Steno.store").path))
    }

    @Test("an unknown subcommand exits 2 with usage on stderr")
    func usageExitCode() throws {
        let directory = try Self.scratch()
        let result = try Self.run(["exprot"], in: directory)
        #expect(result.code == 2)
        #expect(result.err.contains("unknown subcommand"))
        #expect(result.out.isEmpty)
    }

    @Test("a failure exits 1 with the message on stderr, not stdout")
    func failureExitCode() throws {
        let directory = try Self.scratch()
        let result = try Self.run(
            ["import", "--file", directory.appendingPathComponent("absent.json").path],
            in: directory)
        #expect(result.code == 1)
        #expect(result.err.contains("Could not read"))
    }
}

/// A type in the test bundle, so `Bundle(for:)` finds the bundle rather than the
/// framework. `Bundle.module` does not exist here — this is an Xcode unit-test
/// bundle, not a SwiftPM resource target.
private final class BundleAnchor {}
