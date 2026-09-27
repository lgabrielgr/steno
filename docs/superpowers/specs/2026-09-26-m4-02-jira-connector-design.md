# M4-02 — Jira Connector: design

**Status:** proposed 2026-09-26
**Task:** [`docs/tasks/M4-02-jira-connector.md`](../../tasks/M4-02-jira-connector.md)
**Requirements:** §5.2, §5.3, §5.5, §3.3, §3.4, §8, §13, D5, D19
**Branch:** `feat/jira-connector`

---

## What this builds

The first real `SourceConnector`: a read-only Jira Cloud client that turns a `SourceRef` of kind
`jiraIssue` into the `externalUpdate` events a stand-up is assembled from, and that treats an
expiring API token as the scheduled certainty §5.2 says it is.

It also closes the gap M4-01 handed forward. D-183 records that `since` was sent as
`SourceRef.lastFetchedAt` — the *app's* clock — which can step past a change Jira reveals only
after the pass that should have seen it. Serializing passes fixed the concurrent half of that
defect; this task fixes the durable half, and it does so **without a schema change, a new merge
rule, or a REQUIREMENTS amendment** (D-184).

Seven pieces:

| Piece | Responsibility | Needs no |
|---|---|---|
| `JiraEndpoint` | build the four GETs, and nothing else | network, store, credential |
| `JiraWire` | `Decodable` mirrors of the four responses | network, store |
| `AtlassianDocument` | flatten an ADF comment body to plain text | everything |
| `JiraChangeSet` | wire + resume point → `[SourceChange]` + watermark | network, store, clock |
| `JiraClient` | paging, early stop, status → `SourceError` | store |
| `JiraConnector` | the `SourceConnector` conformance | store |
| `AtlassianCredential`, `…Store`, `AtlassianTokenExpiry` | one credential, two APIs; the 14-day rule | network, store |

Five of the seven need neither a network nor a store, which is what lets the wire contract, the
change vocabulary, the ADF flattener and the expiry rule all be table-tested offline under
§9.4's sandbox.

The connector is registered in `StenoApp`'s `SourceRegistry`, so this is also the milestone in
which M4-01's refresh UI becomes reachable in the running app for the first time (D-179).

---

## The design brief

What the user decided, in the four questions this design was built from:

1. **The watermark is derived from the event log** — not a new `SourceRef` field. §10.1's own
   rule ("any mutable field that can be recomputed from the log, should be") applies, and the
   log has a property the row does not: events always export, while `cachedSummary` and
   `lastFetchedAt` are excluded from an export by default (§10.2), so a row-based watermark
   would reset on the machine you import onto.
2. **The transport and Keychain plumbing move to a neutral layer in this PR**, rather than being
   duplicated or reached for across the AI boundary §13 forbids.
3. **The 14-day expiry warning appears in the draft sheet's notice, ranked third** — below a save
   failure and below a real fetch failure (so an actual 401 wins with its own wording), above
   not-configured and staleness. M4-04 adds the Settings copy.
4. **Live verification is two hidden CLI subcommands**, on the `keychain-selftest` /
   `models-selftest` pattern (D-138), because no credential entry UI exists until M4-04.

Assumptions this design makes that the user did not state, each stated so it can be corrected:

- The token expiry date rides **inside the Keychain credential blob** with the site, email and
  token, rather than in `AppSettings`, so a token and its expiry cannot drift apart (D-190).
- A reported comment carries a **truncated gist** of its text rather than only "a new comment"
  (D-195).
- The 401 sentence says "expired **or was revoked**" (D-193).

---

## What this task decides

| # | Decision |
|---|---|
| D-184 | The `since` watermark is derived from `externalUpdate` payloads, not stored on `SourceRef` |
| D-185 | `since` is the watermark minus a 15-minute overlap, and the overlap is deliberate |
| D-186 | De-duplication lives in `SourceRefreshService`, keyed on stable Jira ids |
| D-187 | Remote links are a state set, not a delta stream, because they carry no timestamp |
| D-188 | A first observation stamps a watermark and reports only the summary |
| D-189 | `HTTPTransport` and the Keychain plumbing move to `Support/`; `Credential` stays in `AI/` |
| D-190 | One Atlassian credential, one Keychain blob, expiry included; the site is validated |
| D-191 | Read-only is enforced three ways, and `updateHistory` is never sent |
| D-192 | 401 maps to `.credentialExpired`; 403 maps to `.invalidCredential` |
| D-193 | `SourceNotice` returns a message with an optional link, and the 401 sentence hedges once |
| D-194 | The expiry warning reaches the notice through the connector, once per pass |
| D-195 | Comment bodies are flattened from ADF and truncated |
| D-196 | The changelog is paged backwards from `total`; comments are read newest-first |
| D-197 | Live verification is `make atlassian-login` and `make verify-jira` |

Every code block below is **illustrative and uncompiled.** This repo has a standing lesson that
plan code which type-checks in isolation still fails inside its module, and that a plan written
before the tree is built ships defects review does not catch — so the implementation plan is
generated *from a built tree*, and these blocks exist to fix the shape of the design, not to be
copied.

---

## Verified wire facts

Confirmed on **2026-09-26** against Atlassian's own OpenAPI document
(`https://developer.atlassian.com/cloud/jira/platform/swagger-v3.v3.json`, 2.4 MB, HTTP 200),
not from memory. They are recorded here because until `make verify-jira` first runs, **the
fixtures in this PR are the wire contract**, and a fixture wrong in the same way as the design is
a test that cannot fail.

| Fact | Consequence |
|---|---|
| `GET /rest/api/3/issue/{key}/changelog` takes only `startAt` and `maxResults` — **no date filter** | the `since` window is applied client-side (D-196) |
| Its response is `PageBeanChangelog`: `values`, `startAt`, `maxResults`, `total`, `isLast`, `nextPage` | `total` is what makes backwards paging possible (D-196) |
| A `Changelog` carries `id` (String), `created`, `author`, `items[]` of `field`, `fieldId`, `fromString`, `toString` | `history.id` is the dedup key; `field` selects status and assignee (D-186) |
| `GET /rest/api/3/issue/{key}/comment` takes `startAt`, `maxResults`, `orderBy` (`created`, `-created`, `+created`) and `expand` — **no date filter** | newest-first plus an early stop (D-196) |
| Its response is `PageOfComments`: `comments`, `startAt`, `maxResults`, `total` — **and no `isLast`** | paging is driven by `startAt + total`, unlike the changelog's `isLast` |
| A `Comment` carries `id`, `created`, `updated`, `author`, `body` **in Atlassian Document Format**, and `renderedBody` only under `expand` | ADF must be flattened (D-195) |
| `GET /rest/api/3/issue/{key}/remotelink` returns `RemoteIssueLink`s of `id` (Int), `globalId`, `relationship`, `object.url`, `object.title` — **and no timestamp of any kind** | links cannot be windowed by time; they are a state set (D-187) |
| `GET /rest/api/3/issue/{key}` accepts `updateHistory`, which **writes** to the user's recent-projects list. It defaults to false | never send it, and assert that (D-191) |

**What the summary says.** `SourceUpdate.summary` becomes `SourceRef.cachedSummary`, which §5.2
gives two jobs: the baseline a later fetch is described against, and what the app shows when it
says the data is stale. It is built from the issue detail alone —
`In Review · assigned to Leo · updated 2h ago` — from `fields=summary,status,assignee,updated`,
with the relative age rendered at read time rather than baked into the stored string. A summary
that named counts of comments or links would go stale the moment either changed, and §5.2 already
routes the discrete news through `externalUpdate` events (D-168) rather than through this field.

**Connector identity.** `id` is `"jira"` and `displayName` is `"Jira"`. Both are stable across
launches by contract: `id` keys `RefreshOutcome.Failure` and M4-04's per-integration settings, and
`displayName` is what the staleness banner names. `canHandle` claims `kind == .jiraIssue` and
nothing else — Confluence pages are M4-03's, on the same credential.

---

## D-184 — The `since` watermark is derived from `externalUpdate` payloads, not stored on `SourceRef`

**The problem, precisely.** `SourceRefreshService` sends `ref.lastFetchedAt` as `since`, and
D-171 makes that our own clock deliberately, because §10.1 orders the cache pair on it. So the
next window starts at *when we asked*, not at *what we were told*. A comment created at 09:58
that Jira serves at 10:03, after a pass at 10:00, is never reported: the next `since` is 10:00,
and 09:58 is behind it forever. Nothing in M4-01 can see this happen, which is what makes it
worth a decision rather than a retry.

**The fix is an anchor made of data.** A *watermark* is the newest item timestamp this app has
actually reported for a ref. The next window starts there, not at the clock, so an item that
arrives late is still inside it.

**Where the watermark lives: the event log.** Three fields are added to
`ExternalUpdatePayload`, all optional so every row already written still decodes:

```swift
struct ExternalUpdatePayload: Codable, Equatable {
    // …existing: refID, kind, identifier, changes, url, fetchedAt

    /// The newest item timestamp this event reported. `nil` for a payload
    /// written before M4-02, and for a connector that reports no watermark.
    let watermark: Date?

    /// Stable source ids of the items reported here — `history.id`,
    /// `comment.id`. The dedup key (D-186).
    let changeIDs: [String]?

    /// The complete set of state-item ids observed at this fetch, not a delta
    /// (D-187).
    let presentIDs: [String]?
}
```

**Why not a `SourceRef.watermark` field**, which is the obvious shape and was offered: it costs a
REQUIREMENTS amendment (§3.4's field table, a §10.1 merge rule, a §10.2 decision about export),
and the §10.2 decision is a trap. `cachedSummary` and `lastFetchedAt` are excluded from an export
by default because they are bulky and re-fetchable; a watermark in that class would reset on
import, and a reset watermark means the first pass on the new machine reports a ticket's whole
recent history as news. Events, by contrast, are always exported. Deriving the watermark from
them means it transfers for free — and §10.1 already says a field recomputable from the log
should be recomputed from it.

**The read is bounded.** `SourceRefreshService` needs, per ref, the newest few
`externalUpdate` payloads. That requires a query `EventQueries` does not yet have, and it needs
one deliberate exception:

```swift
/// Every event on one task, newest first, **including redacted rows**.
///
/// The exception to this enum's rule. §3.3 hides a redacted event from
/// summaries, and every other descriptor here honours that — but M4-02 reads
/// payloads to decide what it has already reported, and a redaction must not
/// make a change look unreported. Redacting the sentence a user reads is not
/// a statement that the ticket never moved.
public static func allEvents(forTaskID id: UUID) -> FetchDescriptor<Event>
```

The kind is filtered in memory after the fetch, for the reason this file already records twice:
an `EventKind` inside a `#Predicate` does not compile in either spelling. D18 caps the dataset,
so the fetch is the cost and the filter is free.

The resume point is then a pure function of those payloads:

```swift
struct ResumePoint: Sendable, Equatable {
    let watermark: Date?
    let reportedIDs: Set<String>   // union across the scanned payloads
    let presentIDs: Set<String>    // the newest payload's set, exactly
}
```

`watermark` and `presentIDs` come from the newest payload; `reportedIDs` is the union across the
newest ten. Ten rather than one because a pass writes one event per ref, and a dedup window one
event deep would forget everything the previous pass reported the moment a new one lands.

---

## D-185 — `since` is the watermark minus a 15-minute overlap

`since = watermark − 15 minutes`, or `nil` when there is no watermark.

**The overlap is the part that fixes replication lag**, rather than merely re-anchoring on data.
A watermark alone still assumes the item timestamps we saw are the complete set at or below that
instant; Atlassian Cloud is eventually consistent, and an item created at 09:58 can become
visible after one created at 10:01 is. Re-asking the last fifteen minutes each time means the
straggler is inside the window when it appears.

**It costs nothing on an idle ticket**, which is the property that makes a fixed overlap safe
rather than expensive. The window is `[watermark − 15m, now]`, and the watermark only moves when
something is reported — so on a ticket nobody touched, the window start stays put and the scan
stops at the first item older than it. What the request costs is proportional to what changed,
not to how long the ref has existed.

Fifteen minutes is a named constant with the reasoning above attached, not a literal at a call
site. Larger windows cost only duplicate work the dedup discards; the cost of a smaller one is a
lost change, so the asymmetry points one way.

**The `fetch` signature does not change.** `since` stays a single `Date?` — the service computes
a different value for it, and a connector still cannot decide what "since" means (M4-01's rule).

---

## D-186 — De-duplication lives in `SourceRefreshService`, keyed on stable Jira ids

A deliberate overlap means every pass re-reads items it has already reported. Something must drop
them, and it is not the connector.

**D-172 makes the service the only writer**, so the service is what owns the log — and the log is
where the record of "already reported" lives. A connector that de-duplicated would need to read
the event log, which would make every future connector a second reader of `Event` and a second
place the redaction rule has to be honoured.

So the connector reports everything in its window, with ids, and the service filters:

```swift
/// One discrete change, with the id that makes it de-duplicable.
public struct SourceChange: Sendable, Equatable {
    /// Stable within its ref, across launches: `history.id`, `comment.id`,
    /// `String(link.id)`. **Not a hash of the text** — a comment edited after
    /// being reported would then arrive as a new change, and a status flipped
    /// back and forth would collide.
    public let id: String

    /// What §3.3's event body says. Prose for a human, assembled by the
    /// connector.
    public let text: String
}
```

`SourceUpdate.changes` becomes `[SourceChange]`. `ExternalUpdateBody.text` reads `\.text`, so
§3.3's wording, the blank-string dropping and D-169's first-observation rule are all unchanged.

The filter is one expression: a change survives when `!resume.reportedIDs.contains(change.id)`.
Surviving ids are written to the new payload's `changeIDs`.

**One map, computed once, read twice.** The resume point is needed in both halves of a pass — the
dispatch half computes `since` from it, and the write half de-duplicates against it — and both
halves run on the main actor with the rows in hand. So `run` builds a `[UUID: ResumePoint]` before
dispatch and hands it to `applyAndSave`; nothing re-reads the log in the write phase. Computing it
twice would be two queries per ref and, worse, two chances for the two halves to disagree about
what had already been reported.

**A dropped change is not an error and is not counted as one.** It is the overlap working. It is
counted, though: `RefreshOutcome` already carries `superseded` for results a concurrent pass beat,
and duplicates dropped by the overlap are logged as their own number rather than folded into that
one — D-163's rule is that two different facts cannot share a counter.

---

## D-187 — Remote links are a state set, not a delta stream

`RemoteIssueLink` carries no timestamp — not `created`, not `updated` (verified above). A PR
reference therefore cannot be windowed by time at all, and the id-union dedup of D-186 cannot
carry it either: the union is the newest ten payloads, so a link still attached but last
mentioned eleven events ago would be re-reported as new.

So `SourceUpdate` carries a second, differently-shaped list:

```swift
public struct SourceUpdate: Sendable, Equatable {
    public let summary: String
    public let changes: [SourceChange]      // delta items, windowed by time

    /// The **complete** set of state items observed now, not a delta. A member
    /// absent from the previous fetch's set is news; the rest are the status
    /// quo. For Jira this is remote links, which carry no timestamp of any
    /// kind — so set difference is the only thing that can decide what is new.
    public let present: [SourceChange]

    public let url: URL?
    public let fetchedAt: Date

    /// The newest item timestamp the connector is reporting. `nil` when it has
    /// no notion of one, which keeps `since` at `nil` and the window open.
    public let watermark: Date?
}
```

The service reports `present` members whose ids are absent from `resume.presentIDs`, and writes
the **whole** observed set to the new payload's `presentIDs`. The set is exact, one payload deep,
and cannot produce a false re-report.

**A link that disappears is silent.** An `externalUpdate` saying a PR reference was removed is a
report about Jira's own bookkeeping, not about work the user did, and §3.3's log is not a
changelog of the changelog.

---

## D-188 — A first observation stamps a watermark and reports only the summary

D-169 already says the first observation of a ref is an event carrying the summary, not a list of
changes. The watermark adds a second half to that rule, and it is the subtlety most likely to be
got wrong: **the first event must record a watermark computed from the newest items seen, even
though it reports none of them.**

Without it, the first payload has `watermark == nil`, the second pass therefore sends
`since == nil`, and a ticket with three years of history arrives as a hundred "changes" in one
stand-up — the exact failure D-169 exists to prevent, one pass later.

The first observation also records `presentIDs` for every link it saw while reporting none of
them, for the same reason.

The test is written as the sequence, not as one fetch: observe a ticket with existing history,
assert one summary event and no change lines; then fetch again with nothing new on the wire, and
assert **no second event at all**.

---

## D-189 — `HTTPTransport` and the Keychain plumbing move to `Support/`; `Credential` stays in `AI/`

`HTTPTransport`, `HTTPRequest`, `HTTPResponse`, `HTTPHeaders`, `URLSessionTransport` and
`RedirectBlocker` live under `StenoKit/AI/`. §13 and `ARCHITECTURE.md` forbid the source layer
depending on the AI layer, so a Jira client cannot import them where they are.

They move to `StenoKit/Support/Net/`, and the Keychain plumbing (`KeychainQuery`,
`KeychainError`) moves to `StenoKit/Support/Keychain/`. Both layers then depend on a shared
primitive; neither depends on the other. `withDeadline` already made this move for the same
reason in M4-01 (D-177), so the destination is established rather than invented.

**`Credential`, `CredentialStore` and `KeychainCredentialStore` stay in `AI/`.** They are the AI
provider's credential: an enum with an `.oauth` case §7.2 exists to explain, keyed by
`providerID`. Generalizing them to cover an Atlassian site, email, token and expiry date would
produce one type serving two unrelated schemas — and would put the source layer's credential
shape in the AI layer's file, which is the coupling the move exists to avoid. Only the `SecItem`
mechanics are shared, and those are exactly what was earned once: the add-then-update dance that
never leaves the user with no stored secret, and the error mapping.

**Nothing about behaviour changes.** The move is imports and file paths, so the existing suite is
the check that it is a move: the whole suite is run and its count recorded immediately before the
move and again after, and the two must match, with no test edited except for module-internal
visibility. (The count is not written here: it belongs to the tree the commit is made in, and a
number copied from a previous milestone is a claim nobody measured.)

---

## D-190 — One Atlassian credential, one Keychain blob, expiry included; the site is validated

```swift
public struct AtlassianCredential: Sendable, Equatable, Codable {
    /// `acme.atlassian.net`. Host only — the scheme is ours to choose, so a
    /// stored `http://` cannot downgrade a request.
    public let site: String
    public let email: String
    public let apiToken: String

    /// §5.2's user-entered expiry. **Not a secret, and stored with the token
    /// anyway**: the two are one fact, and a token in the Keychain with its
    /// expiry in `AppSettings` is two writes that can half-fail — leaving an
    /// expiry describing a token that is no longer there, which is worse than
    /// no expiry at all. It is also the reason nothing else has to be purged
    /// when the credential is deleted.
    public let expiresAt: Date?
}
```

Stored under one Keychain item, shared by Jira and Confluence (§5.3: one config, two APIs), which
is what lets M4-03 arrive with no credential work at all.

**The site is validated, not trusted.** `AtlassianCredential.baseURL` returns `nil` unless the
host ends in `.atlassian.net` and the URL it builds is `https`. D19 locks the app to Cloud, so
this costs nothing a supported deployment needs — and what it prevents is the failure that
matters on a Basic-auth credential: a mistyped or hostile site value sending
`Authorization: Basic …` to a host the user never intended. A credential whose site fails
validation reads as absent, so `isConfigured` is false and the ref is reported as
not-configured rather than failing mid-pass.

The token never reaches a log. `SourceError` carries no free-form string (D-165), the selftest
prints the site and email but never the token, and `AtlassianCredential`'s `description` is not
synthesized.

---

## D-191 — Read-only is enforced three ways, and `updateHistory` is never sent

D5 is permanent and the task file is explicit: "assert it, do not merely intend it." Three
mechanisms, because each catches something the others cannot.

**1. Only one thing builds a request.** `JiraEndpoint` is an enum of the four reads, and its
`request` property hard-codes `.get`. Nothing under `Jira/` calls `HTTPRequest(method:…)`.

```swift
enum JiraEndpoint: Equatable {
    case issue(key: String)
    case changelog(key: String, startAt: Int, maxResults: Int)
    case comments(key: String, startAt: Int, maxResults: Int)
    case remoteLinks(key: String)
    case currentUser                       // testConnection()

    func request(base: URL, authorization: String) -> HTTPRequest   // always .get
}
```

**2. A decorator that traps.** `ReadOnlyTransport` wraps the transport the connector is given and
`preconditionFailure`s on any method but GET. **A trap, not a `SourceError`** — a mutating request
against Jira is not a network condition the app should degrade around, it is code that must not
ship, and turning it into a caught error would make D5 a silent fallback instead of a stop.

**3. Tests that would notice.** Every `JiraEndpoint` case emits `.get`; a spy transport records
the method of every request issued across a full `fetch` and a `testConnection` and asserts all
are GET; and a test asserts no request's query string contains `updateHistory`, which is the one
read in this API with a documented write side effect (it reorders the user's recent projects).
Each is mutation-checked: flip a case to `.post`, confirm red, revert.

---

## D-192 — 401 maps to `.credentialExpired`; 403 maps to `.invalidCredential`

`SourceError` gains one case, which is a compile error at every exhaustive switch — including
`SourceNotice` and `metricsLabel` — and that is the intent M4-01 recorded.

```swift
/// The service rejected the credential because it has expired or been
/// revoked. §5.2 requires its own case: a 401 during stand-up prep must
/// produce "create a new one" with a link, never "check your connection".
case credentialExpired
```

| Wire | `SourceError` | Why |
|---|---|---|
| offline, DNS, TLS | `.network` | the request never arrived |
| cancelled, or past the per-fetch deadline | `.timedOut` | the service's own budget is the cause |
| **401** | **`.credentialExpired`** | §5.2, unconditionally — see below |
| 403 | `.invalidCredential` | authentication policy or a blocked account: the credential is rejected, but not by expiry |
| 404 | `.notFound` | includes an issue this account cannot see, which is what Jira returns |
| 429 | `.rateLimited(retryAfter:)` | parsed from `retry-after`; `nil` when absent |
| 3xx, 5xx | `.unavailable(status:)` | a redirect is blocked by `RedirectBlocker` and reaches us as a status |
| 2xx that will not decode | `.invalidResponse` | carries nothing, per D-165 |

**401 maps to `.credentialExpired` without consulting the stored expiry date.** The alternative —
`.credentialExpired` only when `expiresAt` is in the past, `.invalidCredential` otherwise —
sounds more precise and is worse: the expiry date is typed in by hand, so it is exactly the field
that is wrong or absent when a token silently expires, and §5.2's requirement is about what a 401
must never produce. A user who mistyped the date would get the generic sentence at the one moment
§5.2 names as the worst.

---

## D-193 — `SourceNotice` returns a message with an optional link, and the 401 sentence hedges once

§5.2 requires the 401 to carry "a direct link". `SourceNotice.text` returns `String?` and
`StandupDraftSheet` renders it as a `Label`, so today there is nowhere for a link to go.

```swift
public enum SourceNotice {
    public struct Message: Sendable, Equatable {
        public let text: String

        /// Rendered as a `Link` beside the sentence. `nil` for every sentence
        /// but the two about the Atlassian token — a banner where each
        /// complaint is also a button is one the user stops reading.
        public let action: Action?

        public struct Action: Sendable, Equatable {
            public let label: String
            public let url: URL
        }
    }

    public static func message(for outcome: RefreshOutcome, now: Date) -> Message?
}
```

`StandupDraftModel.sourceNotice` becomes `Message?`; the sheet renders the label and, when
present, the link. Nothing else in the sheet changes, and D-176 still holds — the notice is app
side only, never in the copied markdown.

**The sentence: "Your Atlassian token expired or was revoked — create a new one."** §5.2's own
words are "your Atlassian token expired", and a 401 is also what a revoked or mistyped token
returns, so the unhedged sentence would state something false in cases the same 401 covers. The
hedge is three words, keeps expiry first, and the link
(`https://id.atlassian.com/manage-profile/security/api-tokens`, confirmed reachable 2026-09-26)
is the actionable half either way. **This nuance is declared in the PR body**, because it is a
deviation from a requirement's literal wording rather than an implementation choice.

The expiring-soon sentence — "Your Atlassian token expires in 9 days" — carries the same link.

---

## D-194 — The expiry warning reaches the notice through the connector, once per pass

The warning must appear before the token dies, on a surface the user actually sees, and §5.2 names
stand-up prep as the moment when discovering it too late hurts. The draft sheet's notice is that
surface today; Settings is M4-04's.

The draft model must not learn what Atlassian is. So the fact travels the layer that already
exists:

```swift
public protocol SourceConnector: Sendable {
    // …existing members

    /// Something about this connector's credential the user should know before
    /// it breaks. **Synchronous and cheap by contract**, like `isConfigured`:
    /// read once per pass, never per ref.
    var credentialWarning: SourceCredentialWarning? { get }
}

extension SourceConnector {
    /// Defaulted, so M4-01's doubles and M5's MCP connector are unaffected.
    public var credentialWarning: SourceCredentialWarning? { nil }
}

public struct SourceCredentialWarning: Sendable, Equatable {
    public let displayName: String
    public let daysRemaining: Int   // negative once expired
}
```

`SourceRefreshService` collects warnings from `registry.all` **once per pass** — one Keychain read,
not one per ref — and stamps them on `RefreshOutcome`.

**On every outcome the service returns, including the early exits.** `refresh(taskIDs:)` returns
`.idle` for an empty list and `RefreshOutcome(readFailed: true)` when the fetch throws; a pass
with no refs in scope must still be able to say the token expires on Friday, so those two paths
construct an outcome carrying the warnings rather than returning the shared constant.

`AtlassianTokenExpiry` is pure and clock-injected: `daysRemaining(expiresAt:now:)`,
`shouldWarn` at 14 days or fewer (and after expiry), and the management URL. Tests assert the
boundary in both directions — 14 days warns, 15 days is silent — because "does not nag before
that" is half of M4-04's acceptance criterion and the rule belongs to this type.

Ranking in `SourceNotice`, per the user's decision:

| Rank | Sentence |
|---|---|
| 1 | fetched updates could not be saved |
| 2 | a fetch failure — a 401 therefore wins, with its link |
| 3 | **the token expires in N days** |
| 4 | some references have no integration set up |
| 5 | could not read your integrations |
| 6 | some integration data is N days old |

An expired-token 401 and an expiring-token warning cannot both be shown, and rank 2 is the right
winner: the first is already breaking, the second is a calendar.

---

## D-195 — Comment bodies are flattened from ADF and truncated

REST v3 returns comment bodies as Atlassian Document Format JSON. Three options: report only
"a new comment", ask for `expand=renderedBody` and parse HTML, or flatten the ADF.

**Flatten the ADF, and carry a gist.** A recall tool exists so the user can say what happened out
loud; "Ana asked for the migration plan" is the sentence they need, and "1 new comment" sends
them to a browser mid-stand-up. HTML was rejected because parsing markup to recover text we can
read structurally is strictly more work and strictly more fragile.

`AtlassianDocument.plainText(_:)` is pure and walks the node tree: `text` nodes contribute their
text, `hardBreak` a space, `mention` its `attrs.text`, `emoji` its `attrs.text` or `shortName`,
`inlineCard` its `attrs.url`; block-level nodes are joined with a single space, and any unknown
node type contributes its children rather than failing. Whitespace is collapsed, and the result
is truncated on a word boundary at 200 characters with an ellipsis.

**Unknown nodes recurse rather than throw.** ADF grows; a node type added next year must cost a
fragment of a sentence, not a `.invalidResponse` for a ticket the user can see in their browser.
Table-tested, including a body that is an empty document, a body of only a mention, and a node
type that does not exist.

---

## D-196 — The changelog is paged backwards from `total`; comments are read newest-first

Neither endpoint takes a date filter, so the window is ours to apply, and the naïve reading of
both is expensive on exactly the long-lived tickets D7 says are normal.

**Comments: `orderBy=-created`, and stop early.** Page newest-first and stop at the first comment
older than `since`. One page for a normal ticket, regardless of how many comments it has.

**Changelog: page backwards from `total`.** The changelog is ascending with no ordering parameter,
so forward paging from `startAt=0` reads a three-year history to find yesterday's transition.
`PageBeanChangelog.total` makes the end reachable: request
`startAt = max(0, total - maxResults)`, walk backwards until entries are older than `since`, and
stop. `isLast` is honoured where it appears; `PageOfComments` has no `isLast`, so comments page on
`startAt + total`.

**Concurrent additions shift `total` under a backwards walk**, and the dedup is what makes that
benign: a shifted page can re-read an item, and a re-read item is dropped by id. A hard page cap
(10) bounds the worst case, and hitting it is logged, not thrown — a partial window with the
watermark set to the newest item *actually read* leaves the rest inside the next pass's window.

All four requests for one ref are issued concurrently inside the connector, under the service's
per-fetch deadline, and every one is `URLSession`-backed so cancellation is honoured — M4-01
makes that a contract, not a nicety.

---

## D-197 — Live verification is `make atlassian-login` and `make verify-jira`

No credential entry UI exists until M4-04, and `make test` denies outbound networking (§9.4,
D-012). Without a harness, nothing in this PR would ever have spoken to Atlassian, and my
fixtures would be the only description of the wire — the position D-143 and D-161 already
identified as unacceptable for the AI transport.

Two hidden subcommands, absent from `CLIUsage.text`, carrying no `ModelContainer` for
`keychain-selftest`'s reason — verifying a credential has nothing to do with the event log:

```
$ make atlassian-login
site:  acme.atlassian.net
email: leo@example.com
token: (read from stdin, never echoed, never in argv)
expires (YYYY-MM-DD, or blank):
stored.

$ make verify-jira ISSUE=PAY-421
PAY-421  In Review · assigned to Leo
changes  status: In Progress → In Review
         comment from Ana: could you add the migration plan…
         linked acme/api#421
watermark 2026-09-25T18:04:11Z   requests 4 GET
```

**The token is read from stdin, not from a flag.** An argument lands in `ps` output and in shell
history, and §8 keeps tokens out of places like that.

Then `make run`, which is the first time M4-01's refresh UI has a live connector behind it
(D-179): the draft sheet's "Refreshing…" line and the staleness banner become reachable, and are
checked through the StenoKit-linked harness and `log show --info` rather than by claiming to have
seen pixels.

---

## Layout

```
StenoKit/Support/Net/               HTTPTransport.swift          (moved from AI/)
                                   URLSessionTransport.swift    (moved from AI/)
StenoKit/Support/Keychain/          KeychainQuery.swift          (moved from AI/)
                                   KeychainError.swift          (moved from AI/)

StenoKit/Integrations/             AtlassianCredential.swift
                                   AtlassianCredentialStore.swift
                                   AtlassianTokenExpiry.swift
                                   SourceChange.swift
                                   ResumePoint.swift
StenoKit/Integrations/Jira/        JiraConnector.swift
                                   JiraClient.swift
                                   JiraEndpoint.swift
                                   JiraWire.swift
                                   JiraChangeSet.swift
                                   AtlassianDocument.swift
                                   ReadOnlyTransport.swift
StenoKit/CLI/                      AtlassianLogin.swift
                                   JiraSelftest.swift

modified: SourceConnector.swift (SourceUpdate, credentialWarning)
          SourceError.swift (credentialExpired)
          SourceNotice.swift (Message, ranking)
          ExternalUpdate.swift (payload fields, body reads SourceChange.text)
          SourceRefreshService*.swift (resume point, dedup, warnings)
          EventQueries.swift (allEvents(forTaskID:))
          StandupDraftModel.swift, StandupDraftSheet.swift (Message + link)
          CLICommand.swift, CLIParser.swift, CLIEntry.swift, Makefile
          StenoApp.swift (register the connector)
```

Registration is one array literal at the composition root, because order is priority (D-166):

```swift
private let sourceRegistry = SourceRegistry(connectors: [JiraConnector(…)])
```

---

## Verification

**Offline, under `make test`'s sandbox.** Fixtures are hand-built from the OpenAPI shapes recorded
above: issue detail; a two-page changelog with `isLast`; comments paged on `startAt + total` with
no `isLast`; remote links; and 401, 403, 404, 429 with and without `retry-after`, 500, a 302, and
a 200 of garbage.

| Area | What must fail if it breaks |
|---|---|
| `JiraChangeSet` | status, assignee, comment and link changes; items whose input order disagrees with expected output order; window boundaries |
| Watermark | **a change timestamped before the previous `lastFetchedAt` is still reported** — D-183 as one executable assertion, written failing first against the old behaviour |
| First observation | summary only, watermark stamped, and a second no-change fetch writes no event |
| Dedup | a repeated id is dropped; a link set difference reports only newcomers; a redacted prior event still de-duplicates |
| ADF | mentions, inline cards, nested lists, empty document, unknown node type |
| Read-only | every endpoint GET; every request in a full pass GET; `updateHistory` absent |
| Errors | the whole status table, including `retry-after` parsing |
| Notice | the six-rank order, the 401 sentence and its link, 14 days warns, 15 days silent |
| Payload | round-trips with `.sortedKeys`; a `Mirror` over declared properties asserts every non-nil field reaches the JSON, so an added field cannot be silently omitted |
| Credential | a non-`atlassian.net` site and an `http` site both read as unconfigured |

Every new test is mutation-checked before it counts: break the code it covers, watch it go red,
restore. A test that cannot fail is the defect class this repo keeps meeting, and a fixture that
models the wire the way the design imagines it is the same failure wearing a different hat.

**Gates:** `make build && make test && make lint` green; `make format` leaves the tree clean;
then `make atlassian-login`, `make verify-jira ISSUE=…`, and `make run` for D-179's visual check.

---

## Out of scope

- **Confluence** (M4-03). It shares `AtlassianCredential` and every piece of the resume-point
  machinery, and nothing here is Jira-shaped that should not be.
- **Credential entry UI, the enable toggle, "Test connection" as a button, the Settings copy of
  the expiry warning, and "Purge cached external data"** (M4-04). `testConnection()` is
  implemented here; the button that calls it is not.
- **Any write to Jira** (D5), permanently. Q(M4) — auto-transitioning a task when its ticket
  closes — stays open and read-side only; nothing here implements it.
- **Data Center compatibility** (D19, §5.2: do not write that code).
- **A per-ref failure record.** `SourceError.notFound` records why: suppressing the retry needs
  persisted state, and therefore export, import and merge rules, to save one request per pass.
- **Background refresh** (M4-05), which is what will want a catch-up `since` different from this
  one — the reason `fetch` takes `since` explicitly at all.

---

## Risks

1. **The fixtures are the wire contract until `verify-jira` runs.** Mitigated by building them
   from Atlassian's own OpenAPI document and recording its facts above, and closed by D-197's
   harness — but if the live run disagrees, the fixtures are what is wrong, and the finding goes
   in the PR body.
2. **Backwards paging is the least ordinary part of this design.** `total` shifting under a walk
   is handled by dedup and a page cap; a ticket whose changelog is mutated heavily during a pass
   may need a second pass to report everything, which the watermark makes correct rather than
   lossy.
3. **The payload is growing.** Three optional fields now, and it is the one part of the export
   that is base64 and byte-exact (§10.2). `.sortedKeys` is already there and the `Mirror` test
   guards omission, but a fourth consumer of this payload would be the moment to give it a
   version field.
4. **`credentialWarning` reads the Keychain on the main actor.** Once per pass, not per ref, and
   a Keychain read is sub-millisecond — but it is a synchronous call in a path M4-01 spent a
   milestone keeping non-blocking, so the per-pass discipline is a contract in the protocol's doc
   comment, not a convention.
5. **The `Support/` move touches 20-odd files this task otherwise has no business in.** It is
   imports only, and the existing suite is the check; it lands as the first commit so a reviewer
   can read it alone.
6. **This design was not written from a built tree.** Every block above is illustrative, and this
   repo's standing lesson is that plan code verified standalone still fails inside its module —
   so the implementation plan is generated from a compiled tree, and any shape here that does not
   survive contact with the compiler is reported as a finding against this spec rather than
   quietly adjusted.

---

## Proposed REQUIREMENTS.md amendment

**None.** That is the point of D-184: deriving the watermark from the event log leaves §3.4's
field table, §10.1's merge rules and §10.2's export toggle untouched, where a
`SourceRef.watermark` field would have needed all three.

Two things are declared in the PR body instead, because neither is an amendment but both are
places where the implementation and a literal reading of the spec differ:

1. **§5.2's 401 sentence gains three words** — "expired **or was revoked**" — so it is not false
   for the other cases a 401 covers (D-193).
2. **§5.2's "warn in-app 14 days before expiry" is satisfied by the draft sheet's notice in this
   PR**, with Settings following in M4-04 as that task's own scope already says.
