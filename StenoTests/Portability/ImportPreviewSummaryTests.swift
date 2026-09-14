import Foundation
import Testing

@testable import StenoKit

/// §10.4's preview text, line by line.
///
/// Golden tests in the style of `RawReportGoldenTests`: the requirement quotes
/// an exact shape, and a renderer is the kind of code that drifts from its
/// specification silently because nothing breaks when it does.

@Test("the merge preview renders §10.4's example shape")
func mergePreviewMatchesTheRequirementsExample() {
    let plan = PlanFixture.plan(
        mode: .merge,
        projects: PlanFixture.counts(inserted: 3),
        tasks: PlanFixture.counts(inserted: 12, updated: 4, unchanged: 40),
        events: PlanFixture.counts(inserted: 148, unchanged: 21),
        statusChanged: [UUID()])

    #expect(
        ImportPreviewSummary.lines(for: plan) == [
            "+ 12 new tasks, 3 new projects, 148 new events",
            "~ 4 tasks updated (status changed on the other machine)",
            "= 61 records already present, skipped",
        ])
}

@Test("the headline names the file and the operation")
func headlinesDifferByMode() {
    #expect(
        ImportPreviewSummary.headline(filename: "steno-export-2026-08-10.json", mode: .merge)
            == "Import steno-export-2026-08-10.json?")
    // §10.1 wants Replace obviously different from the everyday action at the
    // moment of decision, not in a footnote below it.
    #expect(
        ImportPreviewSummary.headline(filename: "steno-export-2026-08-10.json", mode: .replace)
            == "Replace everything on this Mac with steno-export-2026-08-10.json?")
}

@Test("a type with nothing to report is left out of the line")
func zeroCountTypesAreOmitted() {
    let plan = PlanFixture.plan(tasks: PlanFixture.counts(inserted: 2))
    #expect(ImportPreviewSummary.lines(for: plan) == ["+ 2 new tasks"])
}

@Test("a line with nothing to say is left out entirely")
func emptyCategoriesProduceNoLine() {
    let plan = PlanFixture.plan(tasks: PlanFixture.counts(unchanged: 5))
    // No `+` line and no `~` line — not "+ 0 new tasks".
    #expect(ImportPreviewSummary.lines(for: plan) == ["= 5 records already present, skipped"])
}

@Test("the status parenthetical appears only when a status actually changed")
func theStatusParentheticalIsNotAnInference() {
    let withStatus = PlanFixture.plan(
        tasks: PlanFixture.counts(updated: 1), statusChanged: [UUID()])
    #expect(
        ImportPreviewSummary.lines(for: withStatus) == [
            "~ 1 task updated (status changed on the other machine)"
        ])

    // A task can be updated because its *title* changed on the other machine.
    // Claiming a status change there would be a false statement about the
    // user's own data, in the one place they are relying on the description.
    let withoutStatus = PlanFixture.plan(tasks: PlanFixture.counts(updated: 1))
    #expect(ImportPreviewSummary.lines(for: withoutStatus) == ["~ 1 task updated"])
}

@Test("the replace preview leads with what will be deleted")
func replaceLeadsWithDeletions() {
    let plan = PlanFixture.plan(
        mode: .replace,
        projects: PlanFixture.counts(inserted: 3),
        tasks: PlanFixture.counts(inserted: 12, unchanged: 61),
        deletions: PlanFixture.writes(projects: 2, tasks: 74, events: 902))

    let lines = ImportPreviewSummary.lines(for: plan)
    // Deletions first: it is the consequence the user most needs to weigh, and
    // burying it under the additions is the same mistake as a default-focused
    // destructive button.
    #expect(lines.first == "− 74 tasks, 2 projects, 902 events will be deleted")
    // And the fate of an already-present record differs by mode — a merge
    // leaves it alone, a replace has decided the file's copy is the truth.
    #expect(lines.last == "= 61 records already present, kept as the file has them")
}

@Test("one of something is not one of somethings")
func singularsAreSingular() {
    let plan = PlanFixture.plan(
        mode: .replace,
        tasks: PlanFixture.counts(inserted: 1, unchanged: 1),
        sourceRefs: PlanFixture.counts(updated: 1),
        deletions: PlanFixture.writes(reports: 1))

    #expect(
        ImportPreviewSummary.lines(for: plan) == [
            "− 1 report will be deleted",
            "+ 1 new task",
            "~ 1 reference updated",
            "= 1 record already present, kept as the file has them",
        ])
}

@Test("the provenance line says when the file was written and by what")
func provenanceNamesTheFilesOrigin() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let origin = PlanFixture.origin(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        exportedBy: "steno/0.1.0 (macOS)")

    let line = ImportPreviewSummary.provenance(
        origin, locale: Locale(identifier: "en_US_POSIX"), timeZone: utc)

    // The line that catches importing last month's export, which no count can:
    // twelve new tasks looks identical whichever file produced them.
    //
    // **`\u{202F}` before "PM", not a space.** Foundation emits a narrow
    // no-break space there, and the literal with an ordinary space fails a
    // comparison whose two sides look identical in the failure message —
    // which is exactly how this was found.
    #expect(line == "Written Nov 14, 2023 at 10:13\u{202F}PM by steno/0.1.0 (macOS)")
}

@Test("a file carrying cached summaries says so")
func provenanceNamesCachedData() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let origin = PlanFixture.origin(includesCachedExternalData: true)
    let line = ImportPreviewSummary.provenance(
        origin, locale: Locale(identifier: "en_US_POSIX"), timeZone: utc)
    #expect(line.hasSuffix(", cached summaries included"))
}
