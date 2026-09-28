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
/// cooperative only.
struct JiraClient: Sendable {
    /// `PageBeanChangelog` serves 100 at a time happily, and a ticket's whole
    /// recent history usually fits one page.
    static let changelogPageSize = 100

    /// Comments are bigger documents — each carries an ADF body — so the page is
    /// smaller.
    static let commentPageSize = 50

    /// **A hard cap, because `total` can shift under a backwards walk** (D-196).
    /// Hitting it is logged rather than thrown: a partial window whose watermark is
    /// the newest item actually read leaves the remainder inside the next pass's
    /// window, which is degradation rather than loss.
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

        return JiraChangeSet.make(
            issue: try await issue,
            history: try await history,
            comments: try await comments,
            links: try await links,
            since: since)
    }

    /// FR-6's connection test: the cheapest authenticated read Jira offers.
    ///
    /// `/myself` rather than an issue, because a test must distinguish a rejected
    /// credential from a ticket the account cannot see — and any issue key would
    /// confuse the two.
    func verify(credential: AtlassianCredential) async throws {
        guard let base = credential.baseURL else { throw SourceError.notConfigured }
        _ = try await fetch(
            JiraUser.self, from: .currentUser, base: base,
            authorization: credential.basicAuthorization)
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
    ) async throws -> [JiraChangelogEntry] {
        let probe = try await fetch(
            JiraChangelogPage.self,
            from: .changelog(key: key, startAt: 0, maxResults: Self.changelogPageSize),
            base: base, authorization: authorization)

        let total = probe.total ?? probe.values?.count ?? 0
        if probe.isLast == true || total <= Self.changelogPageSize {
            return probe.values ?? []
        }

        // The probe returned the *oldest* entries, which are outside any window this
        // ref could still care about, so they are discarded rather than merged: an
        // ancient entry whose timestamp failed to parse would otherwise be reported.
        var collected: [String: JiraChangelogEntry] = [:]
        var start = max(0, total - Self.changelogPageSize)
        var pages = 0

        while pages < Self.maxPages {
            if Task.isCancelled { break }

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

            let oldest = (page.values ?? []).compactMap { JiraDate.parse($0.created) }.min()
            if let oldest, oldest < since { break }
            if start == 0 { break }
            start = max(0, start - Self.changelogPageSize)
        }

        if pages >= Self.maxPages {
            Log.sources.info(
                "jira changelog paging stopped at the cap for one ref; the rest falls into the next pass"
            )
        }
        return Array(collected.values)
    }

    /// The comments that could be inside the window.
    ///
    /// Newest first via `orderBy=-created`, stopping at the first page whose oldest
    /// comment predates the window. **Paged on `startAt + total`, because
    /// `PageOfComments` has no `isLast`** — verified against the API's own schema,
    /// where `PageBeanChangelog` does have one.
    private func comments(
        key: String, since: Date?, base: URL, authorization: String
    ) async throws -> [JiraComment] {
        var collected: [JiraComment] = []
        var start = 0
        var pages = 0

        while pages < Self.maxPages {
            if Task.isCancelled { break }

            let page = try await fetch(
                JiraCommentPage.self,
                from: .comments(key: key, startAt: start, maxResults: Self.commentPageSize),
                base: base, authorization: authorization)

            let batch = page.comments ?? []
            collected.append(contentsOf: batch)
            pages += 1

            if batch.isEmpty { break }
            guard let since else { break }

            if let oldest = batch.compactMap(\.stamp).min(), oldest < since { break }

            start += batch.count
            if let total = page.total, start >= total { break }
        }
        return collected
    }

    // MARK: - One request

    /// Send, map the status, decode.
    ///
    /// The three failure shapes are separated deliberately: a transport failure, a
    /// status Jira chose, and a body that would not decode are different facts, and
    /// §5.5's banner says different things about them.
    private func fetch<T: Decodable>(
        _ type: T.Type, from endpoint: JiraEndpoint, base: URL, authorization: String
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
            throw JiraErrors.error(forTransport: error)
        }

        if let failure = JiraErrors.error(forStatus: response.status, headers: response.headers) {
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
