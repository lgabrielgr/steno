# M4-03 — Confluence Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only Confluence Cloud connector that turns a `SourceRef` of kind
`confluencePage` into the `externalUpdate` events a stand-up is assembled from, sharing the
Atlassian credential M4-02 already stores.

**Architecture:** Five new types under `StenoKit/Integrations/Confluence/` — an endpoint builder,
`Decodable` wire mirrors, a pure change set, a client that pages and resolves names, and the
`SourceConnector` conformance — plus a CLI harness that runs the whole path against the real API.
Everything neutral between the two Atlassian APIs moves into `StenoKit/Integrations/Atlassian/`
first, so there is one read-only trap, one status map, one date parser and one text rule rather
than two of each. Endpoints, wire types and change sets stay per-API, because §5.3 says the two
REST APIs are distinct and they page and shape responses differently.

**Tech Stack:** Swift 6, Swift Testing, SwiftData (untouched here), `HTTPTransport` over
`URLSession`, Confluence Cloud REST API **v2** with one v1 endpoint for display names.

**Spec:** [`docs/superpowers/specs/2026-09-29-m4-03-confluence-connector-design.md`](../specs/2026-09-29-m4-03-confluence-connector-design.md)

**How this plan was produced.** It was generated from a tree that is already built, green and
committed on `feat/confluence-connector` — every code block below is verbatim from code that
compiles, passes `make build && make test && make lint`, and survived mutation testing. This
repo's standing lesson is that plan code verified standalone still fails inside its module, and
that is why the order below is the *destination*, not the order the work happened in: the
`AtlassianText` lift lands in Task 1 with the rest of the move, whereas in the commit history it
arrived last, as the fix for a defect the Review Focus pass found.

---

## Global Constraints

Copied verbatim from the spec and from `CLAUDE.md`; every task's requirements include these.

- **Read-only, permanently (D5).** No mutating request anywhere. `ReadOnlyTransport` allows `GET`
  and nothing else, and it traps rather than throwing — a mutating request is not a network
  condition to degrade around.
- **Atlassian Cloud only (D19).** `*.atlassian.net`, validated from the stored site; never a
  host taken from a response.
- **REST API v2** for content (`/wiki/api/v2/…`). The single exception is
  `GET /wiki/rest/api/user`, which is v1, is not in the deprecated set, and exists because v2
  resolves an account id to a name only through a `POST` (D-200, D-201).
- **The event log is append-only (§3.3).** A connector reads. It never writes: no cache, no
  `Event`, no store. `SourceRefreshService` is the only writer (D-172).
- **A connector throws `SourceError` and nothing else.** A `URLError` or `DecodingError` escaping
  a connector is a defect in that connector.
- **`fetch` must be cancellation-aware.** `SourceRefreshService` enforces its per-fetch deadline
  and pass budget with cooperative cancellation; check `Task.isCancelled` in any loop.
- **Degradation ships with the feature (§5.5, §13).** A failed fetch must never block a report.
- **§8:** no secrets, no page content, no account ids and no names in logs or error messages.
- **Gates:** `make build && make test && make lint` must all pass before a PR. `make format`
  must leave the tree clean. Never commit to `main`; branch, PR, stop.
- **Branch:** `feat/confluence-connector`.
- **Every new test is mutation-checked before it counts:** break the code it covers, watch it go
  red, restore. The verdict comes from `make test`'s **exit status** — xcbeautify prints `✖`
  (U+2716) for a failing test and only `⚠️ … recorded an issue with N argument(s)` for a failing
  parameterized one, so a grep-based harness reports false survivors.

---

## Review Focus

Five input classes §5.3 implies that no task's happy-path tests exercise, most likely to bite
first. Each line names the test that pins it and the task that owns it.

1. **A version message containing newlines** — the editor types into a multi-line box, and this
   string becomes one line of a stand-up the user reads aloud. Two lines, the second having lost
   its subject, is the failure. Pinned by `a version message with newlines stays one line of a
   stand-up` (Task 4).
2. **A version message of unbounded length** — release notes pasted into "What did you change?"
   become the stand-up. Pinned by `D-195's limit applies to a version message too, not only to a
   Jira comment` (Task 4).
3. **A page title carrying characters a URL must encode** — "Café Plan" is an ordinary title, and
   the reported link must still open the right page. Pinned by `a webui with characters a URL
   must encode still produces an openable link` (Task 6).
4. **A versions response with no `results` key at all** — absent is not the same shape as `[]`,
   and a walk that reads "no key" as "keep going" pages to the cap against a server saying
   nothing. Pinned by `a versions response with no results at all ends the walk` (Task 5).
5. **An account whose `displayName` is blank** — Confluence answers a deactivated account that
   way, and "edited by " is not a sentence. Pinned by `a deactivated account's blank name is not
   a name` (Task 4).

**Known and deliberately untested: cancellation mid-walk.** `ConfluenceClient.versions` checks
`Task.isCancelled` at the top of each page, and a cancelled walk reports `isWindowCapped: true`,
which holds the watermark at the floor — the correct behaviour, since the unread versions must
stay inside the next window. Staging it needs a task cancelled between two awaits, which is the
shape that makes a test pass or fail on scheduling; this repo has already paid for one of those.
The contract is identical to `JiraClient`'s and is stated in `SourceConnector.fetch`'s doc
comment.

---

### Task 1: Move the neutral Atlassian plumbing out of `Jira/`

**Files:**
- Move: `StenoKit/Integrations/AtlassianCredential.swift` → `StenoKit/Integrations/Atlassian/`
- Move: `StenoKit/Integrations/AtlassianTokenExpiry.swift` → `StenoKit/Integrations/Atlassian/`
- Move: `StenoKit/Integrations/Jira/ReadOnlyTransport.swift` → `StenoKit/Integrations/Atlassian/`
- Move + rename: `StenoKit/Integrations/Jira/JiraErrors.swift` →
  `StenoKit/Integrations/Atlassian/AtlassianErrors.swift` (type `JiraErrors` → `AtlassianErrors`)
- Create: `StenoKit/Integrations/Atlassian/AtlassianDate.swift` (extracted from `Jira/JiraWire.swift`,
  type `JiraDate` → `AtlassianDate`)
- Create: `StenoKit/Integrations/Atlassian/AtlassianCredentialCache.swift` (extracted from
  `Jira/JiraConnector.swift`)
- Create: `StenoKit/Integrations/Atlassian/AtlassianText.swift` (collapse + truncate, extracted
  from `Jira/AtlassianDocument.swift`)
- Modify: `StenoKit/Integrations/Jira/AtlassianDocument.swift` — delegate to `AtlassianText`
- Move: the matching test files into `StenoTests/Integrations/Atlassian/`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ReadOnlyTransport(wrapping:)` / `ReadOnlyTransport.isAllowed(_:) -> Bool`;
  `AtlassianErrors.error(forStatus:headers:) -> SourceError?` and
  `AtlassianErrors.error(forTransport:) -> SourceError`; `AtlassianDate.parse(_:) -> Date?`;
  `AtlassianCredentialCache.credential(now:fresh:read:) -> AtlassianCredential?`;
  `AtlassianText.gist(_:limit:) -> String`, `AtlassianText.limit: Int`.

- [ ] **Step 1: Move the files with `git mv`, so the diff reads as renames**

```bash
mkdir -p StenoKit/Integrations/Atlassian StenoTests/Integrations/Atlassian
git mv StenoKit/Integrations/AtlassianCredential.swift StenoKit/Integrations/Atlassian/
git mv StenoKit/Integrations/AtlassianTokenExpiry.swift StenoKit/Integrations/Atlassian/
git mv StenoKit/Integrations/Jira/ReadOnlyTransport.swift StenoKit/Integrations/Atlassian/
git mv StenoKit/Integrations/Jira/JiraErrors.swift StenoKit/Integrations/Atlassian/AtlassianErrors.swift
git mv StenoTests/Integrations/AtlassianCredentialTests.swift StenoTests/Integrations/Atlassian/
git mv StenoTests/Integrations/AtlassianTokenExpiryTests.swift StenoTests/Integrations/Atlassian/
git mv StenoTests/Integrations/Jira/ReadOnlyTransportTests.swift StenoTests/Integrations/Atlassian/
git mv StenoTests/Integrations/Jira/JiraErrorsTests.swift StenoTests/Integrations/Atlassian/AtlassianErrorsTests.swift
```

`project.yml` globs `StenoKit` and `StenoTests` by directory, so new folders need no manifest
change. Nothing else in the repo needs to know these moved.

- [ ] **Step 2: Rename the two types everywhere**

```bash
grep -rl "JiraDate\|JiraErrors" StenoKit StenoTests \
  | xargs sed -i '' 's/JiraDate/AtlassianDate/g; s/JiraErrors/AtlassianErrors/g'
```

- [ ] **Step 3: Extract `AtlassianDate` from `JiraWire.swift` into its own file**

Cut the `JiraDate` enum and its doc comment out of `StenoKit/Integrations/Jira/JiraWire.swift`
and write this file. The prose changes because the type is no longer Jira's:


```swift
import Foundation

/// Atlassian's timestamps, parsed. Shared by both APIs (D-202).
///
/// **Two formats, tried in order, because both APIs send the fractional-seconds
/// form and Foundation's default parser rejects it.** Jira's
/// `2026-09-25T18:04:11.123+0000` and Confluence's documented
/// `YYYY-MM-DDTHH:mm:ss.sssZ` both need
/// `.withFractionalSeconds`; a value without the fraction needs it absent, since the
/// option is a requirement rather than a permission. Getting this wrong does not
/// throw — it returns `nil`, and every timestamp silently becoming `nil` would leave
/// the watermark `nil` forever and the window permanently open.
enum AtlassianDate {
    /// `nil` for an absent or unparseable value.
    ///
    /// The formatters are built per call rather than held in a `static let`: an
    /// `ISO8601DateFormatter` is not `Sendable`, and D18's twenty tickets make the
    /// allocation irrelevant next to the request that fetched the string.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
```

- [ ] **Step 4: Extract `AtlassianCredentialCache` from `JiraConnector.swift` into its own file**

Cut the `AtlassianCredentialCache` class out of `StenoKit/Integrations/Jira/JiraConnector.swift`
unchanged — it was already named for the credential rather than for Jira — and give it this file:


```swift
import Foundation

/// A short-lived memo over one Keychain read.
///
/// **Thirty seconds, chosen against two failure modes.** Shorter than a refresh pass's own
/// budget would put several Keychain reads back into one pass, which is what this exists to
/// prevent; much longer would make a credential the user has just saved look absent.
///
/// **And it is told when it is wrong**, by observing `.stenoCredentialsDidChange`, which every
/// store that writes a credential posts. The first version of this comment said M4-04 "should
/// call `invalidate()`" — a method reachable only from a private property on a struct, so
/// nothing could have called it, and a credential saved while the app ran would have left
/// routing on a memoized `nil` for half a minute. `testConnection()` bypasses the memo besides,
/// so the button that matters is never answered from it. Raised by Copilot in review round 4 of
/// PR #43.
///
/// A `final class` with a lock because `JiraConnector` is a `Sendable` struct and four
/// fetches run concurrently: an unsynchronized memo would be a data race in the one place
/// that reads a secret.
final class AtlassianCredentialCache: @unchecked Sendable {
    static let ttl: TimeInterval = 30

    private let lock = NSLock()
    private var stored: (credential: AtlassianCredential?, readAt: Date)?

    /// The center the observer was registered on, kept so `deinit` removes it from **that**
    /// center rather than from `.default`.
    ///
    /// The first version stored only the token and unregistered from `.default`, which leaks the
    /// registration whenever a center is injected — every test in this bundle does. Raised by
    /// Copilot in review round 5 of PR #43.
    private let notifications: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(notifications: NotificationCenter = .default) {
        self.notifications = notifications
        // `nonisolated` queue so the memo is dropped wherever the write happened, and `weak`
        // so an observer cannot keep a connector alive past the app.
        observer = notifications.addObserver(
            forName: .stenoCredentialsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }

    /// The memoized credential, reading through `read` when the memo is cold, stale, or
    /// bypassed.
    ///
    /// **A `nil` result is memoized too.** "No credential" is the ordinary state of a
    /// machine nobody has configured, and re-reading the Keychain per ref to learn it again
    /// is exactly the cost being avoided.
    func credential(
        now: Date, fresh: Bool, read: () -> AtlassianCredential?
    ) -> AtlassianCredential? {
        lock.withLock {
            if !fresh, let stored, now.timeIntervalSince(stored.readAt) < Self.ttl {
                return stored.credential
            }
            let value = read()
            stored = (value, now)
            return value
        }
    }

    /// Drop the memo. Called by the observer above, and directly by tests.
    func invalidate() {
        lock.withLock { stored = nil }
    }
}
```

- [ ] **Step 5: Create `AtlassianText` with the rules `AtlassianDocument` kept private**

This is the one part of the move that is not mechanical, and it is the reason the move earns its
keep: `collapse` and `truncate` were `private` inside `AtlassianDocument`, so Jira comment bodies
got them and Confluence version messages — free text from the same kind of box — would not have.


```swift
import Foundation

/// Free text from a source, made safe to put in an event body (D-195, D-202).
///
/// **Two rules, and both are about the stand-up sheet rather than about Atlassian.**
/// A `SourceChange.text` becomes one line of a report a user reads aloud: a newline in
/// it silently becomes two lines, one of which has lost its subject, and an unbounded
/// one turns a stand-up into a paste of somebody's release notes.
///
/// Extracted from `AtlassianDocument`, which applied both to Jira comment bodies and
/// kept them private — so Confluence version messages, which are free text from the
/// same kind of box, arrived with neither. That is the shape D-202 exists to prevent,
/// found by asking which inputs the spec implies and no test covered.
enum AtlassianText {
    /// D-195's limit: enough to recognise what was said, short enough to read out.
    static let limit = 200

    /// `value` with its whitespace collapsed and its length bounded.
    static func gist(_ value: String, limit: Int = limit) -> String {
        truncate(collapse(value), to: limit)
    }

    /// Every run of whitespace — including newlines and tabs — becomes one space.
    static func collapse(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `value` at most `limit` characters, cut on a word boundary with an ellipsis.
    ///
    /// The ellipsis is one character and counts toward the limit, so the result never
    /// exceeds it.
    static func truncate(_ value: String, to limit: Int) -> String {
        guard value.count > limit, limit > 1 else {
            return value.count > limit ? String(value.prefix(limit)) : value
        }

        let head = value.prefix(limit - 1)
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "…" }
        let word = head[head.startIndex..<lastSpace]
        // A single word longer than the limit has no boundary to cut on, so the hard
        // cut is what is left.
        return word.isEmpty ? head + "…" : word + "…"
    }
}
```

- [ ] **Step 6: Point `AtlassianDocument` at the lifted rules and delete its private copies**

In `StenoKit/Integrations/Jira/AtlassianDocument.swift`, replace the body of `plainText` and the
`limit` constant, then delete the two private helpers:


```swift
    /// D-195's limit. Defined by `AtlassianText` now, so both connectors bound their
    /// free text at the same length.
    static let limit = AtlassianText.limit

    /// `node` as plain text, collapsed and truncated.
    ///
    /// Empty for a `nil` node or a document with no text in it — an image-only
    /// comment, say — which the caller treats as "no gist", not as a failure.
    static func plainText(_ node: ADFNode?, limit: Int = limit) -> String {
        guard let node else { return "" }
        // The collapse-and-truncate rules live in `AtlassianText` now: Confluence's
        // version messages are free text from the same kind of box and need both, and a
        // private copy here is how one caller got them and the other did not (D-202).
        return AtlassianText.gist(fragments(node).joined(), limit: limit)
    }
```

- [ ] **Step 7: Generalise the moved files' prose**

`ReadOnlyTransport` and `AtlassianErrors` still describe themselves as Jira's. Two things matter
here beyond tidiness: the trap's message reaches a crash log, and the `400 → .notFound` branch is
justified by Jira's behaviour and must be re-checked against Confluence rather than carried over.


```swift
/// A transport that refuses to be anything but read-only (D5, D-191).
///
/// **Shared by both Atlassian connectors** (D-202). D5 says "Jira/Confluence access,
/// read-only, permanently" — the rule was never Jira's, and Confluence is where a
/// second copy would have drifted first: its only account-id-to-name endpoint is a
/// `POST` that reads, which is exactly the request a connector-local allow-list talks
/// itself into permitting.
///
/// **A trap, not a thrown error.** A mutating request against Atlassian is not a network
/// condition to degrade around — §5.5's degradation exists for the network, and
/// turning this into a `SourceError` would make D5 a silent fallback that a caching
/// path would paper over. D5 is permanent and this is code that must not ship.
///
/// The rule is `isAllowed`, separately testable, because a test cannot survive the
/// trap itself: asserting the predicate is how "every request is a GET" stays
/// verified without a test process that dies to prove it.
```

The `400` branch, with both APIs now named in its justification:


```swift
        case 400:
            // **`.notFound`, not a generic failure.** Jira answers 400 for a
            // malformed issue key, and a malformed key is a mistyped reference in a
            // task title — which is exactly what `.notFound` tells the user, while
            // "the integration is unavailable" would send them to a status page over
            // a typo.
            //
            // **The same reading holds for Confluence**, which is why this branch is
            // shared rather than duplicated: a page id that is not a number is a
            // mangled reference, and `.notFound` is the sentence that helps there too.
            // Checked against both APIs when this moved, because a shared rule
            // justified by one caller's behaviour is how the next reader concludes it
            // does not apply to them.
            return .notFound
```

- [ ] **Step 8: Run the existing suite — it is the whole check for this task**

Run: `make build && make test && make lint`
Expected: all green, no test changes needed. This task adds no behaviour; the existing Jira suite
passing against `AtlassianErrors`, `AtlassianDate` and `AtlassianText` is what says the move was
faithful.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: move the neutral Atlassian plumbing out of Jira/ (D-202)"
```

Land this first and alone, so a reviewer can read the renames without the new connector mixed in.

---

### Task 2: `ConfluenceEndpoint` — every request, and the cursor rule

**Files:**
- Create: `StenoKit/Integrations/Confluence/ConfluenceEndpoint.swift`
- Test: `StenoTests/Integrations/Confluence/ConfluenceEndpointTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest(method:url:headers:body:)` from Task 1's neighbourhood (unchanged).
- Produces: `ConfluenceEndpoint` with cases `.page(id:)`, `.versions(pageID:cursor:limit:)`,
  `.user(accountID:)`, `.spaces(limit:)`; `request(base:authorization:) -> HTTPRequest?`;
  `static isValidPageID(_:) -> Bool`; `static cursor(inNext:) -> String?`;
  `static newestFirst: String`; `var pageID: String?`.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Integrations/Confluence/ConfluenceEndpointTests.swift`:


```swift
import Foundation
import Testing

@testable import StenoKit

/// D5, D-191 and D-205: the requests this connector can build, the one method it may
/// use, and the one thing it takes from a response that tells it where to go next.

private let site = URL(string: "https://acme.atlassian.net")

private func built(_ endpoint: ConfluenceEndpoint) throws -> HTTPRequest {
    let base = try #require(site)
    return try #require(endpoint.request(base: base, authorization: "Basic xyz"))
}

@Test(
    "D5: every Confluence endpoint builds a GET",
    arguments: [
        ConfluenceEndpoint.page(id: "12345"),
        .versions(pageID: "12345", cursor: nil, limit: 50),
        .versions(pageID: "12345", cursor: "eyJpZCI6NDJ9", limit: 50),
        .user(accountID: "557058:aa1b"),
        .spaces(limit: 1),
    ])
func everyConfluenceEndpointIsAGet(endpoint: ConfluenceEndpoint) throws {
    #expect(try built(endpoint).method == .get)
}

@Test("the content paths are v2's; the name lookup is the one v1 path (D-200, D-201)")
func confluencePathsAreV2ExceptTheUserLookup() throws {
    #expect(try built(.page(id: "12345")).url.path == "/wiki/api/v2/pages/12345")
    #expect(
        try built(.versions(pageID: "12345", cursor: nil, limit: 50)).url.path
            == "/wiki/api/v2/pages/12345/versions")
    #expect(try built(.spaces(limit: 1)).url.path == "/wiki/api/v2/spaces")
    #expect(try built(.user(accountID: "557058:aa1b")).url.path == "/wiki/rest/api/user")
}

@Test("§8: the page request never asks for a body")
func confluencePageRequestAsksForNoBody() throws {
    // `body-format` is what makes the API render a page's text into the response.
    // Not sending it is the whole of the §8 claim, so the assertion is that the
    // request carries no query at all — which also pins `include-version`'s default,
    // since the current version is what the summary is built from and nothing here
    // asks for it.
    #expect(try built(.page(id: "12345")).url.query == nil)
}

@Test("the version walk is sorted newest-first, and says so on every page")
func confluenceVersionsAreSortedNewestFirst() throws {
    let first = try built(.versions(pageID: "12345", cursor: nil, limit: 50))
    let items = try #require(
        URLComponents(url: first.url, resolvingAgainstBaseURL: false)?
            .queryItems)

    #expect(items.contains(URLQueryItem(name: "sort", value: "-modified-date")))
    #expect(items.contains(URLQueryItem(name: "limit", value: "50")))
    #expect(items.contains { $0.name == "cursor" } == false)

    // A resumed page keeps both: the cursor encodes position, not ordering, and a
    // walk that dropped `sort` would page the rest of the history ascending.
    let resumed = try built(.versions(pageID: "12345", cursor: "eyJpZCI6NDJ9", limit: 50))
    let resumedItems = try #require(
        URLComponents(url: resumed.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(resumedItems.contains(URLQueryItem(name: "sort", value: "-modified-date")))
    #expect(resumedItems.contains(URLQueryItem(name: "cursor", value: "eyJpZCI6NDJ9")))
}

@Test("the name lookup sends the account id")
func confluenceUserLookupSendsTheAccountID() throws {
    let request = try built(.user(accountID: "557058:aa1b"))
    let items = try #require(
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items == [URLQueryItem(name: "accountId", value: "557058:aa1b")])
}

@Test("D-205: only the cursor is taken out of `_links.next`")
func confluenceCursorIsExtractedFromNext() {
    let next = "/wiki/api/v2/pages/12345/versions?limit=50&sort=-modified-date&cursor=eyJpZCI6NDJ9"
    #expect(ConfluenceEndpoint.cursor(inNext: next) == "eyJpZCI6NDJ9")
}

@Test("D-205: a `next` pointing somewhere else cannot redirect the token")
func confluenceNextOnAnotherHostIsNotFollowed() throws {
    // The attack this rule exists for: every request carries HTTP Basic, so a `next`
    // naming another host would send the user's API token there. Only the cursor
    // survives parsing, and the rebuilt request goes to the configured site.
    let hostile = "https://evil.example.com/wiki/api/v2/pages/1/versions?cursor=stolen"
    let cursor = try #require(ConfluenceEndpoint.cursor(inNext: hostile))

    let request = try built(.versions(pageID: "12345", cursor: cursor, limit: 50))

    #expect(request.url.host() == "acme.atlassian.net")
    #expect(request.url.path == "/wiki/api/v2/pages/12345/versions")
    #expect(request.url.absoluteString.contains("evil.example.com") == false)
}

@Test(
    "a `next` with nothing to resume on ends the walk",
    arguments: [
        nil,
        "",
        "/wiki/api/v2/pages/12345/versions?limit=50",
        "/wiki/api/v2/pages/12345/versions?cursor=",
    ] as [String?])
func confluenceNextWithoutACursorEndsTheWalk(next: String?) {
    // Each of these would otherwise re-request the first page forever.
    #expect(ConfluenceEndpoint.cursor(inNext: next) == nil)
}

@Test(
    "a page id that is not a page id never reaches a URL",
    arguments: ["", "abc", "12 34", "12/34", "12345\u{200B}", "١٢٣", "-1", "12.0"])
func confluenceInvalidPageIDsAreRefusedLocally(id: String) throws {
    #expect(ConfluenceEndpoint.isValidPageID(id) == false)

    let base = try #require(site)
    #expect(ConfluenceEndpoint.page(id: id).request(base: base, authorization: "Basic xyz") == nil)
    #expect(
        ConfluenceEndpoint.versions(pageID: id, cursor: nil, limit: 50)
            .request(base: base, authorization: "Basic xyz") == nil)
}

@Test("a real page id is accepted")
func confluenceValidPageIDIsAccepted() throws {
    #expect(ConfluenceEndpoint.isValidPageID("12345"))
    #expect(ConfluenceEndpoint.isValidPageID("0"))
    #expect(try built(.page(id: "12345")).url.path.hasSuffix("/12345"))
}

@Test("the endpoints that address no page are built whatever the ids around them")
func confluenceEndpointsWithoutAPageIDAreAlwaysBuilt() throws {
    #expect(ConfluenceEndpoint.user(accountID: "557058:aa1b").pageID == nil)
    #expect(ConfluenceEndpoint.spaces(limit: 1).pageID == nil)
    #expect(try built(.spaces(limit: 1)).url.query == "limit=1")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ConfluenceEndpoint' in scope`.

- [ ] **Step 3: Write the implementation**


```swift
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
```

- [ ] **Step 4: Run the tests**

Run: `make test && make lint`
Expected: PASS, 0 violations.

- [ ] **Step 5: Mutation-check the five claims that matter**

Apply each, confirm `make test` exits non-zero, restore. All five were verified to be caught:

| Mutation | Test that must go red |
|---|---|
| `newestFirst = "modified-date"` (drop the `-`) | `the version walk is sorted newest-first…` |
| `cursor(inNext:)` returns `next` whole | both `D-205` tests |
| `isValidPageID` drops `$0.isASCII` | `a page id that is not a page id…` (parameterized — read the exit status, not the output) |
| `.page` sends `body-format=storage` | `§8: the page request never asks for a body` |
| a resumed page's items become `[cursor]` only | `the version walk is sorted newest-first…` |

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Integrations/Confluence/ConfluenceEndpoint.swift \
        StenoTests/Integrations/Confluence/ConfluenceEndpointTests.swift
git commit -m "feat: build every Confluence request in one place, and take only a cursor from a response (D-205)"
```

---

### Task 3: `ConfluenceWire` — the four response mirrors, and the fixtures

**Files:**
- Create: `StenoKit/Integrations/Confluence/ConfluenceWire.swift`
- Create: `StenoTests/Integrations/Confluence/ConfluenceFixture.swift`
- Test: `StenoTests/Integrations/Confluence/ConfluenceWireTests.swift`

**Interfaces:**
- Consumes: `AtlassianDate.parse(_:)` (Task 1), `ConfluenceEndpoint.cursor(inNext:)` (Task 2).
- Produces: `ConfluencePage` (`id`, `title`, `version`, `links.webui`), `ConfluenceVersion`
  (`number`, `createdAt`, `message`, `minorEdit`, `authorId`, computed `stamp`),
  `ConfluenceVersionPage` (`results`, `links.next`, `links.base`), `ConfluenceUser`
  (`displayName`), `ConfluenceSpacePage`. For tests: `ConfluenceFixture` and
  `StubConfluenceTransport(routes:users:fallback:)`.

- [ ] **Step 1: Write the fixtures**

These are the wire contract until `make verify-confluence` first runs, so build them from the
schema rather than from what the code wants. `users` is keyed by account id rather than queued in
order **because the name lookups run concurrently** — a shared queue would hand whichever child
task arrived first whichever answer happened to be next.


```swift
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

    /// Runs before a name lookup is answered, so a test can suspend the walk exactly
    /// where it wants to and act while it is held.
    private let onUserRequest: (@Sendable () async -> Void)?

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
        onUserRequest: (@Sendable () async -> Void)? = nil,
        fallback: Answer = .status(500)
    ) {
        self.routes = routes
        self.users = users
        self.versionsByCursor = versionsByCursor
        self.onUserRequest = onUserRequest
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
        if key == "user", let onUserRequest { await onUserRequest() }
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
```

- [ ] **Step 2: Write the failing tests**


```swift
import Foundation
import Testing

@testable import StenoKit

/// The wire contract, asserted against the recorded shapes (D-197).

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Test("a page carries its title, its current version, and a relative web URL")
func confluencePageDecodesItsCurrentVersion() throws {
    let page = try decode(ConfluencePage.self, ConfluenceFixture.page())

    #expect(page.id == "12345")
    #expect(page.title == "Payments Migration Plan")
    #expect(page.version?.number == 9)
    #expect(page.version?.authorId == ConfluenceFixture.leo)
    #expect(page.links?.webui == ConfluenceFixture.webui)
}

@Test("§8: a body in the response is not decoded, because nothing models it")
func confluencePageIgnoresABodyItNeverAskedFor() throws {
    // `body-format` is never sent, so this should not arrive — but a decoder that
    // choked on an unmodelled field would turn a surprise into a failed fetch, and a
    // mirror that modelled it would put the page's text in memory. Both are wrong;
    // this pins the middle.
    let withBody = """
        {"id":"12345","title":"T","body":{"storage":{"value":"<p>secret</p>","representation":"storage"}}}
        """
    let page = try decode(ConfluencePage.self, withBody)

    #expect(page.title == "T")
    #expect(Mirror(reflecting: page).children.contains { $0.label == "body" } == false)
}

@Test("every field is optional, so one missing value costs only itself")
func confluencePageSurvivesMissingFields() throws {
    let page = try decode(ConfluencePage.self, "{}")

    #expect(page.id == nil)
    #expect(page.title == nil)
    #expect(page.version == nil)
    #expect(page.links == nil)
}

@Test("a version carries the five fields the schema documents")
func confluenceVersionDecodesItsFiveFields() throws {
    let raw = ConfluenceFixture.version(
        number: 7, createdAt: "2026-09-25T18:04:11.123Z", message: "tightened the migration steps",
        minorEdit: true, authorID: ConfluenceFixture.priya)
    let version = try decode(ConfluenceVersion.self, raw)

    #expect(version.number == 7)
    #expect(version.message == "tightened the migration steps")
    #expect(version.minorEdit == true)
    #expect(version.authorId == ConfluenceFixture.priya)
    #expect(version.stamp == AtlassianDate.parse("2026-09-25T18:04:11.123Z"))
}

@Test("a version with an unreadable timestamp decodes, and says so with nil")
func confluenceVersionWithBadTimestampStillDecodes() throws {
    let version = try decode(
        ConfluenceVersion.self, #"{"number":7,"createdAt":"last Tuesday"}"#)

    // It must decode — §5.5 degrades rather than failing a fetch over one field — and
    // `stamp` must be nil rather than some default date, because a default would place
    // an unplaceable version inside or outside the window by accident.
    #expect(version.number == 7)
    #expect(version.stamp == nil)
}

@Test("Z and +0000 are the same instant, so both forms window identically")
func confluenceVersionAcceptsBothOffsetForms() throws {
    // Confluence documents `YYYY-MM-DDTHH:mm:ss.sssZ` while Jira sends `+0000`. They
    // share a parser now (D-202), and this is what says the sharing is sound.
    let zulu = try decode(ConfluenceVersion.self, #"{"createdAt":"2026-09-25T18:04:11.000Z"}"#)
    let offset = try decode(
        ConfluenceVersion.self, #"{"createdAt":"2026-09-25T18:04:11.000+0000"}"#)

    #expect(zulu.stamp != nil)
    #expect(zulu.stamp == offset.stamp)
}

@Test("a versions page carries its results and the cursor to resume on")
func confluenceVersionPageDecodesResultsAndNext() throws {
    let body = ConfluenceFixture.versions(
        [ConfluenceFixture.version(number: 9), ConfluenceFixture.version(number: 8)],
        next: ConfluenceFixture.next(cursor: "eyJpZCI6NDJ9"))
    let page = try decode(ConfluenceVersionPage.self, body)

    #expect(page.results?.count == 2)
    #expect(page.results?.first?.number == 9)
    #expect(ConfluenceEndpoint.cursor(inNext: page.links?.next) == "eyJpZCI6NDJ9")
}

@Test("an absent `next` is how the API says the walk is over")
func confluenceVersionPageWithoutNextEndsTheWalk() throws {
    let page = try decode(
        ConfluenceVersionPage.self, ConfluenceFixture.versions([ConfluenceFixture.version()]))

    #expect(page.links?.next == nil)
    #expect(ConfluenceEndpoint.cursor(inNext: page.links?.next) == nil)
}

@Test("the user lookup reads a display name and nothing else")
func confluenceUserDecodesOnlyTheDisplayName() throws {
    // The real response also carries an email address, a time zone, a personal space
    // and a permissions block. §8 is kept by not modelling them: whatever arrives,
    // only this one field is decoded.
    let rich = """
        {"accountId":"557058:aa1b","displayName":"Leo Gutierrez","email":"leo@example.com",
         "timeZone":"America/Denver","personalSpace":{"key":"~leo"}}
        """
    let user = try decode(ConfluenceUser.self, rich)

    #expect(user.displayName == "Leo Gutierrez")
    #expect(Mirror(reflecting: user).children.map(\.label) == ["displayName"])
}

@Test("an account with no visible space is still a working credential")
func confluenceSpacesDecodesAnEmptyResult() throws {
    let page = try decode(ConfluenceSpacePage.self, ConfluenceFixture.spaces(count: 0))

    #expect(page.results?.isEmpty == true)
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ConfluencePage' in scope`.

- [ ] **Step 4: Write the implementation**


```swift
import Foundation

/// `Decodable` mirrors of the four responses this connector reads.
///
/// **Every field is optional, including ones the API documents as required**, for the
/// reason `JiraWire` states: §5.5's job is to degrade, and one missing `displayName`
/// must cost that editor's name rather than the whole fetch — which is what a
/// non-optional field would do, because one `keyNotFound` fails the entire decode.
///
/// The shapes are taken from Atlassian's own OpenAPI document
/// (`openapi-v2.v3.json`, `info.version` 2.0.0, verified 2026-09-29), and only what is
/// read is modelled. Notably absent: `body`. `ConfluenceEndpoint.page` never sends
/// `body-format`, so a page's text is not asked for — and it could not be decoded here
/// if it arrived anyway (§8).

/// `GET /wiki/api/v2/pages/{id}`.
struct ConfluencePage: Decodable, Equatable {
    let id: String?
    let title: String?

    /// The current version, which arrives because `include-version` defaults to `true`.
    let version: ConfluenceVersion?

    let links: Links?

    /// `AbstractPageLinks`: `webui`, `editui`, `tinyui` — **and no `base`**, which a
    /// versions page's `_links` does have. That asymmetry is why `SourceUpdate.url` is
    /// built from the credential's own host rather than from the response.
    struct Links: Decodable, Equatable {
        /// Relative, and rooted at the Confluence site rather than the Cloud host:
        /// `/spaces/ENG/pages/12345/Payments+Migration+Plan`.
        let webui: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, version
        case links = "_links"
    }
}

/// `Version` in the v2 schema — the same object whether it arrives on a page or in a
/// versions list. It carries these five fields and nothing else.
struct ConfluenceVersion: Decodable, Equatable {
    /// The version number, which is the delta's dedup key (D-203).
    let number: Int?

    /// When this version was published, `"YYYY-MM-DDTHH:mm:ss.sssZ"`. The watermark
    /// source, and the only timestamp §5.3's "last-modified" can mean.
    let createdAt: String?

    /// What the editor typed in "What did you change?", when they typed anything.
    let message: String?

    /// Confluence's "don't notify watchers" checkbox. Reported, not filtered (D-203).
    let minorEdit: Bool?

    /// **An account id, not a name.** Resolving it is a second request (D-201).
    let authorId: String?

    /// `createdAt` as a `Date`, or `nil` when it is absent or unparseable.
    var stamp: Date? { AtlassianDate.parse(createdAt) }
}

/// `MultiEntityResult<Version>` from `GET /wiki/api/v2/pages/{id}/versions`.
struct ConfluenceVersionPage: Decodable, Equatable {
    let results: [ConfluenceVersion]?
    let links: Links?

    /// `MultiEntityLinks`.
    struct Links: Decodable, Equatable {
        /// *"The relative URL for the next set of results, using a cursor query
        /// parameter. This property will not be present if there is no additional data
        /// available."* — which is how the walk learns it is over.
        ///
        /// **Never sent as-is** (D-205): `ConfluenceEndpoint.cursor(inNext:)` takes the
        /// cursor out of it and the request is rebuilt against the configured host.
        let next: String?

        /// Base URL of the Confluence site. Present here, absent on a single page's
        /// links, and unused: the app knows its own site from the credential, and a
        /// base URL taken from a response is a base URL a response can change.
        let base: String?
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case links = "_links"
    }
}

/// `GET /wiki/rest/api/user?accountId=…`, reduced to the one field D-201 wants.
///
/// The real response also carries an email address, a time zone, a personal space and a
/// permissions block. None of it is modelled, so none of it is decoded or retained
/// (§8).
struct ConfluenceUser: Decodable, Equatable {
    let displayName: String?
}

/// `GET /wiki/api/v2/spaces?limit=1`, for `testConnection()` only.
///
/// **The body is not read for content, only for shape.** An account with no visible
/// space answers `{"results": []}`, which is a 200 and therefore a working credential —
/// FR-6 asks whether the integration is reachable and authorised, not whether the user
/// can see anything in particular.
struct ConfluenceSpacePage: Decodable, Equatable {
    let results: [Space]?

    struct Space: Decodable, Equatable {
        let id: String?
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 6: Mutation-check**

| Mutation | Test that must go red |
|---|---|
| `case links = "_links"` → `case links` on `ConfluencePage` | `a page carries its title…` |
| the same on `ConfluenceVersionPage` | `a versions page carries its results…` |
| `stamp` returns `?? Date()` | `a version with an unreadable timestamp…` |
| add `let email: String?` to `ConfluenceUser` | `the user lookup reads a display name and nothing else` |

That last one is why the `Mirror` assertions are there: §8 is kept by *not modelling* a field, and
a `Mirror` over declared properties is what makes adding one a red test rather than a quiet leak.

- [ ] **Step 7: Commit**

```bash
git add StenoKit/Integrations/Confluence/ConfluenceWire.swift StenoTests/Integrations/Confluence/
git commit -m "feat: mirror the four Confluence responses, modelling only what is read"
```

---
### Task 4: `ConfluenceChangeSet` — the delta, the summary, the watermark

**Files:**
- Create: `StenoKit/Integrations/Confluence/ConfluenceChangeSet.swift`
- Test: `StenoTests/Integrations/Confluence/ConfluenceChangeSetTests.swift`

**Interfaces:**
- Consumes: `ConfluencePage`, `ConfluenceVersion` (Task 3); `SourceChange(id:text:)`;
  `AtlassianText.gist(_:)` (Task 1).
- Produces: `ConfluenceChangeSet.make(page:versions:names:since:isCapped:) -> ConfluenceChangeSet`
  with `summary: String`, `changes: [SourceChange]`, `watermark: Date?`, `isWindowCapped: Bool`,
  `webui: String?`. `names` is `[accountID: displayName]`.

This is the only pure type in the connector — no network, no store, no clock — which is what lets
every window and watermark judgment be a table test.

- [ ] **Step 1: Write the failing tests**

Note two deliberate shapes. The delta test's **input order disagrees with its expected order**,
because a test whose input already matched would pass against an implementation that sorted,
reversed, or did nothing. And the summary table is a `private struct` rather than a 4-tuple —
`make lint --strict` caps a tuple at two members — which forces the `@Test` function to be
`private` too.


```swift
import Foundation
import Testing

@testable import StenoKit

/// The pure core: what counts as news, what the summary says, and where the next
/// window starts (§5.3, D-203, D-184, D-188).

private let names = ConfluenceFixture.names

/// A version, built directly rather than decoded — these are table tests about
/// judgment, not about the wire.
private func aVersion(
    _ number: Int?,
    at createdAt: String?,
    message: String? = nil,
    minorEdit: Bool = false,
    by authorID: String? = ConfluenceFixture.leo
) -> ConfluenceVersion {
    ConfluenceVersion(
        number: number, createdAt: createdAt, message: message, minorEdit: minorEdit,
        authorId: authorID)
}

private func aPage(
    title: String? = "Payments Migration Plan",
    version: ConfluenceVersion? = nil,
    webui: String? = ConfluenceFixture.webui
) -> ConfluencePage {
    ConfluencePage(
        id: ConfluenceFixture.pageID, title: title, version: version,
        links: ConfluencePage.Links(webui: webui))
}

private func make(
    page: ConfluencePage = aPage(),
    versions: [ConfluenceVersion] = [],
    since: Date? = ConfluenceFixture.windowStart,
    isCapped: Bool = false
) -> ConfluenceChangeSet {
    ConfluenceChangeSet.make(
        page: page, pageID: ConfluenceFixture.pageID, versions: versions, names: names,
        since: since, isCapped: isCapped)
}

// MARK: - Summary

@Test("§5.3: the summary is title, current version, and last editor")
func confluenceSummaryNamesTheVersionAndEditor() {
    let set = make(page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)))

    #expect(set.summary == "Payments Migration Plan — v9, edited by Leo Gutierrez")
}

@Test("D-176: no timestamp is baked into the stored summary")
func confluenceSummaryCarriesNoTimestamp() {
    // The cached summary outlives the fetch that wrote it. "edited 2h ago" would be
    // wrong one second later, and the staleness banner is what says how old the data
    // is.
    let set = make(page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)))

    #expect(set.summary.contains("2026") == false)
    #expect(set.summary.contains("ago") == false)
}

/// One row of the summary table. A struct rather than a 4-tuple because
/// `make lint --strict` caps a tuple at two members — and it reads better besides.
private struct SummaryCase {
    let title: String?
    let number: Int?
    let authorID: String?
    let expected: String
}

@Test(
    "a missing part is omitted, never rendered as the word unknown",
    arguments: [
        SummaryCase(
            title: nil, number: 9, authorID: ConfluenceFixture.leo,
            expected: "v9, edited by Leo Gutierrez"),
        SummaryCase(
            title: "Payments Migration Plan", number: nil, authorID: ConfluenceFixture.leo,
            expected: "Payments Migration Plan"),
        SummaryCase(
            title: "Payments Migration Plan", number: 9, authorID: "557058:nobody",
            expected: "Payments Migration Plan — v9"),
        SummaryCase(
            title: "Payments Migration Plan", number: nil, authorID: nil,
            expected: "Payments Migration Plan"),
    ])
private func confluenceSummaryOmitsWhatItCannotSay(testCase: SummaryCase) {
    let version = testCase.number.map {
        aVersion($0, at: ConfluenceFixture.inWindow, by: testCase.authorID)
    }
    let set = make(page: aPage(title: testCase.title, version: version))

    #expect(set.summary == testCase.expected)
}

@Test("a page with no title and no readable version still produces a string")
func confluenceSummaryIsEmptyRatherThanWrong() {
    let set = make(page: aPage(title: nil, version: nil))

    #expect(set.summary.isEmpty)
}

// MARK: - The delta

@Test("D-203: one line per version, keyed by page and version number")
func confluenceReportsOneChangePerVersion() {
    // **Input order disagrees with the expected order on purpose.** Versions arrive
    // newest-first, and a test whose input already matched its expectation would pass
    // against an implementation that sorted, reversed, or did nothing at all.
    let set = make(versions: [
        aVersion(9, at: "2026-09-25T18:04:11.000Z", message: "final pass"),
        aVersion(8, at: "2026-09-24T10:00:00.000Z", by: ConfluenceFixture.priya),
        aVersion(7, at: "2026-09-23T09:00:00.000Z", minorEdit: true),
    ])

    #expect(set.changes.map(\.id) == ["12345#v9", "12345#v8", "12345#v7"])
    #expect(
        set.changes.map(\.text) == [
            "v9 by Leo Gutierrez: final pass",
            "v8 by Priya Anand",
            "v7 by Leo Gutierrez (minor)",
        ])
}

@Test("D-201: an editor who could not be named is \"someone\", not an account id")
func confluenceUnresolvedEditorReadsAsSomeone() {
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow, by: "557058:nobody")])

    #expect(set.changes.first?.text == "v9 by someone")
    #expect(set.changes.first?.text.contains("557058") == false)
}

@Test("a deactivated account's blank name is not a name")
func confluenceBlankDisplayNameReadsAsSomeone() {
    // Confluence answers a deactivated account with an empty `displayName`, and
    // "edited by " is not a sentence.
    let set = ConfluenceChangeSet.make(
        page: aPage(), pageID: ConfluenceFixture.pageID,
        versions: [aVersion(9, at: ConfluenceFixture.inWindow)],
        names: [ConfluenceFixture.leo: "   "], since: ConfluenceFixture.windowStart)

    #expect(set.changes.first?.text == "v9 by someone")
}

@Test("D-203: a minor edit is labelled, never dropped")
func confluenceMinorEditIsLabelledNotDropped() {
    let set = make(versions: [
        aVersion(9, at: ConfluenceFixture.inWindow, message: "typo", minorEdit: true)
    ])

    #expect(set.changes.count == 1)
    #expect(set.changes.first?.text == "v9 by Leo Gutierrez (minor): typo")
}

@Test("a version with no number has no stable key, so it is not reported")
func confluenceVersionWithoutANumberIsSkipped() {
    // Reported, it would arrive under a key that cannot de-duplicate, and every pass
    // would say it again.
    let set = make(versions: [aVersion(nil, at: ConfluenceFixture.inWindow)])

    #expect(set.changes.isEmpty)
}

// MARK: - The window

@Test("a version at exactly `since` is inside the window; a second earlier is not")
func confluenceWindowIncludesItsOwnBoundary() {
    let boundary = "2026-09-22T00:00:00.000Z"
    let justBefore = "2026-09-21T23:59:59.000Z"

    let set = make(versions: [aVersion(9, at: boundary), aVersion(8, at: justBefore)])

    #expect(set.changes.map(\.id) == ["12345#v9"])
}

@Test("D-188: with no anchor, everything read is reported and the service suppresses")
func confluenceFirstObservationReportsWhatItSaw() {
    // Filtering here as well would leave the ids unrecorded, and the next pass — whose
    // window deliberately overlaps — would find them again and call them news.
    let set = make(
        versions: [
            aVersion(9, at: ConfluenceFixture.inWindow),
            aVersion(1, at: "2019-01-01T00:00:00.000Z"),
        ],
        since: nil)

    #expect(set.changes.count == 2)
}

@Test("a version whose timestamp will not parse is reported rather than lost")
func confluenceUnparseableTimestampIsReported() {
    let set = make(versions: [aVersion(9, at: "last Tuesday"), aVersion(8, at: nil)])

    // It cannot be placed in the window, and the safe direction is to say it: dedup
    // stops it being said twice, while dropping it would lose a real edit to a
    // date-format change.
    #expect(set.changes.map(\.id) == ["12345#v9", "12345#v8"])
}

// MARK: - Watermark

@Test("D-184: the watermark is the newest thing seen, not the newest thing said")
func confluenceWatermarkCoversWhatWasNotReported() {
    let newest = "2026-09-25T18:04:11.000Z"
    let set = make(
        versions: [aVersion(9, at: newest), aVersion(8, at: ConfluenceFixture.outOfWindow)])

    // v8 is outside the window and goes unreported; the watermark still moves past it,
    // or the next pass would re-read the same history forever.
    #expect(set.changes.count == 1)
    #expect(set.watermark == AtlassianDate.parse(newest))
}

@Test("the page's own version anchors a walk that came back empty")
func confluenceWatermarkFallsBackToTheCurrentVersion() {
    let set = make(page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)), versions: [])

    #expect(set.watermark == AtlassianDate.parse(ConfluenceFixture.inWindow))
}

@Test("with nothing timestamped anywhere, the window stays open")
func confluenceWatermarkIsNilWhenNothingIsTimestamped() {
    let set = make(page: aPage(version: nil), versions: [aVersion(9, at: nil)])

    #expect(set.watermark == nil)
}

@Test("a capped walk reports the floor it reached, not the newest it saw")
func confluenceCappedWalkHoldsTheWatermarkAtItsFloor() {
    let newest = "2026-09-25T18:04:11.000Z"
    let floor = "2026-09-24T10:00:00.000Z"
    let set = make(
        page: aPage(version: aVersion(9, at: newest)),
        versions: [aVersion(9, at: newest), aVersion(8, at: floor)],
        isCapped: true)

    // Coverage is complete only above `floor`; claiming `newest` would close over the
    // versions the cap left unread, and the next pass starts from the watermark.
    #expect(set.watermark == AtlassianDate.parse(floor))
    #expect(set.isWindowCapped)
}

@Test("the capped floor never rises above the newest thing actually seen")
func confluenceCappedFloorCannotExceedWhatWasSeen() {
    // A floor above the newest observation would mean claiming coverage of a region
    // nothing was read from.
    let set = make(
        page: aPage(version: aVersion(9, at: "2030-01-01T00:00:00.000Z")),
        versions: [aVersion(8, at: "2026-09-24T10:00:00.000Z")],
        isCapped: true)

    #expect(set.watermark == AtlassianDate.parse("2026-09-24T10:00:00.000Z"))
}

@Test("a capped walk that read nothing has no anchor to offer")
func confluenceCappedWalkWithNothingReadHasNoWatermark() {
    let set = make(
        page: aPage(version: aVersion(9, at: ConfluenceFixture.inWindow)), versions: [],
        isCapped: true)

    #expect(set.watermark == nil)
}

@Test("an uncapped set says so, which is what the payload records")
func confluenceUncappedSetIsNotFlagged() {
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow)])

    #expect(set.isWindowCapped == false)
}

// MARK: - Free text from a box the editor can type anything into

@Test("a version message with newlines stays one line of a stand-up")
func confluenceMessageNewlinesAreCollapsed() {
    // The change text becomes one line of a report the user reads aloud. A newline in
    // it silently becomes two lines, the second having lost its subject.
    let set = make(versions: [
        aVersion(
            9, at: ConfluenceFixture.inWindow,
            message: "rewrote the rollback steps\n\n- drain the queue\n- flip the flag")
    ])

    let text = try? #require(set.changes.first?.text)
    #expect(text?.contains("\n") == false)
    #expect(
        text
            == "v9 by Leo Gutierrez: rewrote the rollback steps - drain the queue - flip the flag")
}

@Test("D-195's limit applies to a version message too, not only to a Jira comment")
func confluenceLongMessageIsTruncated() {
    // Without this a stand-up line is whatever length somebody's release notes were.
    let long = String(repeating: "migration ", count: 60)
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow, message: long)])

    let text = try? #require(set.changes.first?.text)
    #expect((text?.count ?? 0) <= AtlassianText.limit + "v9 by Leo Gutierrez: ".count)
    #expect(text?.hasSuffix("…") == true)
}

@Test("a message of nothing but whitespace is no message at all")
func confluenceWhitespaceOnlyMessageIsOmitted() {
    let set = make(versions: [aVersion(9, at: ConfluenceFixture.inWindow, message: "  \n\t ")])

    #expect(set.changes.first?.text == "v9 by Leo Gutierrez")
}

@Test("the change id uses the requested page id, not the one the response carried")
func confluenceChangeIDIsStableWhenTheResponseOmitsItsID() {
    // `ConfluencePage.id` is optional like every wire field. Keyed on it, one response
    // gives `#v9` and the next gives `12345#v9` — two ids for one version, which walks
    // straight past the event log's de-duplication and reports the edit a second time.
    let withoutID = ConfluencePage(
        id: nil, title: "Payments Migration Plan", version: nil, links: nil)

    let set = ConfluenceChangeSet.make(
        page: withoutID, pageID: ConfluenceFixture.pageID,
        versions: [aVersion(9, at: ConfluenceFixture.inWindow)], names: names,
        since: ConfluenceFixture.windowStart)

    #expect(set.changes.map(\.id) == ["12345#v9"])
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ConfluenceChangeSet' in scope`.

- [ ] **Step 3: Write the implementation**


```swift
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
    ///   - isCapped: **the walk ended before the end of the window, for any reason** — the
    ///     page cap, a cursor that did not advance, or a `next` with no usable cursor
    ///     (D-208, D-212, D-213). The parameter is not only about the page cap, and reading
    ///     it that way is how two log lines came to say so wrongly.
    ///
    ///     The watermark is then the oldest point from which coverage *is* complete, which
    ///     keeps the fetch from claiming coverage it did not achieve. **That is all it
    ///     does.** It does not keep the unread gap reachable: the next pass walks from the
    ///     newest end and stops in the same place, and closing that needs a persisted
    ///     cursor (D-208). A caller inferring continuation from this flag would be wrong.
    ///   - pageID: **the id that was requested**, not the one the response carried.
    ///     `ConfluencePage.id` is optional like every other wire field, and a change id
    ///     keyed on it would be `#v9` for a response that omitted it and `12345#v9` for
    ///     one that did not — two ids for one version, which walks straight past the
    ///     event log's de-duplication and reports the edit again. The requested id is
    ///     authoritative and always present, so it is what the key is built from.
    ///     Raised by Copilot in review of PR #44.
    static func make(
        page: ConfluencePage,
        pageID: String,
        versions: [ConfluenceVersion],
        names: [String: String],
        since: Date?,
        isCapped: Bool = false
    ) -> ConfluenceChangeSet {
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
```

- [ ] **Step 4: Run the tests**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 5: Mutation-check — ten of them, because this is where the judgments live**

| Mutation | Test that must go red |
|---|---|
| `stamp < since` → `stamp <= since` | `a version at exactly `since` is inside the window…` |
| the same guard becomes `guard let stamp … else { return nil }` | `a version whose timestamp will not parse is reported rather than lost` |
| `minor` is always `""` | `D-203: a minor edit is labelled, never dropped` |
| capped watermark returns `newest` | `a capped walk reports the floor it reached…` |
| `walked` becomes empty | `D-184: the watermark is the newest thing seen…` |
| unresolved editor falls back to `authorId` | `D-201: an editor who could not be named is "someone"…` |
| blank `displayName` accepted | `a deactivated account's blank name is not a name` |
| id drops `#v\(number)` | `D-203: one line per version…` |
| summary renders a missing editor as "unknown" | the summary table (parameterized — exit status) |
| `AtlassianText.gist` → `trimmingCharacters` | the newline and length tests |

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Integrations/Confluence/ConfluenceChangeSet.swift \
        StenoTests/Integrations/Confluence/ConfluenceChangeSetTests.swift
git commit -m "feat: turn Confluence versions into a delta, a summary and a watermark"
```

---

### Task 5: `ConfluenceClient` — cursor paging, bounded names, D-206

**Files:**
- Create: `StenoKit/Integrations/Confluence/ConfluenceClient.swift`
- Test: `StenoTests/Integrations/Confluence/ConfluenceClientTests.swift`
- Test: `StenoTests/Integrations/Atlassian/CancelledWalkTests.swift` — D-207, for **both**
  connectors, in one file because the rule and the defect are shared
- Test: `StenoTests/Integrations/Confluence/ConfluenceClientPagingTests.swift` — the walk's own
  file, split for the reason `JiraClientPagingTests` is: `make lint` caps a file at 400 lines

**Interfaces:**
- Consumes: `ConfluenceEndpoint` (Task 2), the wire types (Task 3),
  `ConfluenceChangeSet.make(…)` (Task 4), `ReadOnlyTransport`, `AtlassianErrors` (Task 1),
  `AtlassianCredential.baseURL` / `.basicAuthorization`.
- Produces: `ConfluenceClient(transport:)`;
  `changeSet(pageID:since:credential:) async throws -> ConfluenceChangeSet`;
  `verify(credential:) async throws`; `static versionPageSize`, `maxPages`, `maxNameLookups`.

- [ ] **Step 1: Write the failing tests**


```swift
import Foundation
import Testing

@testable import StenoKit

/// The walk, the names, and the failures (§5.3, §5.5, D-201, D-205, D-206).

private typealias Answer = StubConfluenceTransport.Answer

private func client(_ transport: StubConfluenceTransport) -> ConfluenceClient {
    ConfluenceClient(transport: transport)
}

private func changeSet(
    _ transport: StubConfluenceTransport, since: Date? = ConfluenceFixture.windowStart
) async throws -> ConfluenceChangeSet {
    try await client(transport).changeSet(
        pageID: ConfluenceFixture.pageID, since: since, credential: ConfluenceFixture.credential())
}

/// The two names every fixture editor resolves to, answered by account id.
private let knownUsers: [String: Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez")),
    ConfluenceFixture.priya: .ok(ConfluenceFixture.user(displayName: "Priya Anand")),
]

// MARK: - Read-only

@Test("D5: a whole Confluence fetch issues only GETs")
func confluenceFetchIssuesOnlyGets() async throws {
    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(), users: knownUsers)

    _ = try await changeSet(transport)

    let methods = await transport.methods
    #expect(methods.isEmpty == false)
    #expect(methods.allSatisfy { $0 == .get })
}

// MARK: - Names

@Test("D-201: one lookup per distinct account, however many versions they wrote")
func confluenceResolvesEachAccountOnce() async throws {
    let versions = ConfluenceFixture.versions([
        ConfluenceFixture.version(
            number: 9, createdAt: ConfluenceFixture.inWindow, authorID: ConfluenceFixture.leo),
        ConfluenceFixture.version(
            number: 8, createdAt: ConfluenceFixture.inWindow, authorID: ConfluenceFixture.priya),
        ConfluenceFixture.version(
            number: 7, createdAt: ConfluenceFixture.inWindow, authorID: ConfluenceFixture.leo),
    ])
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": [.ok(versions)]],
        users: knownUsers)

    let set = try await changeSet(transport)

    let counts = await transport.callCounts
    #expect(counts["user"] == 2)
    #expect(
        set.changes.map(\.text) == [
            "v9 by Leo Gutierrez", "v8 by Priya Anand", "v7 by Leo Gutierrez",
        ])
}

@Test("D-201: the lookups are bounded, and the newest editors are the ones named")
func confluenceNameLookupsAreBounded() async throws {
    // Twelve distinct editors inside one window is not the ordinary case — it is the
    // pathological one the bound exists for, so that one page cannot spend a refresh
    // pass's budget on name lookups.
    let editors = (0..<12).map { "557058:editor-\($0)" }
    let versions = ConfluenceFixture.versions(
        editors.enumerated().map { index, id in
            ConfluenceFixture.version(
                number: 100 - index, createdAt: ConfluenceFixture.inWindow, authorID: id)
        })
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": [.ok(versions)]],
        users: Dictionary(
            uniqueKeysWithValues: editors.map { id in
                (id, Answer.ok(ConfluenceFixture.user(displayName: "Editor \(id.suffix(1))")))
            }))

    let set = try await changeSet(transport)

    let counts = await transport.callCounts
    #expect(counts["user"] == ConfluenceClient.maxNameLookups)

    // The ids are walked newest-first, so the versions that keep their editor are the
    // most recent ones — not whichever the hasher happened to favour.
    #expect(set.changes.first?.text == "v100 by Editor 0")
    #expect(set.changes.last?.text == "v89 by someone")
}

@Test("D-201: a name lookup that fails costs a name, not the fetch")
func confluenceFailedNameLookupDoesNotFailTheFetch() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [.ok(ConfluenceFixture.page())],
            "versions": [
                .ok(
                    ConfluenceFixture.versions([
                        ConfluenceFixture.version(
                            number: 9, createdAt: ConfluenceFixture.inWindow)
                    ]))
            ],
        ],
        users: [ConfluenceFixture.leo: .status(404)])

    let set = try await changeSet(transport)

    #expect(set.changes.first?.text == "v9 by someone")
}

@Test("the page's own editor is named too, not only the versions'")
func confluencePageEditorIsResolved() async throws {
    let transport = StubConfluenceTransport(
        routes: [
            "page": [
                .ok(
                    ConfluenceFixture.page(
                        currentVersion: ConfluenceFixture.version(
                            number: 9, createdAt: ConfluenceFixture.inWindow,
                            authorID: ConfluenceFixture.priya)))
            ],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ], users: knownUsers)

    let set = try await changeSet(transport)

    #expect(set.summary == "Payments Migration Plan — v9, edited by Priya Anand")
}

// MARK: - Failures

@Test("D-206: a failed version walk fails the ref rather than reporting no changes")
func confluenceFailedVersionWalkThrows() async throws {
    // Reported as an empty delta, this would advance the watermark past changes that
    // were never read — and the next pass would start after them. The news would not be
    // delayed; it would be gone.
    let transport = StubConfluenceTransport(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": [.status(503)]],
        users: knownUsers)

    await #expect(throws: SourceError.unavailable(status: 503)) {
        _ = try await changeSet(transport)
    }
}

@Test("a failed page read fails the ref, and its error is the one that escapes")
func confluenceFailedPageReadThrowsItsOwnError() async throws {
    // Both requests fail; the page's error is the one that describes the ref.
    let transport = StubConfluenceTransport(
        routes: ["page": [.status(404)], "versions": [.status(503)]], users: knownUsers)

    await #expect(throws: SourceError.notFound) {
        _ = try await changeSet(transport)
    }
}

@Test(
    "§5.2's status vocabulary reaches Confluence unchanged",
    arguments: [
        (401, SourceError.credentialExpired),
        (403, SourceError.invalidCredential),
        (404, SourceError.notFound),
        (500, SourceError.unavailable(status: 500)),
    ])
func confluenceStatusesMapToSourceErrors(status: Int, expected: SourceError) async throws {
    let transport = StubConfluenceTransport(routes: ["page": [.status(status)]])

    await #expect(throws: expected) {
        _ = try await changeSet(transport)
    }
}

@Test("a body that will not decode is an invalid response, not a network failure")
func confluenceUndecodableBodyIsInvalidResponse() async throws {
    let transport = StubConfluenceTransport(routes: ["page": [.ok("not json at all")]])

    await #expect(throws: SourceError.invalidResponse) {
        _ = try await changeSet(transport)
    }
}

@Test("a page id that is not a page id never leaves the process")
func confluenceInvalidPageIDNeverReachesTheNetwork() async throws {
    let transport = StubConfluenceTransport(routes: ConfluenceFixture.quietRoutes())

    await #expect(throws: SourceError.notFound) {
        _ = try await client(transport).changeSet(
            pageID: "not-a-page", since: nil, credential: ConfluenceFixture.credential())
    }

    let received = await transport.received
    #expect(received.isEmpty)
}

// MARK: - testConnection

@Test("FR-6: the connection test reads spaces, and an empty result still passes")
func confluenceVerifyPassesOnAnEmptySpaceList() async throws {
    let transport = StubConfluenceTransport(routes: [
        "spaces": [.ok(ConfluenceFixture.spaces(count: 0))]
    ])

    try await client(transport).verify(credential: ConfluenceFixture.credential())

    let urls = await transport.urls
    #expect(urls.count == 1)
    #expect(urls.first?.contains("/wiki/api/v2/spaces") == true)
}

@Test("FR-6: an account without Confluence access fails the test specifically")
func confluenceVerifyDistinguishesARefusedCredential() async throws {
    // 403 is the answer for a credential that works for Jira and has no Confluence
    // access — which is the sentence FR-6 exists to produce, and not "the network".
    let transport = StubConfluenceTransport(routes: ["spaces": [.status(403)]])

    await #expect(throws: SourceError.invalidCredential) {
        try await client(transport).verify(credential: ConfluenceFixture.credential())
    }
}
```

Then create `StenoTests/Integrations/Atlassian/CancelledWalkTests.swift`, which owns D-207 for
both connectors. It is a separate file on purpose: the rule is shared, the defect was shared, and
a fix that lands only on the connector in the diff is the failure mode this repo keeps meeting.

```swift
import Foundation
import Testing

@testable import StenoKit

/// D-207: what a cancelled page walk does, for **both** Atlassian connectors.
///
/// **One file rather than a test beside each client**, deliberately. The rule is shared
/// and the defect was shared: `SourceRefreshService.fetchAll` discards a *failed* fetch
/// once the pass budget has expired and keeps a *successful* one, so a walk that
/// answered cancellation by returning what it had read filed a truncated delta as a
/// complete fetch — into a log that cannot be edited afterwards. Fixing only the
/// connector that happened to be in the diff is the failure mode this repo keeps
/// meeting, so the two assertions sit where the next reader sees them together.
///
/// Every test here holds its task at a `TaskGate` until after `cancel()`, which is what
/// makes the ordering a property of the code rather than of the scheduler.

@Test("D-207: a cancelled Confluence walk fails the ref rather than filing a short answer")
func confluenceCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(),
        users: [ConfluenceFixture.leo: .ok(ConfluenceFixture.user())])
    let subject = ConfluenceClient(transport: transport)
    let gate = TaskGate()

    let task = Task {
        await gate.wait()
        return try await subject.changeSet(
            pageID: ConfluenceFixture.pageID, since: ConfluenceFixture.windowStart,
            credential: ConfluenceFixture.credential())
    }
    task.cancel()
    await gate.open()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}

@Test("D-207: a cancelled Jira walk fails the ref rather than filing a short answer")
func jiraCancelledWalkThrowsRatherThanReturningPartialData() async throws {
    let transport = StubJiraTransport(routes: JiraFixture.quietRoutes())
    let subject = JiraClient(transport: transport)
    let gate = TaskGate()

    let task = Task {
        await gate.wait()
        return try await subject.changeSet(
            key: JiraFixture.key, since: JiraFixture.windowStart,
            credential: JiraFixture.credential())
    }
    task.cancel()
    await gate.open()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}

@Test("D-211: cancellation during the name lookups fails the ref, rather than \"someone\"")
func confluenceCancellationDuringNameLookupsThrows() async throws {
    // The second place D-207's failure mode lives. Each lookup's `try?` turns a cancelled
    // request into an unresolved name, so a budget expiring here produced an ordinary
    // *success* in which every editor read "someone" — and `SourceRefreshService` keeps a
    // success after the budget, writing that attribution into a log that cannot be edited.
    //
    // Staged with two gates so the cancellation lands exactly where it matters: the walk
    // is held at its first name lookup, cancelled while held, then released. Nothing here
    // depends on which thread wins a race.
    let reachedLookup = TaskGate()
    let releaseLookup = TaskGate()

    let transport = StubConfluenceTransport(
        routes: ConfluenceFixture.quietRoutes(),
        users: [ConfluenceFixture.leo: .ok(ConfluenceFixture.user())],
        onUserRequest: {
            await reachedLookup.open()
            await releaseLookup.wait()
        })
    let subject = ConfluenceClient(transport: transport)

    let task = Task {
        try await subject.changeSet(
            pageID: ConfluenceFixture.pageID, since: ConfluenceFixture.windowStart,
            credential: ConfluenceFixture.credential())
    }

    await reachedLookup.wait()  // the page and the versions are already read
    task.cancel()
    await releaseLookup.open()

    await #expect(throws: SourceError.timedOut) {
        _ = try await task.value
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ConfluenceClient' in scope`.

- [ ] **Step 3: Write the implementation**

Three things here are load-bearing and easy to write differently by accident:

1. **The page and the walk are awaited page-first.** Both run concurrently, so when both fail the
   error that escapes is whichever is awaited first — and the page's failure describes the ref
   best. Swapping the two lines silently changes which `SourceError` the staleness banner shows.
2. **`withTaskGroup`, not `withThrowingTaskGroup`.** A child of a non-throwing group cannot
   throw, which makes "a name lookup never fails the fetch" a compile error rather than a rule.
3. **Three things end the walk besides the window:** no `next`, an empty page, and a cursor equal
   to the one just used.
4. **Cancellation throws `.timedOut`; it does not `break`** (D-207). Breaking returns a truncated
   delta as an ordinary success, and `SourceRefreshService.fetchAll` keeps successful results
   after the pass budget expires while discarding failed ones — so the short answer reaches the
   append-only log after the budget ran out.


```swift
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
        // reads above, a *failed lookup* is absorbed (D-201).
        //
        // **Cancellation is not a failed lookup, and absorbing it here was D-207's defect
        // in a second place** (D-211). Each child's `try?` turns a cancelled request into
        // an unresolved name, so a budget expiring during this group produced a perfectly
        // ordinary success in which every editor read "someone" — and
        // `SourceRefreshService` keeps a success after the budget, writing that
        // attribution into a log that cannot be edited. The checks are on the parent
        // rather than in the children, which keeps D-201's compile-time guarantee that a
        // lookup *cannot* fail the fetch. Raised by Copilot in review of PR #44.
        if Task.isCancelled { throw SourceError.timedOut }

        let ids = authorIDs(in: page, versions: walked.versions)
        let names = await names(for: ids, base: base, authorization: authorization)

        if Task.isCancelled { throw SourceError.timedOut }

        return ConfluenceChangeSet.make(
            page: page, pageID: pageID, versions: walked.versions, names: names, since: since,
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

    /// Why a version walk stopped.
    ///
    /// **A reason rather than a Bool, because one Bool was being asked to mean three
    /// things** (D-213). `isWindowCapped` is true for the page cap, for a cursor that did
    /// not advance, and for a `next` with no usable cursor — so a log line and a
    /// verification message that both said "hit the page cap" were wrong two thirds of the
    /// time, and a human reading either would have gone looking for a long page history
    /// that was not the problem. Raised by Copilot in review of PR #44.
    private enum WalkStop {
        /// The window ended: a page older than `since`, or no `next` to follow.
        case windowEnd
        case pageCap
        case repeatedCursor
        case unusableNext

        /// Whether the walk covered everything it set out to. Only `windowEnd` does.
        var isComplete: Bool { self == .windowEnd }

        /// What the log says. Each ends the same way, because the consequence is the same
        /// whatever the cause: the oldest versions in the window were not read, and the
        /// watermark is held so the fetch does not claim they were.
        var logLine: String {
            let held = "the watermark is held at the oldest version read"
            switch self {
            case .windowEnd: return ""
            case .pageCap:
                return
                    "confluence version paging hit the \(ConfluenceClient.maxPages)-page cap for one ref; \(held)"
            case .repeatedCursor:
                return "confluence version paging stopped: the cursor did not advance; \(held)"
            case .unusableNext:
                return
                    "confluence version paging stopped: `_links.next` carried no usable cursor; \(held)"
            }
        }
    }

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
        // Falling out of the `while` is the only exit that sets nothing, so this is what
        // that exit means.
        var stop: WalkStop = .pageCap

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
            // earlier version broke out and claimed the window's end, which turned a page
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
                stop = .windowEnd
                break
            }

            // A page whose oldest item predates the window is the end of the window. An
            // empty batch has no oldest item, so this cannot fire for one.
            if let oldest = batch.compactMap(\.stamp).min(), oldest < since {
                stop = .windowEnd
                break
            }

            // **An absent `next` and an unusable one are different answers** (D-212).
            // Absent is the API saying there is nothing further, and is the only shape
            // that may end the walk here. A `next` that is present but carries no cursor
            // this app can use is the API saying there *is* more and failing to say how:
            // the walk cannot continue, and it may not claim the end either, so the stop
            // reason is `.unusableNext` and the watermark is held at the floor.
            // Same distinction as the repeated cursor, on the other branch. Raised by
            // Copilot in review of PR #44.
            guard let link = page.links?.next, !link.isEmpty else {
                stop = .windowEnd
                break
            }
            guard let next = ConfluenceEndpoint.cursor(inNext: link) else {
                stop = .unusableNext
                break
            }

            // **A cursor that does not move ends the walk — as a capped one.** A server
            // that repeated one would otherwise be paged until `maxPages`, re-reading the
            // same versions. But `next` is still present, so older versions may well
            // remain unread: this is a walk that could not continue, not one that reached
            // the end of the window, so the stop reason is `.repeatedCursor` and the
            // watermark is held at the floor rather than claiming coverage it does not
            // have. Raised by Copilot in review of PR #44.
            if next == cursor {
                stop = .repeatedCursor
                break
            }
            cursor = next
        }

        if !stop.isComplete {
            // `error`, not `info`: this is a gap in what the user was told rather than a
            // slow pass. Holding the watermark keeps the fetch from claiming coverage it
            // did not achieve — which is all it does; it does not make the gap reachable
            // on a later pass (D-208).
            //
            // `.public` because every one of these is a fixed sentence about this app's
            // own paging: no page id, no link, no response content (§8).
            Log.sources.error("\(stop.logLine, privacy: .public)")
        }
        return (collected, !stop.isComplete)
    }

    // MARK: - Names

    /// Every account id this fetch will need a name for, **the page's current editor
    /// first**.
    ///
    /// Deduplicated and stably ordered, so the ids that survive `maxNameLookups` are
    /// chosen by a rule rather than by whichever the hasher happened to favour.
    ///
    /// **The current editor leads, and that ordering is a requirement rather than a
    /// preference** (D-211). §5.3 asks for the last editor by name — it is the one
    /// attribution the section actually specifies, and it is what the summary and the
    /// cached last-known state are built from. Appending it after the version authors
    /// meant ten distinct editors in the window exhausted the cap before it was reached,
    /// and the summary then omitted the very thing §5.3 requires. It is also reachable
    /// without a busy page at all: the page read and the version walk run concurrently,
    /// so the page can carry a version newer than anything the walk saw, whose author is
    /// in no other list. Raised by Copilot in review of PR #44.
    private func authorIDs(in page: ConfluencePage, versions: [ConfluenceVersion]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for id in [page.version?.authorId].compactMap({ $0 }) + versions.compactMap(\.authorId)
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
```

- [ ] **Step 4: Run the tests**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

| Mutation | Test that must go red |
|---|---|
| `let walked = (try? await walk) ?? ([], false)` | `D-206: a failed version walk fails the ref…` |
| await `walk` before `pageRead` | `a failed page read fails the ref…` |
| delete the `next == cursor` guard | `a cursor that does not move ends the walk…` |
| `since == nil` keeps paging | `D-188: with no anchor, one page is enough…` |
| `authorIDs(…)` → `versions.compactMap(\.authorId)` | `D-201: one lookup per distinct account…` |
| `ids.prefix(Int.max)` | `D-201: the lookups are bounded…` |
| `return (collected, false)` | `hitting the page cap is reported as a capped window…` |
| `resolved[id] = name ?? id` | `D-201: a name lookup that fails costs a name, not the fetch` |
| cancellation `break`s instead of throwing | `D-207: a cancelled Confluence walk fails the ref…`, and its Jira twin |

**One mutation is expected not to compile**, and that is the point: replacing `try?` with `try`
inside the task group fails the build with *"invalid conversion from throwing function … to
non-throwing function type"*. A mutation that cannot compile is a stronger result than a caught
one — the property is enforced by the type system.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Integrations/Confluence/ConfluenceClient.swift \
        StenoTests/Integrations/Confluence/ConfluenceClientTests.swift
git commit -m "feat: walk Confluence versions by cursor, and name their editors within a bound"
```

---

### Task 6: `ConfluenceConnector` — the `SourceConnector` conformance

**Files:**
- Create: `StenoKit/Integrations/Confluence/ConfluenceConnector.swift`
- Test: `StenoTests/Integrations/Confluence/ConfluenceConnectorTests.swift`

**Interfaces:**
- Consumes: `ConfluenceClient` (Task 5), `AtlassianCredentialCache`, `AtlassianTokenExpiry`,
  `AtlassianCredential.cloudHost(in:)` (Task 1), `SourceRefSnapshot`, `SourceUpdate`,
  `SourceConnector`, `InMemoryAtlassianStore` (existing test double).
- Produces: `ConfluenceConnector(credentials:transport:now:)`, conforming to `SourceConnector`
  with `id == "confluence"`, `displayName == "Confluence"`.

- [ ] **Step 1: Write the failing tests**


```swift
import Foundation
import Testing

@testable import StenoKit

/// The `SourceConnector` conformance (§5.3, D5, D-190, D-194, D-204).

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 24 * 60 * 60

private func pageRef(
    kind: SourceRefKind = .confluencePage,
    url: String? = "https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Payments+Migration+Plan",
    identifier: String = ConfluenceFixture.pageID
) -> SourceRefSnapshot {
    SourceRefSnapshot(refID: UUID(), kind: kind, identifier: identifier, url: url)
}

private func connector(
    credential: AtlassianCredential? = ConfluenceFixture.credential(),
    readError: (any Error)? = nil,
    routes: [String: [StubConfluenceTransport.Answer]] = [:],
    users: [String: StubConfluenceTransport.Answer] = [:]
) -> (ConfluenceConnector, StubConfluenceTransport) {
    let transport = StubConfluenceTransport(routes: routes, users: users)
    let store = InMemoryAtlassianStore(credential, readError: readError)
    return (
        ConfluenceConnector(credentials: store, transport: transport, now: { now }), transport
    )
}

private func fullRoutes() -> [String: [StubConfluenceTransport.Answer]] {
    [
        "page": [.ok(ConfluenceFixture.page())],
        "versions": [
            .ok(
                ConfluenceFixture.versions([
                    ConfluenceFixture.version(
                        number: 9, createdAt: ConfluenceFixture.inWindow, message: "final pass")
                ]))
        ],
    ]
}

private let knownUsers: [String: StubConfluenceTransport.Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez"))
]

// MARK: - Identity

@Test("its id and name are stable, because settings and the banner key on them")
func confluenceConnectorIdentityIsStable() {
    let (confluence, _) = connector()

    #expect(confluence.id == "confluence")
    #expect(confluence.displayName == "Confluence")
}

// MARK: - Routing (D-204)

@Test("it claims Confluence pages and nothing else")
func confluenceConnectorClaimsOnlyConfluencePages() {
    let (confluence, _) = connector()

    #expect(confluence.canHandle(pageRef()))
    #expect(confluence.canHandle(pageRef(kind: .jiraIssue)) == false)
    #expect(confluence.canHandle(pageRef(kind: .githubPR)) == false)
    #expect(confluence.canHandle(pageRef(kind: .url)) == false)
    #expect(confluence.canHandle(pageRef(kind: .mcpResource)) == false)
}

@Test("D-204: a page on another site is not answered from ours")
func confluenceConnectorRefusesAnotherSite() {
    let (confluence, _) = connector()

    // The same page id exists on every Confluence instance, so answering from ours
    // would be confidently wrong — a stand-up line about a document the user has never
    // seen.
    #expect(
        confluence.canHandle(
            pageRef(url: "https://other.atlassian.net/wiki/spaces/X/pages/12345/Page")) == false)
}

@Test("D-204: the classifier's host-free page ids are refused here")
func confluenceConnectorRefusesNonAtlassianHosts() {
    // `SourceURLClassifier` claims any `/pages/<digits>/` URL by design and documents
    // the false positive. This is where that stops being harmless.
    let (confluence, _) = connector()

    #expect(confluence.canHandle(pageRef(url: "https://example.com/pages/12/34")) == false)
    #expect(confluence.canHandle(pageRef(url: "https://wiki.corp.net/pages/12345/x")) == false)
}

@Test("D-204: a ref with no URL is refused, because a page id means nothing alone")
func confluenceConnectorRefusesAURLlessRef() {
    let (confluence, _) = connector()

    #expect(confluence.canHandle(pageRef(url: nil)) == false)
}

@Test("D-204: with nothing configured, a Cloud page is claimed so the user is told")
func confluenceConnectorClaimsCloudPagesWhenUnconfigured() {
    // Without this the ref dispatches `.unhandled` and says nothing, while a Jira ref
    // on the same task says "Atlassian is not set up" — the opposite of §5.3's "one
    // config, two APIs".
    let (confluence, _) = connector(credential: nil)

    #expect(confluence.isConfigured == false)
    #expect(confluence.canHandle(pageRef()))
    #expect(confluence.canHandle(pageRef(url: "https://any.atlassian.net/wiki/pages/9/x")))
    #expect(confluence.canHandle(pageRef(url: "https://example.com/pages/12/34")) == false)
}

// MARK: - Configuration

@Test("D-190: a site that is not an Atlassian Cloud host reads as unconfigured")
func confluenceConnectorRejectsANonCloudSite() {
    let (confluence, _) = connector(
        credential: AtlassianCredential(
            site: "wiki.corp.net", email: "leo@example.com", apiToken: "t"))

    #expect(confluence.isConfigured == false)
}

@Test("a Keychain that will not answer reads as unconfigured, not as a crash")
func confluenceConnectorSurvivesAKeychainFailure() {
    let (confluence, _) = connector(
        credential: nil, readError: KeychainError.unexpected(-25300))

    #expect(confluence.isConfigured == false)
    #expect(confluence.credentialWarning == nil)
}

@Test("an unconfigured fetch throws notConfigured without touching the network")
func confluenceConnectorFetchRequiresACredential() async throws {
    let (confluence, transport) = connector(credential: nil)

    await #expect(throws: SourceError.notConfigured) {
        _ = try await confluence.fetch(pageRef(), since: nil)
    }
    let received = await transport.received
    #expect(received.isEmpty)
}

// MARK: - The expiry warning (§5.2, D-194)

@Test("§5.2: the shared credential's expiry warns under Confluence's own name")
func confluenceConnectorWarnsAboutTheSharedCredential() throws {
    let (confluence, _) = connector(
        credential: ConfluenceFixture.credential(expiresAt: now.addingTimeInterval(10 * day)))

    let warning = try #require(confluence.credentialWarning)
    #expect(warning.displayName == "Confluence")
    #expect(warning.daysRemaining == 10)
    #expect(warning.renewalURL == AtlassianTokenExpiry.renewalURL)
}

@Test("§5.2: fifteen days out is silent, so the warning does not become wallpaper")
func confluenceConnectorDoesNotWarnEarly() {
    let (confluence, _) = connector(
        credential: ConfluenceFixture.credential(expiresAt: now.addingTimeInterval(15 * day)))

    #expect(confluence.credentialWarning == nil)
}

@Test("D-193: the renewal link is constant, so a 401 carries it without an expiry date")
func confluenceConnectorAlwaysOffersARenewalLink() {
    let (confluence, _) = connector(credential: ConfluenceFixture.credential(expiresAt: nil))

    #expect(confluence.credentialWarning == nil)
    #expect(confluence.credentialRenewalURL == AtlassianTokenExpiry.renewalURL)
}

// MARK: - Fetch

@Test("§5.3: a fetch reports the title, the version, the editor and the delta")
func confluenceConnectorFetchReportsTheDelta() async throws {
    let (confluence, _) = connector(routes: fullRoutes(), users: knownUsers)

    let update = try await confluence.fetch(
        pageRef(), since: ConfluenceFixture.windowStart)

    #expect(update.summary == "Payments Migration Plan — v9, edited by Leo Gutierrez")
    #expect(update.changes.map(\.text) == ["v9 by Leo Gutierrez: final pass"])
    #expect(update.watermark == AtlassianDate.parse(ConfluenceFixture.inWindow))
    #expect(update.fetchedAt == now)
    #expect(update.isWindowCapped == false)
}

@Test("D-187 has nothing to do here, so the state set is empty by decision")
func confluenceConnectorReportsNoStateSet() async throws {
    // Every Confluence version carries `createdAt`, so the window does the work. An
    // accidentally-populated `present` would make the service difference a set that
    // nothing here maintains.
    let (confluence, _) = connector(routes: fullRoutes(), users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: ConfluenceFixture.windowStart)

    #expect(update.present.isEmpty)
}

@Test("the reported URL is the page a human would open")
func confluenceConnectorReportsTheHumanURL() async throws {
    let (confluence, _) = connector(routes: fullRoutes(), users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: nil)

    #expect(
        update.url?.absoluteString
            == "https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Payments+Migration+Plan")
}

@Test("a page whose links did not arrive falls back to the ref's own URL")
func confluenceConnectorFallsBackToTheRefURL() async throws {
    let (confluence, _) = connector(
        routes: [
            "page": [.ok(ConfluenceFixture.page(webui: nil))],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ], users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: nil)

    #expect(update.url?.absoluteString == pageRef().url)
}

@Test("the capped flag is forwarded, so a partial window cannot read as a whole one")
func confluenceConnectorForwardsTheCappedFlag() async throws {
    // `SourceUpdate.isWindowCapped` has no default precisely because the Jira adapter
    // forgot to forward it for a whole review round, and every capped walk reported a
    // complete window.
    let pages = (0..<12).map { index in
        StubConfluenceTransport.Answer.ok(
            ConfluenceFixture.versions(
                [
                    ConfluenceFixture.version(
                        number: 100 - index, createdAt: ConfluenceFixture.inWindow)
                ],
                next: ConfluenceFixture.next(cursor: "PAGE\(index)")))
    }
    let (confluence, _) = connector(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": pages], users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: ConfluenceFixture.windowStart)

    #expect(update.isWindowCapped)
}

@Test("D5: a whole fetch through the connector issues only GETs")
func confluenceConnectorFetchIsReadOnly() async throws {
    let (confluence, transport) = connector(routes: fullRoutes(), users: knownUsers)

    _ = try await confluence.fetch(pageRef(), since: ConfluenceFixture.windowStart)

    let methods = await transport.methods
    #expect(methods.isEmpty == false)
    #expect(methods.allSatisfy { $0 == .get })
}

// MARK: - testConnection

@Test("FR-6: the connection test reads through to Confluence")
func confluenceConnectorTestsTheConnection() async throws {
    let (confluence, transport) = connector(
        routes: ["spaces": [.ok(ConfluenceFixture.spaces())]])

    try await confluence.testConnection()

    let urls = await transport.urls
    #expect(urls.first?.contains("/wiki/api/v2/spaces") == true)
}

@Test("FR-6: the test reads the Keychain fresh, never the thirty-second memo")
func confluenceConnectorTestBypassesTheCredentialMemo() async throws {
    // D-198's memo exists so routing does not read the Keychain once per ref — but
    // FR-6's button asks whether what is stored *right now* works, and answering it
    // from a memo makes a freshly pasted token look broken for half a minute.
    let store = InMemoryAtlassianStore(ConfluenceFixture.credential())
    let transport = StubConfluenceTransport(
        routes: ["spaces": [.ok(ConfluenceFixture.spaces()), .ok(ConfluenceFixture.spaces())]])
    let confluence = ConfluenceConnector(
        credentials: store, transport: transport, now: { now })

    _ = confluence.isConfigured  // warms the memo with the old site
    try store.store(
        AtlassianCredential(
            site: "other.atlassian.net", email: "leo@example.com", apiToken: "token-value"))

    try await confluence.testConnection()

    let urls = await transport.urls
    #expect(urls.last?.contains("other.atlassian.net") == true)
    #expect(urls.last?.contains("acme.atlassian.net") == false)
}

@Test("FR-6: an expired token says so here too, not \"the network\"")
func confluenceConnectorTestReportsAnExpiredToken() async throws {
    let (confluence, _) = connector(routes: ["spaces": [.status(401)]])

    await #expect(throws: SourceError.credentialExpired) {
        try await confluence.testConnection()
    }
}

@Test("FR-6: with no credential the test says so rather than asking the network")
func confluenceConnectorTestWithoutACredential() async throws {
    let (confluence, transport) = connector(credential: nil)

    await #expect(throws: SourceError.notConfigured) {
        try await confluence.testConnection()
    }
    let received = await transport.received
    #expect(received.isEmpty)
}

@Test("a webui with characters a URL must encode still produces an openable link")
func confluenceConnectorEncodesAnUnencodedWebui() async throws {
    // `webui` is a string from a response, and a page titled with a space or an accent
    // is ordinary. This was written expecting `URL(string:)` to refuse an unencoded
    // path and the ref's URL to be used instead — it does not: this Foundation
    // percent-encodes. The assertion is therefore what actually matters to the user,
    // which is that the link opens the right page either way.
    let (confluence, _) = connector(
        routes: [
            "page": [.ok(ConfluenceFixture.page(webui: "/spaces/ENG/pages/12345/Café Plan"))],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ], users: knownUsers)

    let update = try await confluence.fetch(pageRef(), since: nil)

    #expect(
        update.url?.absoluteString
            == "https://acme.atlassian.net/wiki/spaces/ENG/pages/12345/Caf%C3%A9%20Plan")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ConfluenceConnector' in scope`.

- [ ] **Step 3: Write the implementation**


```swift
import Foundation
import OSLog

/// §5.3's Confluence connector: read-only, Atlassian Cloud, REST v2.
///
/// **The second `SourceConnector`, on the first one's credential.** §5.3 asks for "one
/// config, two APIs", and that is literally what this is: the same
/// `AtlassianCredentialStore`, the same expiry warning, the same renewal link, the same
/// read-only transport — and its own client, because the two REST APIs share nothing
/// below that line (§5.3: "do not conflate them").
///
/// It holds no store and writes nothing: `SourceRefreshService` is the only writer
/// (D-172), so §3.3's append-only invariant is enforced once rather than once per
/// connector.
public struct ConfluenceConnector: SourceConnector {
    /// Stable across launches: it keys `RefreshOutcome.Failure` and M4-04's
    /// per-integration settings.
    public let id = "confluence"

    /// What Settings and the staleness banner show.
    public let displayName = "Confluence"

    private let credentials: any AtlassianCredentialStore
    private let client: ConfluenceClient
    private let now: @Sendable () -> Date

    /// Its own memo, not one shared with `JiraConnector` (D-198, D-202).
    ///
    /// Both connectors read the same Keychain item, so a shared memo would save one
    /// read per pass — and would need to be owned by something neither connector is, at
    /// the cost of an invalidation question with two answers. Thirty seconds and one
    /// read each is the proportionate trade; the memo drops itself on
    /// `.stenoCredentialsDidChange` either way.
    private let cache = AtlassianCredentialCache()

    /// - Parameters:
    ///   - transport: injected so `make test` can exercise every path with networking
    ///     denied (§9.4). The default is the real adapter, and the client wraps whatever
    ///     it is given in `ReadOnlyTransport`.
    ///   - now: injected so `fetchedAt` and the expiry warning are assertable without
    ///     waiting.
    public init(
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentials = credentials
        self.client = ConfluenceClient(transport: transport)
        self.now = now
    }

    /// Whether there is a usable credential — `baseURL != nil` rather than "a credential
    /// exists" (D-190), for the reason `JiraConnector` states: a stored site that is not
    /// an Atlassian Cloud host cannot be used, and reporting the ref as not-configured
    /// sends the user to Settings, where the problem is.
    public var isConfigured: Bool {
        credential?.baseURL != nil
    }

    /// §5.2's 14-day warning, as a fact for `SourceNotice` to phrase (D-194).
    ///
    /// **The same date the Jira connector warns about**, because there is one credential
    /// (§5.3). Two connectors therefore produce two warnings from one expiry, and
    /// `SourceNotice` is the layer that decides how many sentences the user sees.
    public var credentialWarning: SourceCredentialWarning? {
        AtlassianTokenExpiry.warning(
            displayName: displayName, expiresAt: credential?.expiresAt, now: now())
    }

    /// §5.2's "with a direct link" (D-193). The same page: one token serves both APIs.
    public var credentialRenewalURL: URL? {
        AtlassianTokenExpiry.renewalURL
    }

    /// Confluence pages on **this** Atlassian Cloud site (D-204).
    ///
    /// **Three cases, and the middle one is the easy thing to leave out:**
    ///
    /// - A URL on the configured site is claimed.
    /// - A URL on *some* Atlassian Cloud site, with nothing configured yet, is claimed —
    ///   so the ref reports `.notConfigured` and the user is told to set Atlassian up.
    ///   Without this, an unconfigured machine would say "Atlassian is not set up" for a
    ///   Jira ref and stay silent about a Confluence one on the same task, which is the
    ///   opposite of the sentence §5.3's "one config, two APIs" is meant to produce.
    /// - Everything else is refused, and `false` means `.unhandled` rather than
    ///   `.notConfigured`: nothing here can serve those refs.
    ///
    /// **A ref with no URL is refused, and that is where this departs from D-199.**
    /// `JiraConnector` claims a bare ticket key because a key in a task title can only
    /// mean the configured site. A page id is a number no one types: `SourceURLClassifier`
    /// is the only thing that produces a `.confluencePage` ref and it always sets a URL,
    /// so a URL-less one arrived from a hand-edited import — and claiming it would mean
    /// fetching page 12 from the user's own wiki for a reference that came from
    /// somewhere else. The classifier also claims page ids **without a host check** and
    /// documents the consequence (`https://example.com/pages/12/34` is
    /// `.confluencePage "12"`), which is the other half of why a host is required here.
    public func canHandle(_ ref: SourceRefSnapshot) -> Bool {
        guard ref.kind == .confluencePage else { return false }
        guard let url = ref.url, let host = AtlassianCredential.cloudHost(in: url) else {
            return false
        }

        guard let configured = credential?.site,
            let configuredHost = AtlassianCredential.cloudHost(in: configured)
        else { return true }

        return host == configuredHost
    }

    public func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        guard let credential, let base = credential.baseURL else {
            throw SourceError.notConfigured
        }

        let changeSet = try await client.changeSet(
            pageID: ref.identifier, since: since, credential: credential)

        return SourceUpdate(
            summary: changeSet.summary,
            changes: changeSet.changes,
            url: pageURL(base: base, webui: changeSet.webui, ref: ref),
            // The connector's own clock, diagnostic only — `lastFetchedAt` is stamped by
            // the service from the app's (D-171).
            fetchedAt: now(),
            // **Empty, and not by omission.** `present` is D-187's set difference, which
            // exists for items that carry no timestamp of any kind — Jira's remote links.
            // Every Confluence version carries `createdAt`, so the window does the work
            // and there is no state stream here to difference.
            present: [],
            watermark: changeSet.watermark,
            isWindowCapped: changeSet.isWindowCapped)
    }

    public func testConnection() async throws {
        // **Deliberately uncached**, for `JiraConnector`'s reason: FR-6's test exists to
        // say whether what is stored *right now* works, and answering it from a memo
        // would make a freshly pasted token look broken for as long as the cache lives.
        guard let credential = credential(fresh: true) else { throw SourceError.notConfigured }
        try await client.verify(credential: credential)
    }

    /// The human-facing page, not the API endpoint: this URL ends up on an event payload
    /// and is what a later feature would open.
    ///
    /// `webui` is relative and rooted at the *Confluence site* — `/spaces/ENG/pages/…` —
    /// so `/wiki` goes between it and the Cloud host. A page whose links did not arrive
    /// falls back to the ref's own URL, which is where the ref came from in the first
    /// place (D-204 guarantees there is one).
    private func pageURL(base: URL, webui: String?, ref: SourceRefSnapshot) -> URL? {
        guard let webui, !webui.isEmpty else {
            return ref.url.flatMap(URL.init(string:))
        }
        let path = webui.hasPrefix("/") ? webui : "/\(webui)"
        // **The second fallback is a belt, and an honest comment says so.** A page
        // titled "Café Plan" arrives with characters a URL must encode, and this
        // Foundation's `URL(string:)` percent-encodes them rather than returning nil —
        // `a webui with characters a URL must encode still produces an openable link`
        // pins that. So this `??` covers only whatever it still refuses, and is kept
        // because losing the link entirely is worse than the line costs.
        return URL(string: "\(base.absoluteString)/wiki\(path)")
            ?? ref.url.flatMap(URL.init(string:))
    }

    /// The stored credential, or `nil`.
    ///
    /// **A Keychain failure reads as absent**, for `JiraConnector`'s reason:
    /// `isConfigured` and `credentialWarning` are synchronous and non-throwing by
    /// contract, and the honest reading of "the Keychain would not answer" is that the
    /// integration is not usable right now.
    private var credential: AtlassianCredential? {
        credential(fresh: false)
    }

    /// - Parameter fresh: bypasses the memo. Used by `testConnection()` only.
    private func credential(fresh: Bool) -> AtlassianCredential? {
        cache.credential(now: now(), fresh: fresh) {
            do {
                return try credentials.credential()
            } catch {
                Log.sources.error(
                    "could not read the Atlassian credential: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test && make lint`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

| Mutation | Test that must go red |
|---|---|
| a URL-less ref returns `true` | `D-204: a ref with no URL is refused…` |
| `return host == configuredHost` → `return true` | `D-204: a page on another site is not answered from ours` |
| `isWindowCapped: false` | `the capped flag is forwarded…` |
| `present: changeSet.changes` | `D-187 has nothing to do here…` |
| the URL drops `/wiki` | `the reported URL is the page a human would open` |
| `credential(fresh: true)` → `false` | `FR-6: the test reads the Keychain fresh…` |
| the warning is built with `displayName: "Jira"` | `§5.2: the shared credential's expiry warns under Confluence's own name` |

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Integrations/Confluence/ConfluenceConnector.swift \
        StenoTests/Integrations/Confluence/ConfluenceConnectorTests.swift
git commit -m "feat: register Confluence pages as a source, on the Jira credential (§5.3)"
```

---
### Task 7: Live verification — `confluence-selftest` and `make verify-confluence`

**Files:**
- Create: `StenoKit/CLI/ConfluenceSelftest.swift`
- Create: `StenoKit/CLI/CountingTransport.swift` (lifted out of `StenoKit/CLI/JiraSelftest.swift`)
- Modify: `StenoKit/CLI/JiraSelftest.swift` (lose `CountingTransport`, call the shared rule)
- Modify: `StenoKit/CLI/CLICommand.swift`, `CLIParser.swift`, `CLIRunner.swift`, `CLIEntry.swift`
- Modify: `Makefile`
- Test: `StenoTests/CLI/ConfluenceSelftestTests.swift`, and additions to
  `StenoTests/CLI/CLIParserTests.swift`

**Interfaces:**
- Consumes: `ConfluenceConnector` (Task 6), `ConfluenceEndpoint.isValidPageID` (Task 2),
  `AtlassianKeychainStore`, `CLISync`, `CLIOutput`.
- Produces: `ConfluenceSelftest.run(pageID:credentials:transport:now:out:) async -> Int32` and
  `runSynchronously(pageID:credentials:out:)`; `CLICommand.confluenceSelftest(pageID:)`;
  `CountingTransport(wrapping:)` with `methods: [String]` and
  `static isReadOnly(_ methods: [String]) -> Bool`.

**Why this task exists.** `make test` denies outbound networking (§9.4) and stays out of the
Keychain, which leaves `URLSessionTransport` and the real API shape unexecuted — and the fixtures
in Task 3 were built from an OpenAPI document, so until something real answers them they are a
claim rather than a contract (D-197).

- [ ] **Step 1: Lift `CountingTransport` out of `JiraSelftest.swift` and give it a testable rule**

The harnesses' own D5 assertion is the thing this step exists for. Written inline as
`methods.allSatisfy { $0 == "GET" }`, it can be deleted with the suite still green — nothing a
test can do makes a connector emit a non-GET, because `ReadOnlyTransport` traps first. So the rule
becomes a predicate, exactly as `ReadOnlyTransport.isAllowed` did for the same reason, and both
harnesses call it rather than keeping a copy each.


```swift
import Foundation

/// Records the method of every request that passes through, for both selftests'
/// read-only claim (D-197).
///
/// **Shared by the Jira and Confluence harnesses**, for D-202's reason: a second copy
/// is how a fix lands on one and not the other. Its own type rather than a closure,
/// because it has to be `Sendable` and hold state — several requests run concurrently,
/// and an unsynchronized recorder does not merely race, it makes the harness lie about
/// what the code did.
final class CountingTransport: HTTPTransport, @unchecked Sendable {
    private let wrapped: any HTTPTransport
    private let lock = NSLock()
    private var recorded: [String] = []

    init(wrapping wrapped: any HTTPTransport) {
        self.wrapped = wrapped
    }

    var methods: [String] { lock.withLock { recorded } }

    /// Whether everything that went out was a read (D5).
    ///
    /// **A separately testable predicate, for `ReadOnlyTransport.isAllowed`'s reason.**
    /// Nothing a test can do will make a connector emit a non-GET — `ReadOnlyTransport`
    /// traps first — so the only way this rule stays verified is to assert the rule
    /// itself rather than the situation it exists to catch. What it guards against is a
    /// *live* run: a future endpoint reaching for `POST /users-bulk` (D-201) would show
    /// up here, in front of a human, rather than in nobody's assertions.
    static func isReadOnly(_ methods: [String]) -> Bool {
        methods.allSatisfy { $0 == "GET" }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request.method.rawValue) }
        return try await wrapped.send(request)
    }
}
```

Then in **both** `JiraSelftest.swift` and `ConfluenceSelftest.swift`:

```swift
guard CountingTransport.isReadOnly(methods) else {
```

- [ ] **Step 2: Write the failing tests**


```swift
import Foundation
import Testing

@testable import StenoKit

/// D-197: the harness that answers "have these Confluence fixtures ever met the real
/// API?".

private let selftestNow = Date(timeIntervalSince1970: 1_700_000_000)

private func selftestRoutes() -> [String: [StubConfluenceTransport.Answer]] {
    [
        "page": [.ok(ConfluenceFixture.page())],
        "versions": [
            .ok(
                ConfluenceFixture.versions([
                    ConfluenceFixture.version(
                        number: 9, createdAt: ConfluenceFixture.inWindow, message: "final pass")
                ]))
        ],
    ]
}

private let selftestUsers: [String: StubConfluenceTransport.Answer] = [
    ConfluenceFixture.leo: .ok(ConfluenceFixture.user(displayName: "Leo Gutierrez"))
]

/// One harness run: what it exited with, what it printed, and what it sent.
private struct ConfluenceHarnessRun {
    let code: Int32
    let output: [String]
    let transport: StubConfluenceTransport

    var text: String { output.joined(separator: "\n") }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var lines: [String] { lock.withLock { collected } }

    func append(_ line: String) {
        lock.withLock { collected.append(line) }
    }
}

private func runHarness(
    pageID: String = ConfluenceFixture.pageID,
    credential: AtlassianCredential? = ConfluenceFixture.credential(),
    readError: (any Error)? = nil,
    routes: [String: [StubConfluenceTransport.Answer]]? = nil
) async -> ConfluenceHarnessRun {
    let transport = StubConfluenceTransport(
        routes: routes ?? selftestRoutes(), users: selftestUsers)
    let collected = LineCollector()
    let code = await ConfluenceSelftest.run(
        pageID: pageID,
        credentials: InMemoryAtlassianStore(credential, readError: readError),
        transport: transport, now: { selftestNow }, out: { collected.append($0) })
    return ConfluenceHarnessRun(code: code, output: collected.lines, transport: transport)
}

@Test("it reports what the connector would say, and that every Confluence request was a GET")
func theConfluenceHarnessReportsAndPasses() async {
    let run = await runHarness()

    #expect(run.code == 0)
    #expect(run.text.contains("Payments Migration Plan — v9, edited by Leo Gutierrez"))
    #expect(run.text.contains("v9 by Leo Gutierrez: final pass"))
    #expect(run.text.contains("read-only"))

    let methods = await run.transport.methods
    #expect(methods.allSatisfy { $0 == .get })
}

@Test("it asks a 30-day window, because a first observation would print nothing")
func theConfluenceHarnessAsksAWindow() async {
    // `nil` means "establish an anchor and report nothing" (D-188) — correct behaviour
    // and useless output for a human checking whether the delta comes through.
    let run = await runHarness()

    #expect(run.text.contains("no new versions") == false)
    #expect(ConfluenceSelftest.window == 30 * 24 * 60 * 60)
}

@Test("a capped walk says so, so a short delta is not read as the whole truth")
func theConfluenceHarnessReportsACappedWalk() async {
    let pages = (0..<12).map { index in
        StubConfluenceTransport.Answer.ok(
            ConfluenceFixture.versions(
                [
                    ConfluenceFixture.version(
                        number: 100 - index, createdAt: ConfluenceFixture.inWindow)
                ],
                next: ConfluenceFixture.next(cursor: "PAGE\(index)")))
    }
    let run = await runHarness(
        routes: ["page": [.ok(ConfluenceFixture.page())], "versions": pages])

    #expect(run.code == 0)
    #expect(run.text.contains("the version walk ended early"))
    // Not "the page cap": the same flag is true for a cursor that did not advance and
    // for a `next` with no usable cursor, so a harness naming one cause would mislead
    // two thirds of the time (D-213).
    #expect(run.text.contains("page cap") == false)
}

@Test("with no credential it says what to run, and verifies nothing")
func theConfluenceHarnessWithoutACredential() async {
    let run = await runHarness(credential: nil)

    #expect(run.code == 1)
    #expect(run.text.contains("make atlassian-login"))
    let received = await run.transport.received
    #expect(received.isEmpty)
}

@Test("a non-Cloud site is refused before a request is built (D19)")
func theConfluenceHarnessRefusesANonCloudSite() async {
    let run = await runHarness(
        credential: AtlassianCredential(
            site: "wiki.corp.net", email: "leo@example.com", apiToken: "t"))

    #expect(run.code == 1)
    #expect(run.text.contains("atlassian.net"))
    let received = await run.transport.received
    #expect(received.isEmpty)
}

@Test("a page id that is not digits is refused locally, not spent on a 400")
func theConfluenceHarnessRefusesABadPageID() async {
    let run = await runHarness(pageID: "ENG/Payments")

    #expect(run.code == 1)
    #expect(run.text.contains("is not a page id"))
    let received = await run.transport.received
    #expect(received.isEmpty)
}

@Test("a failure prints the error's own sentence, and never the token")
func theConfluenceHarnessPrintsAFailure() async {
    let run = await runHarness(routes: ["page": [.status(401)]])

    #expect(run.code == 1)
    #expect(run.text.contains("token-value") == false)
    #expect(run.text.lowercased().contains("expired"))
}

@Test("a Keychain that refuses is reported as such, not as a missing credential")
func theConfluenceHarnessReportsAKeychainFailure() async {
    let run = await runHarness(
        credential: nil, readError: KeychainError.unexpected(-25300))

    #expect(run.code == 1)
    #expect(run.text.contains("Keychain refused"))
}

@Test(
    "D5: the read-only rule the harnesses assert, asserted itself",
    arguments: [
        (["GET", "GET", "GET"], true),
        (["GET", "POST"], false),
        (["POST"], false),
        ([], true),
    ])
func countingTransportReadOnlyRule(methods: [String], expected: Bool) {
    // The situation this guards — a live run that built a write — cannot be staged in a
    // test, because `ReadOnlyTransport` traps before a non-GET can be recorded. So the
    // rule is asserted directly, exactly as `ReadOnlyTransport.isAllowed` is, and the
    // one-line call site in each harness is what a reviewer reads.
    //
    // An empty list is `true` on purpose: "nothing was sent" is not a D5 violation, and
    // the harnesses print the request count beside this verdict so a silent zero is
    // visible to the human running it.
    #expect(CountingTransport.isReadOnly(methods) == expected)
}

@Test("the harness's fallback URL is built from the validated site, not the typed one")
func theConfluenceHarnessBuildsAWellFormedFallbackURL() async {
    // `AtlassianCredential.site` keeps what the user typed and accepts a pasted URL with
    // a path, so interpolating it produced `https://https://acme.atlassian.net/…`. The
    // harness prints that as the page's URL whenever `_links.webui` is absent, which is
    // exactly when a human is squinting at the output to decide whether the connector
    // works. Raised by Copilot in review of PR #44.
    let pasted = AtlassianCredential(
        site: "https://acme.atlassian.net/wiki/spaces/ENG/overview",
        email: "leo@example.com", apiToken: "token-value")
    let run = await runHarness(
        credential: pasted,
        routes: [
            "page": [.ok(ConfluenceFixture.page(webui: nil))],
            "versions": [.ok(ConfluenceFixture.versions([]))],
        ])

    #expect(run.code == 0)
    #expect(run.text.contains("https://https://") == false)
    #expect(run.text.contains("url       https://acme.atlassian.net/wiki/pages/12345"))
}
```

- [ ] **Step 3: Add the parser cases to `StenoTests/CLI/CLIParserTests.swift`**

Add the new row to the `selftestParses` table:

```swift
            (
                ["confluence-selftest", "--page", "12345"],
                CLICommand.confluenceSelftest(pageID: "12345")
            ),
```

and these three tests beside the `jira-selftest` ones:


```swift
    @Test("confluence-selftest requires the page it is meant to read")
    func confluenceSelftestRequiresAPage() throws {
        let error = try #require(throws: CLIUsageError.self) {
            try parse(["confluence-selftest"])
        }
        #expect(error.message.contains("--page is required"))
    }

    /// `--issue` is Jira's word. Accepting it here would read a page id out of a
    /// ticket key and spend a request proving it.
    @Test("confluence-selftest rejects an unknown flag, including Jira's")
    func confluenceSelftestRejectsUnknownFlags() throws {
        let error = try #require(throws: CLIUsageError.self) {
            try parse(["confluence-selftest", "--issue", "PAY-421"])
        }
        #expect(error.message.contains("unexpected argument"))
    }

    @Test("confluence-selftest refuses a flag where the page id should be")
    func confluenceSelftestRefusesAFlagAsItsValue() throws {
        let error = try #require(throws: CLIUsageError.self) {
            try parse(["confluence-selftest", "--page", "--replace"])
        }
        #expect(error.message.contains("looks like a flag"))
    }
```

- [ ] **Step 4: Run them to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ConfluenceSelftest' in scope`, and
`type 'CLICommand' has no member 'confluenceSelftest'`.

- [ ] **Step 5: Write the harness**


```swift
import Foundation

/// The only thing that runs the Confluence path against real Atlassian Cloud (D-197).
///
/// **`JiraSelftest`'s twin, for the same three gaps.** `make test` denies outbound
/// networking (§9.4) and stays out of the Keychain, which leaves `URLSessionTransport`
/// and this API's real shape unexecuted — and the fixtures in this PR were written from
/// Atlassian's OpenAPI document, so until something real disagrees with them, **the
/// fixtures are the wire contract**. This is what makes them answerable.
///
/// It prints what the connector would report — the summary, each version line, and the
/// watermark — plus the number of requests and their methods, because "read-only" is a
/// claim worth seeing confirmed against the live API rather than only in a spy's
/// assertions (D-191).
///
/// Run by `make verify-confluence PAGE=12345`. Hidden from `CLIUsage.text`. Every call
/// it makes is a GET, and it never prints the token.
public enum ConfluenceSelftest {
    /// How far back the harness asks, so a real run has something to show.
    ///
    /// **Not `nil`.** A `nil` since means "establish an anchor and report nothing"
    /// (D-188), which is correct for a first observation and useless for a human
    /// checking whether the version delta comes through.
    static let window: TimeInterval = 30 * 24 * 60 * 60

    public static func run(
        pageID: String,
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let credential: AtlassianCredential?
        do {
            credential = try credentials.credential()
        } catch {
            out("confluence-selftest: FAIL — the Keychain refused: \(String(describing: error))")
            return 1
        }

        guard let credential else {
            // The ordinary state of a machine where nobody has run
            // `make atlassian-login` — an instruction, not a stack trace. Still exit 1:
            // nothing was verified.
            out(
                "confluence-selftest: no Atlassian credential is stored. Run `make atlassian-login`."
            )
            return 1
        }
        guard let base = credential.baseURL else {
            out("confluence-selftest: FAIL — the stored site is not an *.atlassian.net host (D19).")
            return 1
        }
        guard ConfluenceEndpoint.isValidPageID(pageID) else {
            // Caught here rather than spent on a request the API would answer 400 to,
            // and said plainly: a page id is the number in the URL, which is the part
            // people most often paste something else in place of.
            out("confluence-selftest: FAIL — \"\(pageID)\" is not a page id (digits only).")
            return 1
        }

        let counter = CountingTransport(wrapping: transport)
        let connector = ConfluenceConnector(
            credentials: credentials, transport: counter, now: now)
        // **Built from `baseURL`, not from `site`.** `AtlassianCredential.site` keeps what
        // the user typed and accepts a pasted URL with a path, so interpolating it
        // produced values like `https://https://acme.atlassian.net/jira/…/wiki/pages/123`
        // — which the harness would then print as the page's URL whenever `_links.webui`
        // was absent. `baseURL` is the validated, normalized form, and this function
        // already refused to continue without it. Raised by Copilot in review of PR #44.
        let ref = SourceRefSnapshot(
            refID: UUID(), kind: .confluencePage, identifier: pageID,
            url: "\(base.absoluteString)/wiki/pages/\(pageID)")

        let update: SourceUpdate
        do {
            update = try await connector.fetch(ref, since: now().addingTimeInterval(-window))
        } catch let error as SourceError {
            // `SourceError` carries no free-form string by construction (D-165), so its
            // own sentence is safe to print.
            out("confluence-selftest: FAIL — \(error.localizedDescription) [\(error.metricsLabel)]")
            return 1
        } catch {
            out(
                "confluence-selftest: FAIL — the connector threw \(String(describing: type(of: error))), which breaks its contract"
            )
            return 1
        }

        report(update, pageID: pageID, out: out)

        let methods = counter.methods
        out("  requests  \(methods.count) — \(Set(methods).sorted().joined(separator: ", "))")

        // D5 as a live assertion, not only a unit test: if the live path ever built a
        // write, this is where a human would see it. It is also the check that would
        // catch a future name lookup reaching for `POST /users-bulk` (D-201).
        guard CountingTransport.isReadOnly(methods) else {
            out("confluence-selftest: FAIL — a non-GET request was issued, which breaks D5")
            return 1
        }

        out("confluence-selftest: PASS — \(methods.count) GETs, read-only")
        return 0
    }

    /// What the connector would report, printed for a human to check against their
    /// browser.
    private static func report(
        _ update: SourceUpdate, pageID: String, out: @escaping @Sendable (String) -> Void
    ) {
        out("confluence-selftest: page \(pageID)")
        out("  summary   \(update.summary)")
        if update.changes.isEmpty {
            out("  changes   no new versions in the last 30 days")
        } else {
            for change in update.changes {
                out("  change    \(change.text)")
            }
        }
        out("  url       \(update.url?.absoluteString ?? "none")")
        out("  watermark \(update.watermark.map(String.init(describing:)) ?? "none")")
        // Printed because a short walk means the oldest versions in the window went
        // unread, and a human comparing this against their browser needs to know that
        // before concluding the delta is wrong.
        //
        // **It does not name the page cap**, because `isWindowCapped` is equally true for
        // a cursor that did not advance and for a `next` with no usable cursor (D-213).
        // Naming one cause in a verification harness would send a reader looking for a
        // long page history that may not be the problem; the log carries the specific
        // reason. Raised by Copilot in review of PR #44.
        if update.isWindowCapped {
            out(
                "  partial   yes — the version walk ended early; the watermark is held at the floor"
            )
        }
    }

    /// Blocking entry point for `main()`. See `CLISync`.
    public static func runSynchronously(
        pageID: String,
        credentials: any AtlassianCredentialStore,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        CLISync.runSynchronously {
            await run(pageID: pageID, credentials: credentials, out: out)
        }
    }
}
```

- [ ] **Step 6: Wire the subcommand through the four CLI files**

`CLICommand.swift` — add the case beside `jiraSelftest`:

```swift
    /// `steno confluence-selftest --page 12345` — hidden, and absent from
    /// `CLIUsage.text`.
    ///
    /// **Carries no store either**, and carries the one argument it cannot default,
    /// for `jiraSelftest`'s reason: there is no sensible "any page", and guessing one
    /// would spend a request on somebody else's document. See `ConfluenceSelftest`.
    case confluenceSelftest(pageID: String)
```

`CLIParser.swift` — add the subcommand arm and its parser:

```swift
        case "confluence-selftest":
            return try parseConfluenceSelftest(Array(rest.dropFirst()))
```


```swift
    /// `steno confluence-selftest --page 12345`.
    ///
    /// The page id is required and has no default, for `--issue`'s reason: a harness
    /// that picked a page would spend a request on a document nobody asked about.
    private static func parseConfluenceSelftest(_ flags: [String]) throws -> CLICommand {
        var pageID: String?
        var index = 0

        while index < flags.count {
            let flag = flags[index]
            switch flag {
            case "--page":
                pageID = try value(after: flag, in: flags, at: &index)
            default:
                throw unexpected(flag, of: "confluence-selftest")
            }
            index += 1
        }

        guard let pageID else {
            throw CLIUsageError("steno confluence-selftest: --page is required.")
        }
        return .confluenceSelftest(pageID: pageID)
    }
```

`CLIRunner.swift` — the runner never acts on a selftest, so it reports the misrouting:

```swift
        case .confluenceSelftest:
            misroutedSelftest("confluence-selftest")
```

`CLIEntry.swift` — answered before any store is opened, beside the Jira one:

```swift
        if case .confluenceSelftest(let pageID) = command {
            return ConfluenceSelftest.runSynchronously(
                pageID: pageID, credentials: AtlassianKeychainStore())
        }
```

- [ ] **Step 7: Add the make target**

Add `verify-confluence` to the `.PHONY` line, then beside `verify-jira`:

```make
# The Confluence half of D-197. Same credential, different API (§5.3) — so this also
# answers whether "one config, two APIs" is true on a real site rather than in a test
# double.
verify-confluence: build ## Fetch one real page with the stored credential (signed build; §5.3, D-197)
	@test -n "$$PAGE" || { echo "usage: make verify-confluence PAGE=12345"; exit 2; }
	@"$(BIN)" confluence-selftest --page "$$PAGE"
```

- [ ] **Step 8: Run everything**

Run: `make build && make test && make lint`
Expected: all green.

- [ ] **Step 9: Mutation-check**

| Mutation | Test that must go red |
|---|---|
| `CountingTransport.isReadOnly` accepts anything | `D5: the read-only rule the harnesses assert…` (parameterized — exit status) |
| the harness asks `since: nil` | `a capped walk says so…` |
| the capped line is not printed | `a capped walk says so…` |
| `isValidPageID` check → `!pageID.isEmpty` | `a page id that is not digits is refused locally…` |

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: add \`make verify-confluence\`, and give both harnesses one read-only rule"
```

---

### Task 8: Register the connector, and record the decisions

**Files:**
- Modify: `Steno/App/StenoApp.swift`
- Modify: `docs/DECISIONS.md` (append D-200 … D-206)
- Modify: `docs/REQUIREMENTS.md` (§5.3, version → v1.23, changelog line)
- Modify: `docs/tasks/README.md` (tick M4-03)

**Interfaces:**
- Consumes: `ConfluenceConnector` (Task 6), `SourceRegistry(connectors:)`.
- Produces: nothing new in code — this is what makes a Confluence ref resolve in the running app
  rather than only in a test double.

- [ ] **Step 1: Register the connector at the composition root**

Replace the registry property in `Steno/App/StenoApp.swift`. Note the doc comment is rewritten,
not extended: it still carried M4-01's "Empty this milestone" paragraph alongside M4-02's
replacement for it, which is a contradiction a reader has to resolve.


```swift
    /// §5.1's connectors, built once for the process.
    ///
    /// **Registration order is priority** (D-166), and this array is the one place it
    /// is decided — rather than a `register()` call some pane could reorder. M4-01
    /// shipped it empty (D-179), M4-02 added Jira, and M4-03 adds Confluence.
    ///
    /// **Two stores, one credential** (§5.3). `AtlassianKeychainStore` is a stateless
    /// struct over a single Keychain item, so both connectors read the same site, email
    /// and token — which is what makes "configure Atlassian once and both work" true
    /// rather than aspirational. Each keeps its own thirty-second memo of it (D-198).
    ///
    /// The two claim different `SourceRefKind`s, so order decides nothing today; it
    /// will when M5's MCP connector claims kinds a native connector also claims.
    private let sourceRegistry = SourceRegistry(connectors: [
        JiraConnector(credentials: AtlassianKeychainStore()),
        ConfluenceConnector(credentials: AtlassianKeychainStore()),
    ])
```

- [ ] **Step 2: Check the tasks README for rows that merged without being ticked**

`CLAUDE.md`'s working procedure, step 4. Run:

```bash
grep -n "^- \[ \]" docs/tasks/README.md
```

Every unticked row from M4-03 onward is unstarted work, so only M4-03 changes here. If an earlier
row is unticked, tick it in this PR too — nothing else prompts it, and §9.5 forbids a direct
commit to `main`.

- [ ] **Step 3: Tick M4-03**

```
- [x] [M4-03](M4-03-confluence-connector.md) — Confluence read-only on the same credential
```

The PR number is appended once the PR exists, matching the M4-01 and M4-02 rows.

- [ ] **Step 4: Append D-200 … D-206 to `docs/DECISIONS.md`**

Seven records, in the file's existing format. **Check the log's maximum first** — inferring it
from a sibling document has shipped a duplicate decision number in this repo before:

```bash
grep -oE '^### D-[0-9]+' docs/DECISIONS.md | sort -t- -k2 -n | tail -1
```

The seven: D-200 (v2, because v1 is past its removal date), D-201 (editor names from the v1 user
GET), D-202 (the plumbing move), D-203 (one change per version), D-204 (the routing rule),
D-205 (cursor paging), D-206 (a failed walk fails the ref). Each states the decision, why the
alternatives lose, and the tests that falsify it.

- [ ] **Step 5: Amend §5.3 and bump REQUIREMENTS.md to v1.23**

§5.3 is silent on which API it means while §5.2 says "REST API v3" — harmless while no code
existed, and now the difference between an implementation that works and one built on endpoints
whose removal was announced for 2025-03-31. Add the deployment line and the consequence a future
reader should not have to rediscover:

```markdown
**Deployment: Atlassian Cloud (D19). REST API v2** — the v1 content API is past the removal date
Atlassian announced for it. Do not write Data Center compatibility code.

- Same Atlassian credential — one config, two APIs. (Jira and Confluence are distinct REST APIs; do not conflate them.)
- Fetch page title, last-modified timestamp, last editor, and version delta since `since`.
- **Editor display names are not available from v2 content endpoints** — a version identifies its
  author by account id — so naming the last editor requires a separate lookup. The endpoint that
  resolves an id in v2 is a `POST`, which D5 forbids; see `DECISIONS.md` D-201 for the read-only
  route taken instead.
```

Bump `**Status:** Draft v1.23`, set the date, and add the changelog line at the top of the list.

- [ ] **Step 6: Run everything and commit**

Run: `make build && make test && make lint`

```bash
git add -A
git commit -m "docs: register Confluence, record D-200..D-206, and amend §5.3 to v1.23"
```

- [ ] **Step 7: Open the PR and stop**

```bash
git push -u origin feat/confluence-connector
gh pr create --title "A read-only Confluence connector on the Jira credential (M4-03)"
```

**Read `.github/pull_request_template.md` before writing the body** — `gh pr create` bypasses it
silently. The body must declare the REQUIREMENTS.md amendment, and say that the fixtures are the
wire contract until `make verify-confluence` has run against a real page.

**Do not merge.** The user reviews and merges (§9.5).

---

## After the plan

Two things this plan cannot do for you:

1. **`make verify-confluence PAGE=…` against a real page**, which is the only thing that turns the
   fixtures from a claim into a contract. Run it before asking for review, and put its output in
   the PR body. If the live API disagrees with a fixture, the fixture is what is wrong — and that
   finding belongs in the PR body rather than in a quiet edit.
2. **The Copilot review loop.** A PR is not done at "opened": fix, reply, resolve, and report only
   when it is green.
