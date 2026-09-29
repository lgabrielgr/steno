import Foundation

@testable import StenoKit

/// Recorded-shape JSON for the four REST v3 responses, and a transport that routes.
///
/// **The shapes come from Atlassian's own OpenAPI document** (verified 2026-09-26),
/// not from a guess: `PageBeanChangelog` carries `isLast` and `PageOfComments` does
/// not, a remote link's `id` is an `Int` while every other id is a `String`, and a
/// comment body is ADF. Until `make verify-jira` runs against a real ticket these
/// fixtures *are* the wire contract (D-197), so they are built from the schema rather
/// than from what the code happens to want.
enum JiraFixture {
    static let key = "PAY-421"
    static let site = "acme.atlassian.net"

    // MARK: - The window every client test shares

    /// Inside the window.
    static let inWindow = "2026-09-25T18:04:11.000+0000"

    /// Before it.
    static let outOfWindow = "2026-09-20T09:00:00.000+0000"

    /// The window start: after `outOfWindow`, before `inWindow`.
    static let windowStart = AtlassianDate.parse("2026-09-22T00:00:00.000+0000")

    /// Routes that answer every endpoint with an empty, well-formed page.
    static func quietRoutes() -> [String: [StubJiraTransport.Answer]] {
        [
            "issue": [.ok(issue())],
            "changelog@0": [.ok(changelog([], total: 0, isLast: true))],
            "comment@0": [.ok(comments([], total: 0))],
            "remotelink": [.ok(remoteLinks([]))],
        ]
    }

    static func credential(expiresAt: Date? = nil) -> AtlassianCredential {
        AtlassianCredential(
            site: site, email: "leo@example.com", apiToken: "token-value", expiresAt: expiresAt)
    }

    // MARK: - Bodies

    static func issue(
        title: String? = "Add the migration plan",
        status: String? = "In Review",
        assignee: String? = "Leo Gutierrez",
        updated: String? = "2026-09-25T18:04:11.123+0000"
    ) -> String {
        var fields: [String: Any] = [:]
        if let title { fields["summary"] = title }
        if let status { fields["status"] = ["name": status] }
        if let assignee { fields["assignee"] = ["displayName": assignee] }
        if let updated { fields["updated"] = updated }
        return json(["key": key, "fields": fields])
    }

    /// One field's change inside a changelog entry.
    struct Change {
        let field: String
        let from: String?
        let toValue: String?
    }

    /// One changelog entry, which may carry several `Change`s — Jira batches changes
    /// made together, and that is what D-186's id scheme has to survive.
    struct Entry {
        let id: String
        let created: String
        let items: [Change]

        /// The common case: a single status transition.
        /// The external label stays `to:` because that is how a transition reads at a
        /// call site; only the internal name grows to satisfy the linter.
        static func status(
            id: String, created: String, from: String?, to newValue: String?
        ) -> Entry {
            Entry(
                id: id, created: created,
                items: [Change(field: "status", from: from, toValue: newValue)])
        }
    }

    static func changelog(
        _ entries: [Entry], total: Int? = nil, startAt: Int = 0, isLast: Bool? = nil
    ) -> String {
        let values = entries.map { entry -> [String: Any] in
            [
                "id": entry.id,
                "created": entry.created,
                "author": ["displayName": "Leo Gutierrez"],
                "items": entry.items.map { item -> [String: Any] in
                    var encoded: [String: Any] = ["field": item.field, "fieldId": item.field]
                    if let from = item.from { encoded["fromString"] = from }
                    if let toValue = item.toValue { encoded["toString"] = toValue }
                    return encoded
                },
            ]
        }
        var page: [String: Any] = [
            "values": values,
            "startAt": startAt,
            "maxResults": JiraClient.changelogPageSize,
            "total": total ?? entries.count,
        ]
        if let isLast { page["isLast"] = isLast }
        return json(page)
    }

    struct Comment {
        let id: String
        let created: String
        let updated: String?
        let author: String?
        let text: String?

        init(
            id: String, created: String, updated: String? = nil,
            author: String? = "Ana Ruiz", text: String? = "Could you add the migration plan?"
        ) {
            self.id = id
            self.created = created
            self.updated = updated
            self.author = author
            self.text = text
        }
    }

    /// **No `isLast`**, exactly as `PageOfComments` is defined.
    static func comments(_ comments: [Comment], total: Int? = nil, startAt: Int = 0) -> String {
        let encoded = comments.map { comment -> [String: Any] in
            var value: [String: Any] = ["id": comment.id, "created": comment.created]
            if let updated = comment.updated { value["updated"] = updated }
            if let author = comment.author { value["author"] = ["displayName": author] }
            if let text = comment.text { value["body"] = adf(text) }
            return value
        }
        return json([
            "comments": encoded,
            "startAt": startAt,
            "maxResults": JiraClient.commentPageSize,
            "total": total ?? comments.count,
        ])
    }

    struct Link {
        let id: Int?
        let globalID: String?
        let title: String?
        let url: String?

        init(
            id: Int? = 10_001, globalID: String? = nil, title: String? = "acme/api#421",
            url: String? = "https://github.com/acme/api/pull/421"
        ) {
            self.id = id
            self.globalID = globalID
            self.title = title
            self.url = url
        }
    }

    static func remoteLinks(_ links: [Link]) -> String {
        json(
            links.map { link -> [String: Any] in
                var value: [String: Any] = [:]
                if let id = link.id { value["id"] = id }
                if let globalID = link.globalID { value["globalId"] = globalID }
                var object: [String: Any] = [:]
                if let title = link.title { object["title"] = title }
                if let url = link.url { object["url"] = url }
                if !object.isEmpty { value["object"] = object }
                return value
            })
    }

    /// A minimal ADF document holding one paragraph of `text`.
    static func adf(_ text: String) -> [String: Any] {
        [
            "type": "doc",
            "version": 1,
            "content": [
                ["type": "paragraph", "content": [["type": "text", "text": text]]]
            ],
        ]
    }

    /// `myself`, for the connection test.
    static let currentUser = #"{"displayName":"Leo Gutierrez","accountId":"abc"}"#

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

/// A transport that answers by endpoint rather than by call order.
///
/// **Routing, not a script.** `JiraClient` issues its four requests concurrently, so
/// the order they arrive in is the scheduler's business — a sequential double would
/// make every one of these tests flaky, and worse, would make a passing run no
/// evidence of anything.
actor StubJiraTransport: HTTPTransport {
    enum Answer: Sendable {
        case respond(HTTPResponse)
        case fail(any Error)

        static func ok(_ json: String) -> Answer {
            .respond(HTTPResponse(status: 200, body: Data(json.utf8)))
        }

        static func status(_ code: Int, headers: [String: String] = [:]) -> Answer {
            .respond(HTTPResponse(status: code, headers: headers, body: Data("{}".utf8)))
        }
    }

    private var routes: [String: [Answer]]
    private let fallback: Answer
    private(set) var received: [HTTPRequest] = []

    /// - Parameter routes: keyed by `endpointKey` — `issue`, `changelog@0`,
    ///   `comment@0`, `remotelink`, `myself`. A key's answers are consumed in order,
    ///   which is what lets a paging test script page one and page two.
    init(routes: [String: [Answer]], fallback: Answer = .status(500)) {
        self.routes = routes
        self.fallback = fallback
    }

    /// Every request's method, for D5's assertion.
    var methods: [HTTPRequest.Method] { received.map(\.method) }

    /// Every request's URL, for the query assertions.
    var urls: [String] { received.map { $0.url.absoluteString } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        received.append(request)

        let key = Self.endpointKey(request)
        let answer: Answer
        if var queued = routes[key], !queued.isEmpty {
            answer = queued.removeFirst()
            routes[key] = queued
        } else {
            answer = fallback
        }

        switch answer {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }

    /// `changelog@100`, `comment@0`, `issue`, `remotelink`, `myself`.
    ///
    /// The paged endpoints carry their `startAt`, because a paging test's whole point
    /// is which offsets were asked for.
    static func endpointKey(_ request: HTTPRequest) -> String {
        let path = request.url.path
        let startAt =
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "startAt" }?.value

        if path.hasSuffix("/changelog") { return "changelog@\(startAt ?? "?")" }
        if path.hasSuffix("/comment") { return "comment@\(startAt ?? "?")" }
        if path.hasSuffix("/remotelink") { return "remotelink" }
        if path.hasSuffix("/myself") { return "myself" }
        return "issue"
    }
}
