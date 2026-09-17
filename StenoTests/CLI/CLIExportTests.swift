import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// `steno export`, against a real store.
@Suite @MainActor struct CLIExportTests {
    /// One project and one task, enough that an export is not five empty
    /// arrays — an empty store would let a dropped fetch pass unnoticed.
    private func seed(_ harness: CLIHarness) throws {
        let project = Project(
            id: UUID(), name: "Payments", colorHex: "#112233",
            modifiedAt: CLIHarness.now)
        harness.context.insert(project)
        let task = TaskItem(
            id: UUID(), title: "Fix the retry handler", projectID: project.id,
            createdAt: CLIHarness.now.addingTimeInterval(10))
        harness.context.insert(task)
        harness.context.insert(
            Event(
                id: UUID(), taskID: task.id, timestamp: CLIHarness.now.addingTimeInterval(10),
                kind: .created, body: "task created"))
        try harness.context.save()
    }

    /// **M2.5-04's first acceptance criterion, stated as equality against the
    /// type the GUI calls.** "Identical to what the GUI produces" is not a
    /// structural claim about two documents; it is the claim that the CLI adds
    /// nothing to the encoder. Comparing bytes to `ExportEncoder` over the same
    /// store, clock and user agent is the only form of that claim a change to
    /// either side cannot satisfy by accident.
    @Test("the file is byte-identical to what ExportEncoder produces")
    func matchesTheEncoder() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let destination = harness.path("out.json")

        let result = try harness.run(["export", "--output", destination.path])
        #expect(result.code == 0)

        let expected = try ExportEncoder(
            context: harness.context,
            includesCachedExternalData: false,
            now: { CLIHarness.now },
            exportedBy: "steno/test (macOS)"
        ).encode()
        #expect(try Data(contentsOf: destination) == expected)
    }

    @Test("with no --output the file lands in the working directory, dated")
    func defaultDestination() throws {
        let harness = try CLIHarness()
        try seed(harness)

        let result = try harness.run(["export"])
        #expect(result.code == 0)

        let expected = harness.path(ExportFilename.forDate(CLIHarness.now))
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(result.stdout.contains(expected.path))
    }

    /// M2.5-05 points a folder at a sync drive and wants exactly this. Without
    /// it, `--output <directory>` would try to write a file over a directory and
    /// fail with an errno nobody can act on.
    @Test("--output naming a directory writes the dated filename inside it")
    func directoryDestination() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let folder = harness.path("exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = try harness.run(["export", "--output", folder.path])
        #expect(result.code == 0)

        let expected = folder.appendingPathComponent(ExportFilename.forDate(CLIHarness.now))
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    /// `ExportFilename`'s own documentation defers collisions to this task, and
    /// the answer is overwrite: a scripted daily export to one folder has to be
    /// re-runnable.
    @Test("an existing file is overwritten")
    func overwrites() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let destination = harness.path("out.json")
        try Data("not an export".utf8).write(to: destination)

        let result = try harness.run(["export", "--output", destination.path])
        #expect(result.code == 0)

        let written = try Data(contentsOf: destination)
        #expect(written != Data("not an export".utf8))
        #expect(try ImportReader.read(written).schemaVersion == 1)
    }

    /// Creating the directory was rejected: `--output` is a destination, not an
    /// instruction to build a tree, and a typo'd path would silently produce
    /// one.
    @Test("a missing parent directory is refused, naming the directory")
    func missingParentDirectory() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let destination = harness.path("nowhere/out.json")

        let result = try harness.run(["export", "--output", destination.path])
        #expect(result.code == 1)
        #expect(result.stderr.contains(harness.path("nowhere").path))
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("--include-cached is carried into the envelope")
    func includeCached() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let destination = harness.path("out.json")

        #expect(try harness.run(["export", "--output", destination.path]).code == 0)
        #expect(
            try ImportReader.read(Data(contentsOf: destination))
                .includesCachedExternalData == false)

        #expect(
            try harness.run(["export", "--output", destination.path, "--include-cached"]).code
                == 0)
        #expect(
            try ImportReader.read(Data(contentsOf: destination))
                .includesCachedExternalData)
    }

    /// Export is a pure read (D-085), so it does not care whether the app has
    /// the store open. The asymmetry matters: M2.5-05 auto-exports from a
    /// machine where Steno is by definition running.
    @Test("export runs even when the app is open")
    func runsAlongsideTheApp() throws {
        let harness = try CLIHarness()
        try seed(harness)
        harness.appIsRunning = true

        let result = try harness.run(["export", "--output", harness.path("out.json").path])
        #expect(result.code == 0)
    }
}
