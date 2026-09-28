# M4-02 Jira Connector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a read-only Jira Cloud connector whose `since` window is anchored on what Jira itself
confirms it has reported, so a change the API reveals late is still reported, and whose token expiry
is handled as the scheduled certainty §5.2 says it is.

**Architecture:** Four concurrent GETs per ref behind `SourceConnector`, with every judgment about
"what counts as news" in pure types (`JiraChangeSet`, `AtlassianDocument`, `JiraErrors`) that need no
network and no store. The watermark that drives `since` is *derived from the event log* rather than
stored on `SourceRef`, which is what keeps this task free of a schema change, a §10.1 merge rule and
a REQUIREMENTS amendment. `SourceRefreshService` remains the only writer and the only reader of the
log; the connector reports what it saw and the service decides what is new.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, swift-testing; Atlassian Jira Cloud REST v3 over
`URLSession`; Keychain via the `Support/` plumbing; XcodeGen + `make`.

**Spec:** [`docs/superpowers/specs/2026-09-26-m4-02-jira-connector-design.md`](../specs/2026-09-26-m4-02-jira-connector-design.md)

---

## How this plan was produced, and what that means for a reviewer

**Every task below is already implemented, verified and committed**, and the plan was written from
the built tree rather than before it. That is deliberate and is this repo's standing lesson: a plan
written first ships code blocks that type-check in isolation and fail inside their module, and it
generates confident claims nobody measured. Writing it from a compiled tree also found four defects
that review would not have — they are marked **FOUND BY BUILDING** where they occur.

Each task therefore carries its commit SHA, and its steps are ticked. A reviewer can read this as the
argument for the diff; an executor re-running it from scratch would follow the same order, because
each commit compiles and tests green on its own.

Final state: **build clean, lint 0 violations / 368 files, 1104 tests passing**, and 16 deliberate
mutations of the new behaviour each caught by the test that names it (see Verification).

## Global Constraints

Copied from the spec and REQUIREMENTS.md; every task's requirements implicitly include these.

- **Atlassian Cloud only** (D19). REST API v3, `*.atlassian.net`. Do not write Data Center code.
- **Read-only, permanently** (D5). No code path may issue a POST, PUT or DELETE against Jira, and
  `updateHistory` — a read parameter that writes — must never be sent.
- **Auth is email + API token over HTTP Basic**, read-scoped (§5.2).
- **Tokens live in the Keychain only** (§8). Never in SwiftData, `UserDefaults`, a plist, a log, or a
  command-line argument.
- **`SourceError` is the only error a connector may throw** (§5.5), and no case of it carries a
  free-form `String` (D-165).
- **`fetch` must be cancellation-aware** (M4-01): `URLSession`-backed, with `Task.isCancelled` checked
  in any loop of its own.
- **A failed integration must never block report generation** (§5.5). Degrade to cache; never throw
  out of a refresh pass.
- **The event log is append-only** (§3.3). The only permitted write to an existing event is
  `isRedacted`.
- **`make build && make test && make lint` must all pass before the PR** (§9.5 step 4), `make format`
  must leave the tree clean (D-075), and `make test` runs with outbound networking denied (§9.4).
- **The AI layer and the source layer stay independent** (§13). Neither may import the other.
- **Never commit to `main`.** One branch, one PR, do not merge (§9.5).

## Review Focus

Input classes the spec implies but does not enumerate, most likely to bite first. Each line names the
task whose tests now pin it.

1. **A site value that is not a bare Atlassian host** — a pasted board URL, a trailing slash, an
   uppercase host, `evil.com/acme.atlassian.net`, `acme.atlassian.net.evil.com`, a value with `@` in
   it. A Basic-auth credential sent to the wrong host is the worst outcome in this PR. → Task 2.
2. **A Jira timestamp in a form the parser does not expect** — with and without fractional seconds,
   with a `+0000` zone rather than `Z`. Every timestamp silently becoming `nil` leaves the watermark
   permanently absent and the window permanently open, and nothing errors. → Task 6.
3. **A changelog entry carrying two changes at once** — Jira batches a status and an assignee change
   made together, so an id scheme keyed on the entry drops one silently. → Task 6.
4. **A comment that was edited rather than created** inside the window: `created` is old, `updated` is
   new, and the text the user is about to read aloud has changed. → Task 6.
5. **An `externalUpdate` event that was redacted** — §3.3 hides it from summaries, and hiding it from
   the resume read would make a redaction re-announce every change it mentioned. → Task 5.

---

## File Structure

```
StenoKit/Support/Net/          HTTPTransport.swift, URLSessionTransport.swift, TransportError.swift
StenoKit/Support/Keychain/     KeychainQuery.swift, KeychainError.swift
StenoKit/Integrations/         AtlassianCredential.swift   credential + store + site validation
                               AtlassianTokenExpiry.swift  §5.2's 14-day rule, pure
                               SourceChange.swift          id + text; SourceCredentialWarning
                               ResumePoint.swift           watermark + dedup sets, pure
                               SourceRefreshService+Reads.swift   the log read and the registry read
StenoKit/Integrations/Jira/    JiraEndpoint.swift          the only request builder; GET only
                               JiraWire.swift              Decodable mirrors + JiraDate
                               AtlassianDocument.swift     ADF → plain text, pure
                               JiraChangeSet.swift         wire + window → changes, pure
                               JiraErrors.swift            status/transport → SourceError, pure
                               ReadOnlyTransport.swift     traps on any non-GET
                               JiraClient.swift            paging, early stop, decode
                               JiraConnector.swift         the SourceConnector conformance
StenoKit/CLI/                  AtlassianLogin.swift, JiraSelftest.swift, CLISync.swift
```

Modified: `SourceConnector`, `SourceError`, `SourceNotice`, `ExternalUpdate`, `RefreshOutcome`,
`SourceRefreshService(+Write)`, `EventQueries`, `StandupDraftModel`, `StandupDraftSheet`,
`CLICommand`/`CLIParser`/`CLIEntry`/`CLIRunner`, `ModelsSelftest`, `KeychainCredentialStore`,
`StenoApp`, `Makefile`.

---

### Task 1: Move the transport and Keychain plumbing to `Support/`

**Commit:** `4fe8154` — *chore: move the transport and Keychain plumbing to Support…*

**Files:**
- Move: `StenoKit/AI/HTTPTransport.swift` → `StenoKit/Support/Net/HTTPTransport.swift`
- Move: `StenoKit/AI/URLSessionTransport.swift` → `StenoKit/Support/Net/URLSessionTransport.swift`
- Create: `StenoKit/Support/Net/TransportError.swift`
- Create: `StenoKit/Support/Keychain/KeychainQuery.swift`, `KeychainError.swift` (extracted from
  `KeychainCredentialStore.swift`)
- Modify: `StenoKit/AI/KeychainCredentialStore.swift`, `StenoTests/AI/KeychainQueryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `KeychainQuery.lookup(service:account:)`, `.insert(_:service:account:)`, `.update(_:)`;
  `TransportError.notHTTP`; `KeychainCredentialStore.service` (internal, `"com.lgabrielgr.steno.ai"`).

- [x] **Step 1: Record the suite's size before touching anything**

Run: `make test`
Expected: PASS. Note the count — it is the only evidence this task is a move. (It was 943.)

- [x] **Step 2: Move the four files with `git mv`, creating the two directories**

`project.yml` needs no change: the `StenoKit` target takes `- path: StenoKit`, so new subfolders are
picked up by `make generate`.

- [x] **Step 3: Replace the AI-layer error in the moved transport**

`URLSessionTransport` threw `AIError.network` for a non-`HTTPURLResponse` response, which is what made
the shared adapter a member of the AI layer:

```swift
guard let http = response as? HTTPURLResponse else {
    throw TransportError.notHTTP
}
```

`AnthropicErrors.error(forTransport:)` already maps an unrecognised error to `AIError.network`, so the
AI path's behaviour is unchanged.

- [x] **Step 4: Make the Keychain service a parameter rather than a constant**

```swift
static func lookup(service: String, account: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
    ]
}
```

`KeychainCredentialStore` passes its own `service`. Do not add `kSecAttrAccessible` — the login
keychain accepts it and does nothing with it (§6 v1.20).

- [x] **Step 5: Run the gate and compare the count**

Run: `make build && make test && make lint`
Expected: PASS, and the test count identical to Step 1. Any difference means this was not a move.

- [x] **Step 6: Commit**

---

### Task 2: The Atlassian credential, its store, and the site validation

**Commit:** `ee3fde4` — *feat: store one Atlassian credential…*

**Files:**
- Create: `StenoKit/Integrations/AtlassianCredential.swift`
- Test: `StenoTests/Integrations/AtlassianCredentialTests.swift` (also defines
  `InMemoryAtlassianStore`, used by Tasks 8 and 9)

**Interfaces:**
- Consumes: `KeychainQuery`, `KeychainError` (Task 1).
- Produces: `AtlassianCredential(site:email:apiToken:expiresAt:)` with `baseURL: URL?`,
  `basicAuthorization: String`, `static cloudHost(in:) -> String?`; protocol
  `AtlassianCredentialStore { store(_:); credential() -> AtlassianCredential?; delete() }`;
  `AtlassianKeychainStore` with `static service`/`account`; test double
  `InMemoryAtlassianStore(_:readError:)`.

- [x] **Step 1: Write the failing tests for the site rule, both directions**

The rejections that matter are the ones that look right:

```swift
@Test(
    "anything that is not an Atlassian Cloud host is refused",
    arguments: [
        "", "   ", "atlassian.net", "acme.atlassian.net.evil.com",
        "evil.com/acme.atlassian.net", "https://evil.com/acme.atlassian.net",
        "acme.example.com", "acme.atlassian.net@evil.com", "acme.atlassian.net/path",
        "https://evil.com?x=acme.atlassian.net",
    ])
func aNonCloudHostIsRefused(site: String) {
    #expect(AtlassianCredential.cloudHost(in: site) == nil)
}
```

Pair it with the accepting direction (bare host, uppercase, padded, full URL with a path), or a
validator that rejected everything would pass.

- [x] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: FAIL — `cannot find 'AtlassianCredential' in scope`.

- [x] **Step 3: Implement the credential**

```swift
public var baseURL: URL? {
    guard let host = Self.cloudHost(in: site) else { return nil }
    return URL(string: "https://\(host)")
}

public var basicAuthorization: String {
    let encoded = Data("\(email):\(apiToken)".utf8).base64EncodedString()
    return "Basic \(encoded)"
}

static func cloudHost(in value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }

    let host: String
    if trimmed.contains("://") {
        guard let parsed = URLComponents(string: trimmed)?.host else { return nil }
        host = parsed
    } else {
        guard !trimmed.contains("/"), !trimmed.contains("@"), !trimmed.contains("?") else {
            return nil
        }
        host = trimmed
    }

    let suffix = ".atlassian.net"
    guard host.hasSuffix(suffix), host.count > suffix.count else { return nil }
    return host
}
```

The scheme is always built `https`, so a stored `http://` cannot downgrade the connection carrying
the token.

- [x] **Step 4: Implement the store on Task 1's plumbing**

Add-then-update, never delete-then-add: if the add half failed, the user would be left with no
credential having asked only to change their token. Service `com.lgabrielgr.steno.integrations`,
account `atlassian` — one item for both Atlassian APIs (§5.3).

- [x] **Step 5: Run the gate and commit**

Run: `make build && make test && make lint`

---

### Task 3: §5.2's token expiry rule

**Commit:** `3207b4c` — *feat: add §5.2's token expiry rule…*

**Files:**
- Create: `StenoKit/Integrations/AtlassianTokenExpiry.swift`
- Test: `StenoTests/Integrations/AtlassianTokenExpiryTests.swift`

**Interfaces:**
- Produces: `AtlassianTokenExpiry.warningThreshold` (14), `.renewalURL`,
  `.daysRemaining(expiresAt:now:) -> Int`, `.shouldWarn(expiresAt:now:) -> Bool`,
  `.warning(displayName:expiresAt:now:) -> SourceCredentialWarning?` (the return type arrives in
  Task 4; until then this task's tests exercise the first three).

- [x] **Step 1: Write the boundary test that most implementations get wrong**

```swift
@Test("the boundary is the interval, not the rounded day count")
func theBoundaryIsTheInterval() {
    #expect(
        AtlassianTokenExpiry.shouldWarn(
            expiresAt: now.addingTimeInterval(14 * day + 1), now: now) == false)
    #expect(
        AtlassianTokenExpiry.shouldWarn(expiresAt: now.addingTimeInterval(14 * day - 1), now: now))
}
```

Flooring first warns at 14.9 days, because `floor(14.9) == 14` — a day early, every day, which is how
a warning becomes the noise FR-5 warns about.

- [x] **Step 2: Run it and watch it fail**

- [x] **Step 3: Implement — two expressions, not one**

```swift
public static func daysRemaining(expiresAt: Date, now: Date) -> Int {
    Int(floor(expiresAt.timeIntervalSince(now) / day))
}

public static func shouldWarn(expiresAt: Date, now: Date) -> Bool {
    expiresAt.timeIntervalSince(now) <= Double(warningThreshold) * day
}
```

`daysRemaining` floors for display, which is the honest direction: with eleven hours left it says
"today", not "tomorrow". Negative values are reachable and say something different.

- [x] **Step 4: Run the gate and commit**

---

### Task 4: The change vocabulary and the payload's watermark fields

**Commit:** `c8298a8` — *feat: give a change a stable id, and the event payload a watermark*

**Files:**
- Create: `StenoKit/Integrations/SourceChange.swift`, `StenoKit/Integrations/ResumePoint.swift`
- Modify: `StenoKit/Integrations/ExternalUpdate.swift`, `StenoKit/Models/EventQueries.swift`
- Test: `StenoTests/Integrations/ResumePointTests.swift`,
  `StenoTests/Integrations/ExternalUpdateTests.swift`

**Interfaces:**
- Produces: `SourceChange(id:text:)`; `SourceCredentialWarning(displayName:daysRemaining:renewalURL:)`;
  `ExternalUpdatePayload(…, watermark:changeIDs:presentIDs:)` (all three optional, defaulted);
  `ResumePoint.from(payloads:) -> ResumePoint` with `.since`, `.watermark`, `.reportedIDs`,
  `.presentIDs`, `.overlap` (900), `.scanDepth` (10), `.none`;
  `EventQueries.allEvents(forTaskID:)`.
- Consumed by: Task 5 (the service), Task 3's `warning(…)` return type.

- [x] **Step 1: Write the resume-point tests, including the two that pin the subtle choices**

```swift
@Test("the watermark is the newest across the scanned payloads, not the first one")
func theWatermarkIsTheNewest() {
    let point = ResumePoint.from(payloads: [
        payload(watermark: origin.addingTimeInterval(-3600)),
        payload(watermark: origin),
    ])
    #expect(point.watermark == origin)
}

@Test("D-187: the link set is the newest recorded set exactly, never a union")
func theLinkSetIsTheNewestRecorded() {
    let point = ResumePoint.from(payloads: [
        payload(watermark: origin, presentIDs: ["L2"]),
        payload(watermark: origin, presentIDs: ["L1", "L2"]),
    ])
    #expect(point.presentIDs == ["L2"])
}
```

- [x] **Step 2: Run and watch them fail**

- [x] **Step 3: Add `SourceChange` and `SourceCredentialWarning`**

The id is not a hash of the text: an edited comment would arrive as new, and a status flipped back
and forth would collide with its own earlier entry.

- [x] **Step 4: Add the three payload fields, with an explicit memberwise initializer**

```swift
let watermark: Date?
let changeIDs: [String]?
let presentIDs: [String]?

init(
    refID: UUID, kind: SourceRefKind, identifier: String, changes: [String], url: String?,
    fetchedAt: Date, watermark: Date? = nil, changeIDs: [String]? = nil,
    presentIDs: [String]? = nil
) { … }
```

Written out rather than synthesized so the three new fields can default — call sites that predate
them say nothing about them, and every row already written decodes.

- [x] **Step 5: Change `ExternalUpdateBody.text` to take `[SourceChange]`**

It reads `\.text`; §3.3's wording, the blank-string dropping and D-169's first-observation rule are
unchanged.

- [x] **Step 6: Add the one `EventQueries` descriptor that keeps redacted rows**

```swift
public static func allEvents(forTaskID id: UUID) -> FetchDescriptor<Event> {
    FetchDescriptor<Event>(
        predicate: #Predicate { $0.taskID == id },
        sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
    )
}
```

The exception is deliberate and documented in the file: redacting the sentence a user reads is not a
statement that the ticket never moved. Filter the kind in memory — an `EventKind` inside a
`#Predicate` does not compile in either spelling.

- [x] **Step 7: Implement `ResumePoint.from(payloads:)`**

```swift
static func from(payloads: [ExternalUpdatePayload]) -> ResumePoint {
    let scanned = payloads.prefix(scanDepth)
    guard !scanned.isEmpty else { return .none }
    let watermark = scanned.compactMap(\.watermark).max()
    let reported = scanned.reduce(into: Set<String>()) { ids, payload in
        ids.formUnion(payload.changeIDs ?? [])
    }
    let present = scanned.first { $0.presentIDs != nil }?.presentIDs ?? []
    return ResumePoint(watermark: watermark, reportedIDs: reported, presentIDs: Set(present))
}
```

- [x] **Step 8: Add the payload tests — round trip, a pre-M4-02 row, and a `Mirror` walk**

The `Mirror` test is the one that matters long-term: an optional encoded with `encodeIfPresent` omits
its key when nil, so a *new* field can be added and silently never written, and a hand-kept list of
expected keys is exactly the thing that stops being updated.

- [x] **Step 9: Run the gate and commit**

---

### Task 5: Resume from the watermark, de-duplicate, and carry credential warnings

**Commit:** `d796f7a` — *feat: resume from the watermark the log recorded…*

**Files:**
- Modify: `StenoKit/Integrations/SourceRefreshService.swift`,
  `StenoKit/Integrations/SourceRefreshService+Write.swift`,
  `StenoKit/Integrations/RefreshOutcome.swift`, `StenoKit/Integrations/SourceConnector.swift`
- Create: `StenoKit/Integrations/SourceRefreshService+Reads.swift`
- Test: `StenoTests/Integrations/WatermarkTests.swift`,
  `StenoTests/Integrations/WindowedConnector.swift`,
  `StenoTests/Integrations/CredentialWarningTests.swift`; update `RefreshFixture`,
  `StubSourceConnector`, `SourceRefreshServiceTests`, `RefreshConcurrencyTests`

**Interfaces:**
- Consumes: `ResumePoint`, `SourceChange`, `EventQueries.allEvents(forTaskID:)` (Task 4).
- Produces: `SourceUpdate(summary:changes:url:fetchedAt:present:watermark:)`;
  `SourceConnector.credentialWarning` (defaulted `nil`); `RefreshOutcome.duplicates`,
  `.credentialWarnings`, `.warning(about:)`; `SourceRefreshService.ReadyFetch`, `.PassContext`.

- [x] **Step 1: Build the double that can show the defect**

`StubSourceConnector` answers from a script regardless of `since`, so a pass asking the *wrong*
window still gets the same changes back and every assertion passes. `WindowedConnector` holds
timestamped items and returns those inside the window — without it, none of this task's tests can
fail for the right reason.

- [x] **Step 2: Write the D-183 regression test, and watch it fail**

```swift
@Test("D-183: a change the source revealed late is still reported")
func aLateChangeIsStillReported() async throws {
    let ref = try fixture.ref("PAY-421", on: task, fetched: lastFetched, summary: "In Progress")
    try fixture.observed(ref, watermark: watermark)

    let late = lastFetched.addingTimeInterval(-60)   // created before the last pass, served after
    let connector = WindowedConnector(items: [
        .init(id: "c-late", text: "status: In Progress → In Review", stamp: late)
    ])

    let outcome = await fixture.service(connectors: [connector]).refresh(taskIDs: [task.id])

    #expect(connector.asked == [RefreshFixture.since(after: watermark)])
    #expect(outcome.changed == 1)
}
```

`RefreshFixture` needs `observed(_:watermark:…)`, which writes a real `externalUpdate` with a payload:
setting `lastFetchedAt` alone now describes a ref the service correctly treats as never reported, so a
fixture that did only that would make this test pass for the wrong reason.

- [x] **Step 3: Compute the resume points once per pass, before dispatch**

One query per *task*, not per ref, with the kind filtered in memory:

```swift
let resume = resumePoints(for: claimed.map(\.snapshot), rows: rows)
let ready = claimed.map {
    ReadyFetch(
        snapshot: $0.snapshot, connector: $0.connector,
        since: resume[$0.snapshot.refID]?.since)
}
```

A read that throws leaves those refs at `.none` — a `nil` since, which asks for an anchor rather than
for history. That is the safe direction.

- [x] **Step 4: Send `ready.since`, not the row's timestamp**

```swift
let update = try await withDeadline(deadline, throwing: SourceError.timedOut) {
    try await connector.fetch(ref, since: ready.since)
}
```

- [x] **Step 5: De-duplicate in the write phase and record every id seen**

```swift
let fresh = update.changes.filter { !resumePoint.reportedIDs.contains($0.id) }
let newcomers = update.present.filter { !resumePoint.presentIDs.contains($0.id) }
applied.duplicates +=
    (update.changes.count - fresh.count) + (update.present.count - newcomers.count)

let reported = isFirst ? [] : fresh + newcomers
```

and in the payload:

```swift
watermark: update.watermark,
changeIDs: update.changes.map(\.id),     // every id seen, not only those reported
presentIDs: update.present.map(\.id)     // the whole set, not a delta
```

**FOUND BY BUILDING:** `changeIDs` must record *every* id the fetch saw, not `reported.map(\.id)`.
With only the reported ids recorded, a first observation — which reports none — left its items
unrecorded, and the next pass found them inside the overlap and announced them. Caught by
`a second pass with nothing new writes no event at all`.

- [x] **Step 6: Collect credential warnings once per pass and stamp every outcome**

Including `.idle` and the `readFailed` exits, via `RefreshOutcome.warning(about:)`: a pass whose refs
are all on done tasks fetches nothing, and a token expiring on Friday must still be sayable.

- [x] **Step 7: Split the file when `make lint` says to**

`SourceRefreshService.swift` passes 400 lines; the reads move to `+Reads.swift` (the log read, the
registry read, the candidate queries). `applyAndSave` also passes five parameters, so the pass's
inputs become `PassContext`.

- [x] **Step 8: Update the three tests that assert the old mechanism**

`sinceIsThePreviousObservation` (renamed to name the watermark), the D-170 two-rows test, and the
D-183 serialization test each pinned `since` to `lastFetchedAt` — which is exactly what D-183 says is
wrong. They now assert `RefreshFixture.since(after: watermark)`.

- [x] **Step 9: Run the gate and commit**

Run: `make build && make test && make lint`

---

### Task 6: The Jira reads — endpoints, wire shapes, ADF, and what counts as news

**Commit:** `90d6c12` — *feat: read Jira — the four endpoints, their shapes, and what counts as news*

**Files:**
- Create: `JiraEndpoint.swift`, `JiraWire.swift`, `AtlassianDocument.swift`, `JiraChangeSet.swift`,
  `JiraErrors.swift`, `ReadOnlyTransport.swift` (all under `StenoKit/Integrations/Jira/`)
- Test: `StenoTests/Integrations/Jira/` — `JiraFixture.swift` (JSON builders +
  `StubJiraTransport`), `JiraEndpointTests`, `JiraWireTests`, `AtlassianDocumentTests`,
  `JiraChangeSetTests`, `JiraErrorsTests`, `ReadOnlyTransportTests`

**Interfaces:**
- Consumes: `HTTPRequest`/`HTTPTransport` (Task 1), `SourceChange` (Task 4), `SourceError`.
- Produces: `JiraEndpoint` (5 cases) with `request(base:authorization:) -> HTTPRequest?`,
  `isValidKey(_:)`, `issueFields`; `JiraIssue`, `JiraUser`, `JiraChangelogPage`,
  `JiraChangelogEntry`, `JiraChangeItem` (`toValue` ↔ `toString`), `JiraCommentPage`, `JiraComment`
  (+ `.stamp`), `JiraRemoteLink`, `ADFNode`, `JiraDate.parse(_:)`;
  `AtlassianDocument.plainText(_:limit:)`; `JiraChangeSet.make(issue:history:comments:links:since:)`
  → `summary`, `changes`, `present`, `watermark`; `JiraErrors.error(forStatus:headers:)`,
  `.error(forTransport:)`, `.retryAfter(in:)`; `ReadOnlyTransport(wrapping:)` + `isAllowed(_:)`.

- [x] **Step 1: Read the wire contract from the source, not from memory**

Run:
```bash
curl -sL -o /tmp/jira.json https://developer.atlassian.com/cloud/jira/platform/swagger-v3.v3.json
python3 -c "import json;s=json.load(open('/tmp/jira.json'));print([p for p in s['paths'] if 'issue/{issueIdOrKey}' in p][:8])"
```
Four facts decide this task's design, and all four were confirmed this way: neither the changelog nor
the comment endpoint takes a date filter; `PageOfComments` has no `isLast` while `PageBeanChangelog`
does; a remote link carries no timestamp; and `GET /issue/{key}` accepts `updateHistory`, which
writes.

- [x] **Step 2: Write the D5 tests first**

```swift
@Test(
    "D5: every endpoint builds a GET",
    arguments: [
        JiraEndpoint.issue(key: "PAY-421"),
        .changelog(key: "PAY-421", startAt: 0, maxResults: 100),
        .comments(key: "PAY-421", startAt: 0, maxResults: 50),
        .remoteLinks(key: "PAY-421"),
        .currentUser,
    ])
func everyEndpointIsAGet(endpoint: JiraEndpoint) throws {
    #expect(try request(endpoint).method == .get)
}
```

Plus `ReadOnlyTransport.isAllowed(.post) == false` and an assertion that no built URL ever contains
`updateHistory`.

- [x] **Step 3: Implement `JiraEndpoint`, and validate the key**

`request` hard-codes `.get` and takes no method parameter, so nothing under `Jira/` can construct a
write. Reject an empty or whitespace-bearing key before building anything:

```swift
if let key, !Self.isValidKey(key) { return nil }
```

**FOUND BY BUILDING:** the first version had no key validation, and the test written for its `nil`
branch failed — `URLComponents` percent-encodes a key with a space happily, so that branch was
unreachable code with a comment claiming otherwise. Validating locally makes it reachable *and*
saves a round trip Jira would answer 400 to.

- [x] **Step 4: Implement the wire types, every field optional**

§5.5 degrades: one absent `displayName` must cost that author, not the whole fetch, and a
non-optional field fails the entire decode. `toString` arrives as `toValue` through a `CodingKeys`
entry.

- [x] **Step 5: Implement `JiraDate.parse` with two formatters, and test both forms**

```swift
let withFraction = ISO8601DateFormatter()
withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
if let date = withFraction.date(from: value) { return date }

let plain = ISO8601DateFormatter()
plain.formatOptions = [.withInternetDateTime]
return plain.date(from: value)
```

`.withFractionalSeconds` is a requirement rather than a permission, so one formatter cannot read both
`…11.123+0000` and `…11Z`. Getting this wrong returns `nil` rather than throwing, which would leave
the watermark permanently absent with nothing to notice it.

- [x] **Step 6: Implement the ADF flattener**

Inline nodes contribute their text; `mention` its rendered `@Ana`; `inlineCard` its URL; block nodes
their children plus a space; **unknown types recurse rather than fail**. Truncate at 200 characters on
a word boundary.

- [x] **Step 7: Implement `JiraChangeSet`, and test the batched entry**

The id is the entry id *and* the field:

```swift
let field = item.fieldId ?? item.field ?? "field"
return SourceChange(id: "\(id)#\(field)", text: text)
```

Jira batches a status change and an assignee change made together into one entry with two items, so
keying on the entry alone drops the second silently.

A comment's window test reads `comment.stamp` — the later of `created` and `updated` — because an edit
is news. An item whose timestamp will not parse is reported rather than dropped: it cannot be placed
in the window, and the id dedup stops it being said twice, where dropping it would lose a real
transition to a date-format change.

- [x] **Step 8: Implement `JiraErrors` as a table, and test every status**

401 → `.credentialExpired` unconditionally (§5.2); 403 → `.invalidCredential`; 400 and 404 →
`.notFound`; 429 → `.rateLimited(retryAfter:)`; everything else → `.unavailable(status:)`.

- [x] **Step 9: Run the gate and commit**

---

### Task 7: The client's paging, and the connector in the app's registry

**Commit:** `58e7d8f` — *feat: fetch a ticket, and put the connector in the app's registry*

**Files:**
- Create: `StenoKit/Integrations/Jira/JiraClient.swift`, `JiraConnector.swift`
- Modify: `Steno/App/StenoApp.swift`
- Test: `StenoTests/Integrations/Jira/JiraClientTests.swift`, `JiraConnectorTests.swift`;
  extend `SourceRegistryTests`

**Interfaces:**
- Consumes: everything from Tasks 2, 3, 4 and 6.
- Produces: `JiraClient(transport:)` with `changeSet(key:since:credential:)` and
  `verify(credential:)`, plus `changelogPageSize` (100), `commentPageSize` (50), `maxPages` (10);
  `JiraConnector(credentials:transport:now:)` conforming to `SourceConnector` with `id == "jira"`.

- [x] **Step 1: Build a transport double that routes rather than scripts**

The client issues four requests concurrently, so `StubHTTPTransport`'s call-order script would make
every test here flaky — and a passing run no evidence of anything. `StubJiraTransport` keys answers
by endpoint and `startAt` (`changelog@150`, `comment@0`).

- [x] **Step 2: Write the backwards-paging test, and watch it fail**

```swift
#expect(
    asked.filter { $0.hasPrefix("changelog") }
        == ["changelog@0", "changelog@150", "changelog@50"])
#expect(set.changes.map(\.id) == ["newest#status"])
```

- [x] **Step 3: Implement the changelog walk**

One probe page at `startAt: 0` establishes `total` and settles the common case (`isLast == true`, the
probe *is* the answer). Anything longer walks backwards from `max(0, total - pageSize)`, keyed by id
so a shifted page boundary costs a duplicate read rather than a duplicate entry, stopping at the first
page older than the window, at `startAt == 0`, or at `maxPages`. The probe's values are discarded on
that path: they are the oldest entries, and keeping them would let an ancient entry with an
unparseable timestamp be reported.

- [x] **Step 4: Implement the comment walk**

`orderBy=-created`, stopping at the first page whose oldest comment predates the window; paged on
`startAt + total`, because `PageOfComments` has no `isLast`.

- [x] **Step 5: Issue the four reads concurrently, and require all four**

```swift
async let issue = fetch(JiraIssue.self, from: .issue(key: key), …)
async let history = history(key: key, since: since, …)
async let comments = comments(key: key, since: since, …)
async let links = fetch([JiraRemoteLink].self, from: .remoteLinks(key: key), …)
```

A failed link request fails the whole fetch: `present` is a state set, so an empty one would make
every existing PR reference look new next pass.

- [x] **Step 6: Implement the connector**

`canHandle` claims `.jiraIssue` only. `isConfigured` is `credential?.baseURL != nil`. A Keychain
failure reads as absent, because `isConfigured` and `credentialWarning` are synchronous and
non-throwing by contract and §5.5 says a refresh must never block a report. `url` is the human-facing
`/browse/KEY` page, not the API endpoint.

- [x] **Step 7: Register it in `StenoApp`, closing D-179**

```swift
private let sourceRegistry = SourceRegistry(connectors: [
    JiraConnector(credentials: AtlassianKeychainStore())
])
```

Registration order is priority (D-166), and this array is the one place it is decided. No test can
reach `StenoApp` — the bundle links `StenoKit`, not the app — so `SourceRegistryTests` asserts the
*shape* of that array instead.

- [x] **Step 8: Run the gate and commit**

---

### Task 8: The two harnesses that let this code meet the real API

**Commit:** `93bf26c` — *feat: add the two harnesses that let this code meet the real API*

**Files:**
- Create: `StenoKit/CLI/AtlassianLogin.swift`, `JiraSelftest.swift`, `CLISync.swift`
- Modify: `CLICommand.swift`, `CLIParser.swift`, `CLIEntry.swift`, `CLIRunner.swift`,
  `AI/ModelsSelftest.swift`, `Makefile`
- Test: `StenoTests/CLI/AtlassianLoginTests.swift`, `JiraSelftestTests.swift`; extend
  `CLIParserTests`

**Interfaces:**
- Produces: `CLICommand.atlassianLogin`, `.jiraSelftest(issueKey:)`;
  `AtlassianLogin.run(store:out:readLine:readSecret:)`, `.fullDate(_:)`;
  `TerminalSecret.read(prompt:)`; `JiraSelftest.run(issueKey:credentials:transport:now:out:)`,
  `.runSynchronously(issueKey:credentials:out:)`; `CLISync.runSynchronously(_:)`; make targets
  `atlassian-login` and `verify-jira`.

- [x] **Step 1: Write the login tests with scripted readers**

Every reader is injected, so the whole sequence runs without a terminal. The two that matter:

```swift
@Test("§8: the token is read without echo and never printed back")
func thetokenIsNeverPrinted() throws { … #expect(result.output.contains { $0.contains("atlassian-token-value") } == false) }

@Test("an expiry date that is not a date is refused rather than stored as nil")
func anUnparseableExpiryIsRefused() throws { … #expect(try store.credential() == nil) }
```

Silently storing `nil` would leave the user believing they had recorded an expiry and the app unable
to warn them — the exact failure §5.2 calls scheduled.

- [x] **Step 2: Implement the no-echo read with `termios`, not `getpass`**

```swift
var quiet = original
quiet.c_lflag &= ~tcflag_t(ECHO)
```

`getpass` is the obvious answer and truncates at 128 bytes; an Atlassian API token is longer, so it
would silently store a mangled token. When stdin is not a terminal, `tcgetattr` fails and the line is
read normally — there is no echo to disable on a pipe.

- [x] **Step 3: Implement the login flow, refusing a bad site before storing anything**

- [x] **Step 4: Implement the Jira harness**

It asks for a 30-day window rather than `nil` (a `nil` since establishes an anchor and reports
nothing), counts the methods of every request through a `CountingTransport`, and fails if any was not
a GET — D5 as a live assertion.

- [x] **Step 5: Wire both into the CLI before the store opens**

Both are hidden from `CLIUsage.text` and carry no `ModelContainer`. Adding the cases makes
`CLIRunner.run`'s switch non-exhaustive, which is the compiler pointing at the one place that also
needs them — route both to `misroutedSelftest`.

`CLIParser.parse` passes its complexity budget with four no-flag subcommands, so they become a table:

```swift
private static let noFlagSubcommands: [String: CLICommand] = [
    "keychain-selftest": .keychainSelftest,
    "models-selftest": .modelsSelftest,
    "atlassian-login": .atlassianLogin,
]
```

- [x] **Step 6: Give `ModelsSelftest` the shared sync bridge**

Three harnesses would otherwise be three copies of a semaphore-and-box, and three chances to get the
ordering wrong. Its own tests are the check that the swap is behaviour-preserving.

- [x] **Step 7: Add the make targets, and list them in `.PHONY`**

```make
atlassian-login: build ## Store the Atlassian credential (signed build; §5.2, §8, D-197)
	@"$(BIN)" atlassian-login

verify-jira: build ## Fetch one real ticket with the stored credential (signed build; §5.2, D-197)
	@test -n "$$ISSUE" || { echo "usage: make verify-jira ISSUE=PAY-421"; exit 2; }
	@"$(BIN)" jira-selftest --issue "$$ISSUE"
```

- [x] **Step 8: Run the gate and commit**

---

### Task 9: Record the decisions and tick the task

**Commit:** this one.

**Files:**
- Modify: `docs/DECISIONS.md` (D-184 … D-197), `docs/tasks/README.md`
- Create: this plan

- [x] **Step 1: Read the decision log's current maximum rather than inferring it**

Run: `grep -o "^### D-[0-9]*" docs/DECISIONS.md | sort -t- -k2 -n | tail -1`
Expected: `### D-183`. Inferring the number from a sibling spec once shipped a duplicate D-140, and a
diff cannot see it.

- [x] **Step 2: Write D-184 … D-197, each with what it rejected and what falsifies it**

- [x] **Step 3: Confirm no REQUIREMENTS amendment is needed**

Deriving the watermark from the log is what keeps §3.4, §10.1 and §10.2 untouched. Two deviations go
in the PR body instead: the 401 sentence's three extra words, and the 14-day warning landing in the
draft sheet with Settings following in M4-04.

- [x] **Step 4: Tick M4-02 in `docs/tasks/README.md`, and check for rows that merged unticked**

Run: `grep -n "M4-0" docs/tasks/README.md`
Expected: M4-01 already ticked; no stragglers.

- [x] **Step 5: `make format`, then the full gate, then commit**

---

## Verification

**Gate:** `make build && make test && make lint` — clean build, **1104 tests passing**, 0 lint
violations across 368 files. `make format` leaves the tree clean.

**Mutation testing.** Every load-bearing behaviour in this PR was broken deliberately and the suite
re-run; all 16 were caught, with no survivors and no false "caught" from a compile error:

| Mutation | Caught by |
|---|---|
| `since` comes from the row again (the D-183 defect) | `D-183: a change the source revealed late is still reported` (+8 more) |
| the overlap is dropped | `D-184: the connector is asked for changes since the watermark, less the overlap` |
| the dedup filter is neutralized | `D-186: a change the log has already reported is dropped, not repeated` |
| only reported ids are recorded | `a second pass with nothing new writes no event at all` |
| the link set difference is neutralized | `D-187: only a link absent from the recorded set is news` |
| the watermark reads the newest payload only | `the watermark is the newest across the scanned payloads` |
| the resume read excludes redacted rows | `a redaction does not make a reported change look unreported` |
| a first observation reports its changes | `D-188: a first observation records the watermark…` |
| read-only allows everything | `D5: POST is not allowed` |
| the batched entry keys on the entry id alone | `D-186: one entry carrying two changes yields two ids` |
| the expiry threshold uses the floored day count | `the boundary is the interval, not the rounded day count` |
| the site validation accepts anything | `anything that is not an Atlassian Cloud host is refused` |
| the changelog is paged forward from zero | `D-196: a long changelog is paged backwards from the end` |
| a comment's stamp ignores its edit | `D-195: an edited comment is news…` |
| warnings are not stamped on an early exit | `a pass with no refs in scope still carries the warning` |
| a 401 is reported as a rejected credential | `§5.2: a 401 on any of the four reads becomes credentialExpired` |

**Still owed, and owed to a human.** `make atlassian-login` and `make verify-jira ISSUE=…` have not
been run — they need a real Atlassian credential, which no agent in this repo can plant. Until then
the fixtures in this PR are the wire contract, built from Atlassian's OpenAPI document rather than
from a response. The same applies to `make run`: D-179's "Refreshing…" line and staleness banner are
now reachable, and the pixels have not been looked at.
