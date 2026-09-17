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
        try seed(target)
        let before = try target.wholeStore()
        // Not a comparison of two empty stores: that would hold no matter what
        // the import did, which is the shape of an assertion that cannot fail.
        #expect(before.tasks.count == 1)
        let file = target.path("truncated.json")
        try bytes.prefix(bytes.count / 2).write(to: file)

        let result = try target.run(["import", "--file", file.path])
        #expect(result.code == 1)
        #expect(result.stderr.contains("isn't a readable Steno export"))
        // **The store, not just the message.** Asserting only the refusal would
        // pass even if the command had partly mutated the store before
        // rejecting the file, which is precisely what §10.6 forbids — and it is
        // the assertion `malformedFile` already makes. Raised in review of
        // PR #31.
        #expect(try target.wholeStore() == before)
    }

    /// **Two CLI writers cannot interleave.** `CLIInstanceCheck` only sees the
    /// GUI — a terminal-launched `steno import` never creates `NSApplication`,
    /// so two of them pass that guard together, both plan against the same
    /// snapshot, both pass `ImportService`'s compare-then-write staleness check,
    /// and both save. Raised in review of PR #31.
    ///
    /// `flock` lives on the open file description, so a second acquisition
    /// fails from within this process exactly as it would from another one —
    /// which is what makes this testable without spawning anything.
    @Test("a second CLI writer is refused while the first holds the lock")
    func writeLockRefusesASecondWriter() throws {
        let harness = try CLIHarness(fileBacked: true)
        try seed(harness)
        let before = try harness.wholeStore()
        let file = harness.path("in.json")
        #expect(try harness.run(["export", "--output", file.path]).code == 0)
        let store = try #require(harness.storeURL)

        try whileLocked(store) {
            let result = try harness.run(["import", "--file", file.path])
            #expect(result.code == 1)
            #expect(result.stderr == CLIWriteLock.busyMessage)
            #expect(try harness.wholeStore() == before)
        }

        // **Released with the scope, and this half is what makes the other half
        // falsifiable.** Without it the assertions above would pass just as well
        // against a lock that never opens for anyone.
        let second = try harness.run(["import", "--file", file.path])
        #expect(second.code == 0)
        #expect(second.stderr.isEmpty)
    }

    /// Runs `body` with the CLI write lock held by this test.
    ///
    /// The lock releases in `deinit`, so "release it" has to be a scope
    /// boundary rather than a call — hence a function rather than two statements
    /// in the test. `withExtendedLifetime` stops the optimiser from dropping it
    /// early, which would make the refusal above depend on timing.
    private func whileLocked(_ store: URL, _ body: () throws -> Void) throws {
        let held = try #require(CLIWriteLock(besideStoreAt: store))
        try body()
        withExtendedLifetime(held) {}
    }

    /// **The check that matters is the last one.** Steno can be launched after
    /// `CLIEntry`'s check and after `importFile`'s, and a GUI holding rows from
    /// before the import would then save them back over it. Asking again
    /// immediately before the transaction narrows the window to the write
    /// itself — it does not close it, and D-118 says so. Raised in review of
    /// PR #31.
    @Test("an app launched mid-import is caught before the transaction")
    func appLaunchedBetweenPlanAndApply() throws {
        let source = try CLIHarness()
        try seed(source)
        let file = source.path("out.json")
        #expect(try source.run(["export", "--output", file.path]).code == 0)

        let target = try CLIHarness()
        let before = try target.wholeStore()
        // Not running when the command starts; running by the time it would
        // write. One boolean cannot express that, which is why the harness
        // scripts the answers.
        target.appIsRunningAnswers = [false, true]

        let result = try target.run(["import", "--file", file.path])

        #expect(result.code == 1)
        #expect(result.stderr == CLIInstanceCheck.refusalMessage)
        #expect(try target.wholeStore() == before)
    }

    /// **Two spellings of one store must take one lock.** The lock path was
    /// derived from the store path as written, so `/tmp/x/Steno.store` and its
    /// resolved `/private/tmp/x/Steno.store` — the same file, since `/tmp` is a
    /// symlink on macOS — locked different files and both ran. Raised in review
    /// of PR #31.
    @Test("a store reached by two spellings takes one lock")
    func lockPathIsCanonical() throws {
        let harness = try CLIHarness(fileBacked: true)
        let store = try #require(harness.storeURL)

        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-lock-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: store.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: alias) }
        let through = alias.appendingPathComponent(store.lastPathComponent)
        #expect(through.path != store.path)

        #expect(
            CLIWriteLock.url(besideStoreAt: through)
                == CLIWriteLock.url(besideStoreAt: store))

        // And the lock actually excludes across the two spellings, which is the
        // property the path equality above only implies.
        let held = try #require(CLIWriteLock(besideStoreAt: store))
        #expect(CLIWriteLock(besideStoreAt: through) == nil)
        withExtendedLifetime(held) {}
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
