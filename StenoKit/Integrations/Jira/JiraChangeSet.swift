import Foundation

/// The wire, turned into what §3.3 records and §5.2 caches.
///
/// **Pure: no network, no store, no clock.** This is where every judgment about
/// what counts as news lives, which is what makes the watermark and the window
/// boundaries table tests rather than fixture exercises.
struct JiraChangeSet: Equatable {
    /// §5.2's cached last-known state — the baseline a later fetch is described
    /// against, and what the app shows when it says the data is stale.
    let summary: String

    /// Everything inside the window, already prose, each with a stable id.
    /// `SourceRefreshService` drops the ones the log has seen (D-186).
    let changes: [SourceChange]

    /// The complete current link set (D-187).
    let present: [SourceChange]

    /// The newest item timestamp observed, whether or not it was reported (D-188).
    let watermark: Date?

    /// Assemble one fetch's answer.
    ///
    /// - Parameter since: `nil` means "no anchor yet" — the client then reads only the
    ///   newest page of each stream (D-196), so what arrives here is bounded.
    ///
    /// **Everything inside the window is returned, including on a first observation**,
    /// and `SourceRefreshService` decides what to *report* (D-188). That division took
    /// a test to find: suppressing changes here as well left the ids of the items a
    /// first observation saw unrecorded, so the next pass — whose window deliberately
    /// overlaps by fifteen minutes (D-185) — found them again and reported them as
    /// news. A connector says what it saw; the service says what is new.
    static func make(
        issue: JiraIssue,
        history: [JiraChangelogEntry],
        comments: [JiraComment],
        links: [JiraRemoteLink],
        since: Date?
    ) -> JiraChangeSet {
        let watermark = self.watermark(history: history, comments: comments)

        // `.distantPast` for a first observation: every item the client chose to fetch
        // is inside the window, and the service is what keeps them out of the event
        // body. A `nil` here would mean "report nothing", which is the bug above.
        let window = since ?? .distantPast
        let changes =
            transitions(in: history, since: window) + commentChanges(in: comments, since: window)

        return JiraChangeSet(
            summary: summary(of: issue),
            changes: changes,
            present: linkChanges(in: links),
            watermark: watermark)
    }

    // MARK: - Summary

    /// "Add the migration plan — In Review · assigned to Leo".
    ///
    /// **No timestamp in it.** The age of this data is the staleness banner's job
    /// (D-176), and baking "updated 2h ago" into a stored string would make the
    /// cache wrong the moment it was written. Parts that are missing are omitted
    /// rather than rendered as "unknown": §5.2 wants last-known state, and a state
    /// full of the word unknown is worse than a shorter sentence.
    private static func summary(of issue: JiraIssue) -> String {
        let title = issue.fields?.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        var state: [String] = []
        if let status = issue.fields?.status?.name, !status.isEmpty { state.append(status) }
        if let assignee = issue.fields?.assignee?.displayName, !assignee.isEmpty {
            state.append("assigned to \(assignee)")
        } else {
            state.append("unassigned")
        }

        let stateText = state.joined(separator: " · ")
        guard let title, !title.isEmpty else { return stateText }
        return "\(title) — \(stateText)"
    }

    // MARK: - Changelog

    /// Status and assignee changes inside the window (§5.2).
    ///
    /// Everything else in a changelog — description edits, labels, sprint churn — is
    /// dropped: §5.2 names two fields, and a stand-up that recited every field edit
    /// would bury the two that matter.
    private static func transitions(
        in history: [JiraChangelogEntry], since: Date
    ) -> [SourceChange] {
        history.flatMap { entry -> [SourceChange] in
            let created = JiraDate.parse(entry.created)

            // **An unparseable timestamp is reported, not dropped.** It cannot be
            // placed in the window, and the safe direction is to say it: the id-based
            // dedup stops it being said twice, while dropping it would lose a real
            // transition to a date-format change.
            if let created, created < since { return [] }

            guard let id = entry.id else { return [] }
            return (entry.items ?? []).compactMap { item in
                guard let text = text(for: item) else { return nil }
                // **The entry id alone is not unique.** Jira batches a status change
                // and an assignee change made together into one changelog entry with
                // two items, so the field has to be part of the key or the second
                // change is dropped as a duplicate of the first.
                let field = item.fieldId ?? item.field ?? "field"
                return SourceChange(id: "\(id)#\(field)", text: text)
            }
        }
    }

    /// "status: In Progress → In Review", or `nil` for a field this connector
    /// ignores.
    private static func text(for item: JiraChangeItem) -> String? {
        let field = (item.fieldId ?? item.field ?? "").lowercased()
        let previous = value(item.fromString)
        let current = value(item.toValue)

        switch field {
        case "status":
            return "status: \(previous) → \(current)"
        case "assignee":
            return "assignee: \(previous) → \(current)"
        default:
            return nil
        }
    }

    /// A changelog value, with Jira's several spellings of "nothing" collapsed.
    ///
    /// An unassigned ticket arrives as `nil`, and as `""` from some endpoints; both
    /// mean the same thing to a reader.
    private static func value(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unassigned" : trimmed
    }

    // MARK: - Comments

    /// New and edited comments inside the window (§5.2).
    private static func commentChanges(in comments: [JiraComment], since: Date) -> [SourceChange] {
        comments.compactMap { comment in
            // **The later of the two timestamps** (D-195). An edited comment moves
            // `updated` without moving `created`, and an edit is news: the text the
            // user will read out has changed.
            if let stamp = comment.stamp, stamp < since { return nil }

            guard let id = comment.id else { return nil }
            let author = comment.author?.displayName ?? "someone"
            let gist = AtlassianDocument.plainText(comment.body)
            let text = gist.isEmpty ? "comment from \(author)" : "comment from \(author): \(gist)"
            return SourceChange(id: id, text: text)
        }
    }

    // MARK: - Links

    /// The complete current link set, as state rather than as a delta (D-187).
    ///
    /// A link with neither an `id` nor a `globalId` is skipped: without a stable key
    /// it would be reported as new on every pass, which is worse than not reporting
    /// it at all.
    private static func linkChanges(in links: [JiraRemoteLink]) -> [SourceChange] {
        links.compactMap { link in
            guard let id = link.id.map(String.init) ?? link.globalId else { return nil }
            let title = link.object?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.object?.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label = [title, url].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
                return nil
            }
            return SourceChange(id: id, text: "linked \(label)")
        }
    }

    // MARK: - Watermark

    /// The newest timestamp Jira itself put on anything this fetch saw (D-184).
    ///
    /// **Over everything, not only over what is being reported.** The point of the
    /// watermark is that the next window starts where the source's data ends; taking
    /// it from the reported subset would move it backwards whenever a pass reported
    /// nothing, and re-report everything in between.
    private static func watermark(
        history: [JiraChangelogEntry], comments: [JiraComment]
    ) -> Date? {
        let historyDates = history.compactMap { JiraDate.parse($0.created) }
        let commentDates = comments.compactMap(\.stamp)
        return (historyDates + commentDates).max()
    }
}
