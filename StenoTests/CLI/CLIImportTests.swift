import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// `steno import`, against a real store — §10.6's round trip end to end.
@Suite @MainActor struct CLIImportTests {
    /// A store with one project, one task and its creation event.
    ///
    /// **No cached ref data.** §10.2 excludes `lastFetchedAt` and
    /// `cachedSummary` from an ordinary export, so a fixture carrying them could
    /// not survive a default round trip and the assertion would fail on the
    /// format working as specified. `CLIReplaceTests` covers the cached fields
    /// through the backup, which does include them.
    @discardableResult
    private func seed(_ harness: CLIHarness, title: String = "Fix the retry handler") throws
        -> TaskItem
    {
        let project = Project(
            id: UUID(), name: "Payments", colorHex: "#112233", modifiedAt: CLIHarness.now)
        harness.context.insert(project)
        let task = TaskItem(
            id: UUID(), title: title, projectID: project.id,
            createdAt: CLIHarness.now.addingTimeInterval(10))
        harness.context.insert(task)
        harness.context.insert(
            Event(
                id: UUID(), taskID: task.id, timestamp: CLIHarness.now.addingTimeInterval(10),
                kind: .created, body: "task created"))
        try harness.context.save()
        return task
    }

    /// Export from one store, import into an empty one, compare every record.
    ///
    /// This is §10.6's first property — "export → import into an empty store →
    /// resulting object graph is identical" — run through the CLI rather than
    /// through the types, which is the whole reason M2.5-04 exists.
    @Test("a round trip through two stores preserves every record")
    func roundTrip() throws {
        let source = try CLIHarness()
        try seed(source)
        let file = source.path("out.json")
        #expect(try source.run(["export", "--output", file.path]).code == 0)

        let target = try CLIHarness()
        let result = try target.run(["import", "--file", file.path])
        #expect(result.code == 0)
        #expect(try target.wholeStore() == source.wholeStore())
    }

    /// §10.6's second property. `apply` already refuses to write for an empty
    /// plan; this asserts the CLI says so and exits 0, which is what a script
    /// re-running an import needs to see.
    @Test("importing the same file twice is a no-op the second time")
    func idempotent() throws {
        let source = try CLIHarness()
        try seed(source)
        let file = source.path("out.json")
        #expect(try source.run(["export", "--output", file.path]).code == 0)

        let target = try CLIHarness()
        #expect(try target.run(["import", "--file", file.path]).code == 0)
        let afterFirst = try target.wholeStore()

        let second = try target.run(["import", "--file", file.path])
        #expect(second.code == 0)
        #expect(second.stdout.contains("Nothing to import."))
        #expect(try target.wholeStore() == afterFirst)
    }

    /// D-108 put `ImportPreviewSummary` in `StenoKit` for this call site. The
    /// assertion is that the CLI prints *that* renderer's output, not that some
    /// counts appear — a second renderer here would be two descriptions of one
    /// plan, free to drift.
    @Test("the preview on stdout is ImportPreviewSummary's own text")
    func printsThePreview() throws {
        let source = try CLIHarness()
        try seed(source)
        let file = source.path("out.json")
        #expect(try source.run(["export", "--output", file.path]).code == 0)

        let target = try CLIHarness()
        let result = try target.run(["import", "--file", file.path])

        #expect(
            result.stdout.contains(
                ImportPreviewSummary.headline(filename: "out.json", mode: .merge)))
        #expect(result.stdout.contains("1 new task"))
        #expect(result.stdout.contains("1 new project"))
    }

    // MARK: - Refusals

    /// **The guard fires before the file is read.** The assertion that
    /// distinguishes this from any other failure is the *absence* of the read
    /// error: the path does not exist, so a run that got past the guard would
    /// say "Could not read" instead.
    @Test("import is refused while the app is running, before reading the file")
    func refusedWhileAppIsRunning() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let before = try harness.wholeStore()
        harness.appIsRunning = true

        let result = try harness.run(["import", "--file", harness.path("absent.json").path])
        #expect(result.code == 1)
        #expect(result.stderr.contains("Steno is running"))
        #expect(result.stderr.contains("Could not read") == false)
        #expect(try harness.wholeStore() == before)
    }

    /// The same run with the guard down reaches the file — which is what makes
    /// the test above falsifiable rather than a tautology about one boolean.
    @Test("with the app closed the same command reaches the file")
    func reachesTheFileWhenClosed() throws {
        let harness = try CLIHarness()
        try seed(harness)

        let result = try harness.run(["import", "--file", harness.path("absent.json").path])
        #expect(result.code == 1)
        #expect(result.stderr.contains("Could not read"))
        #expect(result.stderr.contains("Steno is running") == false)
    }

    @Test("a malformed file is refused and the store is untouched")
    func malformedFile() throws {
        let harness = try CLIHarness()
        try seed(harness)
        let before = try harness.wholeStore()
        let file = harness.path("broken.json")
        try Data("{ this is not json".utf8).write(to: file)

        let result = try harness.run(["import", "--file", file.path])
        #expect(result.code == 1)
        #expect(result.stderr.contains("isn't a readable Steno export"))
        #expect(try harness.wholeStore() == before)
    }

    /// A file cut in half is not "an unknown version", and `ImportReader` says
    /// so. The CLI's job is to print that sentence rather than invent one.
    @Test("a truncated export is refused with the reader's own message")
    func truncatedFile() throws {
        let source = try CLIHarness()
        try seed(source)
        let whole = source.path("out.json")
        #expect(try source.run(["export", "--output", whole.path]).code == 0)
        let bytes = try Data(contentsOf: whole)

        let target = try CLIHarness()
        let file = target.path("truncated.json")
        try bytes.prefix(bytes.count / 2).write(to: file)

        let result = try target.run(["import", "--file", file.path])
        #expect(result.code == 1)
        #expect(result.stderr.contains("isn't a readable Steno export"))
    }

    /// §10.2's mandatory version gate, reaching stderr as the same sentence the
    /// GUI banner shows.
    @Test("an unreadable schema version is refused")
    func unsupportedVersion() throws {
        let harness = try CLIHarness()
        let file = harness.path("future.json")
        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: file)

        let result = try harness.run(["import", "--file", file.path])
        #expect(result.code == 1)
        #expect(
            result.stderr
                == ImportError.unsupportedSchemaVersion(found: 99, supported: 1).message)
    }
}
