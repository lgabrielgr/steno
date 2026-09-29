import Foundation

/// Every Confluence request this app can make, and the only thing that builds one
/// (D-191, D-205).
///
/// **The same shape as `JiraEndpoint`, and deliberately not the same type** (§5.3:
/// "Jira and Confluence are distinct REST APIs; do not conflate them"). The two APIs
/// share a host, a credential and a transport; they share no path, no pagination
/// scheme and no response envelope.
///
/// REST v2 against Atlassian Cloud (D19, D-200), with one exception that is stated
/// rather than hidden: `user` is a v1 endpoint, because v2 resolves an account id to a
/// name only through a `POST`, and `ReadOnlyTransport` allows GET and nothing else
/// (D-201).
enum ConfluenceEndpoint: Equatable {
    /// The page itself: title and current version. §5.3's "page title, last-modified
    /// timestamp, last editor".
    ///
    /// **No query parameters at all.** `include-version` defaults to `true`, so the
    /// current version arrives without asking; `body-format` is *not* sent, which is
    /// what keeps the page's text out of the response (§8).
    case page(id: String)

    /// §5.3's "version delta since `since`", newest first.
    ///
    /// `cursor` is `nil` on the first page and is the value extracted from the previous
    /// response's `_links.next` thereafter — never the URL itself (D-205).
    case versions(pageID: String, cursor: String?, limit: Int)

    /// An account id turned into a display name (D-201). The one v1 path here.
    case user(accountID: String)

    /// The credential check behind `testConnection()` (FR-6).
    case spaces(limit: Int)

    /// `VersionSortOrder`'s descending case, verified against the OpenAPI document:
    /// the enum is exactly `["modified-date", "-modified-date"]`.
    ///
    /// **The whole backwards walk rests on this string.** Sent wrong it does not throw —
    /// the API either answers 400 or, worse, an unrecognised sort could leave the walk
    /// ascending, reading a page's oldest versions first and windowing nothing.
    static let newestFirst = "-modified-date"

    /// This endpoint as a request, or `nil` when the page id cannot go in a URL.
    ///
    /// **Always `.get`** (D-191). No Confluence endpoint this app touches mutates, and
    /// the one that would — `POST /users-bulk` — is not modelled here at all.
    func request(base: URL, authorization: String) -> HTTPRequest? {
        if let pageID, !Self.isValidPageID(pageID) { return nil }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { return nil }

        return HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "authorization": authorization,
                "accept": "application/json",
            ])
    }

    /// The page id this endpoint addresses, or `nil` for the two that address no page.
    var pageID: String? {
        switch self {
        case .page(let id), .versions(let id, _, _):
            return id
        case .user, .spaces:
            return nil
        }
    }

    /// Whether `id` is shaped like a Confluence page id at all: a non-empty run of
    /// ASCII digits.
    ///
    /// **Stricter than `JiraEndpoint.isValidKey`, because the identifier is stricter.**
    /// §3.4 says a Confluence ref's identifier *is* the page id, and `SourceURLClassifier`
    /// only ever produces one by checking `allSatisfy { $0.isASCII && $0.isNumber }` — so
    /// anything else arrived from an import or a hand-typed `--page`, and is a mistyped
    /// reference rather than a programmer error. The client turns the `nil` into
    /// `.notFound`, which saves a round trip the API would answer 400 to.
    ///
    /// ASCII is checked explicitly because `isNumber` covers the whole Unicode Number
    /// category: `١٢٣` is three numbers and not a page id.
    static func isValidPageID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The cursor inside a `_links.next` value, or `nil` when there is none.
    ///
    /// **This is the whole of D-205.** `next` is documented as "the relative URL for the
    /// next set of results, using a cursor query parameter", and the obvious
    /// implementation is to send it — but every request here carries the user's API
    /// token in an `Authorization` header, and following a URL from a response body
    /// lets the response choose where that token goes. So the URL is parsed, the cursor
    /// is taken, and everything else — host, scheme, path, other query items — is
    /// discarded. A `next` pointing at another host yields its cursor and nothing more,
    /// and the next request still goes to the configured site.
    ///
    /// `nil` for an absent `next`, which is how the API says the walk is over, and for a
    /// `next` carrying no cursor, which would otherwise re-request the first page
    /// forever.
    static func cursor(inNext next: String?) -> String? {
        guard let next, !next.isEmpty else { return nil }
        // Relative and absolute strings both parse; only the query survives either way.
        guard let items = URLComponents(string: next)?.queryItems else { return nil }
        guard let cursor = items.first(where: { $0.name == "cursor" })?.value, !cursor.isEmpty
        else { return nil }
        return cursor
    }

    private var path: String {
        switch self {
        case .page(let id): return "/wiki/api/v2/pages/\(id)"
        case .versions(let id, _, _): return "/wiki/api/v2/pages/\(id)/versions"
        case .user: return "/wiki/rest/api/user"
        case .spaces: return "/wiki/api/v2/spaces"
        }
    }

    private var query: [URLQueryItem] {
        switch self {
        case .page:
            return []
        case .versions(_, let cursor, let limit):
            // `sort` and `limit` are sent on every page, including a resumed one: the
            // cursor encodes the position, not the ordering, and a walk that dropped
            // them would page the rest of the history in the API's default ascending
            // order.
            var items = [
                URLQueryItem(name: "sort", value: Self.newestFirst),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
            if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
            return items
        case .user(let accountID):
            return [URLQueryItem(name: "accountId", value: accountID)]
        case .spaces(let limit):
            return [URLQueryItem(name: "limit", value: String(limit))]
        }
    }
}
