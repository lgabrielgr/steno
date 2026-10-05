import Foundation
import OSLog

/// The four reads, their paging, and their failures (§5.2, D-196).
///
/// **Every request goes through `ReadOnlyTransport`**, which this type wraps around
/// whatever it is handed, so D5 holds even if a future endpoint is added carelessly
/// (D-191).
///
/// **Cancellation-aware, as `SourceConnector` requires.** The transport is
/// `URLSession`-backed, which honours cancellation, and each paging loop checks
/// `Task.isCancelled` — without that, a ticket with a long changelog could hold the
/// whole pass past both the per-fetch deadline and the pass budget, which are
/// cooperative only. A cancelled walk **throws `.timedOut`** rather than returning what
/// it had managed to read (D-207).
struct JiraClient: Sendable {
    /// `PageBeanChangelog` serves 100 at a time happily, and a ticket's whole
    /// recent history usually fits one page.
    static let changelogPageSize = 100

    /// Comments are bigger documents — each carries an ADF body — so the page is
    /// smaller.
    static let commentPageSize = 50

    /// **A hard cap, because `total` can shift under a backwards walk** (D-196).
    ///
    /// **What hitting it costs, stated honestly.** The earlier comment here claimed the
    /// remainder "falls into the next pass's window", and that is false: the watermark
    /// advances to the newest entry read, so the next window starts in the same place and
    /// the entries beyond the cap are never reported. Raised by Copilot in review of
    /// PR #43.
    ///
    /// It is a bound on a shape that does not occur rather than a silent loss: reaching it
    /// needs more than a thousand changelog entries inside `ResumePoint.maxLookback`'s
    /// thirty days, on one ticket. Hitting it is logged at `error` — **without naming the
    /// ticket**, deliberately: these lines reach a crash log, and an issue key is the kind
    /// of identifier §8 keeps out of one, which is why `ReadOnlyTransport` withholds a URL
    /// too. The log says "for one ref", which is enough to know it happened.
    static let maxPages = 10

    private let transport: any HTTPTransport

    init(transport: any HTTPTransport) {
        self.transport = ReadOnlyTransport(wrapping: transport)
    }

    /// One ref's whole answer: issue, changelog, comments and links.
    ///
    /// **All four requests are required.** A failed link request could not be
    /// treated as "no links present" — that is a state set (D-187), so an empty one
    /// would make every existing PR reference look new on the next pass — and §5.5
    /// prefers one degraded ref over a false event. The four run concurrently, so
    /// the cost is one round trip rather than four.
    func changeSet(
        key: String, since: Date?, credential: AtlassianCredential
    ) async throws -> JiraChangeSet {
        guard let base = credential.baseURL else { throw SourceError.notConfigured }
        let authorization = credential.basicAuthorization

        async let issue = fetch(
            JiraIssue.self, from: .issue(key: key), base: base, authorization: authorization)
        async let history = history(
            key: key, since: since, base: base, authorization: authorization)
        async let comments = comments(
            key: key, since: since, base: base, authorization: authorization)
        async let links = fetch(
            [JiraRemoteLink].self, from: .remoteLinks(key: key), base: base,
            authorization: authorization)

        // **Awaited issue-first, and the order is a decision.** All four run concurrently, so
        // when several fail the one whose error escapes is whichever is awaited first — and
        // the issue read is the one whose failure describes the ref best. Reordering these
        // lines silently changes which `SourceError` the staleness banner shows, which is how
        // `the connector throws SourceError and nothing else` caught this being rearranged.
        let issueRead = try await issue
        let historyRead = try await history
        let commentsRead = try await comments
        let linksRead = try await links

        var incomplete: Set<JiraChangeSet.Stream> = []
        if historyRead.capped { incomplete.insert(.changelog) }
        if commentsRead.capped { incomplete.insert(.comments) }

        return JiraChangeSet.make(
            issue: issueRead,
            history: historyRead.entries,
            comments: commentsRead.comments,
            links: linksRead,
            since: since,
            incomplete: incomplete)
    }

    /// FR-6's connection test: the cheapest authenticated read Jira offers.
    ///
    /// `/myself` rather than an issue, because a test must distinguish a rejected
    /// credential from a ticket the account cannot see — and any issue key would
    /// confuse the two.
    func verify(credential: AtlassianCredential) async throws {
        guard let base = credential.baseURL else { throw SourceError.notConfigured }
        // **`.siteNotFound` for a 404 here, not `.notFound`** (D-217, revised).
        // `/rest/api/3/myself` answers 200 or 401 on a site that serves the Jira API,
        // so a 404 means this host is not serving it — a mistyped site, or a site
        // without Jira. Telling the user a *reference* does not exist would send them
        // looking for a ticket they never named.
        _ = try await fetch(
            JiraUser.self, from: .currentUser, base: base,
            authorization: credential.basicAuthorization, notFound: .siteNotFound)
    }

    // MARK: - Paging

    /// The changelog entries that could be inside the window.
    ///
    /// **Paged backwards from `total`** (D-196). The changelog is ascending and takes
    /// no date filter, so forward paging reads a three-year history to find
    /// yesterday's transition. One probe page establishes `total` and settles the
    /// common case — a ticket whose whole changelog fits one page, where `isLast` is
    /// true and the probe *is* the answer — and anything longer is walked from the
    /// newest end.
    private func history(
        key: String, since: Date?, base: URL, authorization: String
    ) async throws -> (entries: [JiraChangelogEntry], capped: Bool) {
        let probe = try await fetch(
            JiraChangelogPage.self,
            from: .changelog(key: key, startAt: 0, maxResults: Self.changelogPageSize),
            base: base, authorization: authorization)

        let total = probe.total ?? probe.values?.count ?? 0
        if probe.isLast == true || total <= Self.changelogPageSize {
            return (probe.values ?? [], false)
        }

        // The probe returned the *oldest* entries, which are outside any window this
        // ref could still care about, so they are discarded rather than merged: an
        // ancient entry whose timestamp failed to parse would otherwise be reported.
        var collected: [String: JiraChangelogEntry] = [:]
        var start = max(0, total - Self.changelogPageSize)
        var pages = 0
        var reachedWindowEnd = since == nil

        while pages < Self.maxPages {
            // **Cancellation fails the ref; it does not produce a short answer**
            // (D-207). `SourceRefreshService.fetchAll` discards a *failed* fetch once the
            // pass budget has expired and keeps a *successful* one — on the reasoning that
            // a fetch which beat the cancellation still carries data. A walk that broke out
            // here did not beat the cancellation, it answered one, so returning normally
            // would file a truncated delta as a complete fetch and append it to a log that
            // cannot be edited. Raised by Copilot in review of PR #44.
            //
            // `.timedOut` rather than a new case, because that is already what a
            // cancellation landing *inside* a request maps to
            // (`AtlassianErrors.error(forTransport:)`) — the same budget expiring must not
            // mean two different things depending on which microsecond it lands in.
            if Task.isCancelled { throw SourceError.timedOut }

            let page = try await fetch(
                JiraChangelogPage.self,
                from: .changelog(key: key, startAt: start, maxResults: Self.changelogPageSize),
                base: base, authorization: authorization)

            // Keyed by id, so a page boundary that moved because someone commented
            // mid-walk costs a duplicate read rather than a duplicate entry.
            for entry in page.values ?? [] {
                guard let id = entry.id else { continue }
                collected[id] = entry
            }
            pages += 1

            // No anchor yet: the newest page is all that is needed to establish one,
            // and no changes will be reported from it anyway (D-188).
            guard let since else { break }

            let oldest = (page.values ?? []).compactMap { AtlassianDate.parse($0.created) }.min()
            if let oldest, oldest < since {
                reachedWindowEnd = true
                break
            }
            if start == 0 {
                reachedWindowEnd = true
                break
            }
            start = max(0, start - Self.changelogPageSize)
        }

        if !reachedWindowEnd {
            // `error`, not `info`: this is a gap in what the user was told rather than a slow
            // pass — and the watermark is held back so the fetch does not claim coverage it
            // did not achieve. It does **not** make the gap reachable later: the next pass
            // walks from the same end and stops in the same place (D-208).
            Log.sources.error(
                "jira changelog paging hit the \(Self.maxPages, privacy: .public)-page cap for one ref; the watermark is held at the oldest entry read"
            )
        }
        return (Array(collected.values), !reachedWindowEnd)
    }

    /// The comments that could be inside the window.
    ///
    /// Newest first via `orderBy=-created`, stopping at the first page whose oldest
    /// comment predates the window. **Paged on `startAt + total`, because
    /// `PageOfComments` has no `isLast`** — verified against the API's own schema,
    /// where `PageBeanChangelog` does have one.
    ///
    /// **The early stop has a known blind spot, and it is the API's.** The ordering key is
    /// `created` and there is no filter on `updated`, so an edit to a comment created
    /// before the window sits on a page this walk never reaches. Reading every comment on
    /// every pass is the only way to catch it, which is a poor trade for a ticket with
    /// hundreds of them; §5.2 asks for "new comments", so the boundary is within the
    /// requirement. `JiraChangeSet.commentChanges` states it too, and a test pins it.
    /// Raised by Copilot in review of PR #43.
    private func comments(
        key: String, since: Date?, base: URL, authorization: String
    ) async throws -> (comments: [JiraComment], capped: Bool) {
        var collected: [JiraComment] = []
        var start = 0
        var pages = 0
        var reachedWindowEnd = false

        while pages < Self.maxPages {
            // **Cancellation fails the ref; it does not produce a short answer**
            // (D-207). `SourceRefreshService.fetchAll` discards a *failed* fetch once the
            // pass budget has expired and keeps a *successful* one — on the reasoning that
            // a fetch which beat the cancellation still carries data. A walk that broke out
            // here did not beat the cancellation, it answered one, so returning normally
            // would file a truncated delta as a complete fetch and append it to a log that
            // cannot be edited. Raised by Copilot in review of PR #44.
            //
            // `.timedOut` rather than a new case, because that is already what a
            // cancellation landing *inside* a request maps to
            // (`AtlassianErrors.error(forTransport:)`) — the same budget expiring must not
            // mean two different things depending on which microsecond it lands in.
            if Task.isCancelled { throw SourceError.timedOut }

            let page = try await fetch(
                JiraCommentPage.self,
                from: .comments(key: key, startAt: start, maxResults: Self.commentPageSize),
                base: base, authorization: authorization)

            let batch = page.comments ?? []
            collected.append(contentsOf: batch)
            pages += 1

            if batch.isEmpty {
                reachedWindowEnd = true
                break
            }
            guard let since else {
                reachedWindowEnd = true
                break
            }

            if let oldest = batch.compactMap(\.stamp).min(), oldest < since {
                reachedWindowEnd = true
                break
            }

            start += batch.count
            if let total = page.total, start >= total {
                reachedWindowEnd = true
                break
            }
        }

        // **The cap is a gap in what the user was told, so it is logged as one.** Stopping
        // here without reaching a page older than the window means the oldest comments
        // inside it were not read — and because the watermark advances to the newest comment
        // seen, the next pass starts in the same place and never reaches them. Same shape as
        // the changelog cap, and the same reasoning: a continuation needs a persisted cursor
        // and therefore export, import and merge rules, for a ticket with more than
        // \(Self.maxPages * Self.commentPageSize) comments inside `ResumePoint.maxLookback`.
        // Raised by Copilot in review round 2 of PR #43.
        if !reachedWindowEnd {
            Log.sources.error(
                "jira comment paging hit the \(Self.maxPages, privacy: .public)-page cap for one ref; the watermark is held at the oldest comment read"
            )
        }
        return (collected, !reachedWindowEnd)
    }

    // MARK: - One request

    /// Send, map the status, decode.
    ///
    /// The three failure shapes are separated deliberately: a transport failure, a
    /// status Jira chose, and a body that would not decode are different facts, and
    /// §5.5's banner says different things about them.
    /// - Parameter notFound: what a `404` means for this call (D-217, revised).
    ///   Defaults to `.notFound`, which is right for every ref fetch; `verify`
    ///   passes `.siteNotFound`.
    private func fetch<T: Decodable>(
        _ type: T.Type, from endpoint: JiraEndpoint, base: URL, authorization: String,
        notFound: SourceError = .notFound
    ) async throws -> T {
        // A key that is not shaped like a key is a mistyped reference, not a programmer
        // error — `JiraEndpoint.request` explains why this is `nil` rather than a trap,
        // and why catching it here saves a round trip Jira would answer 400 to.
        guard let request = endpoint.request(base: base, authorization: authorization) else {
            throw SourceError.notFound
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AtlassianErrors.error(forTransport: error)
        }

        if let failure = AtlassianErrors.error(
            forStatus: response.status, headers: response.headers, badRequest: .notFound,
            notFound: notFound)
        {
            throw failure
        }

        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            // **The `DecodingError` is dropped rather than described**, following
            // `AnthropicProvider.decode`: its message quotes the coding path and the
            // value that failed, which here means ticket titles and comment bodies in
            // a thrown error that the logging path prints (§8, D-165).
            Log.sources.error(
                "jira response could not be decoded as \(String(describing: type), privacy: .public)"
            )
            throw SourceError.invalidResponse
        }
    }
}
