# M4-03 — Confluence Connector: design

**Status:** proposed 2026-09-29
**Task:** [`docs/tasks/M4-03-confluence-connector.md`](../../tasks/M4-03-confluence-connector.md)
**Requirements:** §5.3, §5.5, §3.3, §3.4, §8, §13, D5, D7, D19
**Branch:** `feat/confluence-connector`

---

## What this builds

The second `SourceConnector`: a read-only Confluence Cloud client that turns a `SourceRef` of
kind `confluencePage` into the `externalUpdate` events a stand-up is assembled from, on the
credential M4-02 already stores.

§5.3 is two bullets long and one of them carries a warning: *"Jira and Confluence are distinct
REST APIs; do not conflate them."* So the shared half is shared deliberately and the rest is not
shared at all. Four things move out of `Integrations/Jira/` into `Integrations/Atlassian/`
because they were never about Jira, and everything that knows the shape of a response is written
fresh.

| Piece | Responsibility | Needs no |
|---|---|---|
| `ConfluenceEndpoint` | build the four GETs, and nothing else | network, store, credential |
| `ConfluenceWire` | `Decodable` mirrors of the four responses | network, store |
| `ConfluenceChangeSet` | wire + `since` → `[SourceChange]` + watermark | network, store, clock |
| `ConfluenceClient` | cursor paging, the name lookup, status → `SourceError` | store |
| `ConfluenceConnector` | the `SourceConnector` conformance | store |
| `ConfluenceSelftest` | D-197's live check, against the real API | — |

Three of the six need neither a network nor a store, which is what lets the wire contract, the
change vocabulary and the window boundaries be table-tested offline under §9.4's sandbox.

The connector joins `JiraConnector` in `StenoApp`'s `SourceRegistry`, so configuring Atlassian
once enables both — which is the acceptance criterion §5.3 states as "one config, two APIs".

---

## The design brief

What the user decided, in the four questions this design was built from:

1. **Content comes from REST v2; editor *names* come from the v1 user GET.** v2 version objects
   carry `authorId` and no display name, and the only v2 way to resolve one is
   `POST /wiki/api/v2/users-bulk` — a POST, which `ReadOnlyTransport` traps by construction. The
   name lookup is `GET /wiki/rest/api/user?accountId=…`, which is a read, is a GET, and is not in
   the deprecated set (D-200, D-201).
2. **One `SourceChange` per version**, id `<pageID>#v<number>`, minor edits labelled rather than
   dropped. A collapsed "edited 3 times" has no stable id, so it would either re-report every
   pass or need a synthetic key that changes whenever the count does (D-203).
3. **The neutral plumbing moves to `Integrations/Atlassian/`.** One D5 trap, one 401 rule, one
   date parser, one credential memo — endpoints, wire types and change sets stay per-API (D-202).
4. **A Confluence ref is claimed only when its URL is on the configured site** (D-204).

Assumptions this design makes that the user did not state, each stated so it can be corrected:

- `testConnection()` reads `GET /wiki/api/v2/spaces?limit=1` rather than a user endpoint, so a
  credential that works for Jira but has no Confluence access fails the Confluence test
  specifically — which is the sentence FR-6 exists to produce.
- Name lookups are memoized **per fetch**, not per pass, and bounded at ten distinct accounts.
- A version with no `message` reads as `v7 by Leo Gutierrez` — the version comment is included
  when the editor typed one, and nothing stands in for it when they did not.
- `SourceUpdate.present` stays empty: Confluence has no untimestamped state stream, so D-187's
  set machinery is unused here rather than repurposed.

---

## What this task decides

| # | Decision |
|---|---|
| D-200 | Confluence is REST v2; the v1 content API is past its announced removal date |
| D-201 | Editor names come from the v1 user GET, memoized per fetch; a failed lookup says "someone" |
| D-202 | The neutral Atlassian plumbing moves to `Integrations/Atlassian/`; wire and endpoints stay per-API |
| D-203 | One `SourceChange` per version, keyed `<pageID>#v<number>`; minor edits are labelled, not dropped |
| D-204 | A Confluence ref is claimed only when its URL is on the configured site |
| D-205 | Cursor paging rebuilds the request from the cursor; `_links.next` is never followed |
| D-206 | A failed version walk fails the ref; an empty delta is never reported |

---

## Verified wire facts

Confirmed on **2026-09-29** against Atlassian's published v2 reference and its developer
community announcements, not from memory. They are recorded here because until
`make verify-confluence` first runs, **the fixtures in this PR are the wire contract**, and a
fixture wrong in the same way as the design is a test that cannot fail.

| Fact | Consequence |
|---|---|
| The v1 deprecation set was announced for removal on **2025-03-31**, four months after the 2024-11-28 notice | v1 content endpoints are not a design option (D-200) |
| `GET /wiki/rest/api/user` carries **no deprecation notice** in the current v1 reference | the name lookup is available, and is a GET (D-201) |
| `GET /wiki/api/v2/pages/{id}` returns `id`, `status`, `title`, `spaceId`, `authorId`, `ownerId`, `createdAt`, `version{number, createdAt, message, minorEdit, authorId}`, `_links{webui, editui, tinyui}` | title, current version and the human-facing URL come from one request |
| Its `version` carries **`authorId` only** — no display name, and no expansion produces one | the name lookup is not optional (D-201) |
| `GET /wiki/api/v2/pages/{id}` takes `include-version`, which **defaults to `true`** | the current version arrives without being asked for |
| `GET /wiki/api/v2/pages/{id}/versions` takes `sort`, `limit`, `cursor` and `body-format`; `limit` defaults to 25 and caps at 250 | the window is applied client-side, newest-first |
| `VersionSortOrder` is exactly `["modified-date", "-modified-date"]` | `sort=-modified-date` is valid, and is the whole basis of the backwards walk |
| A `Version` carries `createdAt`, `message`, `number`, `minorEdit`, `authorId` — and nothing else | `createdAt` is the watermark source; `number` is the dedup key (D-203) |
| v2 paginates by **cursor**: the response's `_links.next` is a *relative* URL carrying a `cursor` query item, mirrored by a `Link: <…>; rel="next"` header, and absent when the walk is done | paging is neither `startAt` nor `isLast`; the cursor is extracted, not followed (D-205) |
| The only v2 account-id → name endpoint is `POST /wiki/api/v2/users-bulk` | rejected: `ReadOnlyTransport` allows GET and nothing else (D5, D-191) |

**Where these came from.** The reference pages name the parameters but truncate their enums, so
every row above was read out of Atlassian's own OpenAPI document —
`https://dac-static.atlassian.com/cloud/confluence/openapi-v2.v3.json`, 600 KB, HTTP 200,
`info.version` 2.0.0 — on 2026-09-29, the way M4-02 read the Jira contract out of
`swagger-v3.v3.json`. The one value this design depends on most, `sort=-modified-date`, was the
reason: the reference page names the type `VersionSortOrder` and does not list its cases, and an
unverified sort value would have made the backwards walk silently ascending or a `400`.

The document also settles the response envelope: a versions page is
`MultiEntityResult<Version>` — `results[]` plus `_links{next, base}`, where `next` is documented
as *"the relative URL for the next set of results, using a cursor query parameter"* and is absent
when the walk is done. A single page's `_links` is `{webui, editui, tinyui}` with no `base`, which
is why `SourceUpdate.url` is built from the credential's own host rather than from the response.

**What the summary says.** `SourceUpdate.summary` becomes `SourceRef.cachedSummary`, which §5.3
and §5.2 give two jobs: the baseline a later fetch is described against, and what the app shows
when it says the data is stale.

```
Payments Migration Plan — v9, edited by Leo Gutierrez
```

Title, current version number, last editor. **No timestamp in it**, and §5.3 asks for one: the
last-modified timestamp is the current version's own `createdAt`, which this design carries as
the watermark, while how old the *data* is remains the staleness banner's job, spoken from
`lastFetchedAt` (D-176). A stored string saying "edited 2h ago" would be wrong the moment after
it was written. Missing parts are omitted rather than rendered as the word unknown: a page whose
editor could not be named reads `Payments Migration Plan — v9`.

**Connector identity.** `id` is `"confluence"` and `displayName` is `"Confluence"`. Both are
stable across launches by contract: `id` keys `RefreshOutcome.Failure` and M4-04's
per-integration settings, and `displayName` is what the staleness banner names. The credential
warning and the renewal URL come from the same `AtlassianTokenExpiry` the Jira connector uses, so
a single stored expiry date warns once per connector and both point at the same page.

---

## D-200 — Confluence is REST v2, because v1 is past its removal date

**The decision.** Every Confluence content request this app makes is REST v2, under
`/wiki/api/v2/`. The v1 content API — `/wiki/rest/api/content/{id}?expand=version,history` — is
not used, even though it answers three of §5.3's four fields in one request and names the editor
without a second lookup.

**Why.** Atlassian announced the removal of the deprecated v1 set for 2025-03-31. That date is
eighteen months past. Building this connector on an API whose removal has already been announced
and scheduled would be shipping a feature with a known expiry, and §5.2's whole token-expiry
section exists because this project treats a scheduled, guaranteed failure as something to handle
rather than to discover.

**What it costs, stated plainly.** v1 would have been two requests instead of three — content and
version history — and it would have carried `version.by.displayName` directly. v2 costs the extra
lookup D-201 describes. That is the price of an API that will still be there.

**The corollary that is not obvious.** "v1 is deprecated" is not the same claim as "every path
under `/wiki/rest/api/` is deprecated". The deprecation applies to a published set, and
`GET /wiki/rest/api/user` is not in it — which is what makes D-201 possible at all. This
distinction is recorded because a future reader who remembers only "v1 is gone" would delete the
one v1 call in this connector and break the editor's name.

---

## D-201 — Editor names come from the v1 user GET, memoized per fetch

**The problem.** §5.3 requires the last editor, and the task's acceptance criteria require that
editor to appear in the report. A v2 version object carries `authorId` — an Atlassian account id,
`557058:aa1b…` — and nothing else about the person. No `expand`, no include parameter and no
other v2 content endpoint turns that into a name.

**The three candidates, and why the third wins.**

1. `POST /wiki/api/v2/users-bulk` is the v2 answer. It is a POST. `ReadOnlyTransport` allows GET
   and nothing else, and it does so with a `preconditionFailure` rather than a thrown error,
   precisely so that D5 cannot degrade into a fallback that a caching path papers over.
   Permitting one POST would turn "read-only by construction" into "read-only by allow-list",
   which is a materially weaker property and a precedent this repo has already decided not to set.
2. Reporting the raw account id satisfies the letter of "last editor" and none of its purpose. A
   stand-up line reading `v7 by 557058:aa1b…` is worse than no attribution.
3. `GET /wiki/rest/api/user?accountId=…` is a read, is a GET, and is not in the deprecated set.

**So: one GET per distinct `authorId` in the window.** Memoized in a local dictionary for the
duration of one `changeSet` call, so a page edited six times by two people costs two lookups.
Bounded at **ten distinct accounts per fetch**; beyond that the remaining editors read as
"someone" and the cap is logged. The bound is not for the ordinary case — D7 says Confluence refs
are rare and D18 caps the pass at twenty tasks — it is so that one pathological page cannot spend
a refresh pass's whole budget on name lookups.

**Per fetch, not per pass, and that is a deliberate under-engineering.** A shared cache across a
pass would save requests when the same person edited several pages, and it would need a second
locked class alongside `AtlassianCredentialCache`, with its own invalidation question. §5.3's own
note — "Confluence refs are likely rarer than Jira ones; keep the implementation proportionate" —
says which side of that trade to be on.

**A failed lookup never fails the fetch.** The name is cosmetic; the version happened either way,
and §5.5 would rather report `v7 by someone` than degrade a whole ref to cache over a display
name. This is the opposite of D-206's rule for the version walk, and the difference is whether
the missing data changes what the user is told *happened*.

**§8.** The response is a large user object — email, time zone, personal space, permissions. The
wire mirror models `displayName` and nothing else, so nothing else is decoded or outlives the
response buffer, and no name is logged.

---

## D-202 — The neutral Atlassian plumbing moves to `Integrations/Atlassian/`

**What moves, and why each one was never Jira's.**

| Moved | Was | Why it is neutral |
|---|---|---|
| `ReadOnlyTransport` | `Jira/` | D5 says "Jira/Confluence access, read-only, permanently". The trap is about Atlassian |
| `JiraErrors` → `AtlassianErrors` | `Jira/` | pure functions over a status code and headers; no Jira concept appears in it |
| `JiraDate` → `AtlassianDate` | inside `JiraWire.swift` | an ISO-8601 parser with two format options |
| `AtlassianCredentialCache` | inside `JiraConnector.swift` | already named for the credential it memoizes, and both connectors read that credential per ref |
| `AtlassianCredential`, `AtlassianTokenExpiry` | `Integrations/` root | already neutral, already named so; they simply join the folder |

**The one branch that deserves an argument.** `AtlassianErrors` maps `400` to `.notFound`, and
the comment justifying it is Jira-specific: "Jira answers 400 for a malformed issue key, and a
malformed key is a mistyped reference in a task title." The same reading holds for Confluence — a
page id that is not a number is a mistyped or mangled reference, and `.notFound` is the sentence
that helps — so the mapping is genuinely shared rather than conveniently shared. The comment is
rewritten to say so, naming both APIs, because a shared rule justified by one caller's behaviour
is how the next reader concludes it does not apply to them.

**What does not move.** `JiraEndpoint`, `JiraWire`, `JiraChangeSet`, `JiraClient`,
`AtlassianDocument`. §5.3's warning is exactly about these: the two APIs page differently (Jira
`startAt`/`total`, Confluence `cursor`), shape their responses differently, and describe change
differently. A common client would leak both APIs through one interface within a milestone.

**The cost, up front.** This PR moves files M4-02 merged yesterday, so the diff contains
renames a reviewer has to read past. It lands as the **first commit**, imports and call sites
only, with the existing suite as the check — the same shape D-189 used when the transport and
Keychain plumbing moved to `Support/`, and the same reason: the alternative is two copies of a
guard, and this repo has already shipped a review fix that landed on the type in the diff and not
on the other four.

---

## D-203 — One `SourceChange` per version, keyed `<pageID>#v<number>`

**The decision.** Every version created at or after `since` becomes one `SourceChange`:

```
id    12345#v7
text  v7 by Leo Gutierrez: tightened the migration steps
```

- No version message: `v7 by Leo Gutierrez`
- Editor not resolvable: `v7 by someone`
- `minorEdit == true`: `v9 by Leo Gutierrez (minor)`

**Why not collapse.** "Edited 3 times since Monday" has no stable identity. `SourceRefreshService`
de-duplicates on `SourceChange.id` against the ids the event log records (D-186), so a collapsed
line either repeats on every pass or carries a key that changes with the count — which means the
same edits are reported again under a new id the moment a fourth arrives. Per-version ids are
what make the overlap window (D-185) safe.

**Why minor edits are labelled rather than dropped.** `minorEdit` is Confluence's "don't notify
watchers" checkbox. It says something about notification preference, not about whether work
happened, and a user who ticks it out of habit would find their afternoon's editing invisible in
the morning's stand-up. Labelling costs four characters and keeps the decision with the reader.

**The id's prefix is for legibility, not for collision-avoidance.** `ResumePoint.from(payloads:)`
is documented as taking payloads already filtered to one `refID`, so a bare `v7` could not collide
with another page's version anyway. The page id is in the key so that a payload read in an export
or a log line says which page it belongs to — the same reason a Jira transition's key is
`<historyID>#<field>` rather than the field alone.

**An unparseable `createdAt` is reported, not dropped**, following the Jira changelog's rule: it
cannot be placed in the window, the id-based dedup stops it being said twice, and dropping it
would lose a real edit to a date-format change.

---

## D-204 — A Confluence ref is claimed only when its URL is on the configured site

**The rule**, in three cases:

| Ref | Claimed? |
|---|---|
| `.confluencePage` with a URL on the configured host | yes |
| `.confluencePage` with a URL on an Atlassian Cloud host, **nothing configured yet** | yes |
| anything else — no URL, a non-Cloud host, another `*.atlassian.net` site, another kind | no |

Everything in the third row returns false, which `SourceRegistry` reports as `.unhandled`:
nothing is fetched and nothing is said.

**The second row is not a softening of the first, and leaving it out was a real hole in the
first draft of this design.** With no credential stored there is no host to compare against, so a
strict "must match the configured host" would refuse every Confluence ref on a fresh install —
and `JiraConnector` claims a Cloud URL in exactly that state so the ref reports `.notConfigured`
and the user is told to go to Settings. Without the same rule here, an unconfigured machine would
say "Atlassian is not set up" for a Jira ref and stay silent about a Confluence one on the same
task, which is the opposite of the sentence §5.3's "one config, two APIs" is meant to produce.
Once a credential exists the comparison is strict again, so this widens nothing for a configured
user.

**Why this is not D-199's rule.** D-199 lets `JiraConnector` claim a *bare* key with no URL,
because a ticket key in a task title is D7's common case and the only instance it could mean is
the configured one. Confluence has no equivalent:

- A page id is a number a human never types. `SourceURLClassifier` is the only producer of
  `.confluencePage` refs in this codebase, and it always sets `url` — verified, not assumed.
- That classifier claims page ids **without a host check**, deliberately, and documents the
  consequence: `https://example.com/pages/12/34` becomes `.confluencePage "12"`. Claiming a
  URL-less ref would mean fetching page 12 from the user's own wiki for a reference that came
  from somewhere else — a stand-up line about a document they have never seen.

So the only shape this rule refuses that the app can actually produce is a hand-edited import, and
for that shape silence is better than a confident answer from the wrong site.

**`.unhandled`, not `.notConfigured`.** Nothing here can serve those refs, and telling the user to
configure Atlassian would not help — the same reasoning D-199 records for a Jira URL on another
instance.

---

## D-205 — Cursor paging rebuilds the request from the cursor; `_links.next` is never followed

**The problem.** v2 pages by opaque cursor. The response hands back `_links.next` — a relative URL
already containing the right `cursor` — and the obvious implementation is to send it.

**Why not.** This connector authenticates with HTTP Basic: every request carries the user's
Atlassian token in a header. Following a URL that came from a response body means the destination
of an authenticated request is chosen by the response rather than by this app. `_links.next` is
relative today, and `RedirectBlocker` already exists in this codebase because the same question
was answered the same way for redirects.

It would also put a second request builder in the app. `JiraEndpoint`'s doc comment states that
"the connector never writes" is a property of the one place a request can come from; a code path
that constructs a request from a string breaks that property for Confluence.

**The rule.** Parse `_links.next`, extract the `cursor` query item, discard everything else, and
build the next request through `ConfluenceEndpoint.versions(pageID:cursor:limit:)`. A `next` with
no `cursor` item ends the walk rather than being followed as-is.

**The cap.** Ten pages of fifty, matching `JiraClient.maxPages`, with the same consequence and the
same honesty about it: hitting the cap means the *oldest* versions inside the window were not
read, so the walk reports `isWindowCapped` and `ConfluenceChangeSet` holds the watermark at the
oldest `createdAt` it did read, floored to no later than the newest. Without that, the next pass
would start above the gap and never look at it again. The cap is logged at `error` with the page
named, because it is a gap in what the user was told rather than a slow pass.

---

## D-206 — A failed version walk fails the ref; an empty delta is never reported

**The asymmetry this records.** Three requests make up a fetch, and they fail differently:

| Request | On failure |
|---|---|
| `GET /pages/{id}` | fail the ref — there is no title, no version, no summary |
| `GET /pages/{id}/versions` | **fail the ref** |
| `GET /user?accountId=` | continue; the editor reads "someone" (D-201) |

**Why the version walk cannot degrade to "no changes".** The watermark advances on every fetch
that writes an event, including one that reports nothing (D-188). So a fetch that treated a failed
version request as an empty delta would tell the user nothing changed *and* move the window past
the changes it failed to read — and the next pass would start after them. The news would not be
delayed; it would be gone.

This is the same trap D-187 avoided for Jira's remote links, where an empty set on failure would
have made every existing link look new. Here the direction is reversed and the outcome is worse:
a silent loss rather than a false positive.

**What the user sees instead.** `SourceError` propagates, `SourceRefreshService` records the
failure without writing an event, the watermark stays where it was, and §5.5's degradation shows
the cached summary with a visible staleness label. The next pass retries the same window.

---

## Layout

```
StenoKit/Integrations/Atlassian/    AtlassianCredential.swift        (moved; it also holds the
                                                                    store protocol and the
                                                                    Keychain store)
                                   AtlassianTokenExpiry.swift       (moved)
                                   AtlassianCredentialCache.swift   (extracted from JiraConnector)
                                   AtlassianErrors.swift            (renamed from Jira/JiraErrors)
                                   AtlassianDate.swift              (extracted from Jira/JiraWire)
                                   ReadOnlyTransport.swift          (moved from Jira/)
StenoKit/Integrations/Confluence/   ConfluenceConnector.swift
                                   ConfluenceClient.swift
                                   ConfluenceEndpoint.swift
                                   ConfluenceWire.swift
                                   ConfluenceChangeSet.swift
StenoKit/CLI/                      ConfluenceSelftest.swift

modified: Jira/*.swift            (imports, AtlassianErrors, AtlassianDate call sites)
          CLICommand.swift, CLIParser.swift, CLIRunner.swift, CLIEntry.swift
          Makefile                (verify-confluence)
          StenoApp.swift          (register the connector; and delete the stale doc comment
                                   above the registry, which still says "Empty this milestone"
                                   from M4-01 alongside M4-02's replacement for it)
          docs/tasks/README.md    (tick M4-03)
```

Registration stays one array literal at the composition root, because order is priority (D-166):

```swift
private let sourceRegistry = SourceRegistry(connectors: [
    JiraConnector(credentials: AtlassianKeychainStore()),
    ConfluenceConnector(credentials: AtlassianKeychainStore()),
])
```

Two store values rather than one shared instance: `AtlassianKeychainStore` is a stateless struct
over one Keychain item, so the credential is the same either way — and each connector keeps its
own thirty-second memo of it (D-198), which is what that memo is for.

The four endpoints, in full:

| Case | Path | Query |
|---|---|---|
| `page(id:)` | `/wiki/api/v2/pages/{id}` | — |
| `versions(pageID:cursor:limit:)` | `/wiki/api/v2/pages/{id}/versions` | `sort=-modified-date`, `limit`, `cursor` when resuming |
| `user(accountID:)` | `/wiki/rest/api/user` | `accountId` |
| `spaces(limit:)` | `/wiki/api/v2/spaces` | `limit=1` — `testConnection()` only |

`body-format` is never sent, so the API has no format to render a body in, and `ConfluenceWire`
does not model `body` either — a page's text is neither asked for nor decoded if it arrives
anyway (§8). The page id is validated as ASCII digits before it
reaches a URL, for the reason `JiraEndpoint.isValidKey` exists: an id that is not an id is a
mistyped reference, answered locally as `.notFound` rather than spent on a round trip.

`SourceUpdate.url` is the human-facing page — the credential's base URL, `/wiki`, then the page's
`_links.webui` — falling back to the ref's own URL when `webui` is absent.

---

## Verification

**Offline, under `make test`'s sandbox.** Fixtures are hand-built from the v2 shapes recorded
above: a page with and without a version message; a two-page versions walk with `_links.next` and
then without; a `next` whose URL points at another host; a version with an unparseable
`createdAt`; a user response; and 401, 403, 404, 429 with and without `retry-after`, 500, a 302,
and a 200 of garbage.

| Area | What must fail if it breaks |
|---|---|
| `ConfluenceChangeSet` | version lines, the minor label, the missing-message form, the unknown-editor form; input order disagreeing with expected output order |
| Window | a version created exactly at `since` is reported; one a second before is not |
| Watermark | the newest `createdAt` is stamped **even when nothing is reported**; a capped walk holds the floor and never exceeds the newest seen |
| First observation | summary only, watermark stamped, and a second no-change fetch writes no event |
| Cursor paging | the cursor is taken from `_links.next` and the request rebuilt; a `next` on another host is not followed; a `next` with no cursor ends the walk; the ten-page cap sets `isWindowCapped` |
| Names | one GET per distinct `authorId`; a 404 on the lookup yields "someone" and does not fail the fetch; the ten-account cap |
| D-206 | a failing versions request throws rather than reporting an empty delta — written failing first against an implementation that swallows it |
| Routing | configured host, another `*.atlassian.net`, another host, no URL, wrong kind, **and a Cloud URL with nothing configured, which must dispatch `.notConfigured` rather than `.unhandled`** |
| Read-only | every endpoint is GET; every request in a full fetch is GET |
| Errors | the whole status table, shared with Jira's after the rename |
| Moves | the existing Jira suite passes unchanged against `AtlassianErrors` and `AtlassianDate` |

Every new test is mutation-checked before it counts: break the code it covers, watch it go red,
restore. A test that cannot fail is the defect class this repo keeps meeting, and a fixture that
models the wire the way the design imagines it is the same failure wearing a different hat.

**Gates:** `make build && make test && make lint` green; `make format` leaves the tree clean;
then `make verify-confluence PAGE=…` against the real site with the credential
`make atlassian-login` already stored, and `make run` to see a Confluence ref resolve in the app.

`make verify-confluence PAGE=12345` prints what the connector would report — the summary, each
version line, the watermark — plus the number of requests and their methods, because "read-only"
is a claim worth seeing confirmed against the live API rather than only in a spy's assertions
(D-191, D-197). It asks a 30-day window for the reason `JiraSelftest` does: `nil` would establish
an anchor and report nothing, which is correct behaviour and useless output.

---

## Out of scope

- **Credential entry UI, the enable toggle, "Test connection" as a button, and "Purge cached
  external data"** (M4-04). `testConnection()` is implemented here; the button that calls it is
  not.
- **Any write to Confluence** (D5), permanently — including the one POST that would only read.
- **Confluence comments, attachments, blog posts, whiteboards, databases.** §5.3 names four
  things: page title, last-modified timestamp, last editor, version delta. A page's comment
  stream is a second delta with its own paging and its own dedup key, and §5.3 does not ask for
  it.
- **The legacy `/display/SPACE/Title` URL form.** `SourceURLClassifier` deliberately returns
  `.url` for a page with no numeric id, because §3.4 says the identifier *is* the page id.
  Resolving a title to an id is a search request against a different endpoint.
- **A shared per-pass name cache** (D-201), and any other cross-connector state.
- **Background refresh** (M4-05).

---

## Risks

1. ~~**`sort=-modified-date` is the one parameter value not confirmed.**~~ **Closed before the
   plan was written**, by reading `VersionSortOrder` out of the OpenAPI document: the enum is
   exactly `["modified-date", "-modified-date"]`. It is left here rather than deleted because the
   check is the point — an unverified sort value would have made the backwards walk silently
   ascending, and this repo has shipped a decision record containing an unmeasured claim before.
2. **The fixtures are the wire contract until `verify-confluence` runs.** Mitigated by building
   them from the published v2 shapes recorded above, and closed by the harness — but if the live
   run disagrees, the fixtures are what is wrong, and the finding goes in the PR body.
3. **The move touches files M4-02 merged yesterday.** Imports and call sites only, landing
   as the first commit so a reviewer can read it alone, with the existing suite as the check.
4. **One v1 endpoint in a v2 client will look like an oversight.** D-200 states why it is not,
   and the endpoint's own case carries a comment; if Atlassian later deprecates
   `/wiki/rest/api/user`, the fallback is already implemented, because a failed lookup degrades
   to "someone" by design rather than by accident.
5. **A page edited by many people costs many requests.** Bounded at ten lookups and ten pages per
   fetch, inside the per-fetch deadline `SourceRefreshService` already enforces — but it is a
   request count that scales with someone else's editing habits, which is a shape this app has
   not had before.
6. **This design was not written from a built tree.** Every block above is illustrative, and this
   repo's standing lesson is that plan code verified standalone still fails inside its module —
   so the implementation plan is generated from a compiled tree, and any shape here that does not
   survive contact with the compiler is reported as a finding against this spec rather than
   quietly adjusted.

---

## Proposed REQUIREMENTS.md amendment

**One, small.** §5.2 opens with "Deployment: Atlassian Cloud (D19). REST API v3. Do not write
Data Center compatibility code." §5.3 says nothing about which API it means, which was harmless
while no code existed and is now the difference between an implementation that works and one
built on endpoints whose removal was announced for 2025-03-31.

§5.3 gains one line, matching §5.2's shape:

> **Deployment: Atlassian Cloud (D19). REST API v2** — the v1 content API is past its announced
> removal date. Editor display names are not available from v2 content endpoints and are resolved
> separately (D-201).

REQUIREMENTS.md goes to **v1.23** with a changelog entry recording that this is a statement of
which API satisfies §5.3, not a change to what §5.3 requires: the four fields, the shared
credential and the §5.5 degradation are all untouched.

Nothing else changes. §3.4's field table, §10.1's merge rules and §10.2's export toggle are
unaffected, because D-184's watermark already lives in the event log and this connector writes
nothing of its own.
