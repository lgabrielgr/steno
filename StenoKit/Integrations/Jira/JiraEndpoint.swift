import Foundation

/// Every Jira request this app can make, and the only thing that builds one
/// (D-191).
///
/// **This type is half of how D5 is enforced rather than intended.** `request`
/// hard-codes `.get`, and nothing under `Jira/` calls `HTTPRequest(method:…)`
/// directly — so "the connector never writes" is a property of the one place a
/// request can come from, not a rule spread over a client. The other halves are
/// `ReadOnlyTransport`, which traps on anything else, and the tests that walk these
/// cases.
///
/// REST v3 against Atlassian Cloud only (D19, §5.2).
enum JiraEndpoint: Equatable {
    /// The issue's own fields. §5.2's "issue detail".
    case issue(key: String)

    /// §5.2's "issue changelog" — status transitions and assignee changes.
    case changelog(key: String, startAt: Int, maxResults: Int)

    /// §5.2's "issue comments". Newest first, because there is no date filter
    /// (D-196).
    case comments(key: String, startAt: Int, maxResults: Int)

    /// Linked PR references (§5.2's "linked PR references"). Not paginated by the
    /// API, and carries no timestamps at all — see D-187.
    case remoteLinks(key: String)

    /// The credential check behind `testConnection()` (FR-6).
    case currentUser

    /// The fields the issue request asks for.
    ///
    /// **Named rather than left to the default, which returns everything.** A bare
    /// issue GET is a large document — every custom field an org has ever added —
    /// and §8's rule about not logging content is easier to keep when the response
    /// never contained the content in the first place.
    static let issueFields = "summary,status,assignee,updated"

    /// This endpoint as a request, or `nil` when `key` cannot go in a URL.
    ///
    /// **Always `.get`** (D-191). The `updateHistory` parameter that `GET
    /// /issue/{key}` accepts is never sent: it *writes* to the user's recent-projects
    /// list, which would make a read mutate state D5 says this app does not touch.
    ///
    /// `nil` for a key that is not a key — see `isValidKey`. A ticket identifier comes
    /// from text the user typed, so that is input rather than a programmer error, and
    /// the client turns the `nil` into `.notFound`, which is what a mistyped reference
    /// deserves.
    func request(base: URL, authorization: String) -> HTTPRequest? {
        // **Validated here rather than left to Jira.** `URLComponents` will happily
        // percent-encode a key with a space in it, so without this the request is built,
        // sent, and answered 400 — a round trip spent on something knowable locally.
        // It is also what makes this `nil` path reachable and therefore testable:
        // before the check it was unreachable code with a comment claiming otherwise.
        if let key, !Self.isValidKey(key) { return nil }

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

    /// The issue key this endpoint addresses, or `nil` for the one endpoint that
    /// addresses no issue.
    var key: String? {
        switch self {
        case .issue(let key), .changelog(let key, _, _), .comments(let key, _, _),
            .remoteLinks(let key):
            return key
        case .currentUser:
            return nil
        }
    }

    /// Whether `key` is shaped like a Jira issue key at all.
    ///
    /// Deliberately not a pattern for `ABC-123`: project keys are more varied than that
    /// (digits and underscores are allowed, and lengths differ by site), and a regex that was
    /// almost right would reject real tickets. What this accepts is the character set a key can
    /// be drawn from — ASCII letters, digits, `-` and `_`.
    ///
    /// **An allow-list, because the first version only rejected whitespace** — and `PAY/421`
    /// then interpolated into the path as an extra segment, sending the request to a different
    /// Jira route instead of taking the local `.notFound` path. Capture's own regex would never
    /// produce such a key, but an imported ref and `jira-selftest --issue` both bypass it.
    /// Raised by Copilot in review round 4 of PR #43.
    static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-"
                    || character == "_")
        }
    }

    private var path: String {
        switch self {
        case .issue(let key): return "/rest/api/3/issue/\(key)"
        case .changelog(let key, _, _): return "/rest/api/3/issue/\(key)/changelog"
        case .comments(let key, _, _): return "/rest/api/3/issue/\(key)/comment"
        case .remoteLinks(let key): return "/rest/api/3/issue/\(key)/remotelink"
        case .currentUser: return "/rest/api/3/myself"
        }
    }

    private var query: [URLQueryItem] {
        switch self {
        case .issue:
            return [URLQueryItem(name: "fields", value: Self.issueFields)]
        case .changelog(_, let startAt, let maxResults):
            return [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: String(maxResults)),
            ]
        case .comments(_, let startAt, let maxResults):
            return [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: String(maxResults)),
                // Verified against the API's own OpenAPI document: `orderBy` accepts
                // `created`, `-created` and `+created`, and there is no date filter
                // of any kind — so newest-first plus an early stop is how a window
                // is applied (D-196).
                URLQueryItem(name: "orderBy", value: "-created"),
            ]
        case .remoteLinks, .currentUser:
            return []
        }
    }
}
