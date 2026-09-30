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

    /// The newest item timestamp observed, whether or not it was reported (D-188) — or, when a
    /// walk was capped, the oldest point from which coverage is complete.
    let watermark: Date?

    /// Whether a page walk stopped at the cap rather than at the end of the window.
    ///
    /// **Carried through to the payload, because the watermark alone cannot say it.**
    /// `ResumePoint` resolves several payloads' watermarks with `max` — deliberately, so a
    /// watermark written out of order cannot move the window backwards — and that discarded a
    /// deliberately lowered floor the moment the previous event was still in the scan. So the
    /// lowering has to be distinguishable from disorder, and this is the flag that does it.
    /// Raised by Copilot in review round 6 of PR #43.
    let isWindowCapped: Bool

    /// A stream whose walk stopped at the page cap rather than at the end of the window.
    ///
    /// **Why this has to reach the watermark.** The watermark means "everything above this
    /// has been reported". A capped walk reads the *newest* page and misses the oldest
    /// entries inside the window, so claiming the newest timestamp would close over a gap and
    /// the next pass — which starts from that timestamp — would never look at it again. The
    /// first attempt at this finding logged the cap and changed nothing, and a mutation of
    /// that log survived the suite, which is what showed the fix was in the wrong place.
    /// Raised by Copilot in review round 2 of PR #43.
    enum Stream: Sendable {
        case changelog
        case comments
    }

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
    ///
    /// - Parameter incomplete: streams whose walk hit the page cap. The watermark is then
    ///   the oldest point from which coverage *is* complete, so the fetch does not claim
    ///   coverage it did not achieve. **It does not fill itself** — the next pass walks from
    ///   the same end and stops in the same place, and reaching past the cap needs a
    ///   persisted cursor (D-208). The earlier wording here promised otherwise.
    static func make(
        issue: JiraIssue,
        history: [JiraChangelogEntry],
        comments: [JiraComment],
        links: [JiraRemoteLink],
        since: Date?,
        incomplete: Set<Stream> = []
    ) -> JiraChangeSet {
        let watermark = self.watermark(
            history: history, comments: comments, incomplete: incomplete)

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
            watermark: watermark,
            isWindowCapped: !incomplete.isEmpty)
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
            let created = AtlassianDate.parse(entry.created)

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
    ///
    /// **Known limitation, and it is the API's.** The endpoint orders by `created` and
    /// takes no filter on `updated`, so an edit to a comment created before the paged
    /// window is not detected — `JiraClient` stops paging once a page predates the
    /// window, and that edit sits on a later page. Detecting it would mean reading every
    /// comment on every pass. §5.2 asks for "new comments", so this is within the
    /// requirement; the boundary is stated here rather than implied, and
    /// `anEditOutsideThePagedWindowIsNotDetected` pins it. Raised by Copilot in review of
    /// PR #43.
    private static func commentChanges(in comments: [JiraComment], since: Date) -> [SourceChange] {
        comments.compactMap { comment in
            // **The later of the two timestamps** (D-195). An edited comment moves
            // `updated` without moving `created`, and an edit is news: the text the
            // user will read out has changed.
            if let stamp = comment.stamp, stamp < since { return nil }

            guard let id = comment.id else { return nil }
            let author = comment.author?.displayName ?? "someone"
            let gist = AtlassianDocument.plainText(comment.body)
            let isEdit = comment.updated != nil && comment.updated != comment.created
            let opening = isEdit ? "edited comment from \(author)" : "comment from \(author)"
            let text = gist.isEmpty ? opening : "\(opening): \(gist)"

            // **The id carries the revision, not just the comment** (Copilot, PR #43).
            // Jira keeps one id across edits, and `SourceRefreshService` de-duplicates on
            // it — so a bare comment id made every edit after the first observation into
            // silently dropped news, which is the opposite of what `stamp` was written to
            // do. The comment id stays the prefix, so the source identity is still legible
            // in a payload.
            //
            // **The revision is Jira's own timestamp string, not a number we derive from
            // it.** The first fix used `Int(timeIntervalSince1970)`, which truncates to
            // whole seconds — so two edits inside one second collided and the second was
            // dropped again, by the same dedup, for a new reason. Carrying the string keeps
            // whatever precision the source sent and cannot round. Raised by Copilot in
            // review round 2 of PR #43.
            let revision = comment.revision.map { "@\($0)" } ?? ""
            return SourceChange(id: "\(id)\(revision)", text: text)
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
        history: [JiraChangelogEntry], comments: [JiraComment], incomplete: Set<Stream>
    ) -> Date? {
        let historyDates = history.compactMap { AtlassianDate.parse($0.created) }
        let commentDates = comments.compactMap(\.stamp)

        guard !incomplete.isEmpty else { return (historyDates + commentDates).max() }

        // **The oldest floor, not the newest.** Each capped stream was read down to its own
        // floor, so the unreported region is the union of what lies below them — and the
        // smaller boundary is the one that keeps more of that union inside the next window.
        // Taking the newer boundary reads as "the point above which every stream is covered",
        // which is true and useless: it advances the window past the older stream's gap and
        // skips it permanently. Raised by Copilot in review round 3 of PR #43.
        //
        // Not `nil` either, which would hold the anchor exactly where it was and cover the
        // whole union: after ten consecutive capped passes the previous watermark falls out of
        // `ResumePoint.scanDepth`'s scan and the anchor would be lost altogether. A monotone
        // floor cannot do that.
        // **The comments floor is `created`, not `stamp`.** The endpoint traverses by `created`,
        // so coverage after a capped walk is "everything created at or after the oldest `created`
        // read" — and a recently edited old comment has a newer `stamp`, which would put the floor
        // above unread comments and skip them for good (Copilot, review round 6).
        let floors = [
            incomplete.contains(.changelog) ? historyDates.min() : nil,
            incomplete.contains(.comments) ? comments.compactMap(\.createdAt).min() : nil,
        ].compactMap { $0 }

        // Never above what was actually seen: a floor cannot exceed the newest item, and with
        // nothing read there is no anchor to report at all.
        guard let floor = floors.min(), let newest = (historyDates + commentDates).max() else {
            return nil
        }
        return min(floor, newest)
    }
}
