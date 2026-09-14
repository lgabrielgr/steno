import Foundation
import Testing

@testable import StenoKit

/// §10.4's preview state, and §10.1's typed confirmation.
///
/// GUI verification is unavailable here, so every decision the sheet appears to
/// make is made in this type instead — which is what lets it be asserted at all.

@MainActor
@Test("merge is ready to apply as soon as there is something to do")
func mergeIsReadyImmediately() {
    let preview = ImportPreviewModel()
    preview.begin(
        plan: PlanFixture.plan(tasks: PlanFixture.counts(inserted: 1)),
        filename: "steno-export-2026-08-10.json", mode: .merge)

    #expect(preview.canApply)
    #expect(preview.phase == .previewing)
}

@MainActor
@Test("replace refuses everything but the word, typed exactly")
func replaceDemandsTheExactWord() {
    let preview = ImportPreviewModel()
    preview.begin(
        plan: PlanFixture.plan(mode: .replace, tasks: PlanFixture.counts(inserted: 1)),
        filename: "steno-export-2026-08-10.json", mode: .replace)

    #expect(!preview.canApply)

    // Case matters, and so does whitespace. A comparison that forgave either
    // would accept what an impatient user types on the way past, which is the
    // entire population this guard exists for.
    for rejected in ["replace", "Replace", "REPLACE ", " REPLACE", "REPLAC", ""] {
        preview.confirmation = rejected
        #expect(!preview.canApply, "should refuse \"\(rejected)\"")
    }

    preview.confirmation = "REPLACE"
    #expect(preview.canApply)
}

@MainActor
@Test("an empty plan is never applicable, whatever is typed")
func anEmptyPlanIsNeverApplicable() {
    let preview = ImportPreviewModel()
    preview.begin(plan: PlanFixture.plan(mode: .replace), filename: "f.json", mode: .replace)

    // §10.6's idempotency, seen from the sheet: the second import of a file
    // lands here. A button that is live only to refuse is worse than one that
    // is not offered.
    #expect(preview.phase == .nothingToImport)
    preview.confirmation = "REPLACE"
    #expect(!preview.canApply)
}

@MainActor
@Test("a file with nothing new is named as such rather than shown as zeroes")
func nothingToImportIsItsOwnPhase() {
    let preview = ImportPreviewModel()
    preview.begin(
        plan: PlanFixture.plan(tasks: PlanFixture.counts(unchanged: 12)),
        filename: "f.json", mode: .merge)
    #expect(preview.phase == .nothingToImport)
    #expect(!preview.canApply)
}

@MainActor
@Test("dismissing clears the plan and the typed word")
func dismissClearsEverything() {
    let preview = ImportPreviewModel()
    preview.begin(
        plan: PlanFixture.plan(mode: .replace, tasks: PlanFixture.counts(inserted: 1)),
        filename: "steno-export-2026-08-10.json", mode: .replace,
        backupURL: URL(fileURLWithPath: "/tmp/backup.json"))
    preview.confirmation = "REPLACE"

    preview.dismiss()

    // The typed word especially: a confirmation surviving a dismissal would
    // mean the *next* Replace opens already confirmed.
    #expect(preview.confirmation.isEmpty)
    #expect(preview.plan == nil)
    #expect(preview.backupURL == nil)
    #expect(preview.mode == .merge)
    #expect(!preview.canApply)
}

@MainActor
@Test("beginning a second preview does not inherit the first one's confirmation")
func a2ndPreviewStartsUnconfirmed() {
    let preview = ImportPreviewModel()
    preview.begin(
        plan: PlanFixture.plan(mode: .replace, tasks: PlanFixture.counts(inserted: 1)),
        filename: "a.json", mode: .replace)
    preview.confirmation = "REPLACE"
    #expect(preview.canApply)

    // Without `begin` clearing it, cancelling one Replace and opening another
    // would present a live destructive button over a file the user has not yet
    // read a word about.
    preview.begin(
        plan: PlanFixture.plan(mode: .replace, tasks: PlanFixture.counts(inserted: 2)),
        filename: "b.json", mode: .replace)
    #expect(!preview.canApply)
}

@MainActor
@Test("a failure leaves the preview up and the success notice absent")
func failureAndSuccessAreDifferentProperties() {
    let preview = ImportPreviewModel()
    preview.begin(
        plan: PlanFixture.plan(tasks: PlanFixture.counts(inserted: 1)), filename: "f.json",
        mode: .merge)

    preview.failed("nope")
    #expect(preview.lastError == "nope")
    #expect(preview.notice == nil)

    preview.succeeded(backupURL: nil)
    #expect(preview.lastError == nil)
    #expect(preview.notice == "Imported.")
    // Applied once, and not again: the button goes away rather than offering to
    // import the same file a second time.
    #expect(!preview.canApply)
}

@MainActor
@Test("the replace notice names the backup so it can be found later")
func theReplaceNoticeNamesTheBackup() {
    let url = URL(fileURLWithPath: "/tmp/steno-backup-2026-09-14-142205.json")
    let notice = ImportPreviewModel.successNotice(mode: .replace, backupURL: url)

    // The user who realises in ten minutes that they restored the wrong
    // snapshot should not have to go looking for the folder.
    #expect(notice.contains(url.path))
}
