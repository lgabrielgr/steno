import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// `steno import --replace`: §10.1's break-glass path from the command line.
///
/// **There is no typed confirmation here, and that is the design.** M2.5-04 puts
/// interactive prompts out of scope; `--replace` typed in full on a command line
/// is itself the explicit gesture §10.1 asks for. What must survive the move to
/// the CLI is the *backup*, which `ImportService.apply` enforces by refusing a
/// `.replace` plan without a writer (D-110) — so these tests assert the file
/// exists and describes the store that was wiped, not merely that the command
/// exited 0.
@Suite @MainActor struct CLIReplaceTests {
    /// One project, one task, one event — with a distinct title per harness so
    /// "the file won" is visible rather than inferred.
    @discardableResult
    private func seed(_ harness: CLIHarness, title: String, project: String) throws -> TaskItem {
        let item = Project(
            id: UUID(), name: project, colorHex: "#112233", modifiedAt: CLIHarness.now)
        harness.context.insert(item)
        let task = TaskItem(
            id: UUID(), title: title, projectID: item.id,
            createdAt: CLIHarness.now.addingTimeInterval(10))
        harness.context.insert(task)
        harness.context.insert(
            Event(
                id: UUID(), taskID: task.id, timestamp: CLIHarness.now.addingTimeInterval(10),
                kind: .created, body: "task created"))
        try harness.context.save()
        return task
    }

    private func exportFile(from harness: CLIHarness) throws -> URL {
        let file = harness.path("out.json")
        #expect(try harness.run(["export", "--output", file.path]).code == 0)
        return file
    }

    @Test("--replace installs the file and removes what it lacks")
    func replacesTheStore() throws {
        let source = try CLIHarness()
        try seed(source, title: "From the other Mac", project: "Billing")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        try seed(target, title: "Only on this Mac", project: "Payments")

        let result = try target.run(["import", "--file", file.path, "--replace"])
        #expect(result.code == 0)

        let after = try target.wholeStore()
        #expect(after.tasks.map(\.title) == ["From the other Mac"])
        #expect(after.projects.map(\.name) == ["Billing"])
    }

    /// §10.1 calls the backup mandatory. The assertion is not that a file
    /// appeared but that it is a readable export **of the store that was about
    /// to be wiped** — a backup describing the post-replace state would be
    /// worthless in exactly the situation it exists for.
    @Test("--replace writes a backup of the pre-replace store")
    func writesABackup() throws {
        let source = try CLIHarness()
        try seed(source, title: "From the other Mac", project: "Billing")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        try seed(target, title: "Only on this Mac", project: "Payments")

        let result = try target.run(["import", "--file", file.path, "--replace"])
        #expect(result.code == 0)

        let backupName = BackupWriter.filename(for: CLIHarness.now)
        let backup = target.backupDirectory.appendingPathComponent(backupName)
        #expect(result.stdout.contains(backup.path))

        let document = try ImportReader.read(Data(contentsOf: backup))
        #expect(document.tasks.map(\.title) == ["Only on this Mac"])
        // `includesCachedExternalData: true` is not optional for a backup —
        // a snapshot that drops the cached fields is not one anybody can
        // restore from, and §10.1's "nil loses to any value" would hand them
        // away on the way back in.
        #expect(document.includesCachedExternalData)
    }

    /// The acceptance criterion is that Replace "fails safe if that backup
    /// cannot be written". A throw from the writer must leave the store whole.
    @Test("a backup that cannot be written stops the replace")
    func failsSafeWhenTheBackupFails() throws {
        let source = try CLIHarness()
        try seed(source, title: "From the other Mac", project: "Billing")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        try seed(target, title: "Only on this Mac", project: "Payments")
        let before = try target.wholeStore()
        target.backupWrite = { _, _ in throw CocoaError(.fileWriteNoPermission) }

        let result = try target.run(["import", "--file", file.path, "--replace"])
        #expect(result.code == 1)
        #expect(result.stderr.contains("could not write a backup"))
        #expect(try target.wholeStore() == before)
    }

    /// **Merge must never delete.** The same two stores, without `--replace`,
    /// keep both tasks — which is what makes the replace assertion above a
    /// statement about the mode rather than about the fixture.
    @Test("the same file merged keeps what the file lacks")
    func mergeKeepsLocalRecords() throws {
        let source = try CLIHarness()
        try seed(source, title: "From the other Mac", project: "Billing")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        try seed(target, title: "Only on this Mac", project: "Payments")

        let result = try target.run(["import", "--file", file.path])
        #expect(result.code == 0)

        let after = try target.wholeStore()
        #expect(after.tasks.count == 2)
        #expect(after.projects.count == 2)
    }

    /// **A damaged store is the situation Replace exists for, and it used to
    /// no-op there.**
    ///
    /// `id` carries no `@Attribute(.unique)`, so a store can hold two physical
    /// rows under one id, and `.replace` is the one mode that reaches `plan`
    /// without `StoreMerge.validateShape` refusing such a store first (D-106).
    /// For a duplicated row whose id *is* in the file with identical content,
    /// every id-level signal reads empty — `writes`, `deletions`, and
    /// `deletedRows`, which counts doomed ids and so cannot see it either — and
    /// the whole operation returned success having installed nothing. Raised in
    /// review of PR #31.
    @Test("--replace collapses a duplicated row the file describes once")
    func replaceCollapsesDuplicateRows() throws {
        let source = try CLIHarness()
        try seed(source, title: "Shared", project: "Payments")
        let file = try exportFile(from: source)

        // **The target must be identical to the file apart from the duplicate.**
        // Seeding it independently would give it rows the file lacks, which land
        // in `deletions` — and a non-empty `deletions` makes the plan non-empty
        // for a reason that has nothing to do with the defect. Importing the
        // file first is what produces a store where every id already agrees.
        let target = try CLIHarness()
        #expect(try target.run(["import", "--file", file.path]).code == 0)
        let installed = try #require(
            try target.context.fetch(FetchDescriptor<TaskItem>()).first)

        // A second physical row under the id the file already carries. Inserted
        // directly: no service in this app can produce one, which is precisely
        // why only a damaged store reaches this path.
        target.context.insert(
            TaskItem(
                id: installed.id, title: installed.title, projectID: installed.projectID,
                createdAt: installed.createdAt))
        try target.context.save()
        #expect(try target.context.fetch(FetchDescriptor<TaskItem>()).count == 2)

        let result = try target.run(["import", "--file", file.path, "--replace"])

        #expect(result.code == 0)
        #expect(result.stdout.contains("Nothing to import.") == false)
        #expect(try target.context.fetch(FetchDescriptor<TaskItem>()).count == 1)
        // **The preview has to say the row goes away.** Letting Replace proceed
        // was only half of it: the extra row is not doomed and is not a write, so
        // §10.4's summary said only "= 1 task already present, kept as the file
        // has it" while `apply` deleted a physical row. A destructive preview
        // that under-reports destruction is the one kind this product must not
        // ship. Raised in the second review round of PR #31.
        #expect(result.stdout.contains("1 task will be deleted"))
    }

    /// **A damaged store must not be wiped behind a backup nobody can
    /// restore.** Letting `.replace` proceed on duplicate ids created exactly
    /// that: `ExportEncoder` serializes every physical row, so the backup
    /// carries the duplicates and `ImportReader` refuses it on the way back in.
    /// Raised in review of PR #31, as a consequence of the fix two rounds
    /// earlier.
    @Test("a Replace whose backup will not import says so, and still proceeds")
    func warnsWhenTheBackupWouldNotRestore() throws {
        let source = try CLIHarness()
        try seed(source, title: "Shared", project: "Payments")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        #expect(try target.run(["import", "--file", file.path]).code == 0)
        let installed = try #require(
            try target.context.fetch(FetchDescriptor<TaskItem>()).first)
        target.context.insert(
            TaskItem(
                id: installed.id, title: "a different title under the same id",
                projectID: installed.projectID, createdAt: installed.createdAt))
        try target.context.save()
        let before = try target.context.fetch(FetchDescriptor<TaskItem>()).count
        #expect(before == 2)

        let result = try target.run(["import", "--file", file.path, "--replace"])

        // **Proceeds.** Refusing here was tried and reverted: it would make
        // Replace permanently unable to repair a duplicated store, which is the
        // recovery D-106 keeps available on purpose.
        #expect(result.code == 0)
        #expect(try target.context.fetch(FetchDescriptor<TaskItem>()).count == 1)

        // **And says so, on stderr, on a run that exited 0.** The user's way
        // back is impaired; silence would let them believe otherwise.
        // **The wording must match what happened.** It said "nothing was
        // replaced" while everything had been — the message described a refusal
        // that was implemented and then reverted. Raised in review of PR #31.
        #expect(result.stderr.contains("Your data was replaced"))
        #expect(result.stderr.contains("nothing was replaced") == false)
        #expect(result.stderr.contains("share the id"))

        // The backup exists and holds the pre-wipe rows — it is the user's
        // data, needing one hand edit before `ImportReader` will take it, which
        // is the property §10.2 chose JSON for.
        let backup = target.backupDirectory
            .appendingPathComponent(BackupWriter.filename(for: CLIHarness.now))
        let bytes = try Data(contentsOf: backup)
        #expect(
            String(bytes: bytes, encoding: .utf8)?
                .contains("a different title under the same id") == true)
        #expect(throws: ImportError.self) { try ImportReader.read(bytes) }
    }

    /// **An orphan is as unrestorable as a duplicate, and `ImportReader` alone
    /// cannot see it.** That reader deliberately skips referential closure — a
    /// hand-trimmed file may rely on parents already on the target Mac — so a
    /// store with a task whose project is missing produced no warning, and the
    /// backup was still refused by `ImportService.plan` with
    /// `danglingReference`, after Replace had wiped the original. Raised in
    /// review of PR #31.
    @Test("a backup with an orphaned row is named too, not just a duplicated id")
    func warnsWhenTheBackupHasAnOrphan() throws {
        let source = try CLIHarness()
        try seed(source, title: "Shared", project: "Payments")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        #expect(try target.run(["import", "--file", file.path]).code == 0)
        // A task pointing at a project that is not in the store.
        target.context.insert(
            TaskItem(
                id: UUID(), title: "orphan", projectID: UUID(),
                createdAt: CLIHarness.now.addingTimeInterval(20)))
        try target.context.save()

        let result = try target.run(["import", "--file", file.path, "--replace"])

        #expect(result.code == 0)
        #expect(result.stderr.contains("Your data was replaced"))
        #expect(result.stderr.contains("cannot be imported as it stands"))
    }

    /// The preview names the destruction before it happens, on stdout, in the
    /// same words the sheet uses.
    @Test("the replace preview says what will be deleted")
    func previewNamesTheDeletions() throws {
        let source = try CLIHarness()
        try seed(source, title: "From the other Mac", project: "Billing")
        let file = try exportFile(from: source)

        let target = try CLIHarness()
        try seed(target, title: "Only on this Mac", project: "Payments")

        let result = try target.run(["import", "--file", file.path, "--replace"])
        #expect(
            result.stdout.contains(
                ImportPreviewSummary.headline(filename: "out.json", mode: .replace)))
        #expect(result.stdout.contains("will be deleted"))
    }
}
