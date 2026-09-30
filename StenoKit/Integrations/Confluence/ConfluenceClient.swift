import Foundation
import OSLog

/// The three reads, their paging, and their failures (§5.3, D-205, D-206).
///
/// **Every request goes through `ReadOnlyTransport`**, which this type wraps around
/// whatever it is handed, so D5 holds even if a future endpoint is added carelessly
/// (D-191, D-202).
///
/// **Cancellation-aware, as `SourceConnector` requires.** The transport is
/// `URLSession`-backed, which honours cancellation, and the paging loop checks
/// `Task.isCancelled` — without that, a page with a long history could hold the whole
/// pass past both the per-fetch deadline and the pass budget, which are cooperative
/// only. A cancelled walk **throws `.timedOut`** rather than returning what it had
/// managed to read (D-207).
struct ConfluenceClient: Sendable {
    /// `limit` defaults to 25 and caps at 250. Fifty is the same order as
    /// `JiraClient.commentPageSize`, and a page's whole recent history usually fits one
    /// request.
    static let versionPageSize = 50

    /// A hard cap on the walk, matching `JiraClient.maxPages`.
    ///
    /// **What hitting it costs, stated honestly — and the first version of this comment
    /// was not honest enough.** The versions beyond the cap are not read, and they are
    /// **not read on any later pass either**: every walk restarts at `cursor == nil` and
    /// pages newest-first, while `since` is only a client-side stopping condition, so the
    /// next pass re-reads the same ten pages and stops in the same place. Lowering the
    /// watermark to the floor (D-196's shape) keeps the fetch from *claiming* coverage it
    /// did not achieve; it does not fill the gap, and the earlier claim that it "fills
    /// itself once the page quiets down" was false. Reaching page eleven needs a
    /// persisted cursor, which §10's export, import and merge rules would all have to
    /// learn about — see D-208.
    ///
    /// So this is a bound on a shape that does not occur rather than a routine loss:
    /// reaching it needs more than five hundred versions of one page inside
    /// `ResumePoint.maxLookback`'s thirty days. Hitting it is logged, so a real
    /// occurrence is visible rather than inferred, and
    /// `a capped walk does not continue on the next pass` pins the limitation.
    static let maxPages = 10

    /// How many distinct accounts one fetch will resolve to names (D-201).
    ///
    /// Not for the ordinary case — a page has one or two editors in a window — but so
    /// that one pathological page cannot spend a refresh pass's budget on name lookups.
    /// Beyond it the remaining editors read as "someone", which is what an unresolved
    /// id reads as anyway.
    static let maxNameLookups = 10

    private let transport: any HTTPTransport

    init(transport: any HTTPTransport) {
        self.transport = ReadOnlyTransport(wrapping: transport)
    }

    /// One ref's whole answer: the page, its versions, and the names behind the ids.
    ///
    /// **The page and the version walk run concurrently and both are required.** Either
    /// failing fails the ref (D-206): a failed version walk cannot be read as "no
    /// versions", because the watermark would advance past changes that were never
    /// read and the next pass would start after them. §5.5 prefers one degraded ref to
    /// a false silence.
    func changeSet(
        pageID: String, since: Date?, credential: AtlassianCredential
    ) async throws -> ConfluenceChangeSet {
        guard let base = credential.baseURL else { throw SourceError.notConfigured }
        let authorization = credential.basicAuthorization

        async let pageRead = fetch(
            ConfluencePage.self, from: .page(id: pageID), base: base, authorization: authorization)
        async let walk = versions(
            pageID: pageID, since: since, base: base, authorization: authorization)

        // **Awaited page-first, and the order is a decision.** Both run concurrently, so
        // when both fail the error that escapes is whichever is awaited first — and the
        // page read is the one whose failure describes the ref best. Reordering these
        // two lines silently changes which `SourceError` the staleness banner shows.
        let page = try await pageRead
        let walked = try await walk

        // Names last, because they depend on what the walk found — and unlike the two
        // reads above, a failure here is absorbed (D-201).
        let ids = authorIDs(in: page, versions: walked.versions)
        let names = await names(for: ids, base: base, authorization: authorization)

        return ConfluenceChangeSet.make(
            page: page, versions: walked.versions, names: names, since: since,
            isCapped: walked.capped)
    }

    /// FR-6's connection test: the cheapest authenticated Confluence read.
    ///
    /// **`/spaces?limit=1` rather than a user endpoint**, because the question this
    /// answers is whether the stored credential can read *Confluence* — an account that
    /// works for Jira but has no Confluence access answers 403 here, which is the
    /// specific sentence FR-6 exists to produce. An empty `results` is still a pass: the
    /// credential is valid and authorised, whatever it can see.
    func verify(credential: AtlassianCredential) async throws {
        guard let base = credential.baseURL else { throw SourceError.notConfigured }
        _ = try await fetch(
            ConfluenceSpacePage.self, from: .spaces(limit: 1), base: base,
            authorization: credential.basicAuthorization)
    }

    // MARK: - Paging

    /// Every version that could be inside the window, newest first.
    ///
    /// Walked by cursor — v2 has no `startAt` and no `isLast`, only `_links.next` — and
    /// stopped at the first page whose oldest version predates the window. The cursor is
    /// extracted from `next` rather than the URL being followed (D-205).
    private func versions(
        pageID: String, since: Date?, base: URL, authorization: String
    ) async throws -> (versions: [ConfluenceVersion], capped: Bool) {
        var collected: [ConfluenceVersion] = []
        var seenNumbers: Set<Int> = []
        var cursor: String?
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
                ConfluenceVersionPage.self,
                from: .versions(pageID: pageID, cursor: cursor, limit: Self.versionPageSize),
                base: base, authorization: authorization)

            // **`results` absent and `results: []` are treated alike here, and neither
            // ends the walk by itself** (D-209). An empty batch says nothing about
            // whether more history exists — only `_links.next` does — so this falls
            // through to the cursor check below rather than short-circuiting. The
            // earlier version broke out and set `reachedWindowEnd`, which turned a page
            // carrying `next` into a *complete* walk: the same defect as the repeated
            // cursor, reached from the other side.
            //
            // Not `.invalidResponse` for a missing `results`, though it was suggested:
            // `MultiEntityResult<Version>` declares no `required`, so a body without the
            // key is schema-valid and hard-failing it would refuse a shape the API is
            // permitted to send. What must not happen is *claiming coverage* on it.
            let batch = page.results ?? []

            // **De-duplicated by version number, because cursor paging is not a
            // snapshot** (D-210). Publishing a version mid-walk shifts every boundary
            // below it, so the same version can arrive on two consecutive pages — and
            // `SourceRefreshService` de-duplicates a change against the ids the *log* has
            // already reported, not within one update, so a repeat here reaches the
            // stand-up as the same edit said twice. `JiraClient` keys its walk for this
            // reason; this is the same guard, on the key Confluence has.
            //
            // A version with no `number` is kept rather than dropped: it cannot collide
            // on a key it does not have, `ConfluenceChangeSet` is what declines to report
            // it, and its timestamp still belongs to the watermark.
            for version in batch {
                if let number = version.number, !seenNumbers.insert(number).inserted { continue }
                collected.append(version)
            }
            pages += 1

            // No anchor yet: one page is all that is needed to establish one, and
            // nothing from it will be reported anyway (D-188).
            guard let since else {
                reachedWindowEnd = true
                break
            }

            // A page whose oldest item predates the window is the end of the window. An
            // empty batch has no oldest item, so this cannot fire for one.
            if let oldest = batch.compactMap(\.stamp).min(), oldest < since {
                reachedWindowEnd = true
                break
            }

            guard let next = ConfluenceEndpoint.cursor(inNext: page.links?.next) else {
                // No `next` is how the API says there is nothing further.
                reachedWindowEnd = true
                break
            }

            // **A cursor that does not move ends the walk — as a capped one.** A server
            // that repeated one would otherwise be paged until `maxPages`, re-reading the
            // same versions. But `next` is still present, so older versions may well
            // remain unread: this is a walk that could not continue, not one that reached
            // the end of the window, and `reachedWindowEnd` stays false so the watermark
            // is held at the floor rather than claiming coverage it does not have.
            // Raised by Copilot in review of PR #44.
            if next == cursor { break }
            cursor = next
        }

        if !reachedWindowEnd {
            // `error`, not `info`: this is a gap in what the user was told rather than a
            // slow pass — and the watermark is held back so the gap stays inside the
            // next window.
            Log.sources.error(
                "confluence version paging hit the \(Self.maxPages, privacy: .public)-page cap for one ref; the watermark is held at the oldest version read"
            )
        }
        return (collected, !reachedWindowEnd)
    }

    // MARK: - Names

    /// Every account id this fetch will need a name for, page's own editor included.
    ///
    /// Deduplicated and **stably ordered** — newest version first, page last — so the
    /// ids that survive `maxNameLookups` are the ones on the most recent edits rather
    /// than whichever the hasher happened to favour.
    private func authorIDs(in page: ConfluencePage, versions: [ConfluenceVersion]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for id in versions.compactMap(\.authorId) + [page.version?.authorId].compactMap({ $0 })
        where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    /// Account id → display name, for as many as could be resolved (D-201).
    ///
    /// **Never throws.** A name is cosmetic: the version happened either way, and §5.5
    /// would rather report `v7 by someone` than degrade a whole ref to cache over a
    /// display name. This is the opposite of the version walk's rule (D-206), and the
    /// difference is whether the missing data changes what the user is told *happened*.
    ///
    /// Concurrent, because up to ten sequential round trips inside a per-fetch deadline
    /// is the shape that turns a bounded cost into a timeout.
    ///
    /// **`withTaskGroup`, not `withThrowingTaskGroup`, and that is the enforcement.** A
    /// child of a non-throwing group cannot throw, so "a name lookup never fails the
    /// fetch" is a compile error rather than a rule — verified by mutation: replacing
    /// `try?` with `try` does not produce a failing test, it produces a build failure.
    private func names(
        for ids: [String], base: URL, authorization: String
    ) async -> [String: String] {
        let wanted = ids.prefix(Self.maxNameLookups)
        if ids.count > Self.maxNameLookups {
            // No id in the message: an account id identifies a person (§8).
            Log.sources.info(
                "confluence name lookup capped at \(Self.maxNameLookups, privacy: .public) accounts for one page; the rest are reported as \"someone\""
            )
        }
        guard !wanted.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, String?).self) { group in
            for id in wanted {
                group.addTask {
                    let user = try? await fetch(
                        ConfluenceUser.self, from: .user(accountID: id), base: base,
                        authorization: authorization)
                    return (id, user?.displayName)
                }
            }

            var resolved: [String: String] = [:]
            for await (id, name) in group {
                guard let name else { continue }
                resolved[id] = name
            }
            return resolved
        }
    }

    // MARK: - One request

    /// Send, map the status, decode.
    ///
    /// The three failure shapes are separated deliberately: a transport failure, a
    /// status Confluence chose, and a body that would not decode are different facts,
    /// and §5.5's banner says different things about them.
    private func fetch<T: Decodable>(
        _ type: T.Type, from endpoint: ConfluenceEndpoint, base: URL, authorization: String
    ) async throws -> T {
        // A page id that is not a page id is a mistyped reference, not a programmer
        // error — `ConfluenceEndpoint.request` explains why this is `nil` rather than a
        // trap, and why catching it here saves a round trip the API would answer 400 to.
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
            forStatus: response.status, headers: response.headers)
        {
            throw failure
        }

        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            // **The `DecodingError` is dropped rather than described**, following
            // `JiraClient.fetch`: its message quotes the coding path and the value that
            // failed, which here means page titles and version messages in a thrown
            // error that the logging path prints (§8, D-165).
            Log.sources.error(
                "confluence response could not be decoded as \(String(describing: type), privacy: .public)"
            )
            throw SourceError.invalidResponse
        }
    }
}
