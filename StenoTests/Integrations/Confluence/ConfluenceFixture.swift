import Foundation

@testable import StenoKit

/// Recorded-shape JSON for the four v2/v1 responses, and a transport that routes.
///
/// **The shapes come from Atlassian's own OpenAPI document** (`openapi-v2.v3.json`,
/// `info.version` 2.0.0, verified 2026-09-29), not from a guess: a version's five
/// fields, `MultiEntityResult<Version>`'s `results` + `_links{next, base}`, and a single
/// page's `_links{webui, editui, tinyui}` with no `base`. Until
/// `make verify-confluence` runs against a real page these fixtures *are* the wire
/// contract (D-197), so they are built from the schema rather than from what the code
/// happens to want.
enum ConfluenceFixture {
    static let pageID = "12345"
    static let site = "acme.atlassian.net"
    static let title = "Payments Migration Plan"
    static let webui = "/spaces/ENG/pages/12345/Payments+Migration+Plan"

    /// The account ids the fixtures edit under, and the names they resolve to.
    static let leo = "557058:aa1b-leo"
    static let priya = "557058:cc2d-priya"
    static let names = [leo: "Leo Gutierrez", priya: "Priya Anand"]

    // MARK: - The window every client test shares

    /// Inside the window.
    static let inWindow = "2026-09-25T18:04:11.000Z"

    /// Before it.
    static let outOfWindow = "2026-09-20T09:00:00.000Z"

    /// The window start: after `outOfWindow`, before `inWindow`.
    static let windowStart = AtlassianDate.parse("2026-09-22T00:00:00.000Z")

    static func credential(expiresAt: Date? = nil) -> AtlassianCredential {
        AtlassianCredential(
            site: site, email: "leo@example.com", apiToken: "token-value", expiresAt: expiresAt)
    }

    /// Routes that answer every endpoint with a well-formed, quiet response.
    static func quietRoutes() -> [String: [StubConfluenceTransport.Answer]] {
        [
            "page": [.ok(page())],
            "versions": [.ok(versions([version(number: 9, createdAt: outOfWindow)]))],
            "user": [.ok(user())],
            "spaces": [.ok(spaces())],
        ]
    }

    // MARK: - Bodies

    /// - Parameters:
    ///   - currentVersion: a `version(…)` body, or `nil` to omit the field entirely —
    ///     which is the shape a page whose version could not be read would have.
    ///   - webui: `nil` omits `_links`, so the URL fallback has something to fall back
    ///     from.
    static func page(
        title: String? = Self.title,
        currentVersion: String? = Self.version(number: 9, createdAt: inWindow),
        webui: String? = Self.webui
    ) -> String {
        var body: [String: Any] = ["id": pageID]
        if let title { body["title"] = title }
        if let currentVersion { body["version"] = object(of: currentVersion) }
        if let webui {
            body["_links"] = [
                "webui": webui,
                "editui": "/pages/edit-v2.action?pageId=\(pageID)",
                "tinyui": "/x/AQBd",
            ]
        }
        return json(body)
    }

    /// One `Version`, as its five documented fields.
    static func version(
        number: Int? = 7,
        createdAt: String? = inWindow,
        message: String? = nil,
        minorEdit: Bool? = false,
        authorID: String? = leo
    ) -> String {
        var body: [String: Any] = [:]
        if let number { body["number"] = number }
        if let createdAt { body["createdAt"] = createdAt }
        if let message { body["message"] = message }
        if let minorEdit { body["minorEdit"] = minorEdit }
        if let authorID { body["authorId"] = authorID }
        return json(body)
    }

    /// `MultiEntityResult<Version>`. `next` absent means the walk is over.
    static func versions(_ entries: [String], next: String? = nil) -> String {
        var links: [String: Any] = ["base": "https://\(site)/wiki"]
        if let next { links["next"] = next }
        return json([
            "results": entries.map(object(of:)),
            "_links": links,
        ])
    }

    /// The relative `_links.next` the API sends, with a cursor in it.
    static func next(cursor: String) -> String {
        "/wiki/api/v2/pages/\(pageID)/versions?limit=50&sort=-modified-date&cursor=\(cursor)"
    }

    static func user(displayName: String? = "Leo Gutierrez") -> String {
        var body: [String: Any] = ["accountId": leo, "type": "known"]
        if let displayName { body["displayName"] = displayName }
        return json(body)
    }

    static func spaces(count: Int = 1) -> String {
        json([
            "results": (0..<count).map { ["id": "space-\($0)", "key": "ENG"] },
            "_links": ["base": "https://\(site)/wiki"],
        ])
    }

    // MARK: - JSON

    private static func object(of raw: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}

/// Answers Confluence requests from a script, and records what it was asked.
///
/// Keyed by endpoint rather than by URL so a paging test can queue two answers for
/// `versions` and get them in order — the same shape `StubJiraTransport` uses, and an
/// actor for the same reason: the client issues its requests concurrently, and an
/// unsynchronized recorder does not merely race, it makes the test lie about what the
/// code did.
actor StubConfluenceTransport: HTTPTransport {
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
    private let users: [String: Answer]

    /// Versions answers keyed by the cursor that asks for them, `""` being the first
    /// page.
    ///
    /// **A real server answers a cursor, not a position in a queue**, and the
    /// difference is not cosmetic: a test that walks the same page twice gets the
    /// *first* page again on the second walk, which is exactly the behaviour the cap's
    /// continuation claim turns on. The FIFO `routes` queue silently modelled a server
    /// that remembered where the last walk stopped, which made a limitation look like a
    /// feature.
    private let versionsByCursor: [String: Answer]

    private let fallback: Answer
    private(set) var received: [HTTPRequest] = []

    /// - Parameters:
    ///   - routes: keyed by `page`, `versions`, `user`, `spaces`. A key's answers are
    ///     consumed in order, which is what lets a paging test script page one and page
    ///     two.
    ///   - users: keyed by account id, answered **by lookup rather than in order**. The
    ///     name lookups run concurrently, so a shared queue would hand whichever child
    ///     task arrived first whichever answer happened to be next — a test that passes
    ///     or fails on scheduling. Keying by id is what makes "Leo's id resolves to
    ///     Leo's name" a fact rather than a race.
    init(
        routes: [String: [Answer]], users: [String: Answer] = [:],
        versionsByCursor: [String: Answer] = [:],
        fallback: Answer = .status(500)
    ) {
        self.routes = routes
        self.users = users
        self.versionsByCursor = versionsByCursor
        self.fallback = fallback
    }

    /// Every request's method, for D5's assertion.
    var methods: [HTTPRequest.Method] { received.map(\.method) }

    /// Every request's URL, for the query assertions.
    var urls: [String] { received.map { $0.url.absoluteString } }

    /// How many times each endpoint was asked — what pins "one lookup per distinct
    /// author" (D-201).
    var callCounts: [String: Int] {
        received.reduce(into: [:]) { counts, request in
            counts[Self.endpointKey(request), default: 0] += 1
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        received.append(request)

        let key = Self.endpointKey(request)
        if key == "versions", !versionsByCursor.isEmpty {
            let cursor = Self.cursor(in: request) ?? ""
            switch versionsByCursor[cursor] ?? fallback {
            case .respond(let response): return response
            case .fail(let error): throw error
            }
        }
        if key == "user", let id = Self.accountID(in: request), let answer = users[id] {
            switch answer {
            case .respond(let response): return response
            case .fail(let error): throw error
            }
        }

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

    /// The `cursor` a versions request resumed on, or `nil` for the first page.
    static func cursor(in request: HTTPRequest) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "cursor" }?.value
    }

    /// The `accountId` a name lookup asked about.
    static func accountID(in request: HTTPRequest) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "accountId" }?.value
    }

    /// `versions` before `page`, because a versions path contains the page path.
    static func endpointKey(_ request: HTTPRequest) -> String {
        let path = request.url.path
        if path.hasSuffix("/versions") { return "versions" }
        if path.hasPrefix("/wiki/api/v2/pages/") { return "page" }
        if path == "/wiki/rest/api/user" { return "user" }
        if path == "/wiki/api/v2/spaces" { return "spaces" }
        return "unknown"
    }
}
