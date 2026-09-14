import Foundation

/// §10.4's preview, as text.
///
/// **A pure function of an `ImportPlan`, in `StenoKit` rather than in the
/// sheet.** Two reasons. The headless bundle can reach it, so the lines the
/// user actually reads are golden-tested (D-010) rather than assumed from a
/// view nobody can run. And M2.5-04's CLI has to print the same preview to
/// stdout — a second renderer there would be two descriptions of one plan,
/// free to drift in exactly the direction the acceptance criterion forbids.
///
/// The counts come from the plan and are never recomputed here. "The preview's
/// counts match what the import actually does" is a property of
/// `ImportPlan.diff` producing them in the same walk that produces the write
/// set; this file's only job is to put them in a sentence.
public enum ImportPreviewSummary {
    /// §10.4's first line: what is about to happen, to which file.
    public static func headline(filename: String, mode: ImportMode) -> String {
        switch mode {
        case .merge:
            "Import \(filename)?"
        case .replace:
            // Names the destruction in the question itself, not in a footnote.
            // §10.1 wants the break-glass operation to be obviously different
            // from the everyday one at the moment of decision.
            "Replace everything on this Mac with \(filename)?"
        }
    }

    /// Where the file came from — the line that catches importing last month's
    /// export, which no count can.
    public static func provenance(
        _ origin: ImportPlan.Origin,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let when = origin.exportedAt.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .shortened, locale: locale,
                timeZone: timeZone))
        let cached = origin.includesCachedExternalData ? ", cached summaries included" : ""
        return "Written \(when) by \(origin.exportedBy)\(cached)"
    }

    /// §10.4's body: the `−`, `+`, `~` and `=` lines, in that order, with
    /// every line that would say "nothing" omitted.
    ///
    /// Deletions first in `.replace`: it is the consequence the user most needs
    /// to weigh, and burying it under the additions would be the same mistake
    /// as a default-focused destructive button.
    public static func lines(for plan: ImportPlan) -> [String] {
        var lines: [String] = []
        if let removed = removedLine(plan) { lines.append(removed) }
        if let added = addedLine(plan) { lines.append(added) }
        if let updated = updatedLine(plan) { lines.append(updated) }
        if let kept = unchangedLine(plan) { lines.append(kept) }
        return lines
    }

    private static func removedLine(_ plan: ImportPlan) -> String? {
        let parts = phrases(plan, value: \.deleted)
        guard !parts.isEmpty else { return nil }
        return "− \(parts.joined(separator: ", ")) will be deleted"
    }

    private static func addedLine(_ plan: ImportPlan) -> String? {
        // "12 new tasks", not "12 tasks new": §10.4's example puts the adjective
        // before the noun, and this line is quoted in the requirement.
        let parts = phrases(plan, value: \.counts.inserted, prefix: "new ")
        guard !parts.isEmpty else { return nil }
        return "+ \(parts.joined(separator: ", "))"
    }

    private static func updatedLine(_ plan: ImportPlan) -> String? {
        let parts = phrases(plan, value: \.counts.updated)
        guard !parts.isEmpty else { return nil }
        // §10.4's parenthetical, and it renders only when the plan actually has
        // a status change to point at — it is `plan.statusChanged`, not an
        // inference from the fact that some task was updated. A task can be
        // updated because its title changed on the other machine, and claiming
        // a status change there would be a false statement about the user's own
        // data.
        let why = plan.statusChanged.isEmpty ? "" : " (status changed on the other machine)"
        return "~ \(parts.joined(separator: ", ")) updated\(why)"
    }

    private static func unchangedLine(_ plan: ImportPlan) -> String? {
        let total = categories(plan).reduce(0) { $0 + $1.counts.unchanged }
        guard total > 0 else { return nil }
        let noun = total == 1 ? "record" : "records"
        // The two modes do different things to a record that is already
        // present, and the line says which. A merge leaves it alone; a replace
        // has decided the file's copy is the truth and happens to agree.
        let fate = plan.mode == .replace ? "kept as the file has them" : "skipped"
        return "= \(total) \(noun) already present, \(fate)"
    }

    /// One record type's counts and the words for it.
    ///
    /// A named type rather than a three-member tuple, which SwiftLint's
    /// `large_tuple` rejects under `--strict`.
    private struct Category {
        let counts: ImportPlan.Counts
        let deleted: Int
        let singular: String
        let plural: String

        /// "3 projects", "1 project" — or `nil` when there is nothing to say.
        func phrase(_ number: Int, prefix: String = "") -> String? {
            guard number > 0 else { return nil }
            return "\(number) \(prefix)\(number == 1 ? singular : plural)"
        }
    }

    /// §10.4's example order — tasks, projects, events — then the two types it
    /// does not happen to mention.
    private static func categories(_ plan: ImportPlan) -> [Category] {
        [
            Category(
                counts: plan.tasks, deleted: plan.deletions.tasks.count,
                singular: "task", plural: "tasks"),
            Category(
                counts: plan.projects, deleted: plan.deletions.projects.count,
                singular: "project", plural: "projects"),
            Category(
                counts: plan.events, deleted: plan.deletions.events.count,
                singular: "event", plural: "events"),
            Category(
                counts: plan.sourceRefs, deleted: plan.deletions.sourceRefs.count,
                singular: "reference", plural: "references"),
            Category(
                counts: plan.reports, deleted: plan.deletions.reports.count,
                singular: "report", plural: "reports"),
        ]
    }

    private static func phrases(
        _ plan: ImportPlan, value: (Category) -> Int, prefix: String = ""
    ) -> [String] {
        categories(plan).compactMap { $0.phrase(value($0), prefix: prefix) }
    }
}
