import Foundation

/// §7.3's returned structure, rendered into the sections M2-02 already emits.
///
/// **The same `[ReportSection]` the raw path produces, so both end at the same
/// `SlackMarkdown.render`.** §7.3: "The app renders markdown from whichever
/// structure came back. Never ask the model to format the final Slack text —
/// formatting is the app's job, and separating them makes output stable."
/// `ReportSection`'s own doc comment named this type before it existed: "M3-03
/// produces them from schema-validated AI bullets."
///
/// A stenographer, like `RawReportSections`, with one licence the raw path does
/// not have: it appends ticket keys (D-150). Everything else the model wrote
/// reaches the user unedited.
public enum DraftSections {
    /// Build the three sections this draft's cadence calls for.
    ///
    /// **Cadence comes from the draft's own case, not from the window.** The
    /// two agree by construction — the request carried the window's cadence —
    /// and reading it here means a mismatched pair cannot be assembled at all.
    public static func build(from draft: StandupDraft, window: GatheredWindow) -> [ReportSection] {
        let keys = ticketKeys(in: window)
        switch draft {
        case .daily(let daily):
            return [
                ReportSection(
                    title: ReportHeadings.sinceLastStandup,
                    bullets: bullets(daily.sinceLastStandup, keys: keys)),
                ReportSection(
                    title: ReportHeadings.today, bullets: bullets(daily.today, keys: keys)),
                ReportSection(
                    title: ReportHeadings.blockers, bullets: bullets(daily.blockers, keys: keys)),
            ]
        case .periodic(let periodic):
            return [
                ReportSection(
                    title: ReportHeadings.completed,
                    bullets: bullets(periodic.completed, keys: keys)
                ),
                ReportSection(
                    title: ReportHeadings.inFlight, bullets: bullets(periodic.inFlight, keys: keys)),
                ReportSection(
                    title: ReportHeadings.blockersAndRisks,
                    bullets: bullets(periodic.blockersAndRisks, keys: keys)),
            ]
        }
    }

    /// Each task's ticket keys, already sorted by the gatherer (D-065).
    ///
    /// `uniquingKeysWith` rather than `uniqueKeysWithValues`: the gatherer
    /// cannot return one task twice, and a trap on an invariant held elsewhere
    /// is a crash in a stand-up rather than a report.
    private static func ticketKeys(in window: GatheredWindow) -> [UUID: [String]] {
        Dictionary(
            window.tasks.map { ($0.id, $0.ticketKeys) },
            uniquingKeysWith: { first, _ in
                first
            })
    }

    private static func bullets(_ source: [DailyBullet], keys: [UUID: [String]]) -> [ReportBullet] {
        source.compactMap { bullet(text: $0.text, taskIDs: [$0.taskID], keys: keys) }
    }

    /// An overload rather than a protocol over the two bullet types: they carry
    /// their ids under different names and different cardinalities, which is
    /// §7.3's whole point about the two schemas not being cosmetic variants.
    private static func bullets(_ source: [ThemedBullet], keys: [UUID: [String]]) -> [ReportBullet]
    {
        source.compactMap { bullet(text: $0.text, taskIDs: $0.taskIDs, keys: keys) }
    }

    /// One bullet: the model's sentence, plus any ticket key it left out.
    ///
    /// **Blank bullets are dropped** (D-152). `StandupDraft.isEmpty` counts
    /// bullets rather than content, deliberately — its subject is a bullet's
    /// *identity*, not its text — so a model that answers with empty strings
    /// passes validation and would render as `• ` in Slack, or as `• (STENO-12)`
    /// once the keys below are appended.
    ///
    /// **Keys are re-attached rather than trusted** (D-150). A ticket key is a
    /// fact in the event log, on the task this bullet is about, and
    /// `RawReportSections` already emits it on the same bullet in the fallback
    /// path — so the AI path emitting less would be a regression, not restraint.
    /// The prompt still asks the model to preserve keys: this covers the case
    /// where it does not.
    ///
    /// **Presence is checked case-insensitively; the appended form is verbatim.**
    /// A model that wrote "landed steno-12 behind a flag" preserved the key
    /// badly but did preserve it, and appending a second copy would read worse
    /// than the imperfect original.
    ///
    /// `details` stays empty: an AI bullet is one line, which is what
    /// `ReportBullet.details`' default was added for.
    private static func bullet(
        text: String, taskIDs: [UUID], keys: [UUID: [String]]
    ) -> ReportBullet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let haystack = trimmed.lowercased()
        var missing: [String] = []
        for key in taskIDs.flatMap({ keys[$0] ?? [] })
        where !missing.contains(key) && !haystack.contains(key.lowercased()) {
            missing.append(key)
        }

        guard !missing.isEmpty else { return ReportBullet(text: trimmed) }
        return ReportBullet(text: trimmed + " (\(missing.joined(separator: ", ")))")
    }
}
