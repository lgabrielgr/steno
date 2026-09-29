import Foundation

/// The wire, turned into what §3.3 records and §5.3 caches.
///
/// **Pure: no network, no store, no clock.** This is where every judgment about what
/// counts as news lives, which is what makes the watermark and the window boundaries
/// table tests rather than fixture exercises.
struct ConfluenceChangeSet: Equatable {
    /// §5.3's cached last-known state — the baseline a later fetch is described
    /// against, and what the app shows when it says the data is stale.
    let summary: String

    /// One entry per version inside the window, already prose, each with a stable id
    /// (D-203). `SourceRefreshService` drops the ones the log has seen (D-186).
    let changes: [SourceChange]

    /// The newest version timestamp observed, whether or not it was reported (D-188) —
    /// or, when the walk was capped, the oldest point from which coverage is complete.
    let watermark: Date?

    /// Whether the version walk stopped at the page cap rather than at the end of the
    /// window. Carried to the payload because the watermark alone cannot say it
    /// (D-196's reasoning, and `ResumePoint` resolves several watermarks with `max`).
    let isWindowCapped: Bool

    /// The page's `_links.webui`, exactly as it arrived: relative, and rooted at the
    /// Confluence site rather than the Cloud host.
    ///
    /// **Raw rather than composed, because composing needs the credential** — the site
    /// this app is configured for — and this type is pure by construction. The
    /// connector joins the two, which is also the layer that knows to fall back on the
    /// ref's own URL.
    let webui: String?

    /// Assemble one fetch's answer.
    ///
    /// - Parameters:
    ///   - versions: everything the walk read, newest first, **unfiltered**. Filtering
    ///     here as well as in `SourceRefreshService` is the bug D-188 records: the ids
    ///     of what a first observation saw would go unrecorded, and the next pass —
    ///     whose window deliberately overlaps (D-185) — would find them again and call
    ///     them news. A connector says what it saw; the service says what is new.
    ///   - names: `authorId` → display name, for the ids that could be resolved
    ///     (D-201). An id that is missing here reads as "someone" rather than failing
    ///     the fetch.
    ///   - since: `nil` means "no anchor yet", which reports everything the client
    ///     chose to read and lets the service keep it out of the event body (D-188).
    ///   - isCapped: the walk stopped at the page cap. The watermark is then the oldest
    ///     point from which coverage *is* complete, so the gap stays inside the next
    ///     pass's window instead of being closed over.
    static func make(
        page: ConfluencePage,
        versions: [ConfluenceVersion],
        names: [String: String],
        since: Date?,
        isCapped: Bool = false
    ) -> ConfluenceChangeSet {
        let pageID = page.id ?? ""
        let window = since ?? .distantPast

        return ConfluenceChangeSet(
            summary: summary(of: page, names: names),
            changes: versionChanges(
                in: versions, pageID: pageID, names: names, since: window),
            watermark: watermark(page: page, versions: versions, isCapped: isCapped),
            isWindowCapped: isCapped,
            webui: page.links?.webui)
    }

    // MARK: - Summary

    /// "Payments Migration Plan — v9, edited by Leo Gutierrez".
    ///
    /// **No timestamp in it.** §5.3 asks for the last-modified timestamp and this
    /// carries it as the watermark; how old the *data* is belongs to the staleness
    /// banner (D-176), and baking "edited 2h ago" into a stored string would make the
    /// cache wrong the moment it was written.
    ///
    /// Parts that are missing are omitted rather than rendered as "unknown": §5.3 wants
    /// last-known state, and a state full of the word unknown is worse than a shorter
    /// sentence.
    private static func summary(of page: ConfluencePage, names: [String: String]) -> String {
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        var state: [String] = []
        if let number = page.version?.number { state.append("v\(number)") }
        if let editor = name(of: page.version?.authorId, in: names) {
            state.append("edited by \(editor)")
        }

        let stateText = state.joined(separator: ", ")
        guard let title, !title.isEmpty else { return stateText }
        guard !stateText.isEmpty else { return title }
        return "\(title) — \(stateText)"
    }

    // MARK: - Versions

    /// One `SourceChange` per version inside the window (§5.3's "version delta").
    ///
    /// A version with no `number` is skipped: without it there is no stable key, and an
    /// entry re-reported on every pass is worse than one not reported at all.
    private static func versionChanges(
        in versions: [ConfluenceVersion], pageID: String, names: [String: String], since: Date
    ) -> [SourceChange] {
        versions.compactMap { version in
            // **An unparseable timestamp is reported, not dropped.** It cannot be placed
            // in the window, and the safe direction is to say it: the id-based dedup
            // stops it being said twice, while dropping it would lose a real edit to a
            // date-format change.
            if let stamp = version.stamp, stamp < since { return nil }
            guard let number = version.number else { return nil }

            return SourceChange(
                id: "\(pageID)#v\(number)", text: text(for: version, number: number, names: names))
        }
    }

    /// "v7 by Leo Gutierrez: tightened the migration steps".
    ///
    /// The version message is included when the editor typed one, and nothing stands in
    /// for it when they did not — "v7 by Leo Gutierrez" is a complete sentence about a
    /// complete fact.
    private static func text(
        for version: ConfluenceVersion, number: Int, names: [String: String]
    ) -> String {
        // **"someone", not the account id.** A stand-up line reading `v7 by 557058:aa1b`
        // satisfies the letter of "last editor" and none of its purpose (D-201).
        let editor = name(of: version.authorId, in: names) ?? "someone"

        // **Minor edits are labelled, not dropped** (D-203). `minorEdit` is Confluence's
        // "don't notify watchers" checkbox: it says something about notification
        // preference, not about whether work happened, and a user who ticks it out of
        // habit would find their afternoon's editing invisible in the morning.
        let minor = version.minorEdit == true ? " (minor)" : ""

        // **Collapsed and bounded, by the same rule Jira's comment bodies get** (D-195,
        // via `AtlassianText`). A version message is free text from a box the editor
        // can type anything into, and this string becomes one line of a stand-up: a
        // newline in it silently becomes two lines, the second having lost its subject,
        // and an unbounded one turns the report into a paste of somebody's release
        // notes. Found by asking which inputs §5.3 implies that no test covered.
        let message = AtlassianText.gist(version.message ?? "")
        guard !message.isEmpty else { return "v\(number) by \(editor)\(minor)" }
        return "v\(number) by \(editor)\(minor): \(message)"
    }

    /// A display name for an account id, or `nil` when there is none to give.
    ///
    /// An id that resolved to an empty string is `nil` too: Confluence returns a blank
    /// `displayName` for a deactivated account, and "edited by " is not a sentence.
    private static func name(of accountID: String?, in names: [String: String]) -> String? {
        guard let accountID, let name = names[accountID] else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Watermark

    /// The newest timestamp Confluence itself put on anything this fetch saw (D-184).
    ///
    /// **Over everything, not only over what is being reported.** The point of the
    /// watermark is that the next window starts where the source's data ends; taking it
    /// from the reported subset would move it backwards whenever a pass reported
    /// nothing, and re-report everything in between.
    ///
    /// The page's own current version counts as an observation: it is a timestamp the
    /// source assigned to something it served, and on a page whose version list came
    /// back empty it is the only anchor available. Leaving it out would hold the window
    /// open at `nil` forever.
    private static func watermark(
        page: ConfluencePage, versions: [ConfluenceVersion], isCapped: Bool
    ) -> Date? {
        let walked = versions.compactMap(\.stamp)
        let newest = (walked + [page.version?.stamp].compactMap { $0 }).max()

        guard isCapped else { return newest }

        // **The floor, not the newest.** A capped walk read the *newest* page and missed
        // the oldest versions inside the window, so claiming the newest timestamp would
        // close over a gap the next pass — which starts from that timestamp — would
        // never look at again.
        //
        // Not `nil` either, which would hold the anchor exactly where it was and cover
        // the whole gap: after ten consecutive capped passes the previous watermark
        // falls out of `ResumePoint.scanDepth`'s scan and the anchor would be lost
        // altogether. A monotone floor cannot do that.
        //
        // **The floor comes from the walk alone**, deliberately excluding the page's
        // current version: that version is the newest thing there is, and letting it
        // into the floor would put the boundary above every version the cap left unread.
        guard let floor = walked.min(), let newest else { return nil }
        return min(floor, newest)
    }
}
