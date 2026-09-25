# M4-01 — SourceConnector Protocol, Cache & Refresh Policy: design

**Status:** approved 2026-09-25
**Task:** [`docs/tasks/M4-01-source-connector-protocol.md`](../../tasks/M4-01-source-connector-protocol.md)
**Requirements:** §5.1, §5.5, §3.4, §3.3, §7.4, FR-4 step 4, §13
**Branch:** `feat/source-connector-protocol`

---

## What this builds

The source layer's spine: one protocol every external fetch goes through, a registry that routes
a `SourceRef` to the connector that handles it, a durable last-known-state cache, and the
refresh policy that makes §5.5's "a failed integration must never block report generation" a
property of the code rather than a rule someone has to remember.

**No real connector ships here.** Jira is M4-02, Confluence M4-03, MCP M5. The production
registry is built empty, so at runtime this milestone changes nothing a user can see; the
subsystem is exercised end to end by a test double. That is the same shape M3-01 shipped before
M3-02 supplied a provider, and for the same reason: the protocol and its degradation are worth
reviewing on their own, without a vendor's REST quirks in the same diff.

Six pieces:

| Piece | Responsibility | Needs no |
|---|---|---|
| `SourceConnector`, `SourceUpdate`, `SourceRefSnapshot` | the §5.1 protocol; a pure network adapter | store |
| `SourceError` | the only error a connector may throw | — |
| `SourceRegistry`, `SourceDispatch` | route a ref to a connector; three outcomes | store, network |
| `RefreshPolicy` | which refs are due (§5.5's 30-minute rule) | store, network, clock |
| `SourceRefreshService`, `RefreshOutcome` | the only writer: cache, events, save, notification | network |
| `ExternalUpdatePayload`, `ExternalUpdateBody` | what a found change looks like on an `Event` | store, network |

Plus the FR-4 step 4 wiring: a refresh stage in front of M3-03's polish stage inside
`StandupDraftModel`, and a launch-time pass from the app's composition root.

---

## The design brief

Five questions were put to the user before any of this was written. Their answers are the
constraints the rest of the document is built on, and each one is recorded as a decision below.

1. **Where does the staleness label live?** App only — the draft sheet. The markdown that
   reaches the clipboard is untouched. (D-176)
2. **How does fetched external state reach a report?** Only as `externalUpdate` events. Nothing
   in this task touches the renderer or §7.3's prompt. (D-168)
3. **When does the Prepare-time refresh happen, given FR-4 calls the indicator
   non-blocking?** A two-stage async chain: the sheet opens instantly on the cached raw report,
   then refresh → re-gather → polish → install. (D-175)
4. **Which surfaces show refresh state?** The draft sheet only. The launch pass is silent, logs
   only. (D-176, D-179)
5. **Does the first fetch of a ref append an event?** Yes — the first observation is an event.
   (D-169)

---

## What this task decides

| # | Decision |
|---|---|
| D-164 | Connectors take a `SourceRefSnapshot`, which §5.1's printed signature does not |
| D-165 | No case of `SourceError` carries a free-form `String`, and `.notFound` is its own case |
| D-166 | The registry routes on `canHandle` *and* configuration; registration order is priority; `.unhandled` is silent |
| D-167 | `SourceRefreshService.refresh` does not throw — §5.5 as a signature |
| D-168 | External state reaches a report only as `externalUpdate` events |
| D-169 | The first observation of a ref is an event |
| D-170 | No fetch coalescing across rows that share an identifier |
| D-171 | `lastFetchedAt` is our clock; the connector's `fetchedAt` lives only in the payload |
| D-172 | One save per pass, with a rollback, and `.stenoDidWrite` posted once |
| D-173 | A refresh never stamps `task.modifiedAt` |
| D-174 | `ExternalUpdatePayload` encodes with `.sortedKeys` |
| D-175 | The draft's window may be replaced once, before polish, and only while the text is pristine |
| D-176 | The staleness label is app-side only; the clipboard text is untouched |
| D-177 | `withDeadline` moves to `Support/` with its timeout error injected |
| D-178 | Four fetches in flight, an 8-second per-fetch deadline, a 10-second pass budget |
| D-179 | The production registry is empty, and the refresh UI is visually unverified until M4-02 |

> **These numbers are reserved against `DECISIONS.md`'s maximum of D-163 as of 2026-09-25.**
> Re-check that maximum before writing them — a sibling spec landing first shifts the range, and
> a duplicate number cannot be seen in a diff.

---

## D-164 — Connectors take a `SourceRefSnapshot`, which §5.1's printed signature does not

§5.1 prints `func fetch(_ ref: SourceRef, since: Date?) async throws -> SourceUpdate`. That
signature does not compile under this project's terms. `SourceRef` is an `@Model` class and
therefore not `Sendable`; `fetch` is `async`, so the argument crosses an isolation boundary; and
`SWIFT_VERSION` is 6.0, which makes that an error rather than a warning.

Connectors therefore take a value:

```swift
/// A `SourceRef` as a connector sees it.
public struct SourceRefSnapshot: Sendable, Equatable {
    public let refID: UUID          // the service's key back to the row
    public let kind: SourceRefKind
    public let identifier: String   // "PAY-421", a Confluence page id, "acme/api#421"
    public let url: String?
    public let lastFetchedAt: Date?
}
```

This is the same wall `GatheredWindow` was built for: `TaskItem` and `Event` cannot cross into
an `AIProvider`, so the report layer hands over values. The source layer needs the identical
treatment in the identical place, and doing it now — rather than when M4-02 first awaits a real
network call — keeps the workaround out of a PR whose review gate is about Atlassian's REST API.

`since` stays in the signature even though the snapshot carries `lastFetchedAt`. It keeps
refresh *policy* in the service: a connector reading the snapshot's timestamp instead would be
deciding what "since" means, and M4-05's catch-up pass needs to be able to pass something else.

**Handled like D-131, not as a spec amendment.** M3-01 added `Sendable` to §7.1's printed
`AIProvider` and recorded it in the protocol's own doc comment plus the PR body, per CLAUDE.md.
Same here: the deviation is forced, local, and visible where a reader of the protocol will meet
it.

---

## D-165 — No case of `SourceError` carries a free-form `String`, and `.notFound` is its own case

```swift
public enum SourceError: Error, Equatable, Sendable {
    case notConfigured
    case invalidCredential
    case notFound
    case network
    case timedOut
    case rateLimited(retryAfter: Duration?)
    case unavailable(status: Int)
    case invalidResponse
}
```

`AIError`'s rule, inherited deliberately: the obvious shape for `invalidResponse` is
`(reason: String)`, and the obvious reason string is built from the API's own response — which
on this layer means ticket titles, comment bodies and assignee names inside a value the logging
path prints, against §8. Typed cases make "a `SourceError` is always safe to log" true of the
type rather than of every future connector's discipline. `LocalizedError` supplies the banner
wording; a `metricsLabel` supplies the one-word log vocabulary, spelled out rather than derived
from `String(describing:)` — which would print `retryAfter` and a status code into a field meant
to be a label.

**`.notFound` is separate because it is permanent.** A mistyped ticket key in a task title will
never resolve, and a banner reading "couldn't reach Atlassian" for it sends the user to check
their wifi. It is also the one failure where the right fix is in the task title, not in the app.

**No retry suppression.** A permanently-missing ref is re-attempted on every pass, forever. The
alternative needs a persisted per-ref failure record — a new field on `SourceRef`, and therefore
export, import and merge rules for it — to save one HTTP request per 30 minutes on a ref the
user will notice and fix. Recorded so the next reader knows it was considered.

**Known extension point:** M4-02 adds `credentialExpired` for §5.2's 401 handling. That is a
compile error at every exhaustive switch, which is the intent — planned, not drift.

---

## D-166 — The registry routes on `canHandle` *and* configuration; registration order is priority; `.unhandled` is silent

```swift
public enum SourceDispatch: Sendable {
    case ready(any SourceConnector)   // a configured connector claims this ref
    case notConfigured                // one claims it, none configured
    case unhandled                    // nothing claims it
}

public struct SourceRegistry: Sendable {
    public init(connectors: [any SourceConnector])
    public func dispatch(_ ref: SourceRefSnapshot) -> SourceDispatch
    public func connector(withID id: String) -> (any SourceConnector)?
}
```

Three outcomes rather than an optional, because the service accounts for each differently:
`.ready` is fetched, `.notConfigured` is counted so the sheet can say "Atlassian isn't set up
yet", and `.unhandled` is dropped without a trace.

**`.unhandled` is the normal case, not an error.** `SourceRefKind.url` has no connector in any
planned milestone and FR-1.5's extractor creates one for every link the user pastes. Logging it,
or counting it as a failure, would put a permanent warning in front of a user who did nothing
wrong — and a warning that always fires is one they learn to ignore (FR-5's reasoning, applied
to a different surface).

**Registration order is priority, fixed at `init`.** No `register()` method: M5's MCP connector
will claim kinds a native connector also claims, and ordering decided by which pane the user
happened to open first is not a routing rule anyone can reason about. The order lives at the
composition root, where it is one readable array literal.

**`connector(withID:)` exists for M4-04's "Test connection" button**, which needs to reach one
named connector rather than route a ref.

---

## D-167 — `SourceRefreshService.refresh` does not throw — §5.5 as a signature

```swift
@MainActor
public struct SourceRefreshService {
    public init(context: ModelContext, registry: SourceRegistry,
                now: @escaping () -> Date = Date.init,
                save: @escaping (ModelContext) throws -> Void = { try $0.save() },
                perFetch: Duration = .seconds(8), budget: Duration = .seconds(10))

    /// §5.5's launch pass: refs on non-done tasks not fetched in the last 30 minutes.
    public func refreshDue(olderThan: Duration = RefreshPolicy.launchStaleness) async -> RefreshOutcome

    /// FR-4 step 4: every ref on the tasks in this window.
    public func refresh(taskIDs: [UUID]) async -> RefreshOutcome
}
```

Neither method throws. §5.5 says a failed integration must never block a report; §7.4 makes
arriving empty-handed a P0 failure. Expressed as a signature there is no error a caller could be
handed, and therefore no path on which a caller could forget to degrade — which is exactly why
`StandupSummarizer.summarize` has no `throws` either. A rule enforced by a type survives the
next four connectors; a rule enforced by review does not.

`@MainActor` because `ModelContext` is not `Sendable`; `now` injected so timestamps are
assertable; `save` injected because a real `ModelContext` cannot be made to fail on demand and
the rollback is the path that most needs a test. All three for the reasons `NoteService`,
`StatusService` and `CaptureService` already record.

**The pass, in order:**

1. Fetch candidate rows on the main actor; snapshot them to values.
2. `dispatch` each: `.unhandled` dropped silently, `.notConfigured` counted.
3. `withThrowingTaskGroup`, bounded concurrency, each fetch inside `perFetch` (D-178). **The
   pass budget is not a deadline around the group** — that would discard every completed fetch
   when the slowest one overran, which is the opposite of best-effort. Instead: as each result
   arrives, the elapsed time is checked; past `budget` no further fetch is started, the in-flight
   ones are cancelled, and the unstarted refs are counted `skipped`. Everything already fetched
   is applied.
4. **No `@Model` row is touched inside the group.** Results return as
   `[UUID: Result<SourceUpdate, SourceError>]`, keyed by `refID` (D-164's reason again).
5. Back on the main actor, apply each result: `recordFetch(summary:at:)`, plus an
   `externalUpdate` `Event` where one is due.
6. One `save` for the pass; on failure, `rollback()` (D-172).
7. Post `.stenoDidWrite` once, only after a successful save that wrote something.

**`RefreshPolicy` is pure age arithmetic:**

```swift
public enum RefreshPolicy {
    public static let launchStaleness: Duration = .seconds(30 * 60)   // §5.5
    public static func due(_ refs: [SourceRefSnapshot], now: Date, olderThan: Duration) -> [SourceRefSnapshot]
}
```

"Non-done tasks" is a store predicate, so it lives in the service's fetch and is tested against
a container the way `ReportGatherer`'s project scoping is. A ref with `lastFetchedAt == nil` is
always due. The boundary is strict: *older than* 30 minutes, so exactly 30 minutes is not due,
and a test pins both sides.

**The outcome is counts, not collections:**

```swift
public struct RefreshOutcome: Sendable, Equatable {
    /// One ref's failure, with the connector that owns it — so the banner can
    /// name the source. `displayName` is the connector's own constant, never
    /// response content (§8).
    public struct Failure: Sendable, Equatable {
        public let connectorID: String
        public let displayName: String
        public let error: SourceError
    }

    public let attempted: Int
    public let cached: Int           // refs whose summary was written
    public let changed: Int          // refs that produced an event
    public let failures: [Failure]
    public let notConfigured: Int
    public let skipped: Int          // the budget ran out before these were tried
    public let oldestFetch: Date?    // drives "…data from 2 days ago"
    public let saveFailed: Bool
}
```

`Failure` carries the connector's `displayName` rather than only an error, because a banner that
says "a source couldn't be reached" tells the user nothing they can act on while "Jira couldn't be
reached" sends them to the right settings pane. It carries no response content, which is what
keeps D-165's logging property intact.

D-163's lesson applies directly: an empty collection is never evidence that nothing was
fetched, so `attempted` is carried explicitly rather than inferred from the size of anything.
`failures` and `saveFailed` stay separate for the reason `lastError` and `notice` are separate
on `StandupDraftModel` — one means the network let us down and the cache still holds, the other
means nothing was recorded at all, and one field cannot say which.

---

## D-168 — External state reaches a report only as `externalUpdate` events

§5.2 says to "persist `cachedSummary` so a report can be generated offline with last-known
state, clearly labeled as stale". The task file says "nothing in this task may reference the AI
layer". Read together at face value they cannot both be honoured: putting last-known state into
a *report* means putting it into M2-02's renderer **and** into §7.3's prompt, and the prompt is
`StenoKit/AI/StandupPrompt.swift`.

The resolution: the event log is the integration point. A fetch that finds a change appends an
`externalUpdate` event; `ReportGatherer` already collects every non-redacted event in the window
and hands it to both the raw renderer and the prompt, with no change to either. `cachedSummary`
keeps two jobs — it is the baseline a later fetch's changes are described against, and it is
what the app shows when it explains that data is stale.

**Why not add source state to `GatheredTask` anyway:**

- Adding it to the renderer *and* the prompt is forbidden by the task's own scope line, and
  would put a prompt change in a PR about a protocol.
- Adding it to the renderer *only* is worse than either: the AI-polished draft would silently
  drop ticket state that the offline fallback displayed. "Never worse than the fallback" is the
  coverage rule M3-03 spent three review rounds settling, and this would breach it on day one.

**§5.2's wording is amended in this PR** rather than left as a reading someone has to
reconstruct. See the amendment section at the end: v1.22 states that last-known state reaches a
report as `externalUpdate` events, and that `cachedSummary` is the baseline for change detection
and the app's staleness surface. Nothing about caching, degradation, or the offline guarantee
changes — only where the requirement says the data appears.

---

## D-169 — The first observation of a ref is an event

§3.3 says `externalUpdate` is created when a fetch "finds a change". The first fetch of a ref has
nothing to compare against, so read strictly it produces no event — and under D-168 that means
the first stand-up after enabling Jira contains nothing from Jira at all, which reads as a broken
integration.

So: the first successful fetch of a ref (`lastFetchedAt == nil`) appends an event whose body is
the connector's `summary`. Every later fetch appends only when `changes` is non-empty.

```swift
enum ExternalUpdateBody {
    /// "PAY-421: In Review, assigned to Dana"     (first observation)
    /// "PAY-421: moved to In Review; 2 new comments"  (subsequent change)
    static func text(identifier: String, summary: String, changes: [String]) -> String?
}
```

A pure function returning `nil` when there is nothing to say, so "when is an event due" is one
testable expression rather than a condition spread across the apply loop.

The cost is one event per ref, once ever — roughly one line per task under D18's 20-task cap,
and only on the first pass after a connector is configured. The benefit is that the first report
carries the ticket state the connector exists to supply.

---

## D-170 — No fetch coalescing across rows that share an identifier

The same ticket key on two tasks is two `SourceRef` rows (§3.4: "two tasks may of course
reference the same resource; that is a different row each time"), each with its own
`lastFetchedAt`. A pass therefore fetches `PAY-421` twice.

Coalescing would need one `since` for both rows, and the only safe choice is
`min(lastFetchedAt)` — which hands the row with the later timestamp changes it has already
reported, producing a **duplicate `externalUpdate` in the next report**. A repeated bullet in a
stand-up the user reads aloud is a worse defect than a second HTTP request, D18 caps a project
at ~20 tasks, and §5.5 asks for best-effort rather than for efficiency. Recorded as a deliberate
non-optimization so the next reader does not "fix" it.

---

## D-171 — `lastFetchedAt` is our clock; the connector's `fetchedAt` lives only in the payload

`SourceUpdate.fetchedAt` comes from the connector, which may derive it from a server response.
`SourceRef.lastFetchedAt` is set from the service's injected `now()` instead.

§10.1 resolves `cachedSummary` and `lastFetchedAt` as a pair, later timestamp winning. A value
sourced from a remote clock makes that comparison depend on two machines' skew against a third,
so a merge could prefer the older observation — and `SourceRef.recordFetch`'s own doc comment
already exists because a caller able to desynchronize that pair "could produce a record the
merge cannot order". The connector's timestamp is still kept, in the event payload, where it is
diagnostic rather than load-bearing.

The `Event.timestamp` is `now()` for the same reason: the log's order must be the app's order.

---

## D-172 — One save per pass, with a rollback, and `.stenoDidWrite` posted once

Every write of a pass — every `recordFetch`, every inserted `Event` — is committed by a single
`save`. On failure: `context.rollback()`, `saveFailed = true`, and a log line.

**The rollback is load-bearing, not tidiness.** Inserted events left in a dirty context are
committed by the *next* unrelated save — a capture, a status change, a note — which turns a
refresh failure into phantom `externalUpdate` events appearing in a later report with no trace of
where they came from. `CaptureService` and `MainWindowModel+Saving` already carry this reasoning;
this is the first place where the orphaned rows would be invisible rather than merely stale.

One save rather than one per ref because §5.5 is best-effort: a pass that cannot be persisted is
retried in 30 minutes, and a partially-saved pass is harder to reason about than a discarded one.

`.stenoDidWrite` is posted once, after a successful save that wrote something — so an open
timeline shows the new rows (D-031's rule), and a pass that fetched nothing does not make three
surfaces refetch for no reason.

---

## D-173 — A refresh never stamps `task.modifiedAt`

`NoteService.addNote` declines to stamp it, on the grounds that a note is a fact about the log
rather than a mutation of the task. A refresh is one step further removed: nothing about the
task changed, and the app was not even asked.

Stamping it would let a task that merely had its Jira ticket looked at outrank, in §10.1's
"later `modifiedAt` wins" merge, a task whose title was genuinely edited on another Mac. The
launch pass runs on every launch, so this would not be a rare loss — it would be the common
case, and the user would see their own edit silently reverted after an import.

A test asserts `modifiedAt` is unchanged across a pass that writes both a cache and an event.

---

## D-174 — `ExternalUpdatePayload` encodes with `.sortedKeys`

```swift
struct ExternalUpdatePayload: Codable, Equatable {
    let refID: UUID
    let kind: SourceRefKind
    let identifier: String
    let changes: [String]
    let url: String?
    let fetchedAt: Date        // the connector's own timestamp (D-171)
}
```

`Event.payload` is exported as base64 and `ExportRecords` keeps it byte-exact by design. Swift's
`Codable` emits keys in an internal dictionary order that **differs between processes**, so
without `.sortedKeys` two exports of an unchanged store are byte-different files — which is
precisely the defect v1.16 and D-090 already fixed once, at the envelope level, for the same
reason. `StandupReportedPayload` gets away with a bare `JSONEncoder` because it has exactly one
key; this type has six.

Encoding returns `Data?` and a failure yields `nil` rather than throwing, following
`StandupReportedPayload`: a payload that cannot be encoded must not abort a refresh whose cache
write is fine. The cost of a missing payload is a diagnostic, not a report.

---

## D-175 — The draft's window may be replaced once, before polish, and only while the text is pristine

FR-4 sequences the refresh at step 4, between gathering the window and building the AI request,
and calls the indicator "visible but non-blocking". Those pull apart: events appended by the
refresh are timestamped after the window was gathered, so the window the user is looking at
predates them.

`StandupDraftModel` already owns the machinery for exactly this — an async stage, a generation
counter, and a "has the user typed?" guard — so the refresh becomes a sibling stage in front of
polish:

```swift
public struct RefreshedWindow: Sendable, Equatable {
    public let window: GatheredWindow   // re-gathered; == the input when nothing changed
    public let outcome: RefreshOutcome
}

private let refresh: @MainActor (GatheredWindow) async -> RefreshedWindow
public private(set) var isRefreshing = false
public private(set) var sourceNotice: String?
```

The chain from `begin(window:text:)`:

1. Raw text on screen, sheet open, `phase == .editing`, **Copy live**. Nothing waits on a
   network — the extension of the rule polish already follows, and §7.4's promise.
2. `isRefreshing = true` → the sheet's "Refreshing…" line, in the same slot as "Polishing…".
3. `await refresh(window)`; bail if the generation moved.
4. If the pass appended events **and the text is still pristine**: adopt `refreshed.window` and
   re-render the raw text from it.
5. `sourceNotice` from the outcome; `isRefreshing = false`; then polish, unchanged, on whichever
   window is current.

**Both upgrade stages are pristine-gated.** Once the user types, they own the draft: no
re-render, and — already true — no polish install.

**The window is replaced at most once, before polish, and never after the user has typed.** This
is the part that needed restating rather than inheriting: `StandupDraftModel.window` is
documented as frozen, and the honest statement is that it is frozen *at Copy*, not at Prepare.
Replacing it under an untouched draft is safe, because the text is re-rendered from the same
window. Replacing it under a typed draft would advance `lastStandupAt` to a window end past
`externalUpdate` events the user's text never mentions — consuming them from the window and
losing them from recall, which is the exact harm D-076 exists to prevent. So a typed draft keeps
its original window and the refresh's events fall into the next report.

**One generation counter covers both stages**, bumped by `begin` and `dismiss`, for the reason
already in the file: cancellation is cooperative, so a superseded refresh still finishes and must
touch nothing.

**`sourceNotice` is its own property**, not a reading of `lastError` or `notice`. Those two are
already separate because one means a write failed and retrying is safe while the other means the
write landed; this third one means neither — the data is simply old.

**The closure is assembled in `MainWindowModel+Standup`**, beside `standupPolish`, as a `static`
function so `init` can build it before `self` exists. It owns the re-gather, because the
re-gather needs a `ModelContext` and `StandupDraftModel` deliberately holds services rather than
a store.

**§13, stated explicitly because this is the riskiest boundary claim in the task:**
`SourceConnector`, `SourceRegistry`, `SourceRefreshService` and `SourceError` never name an AI
type, and no file under `StenoKit/AI/` is edited except `Deadline.swift`'s move and its call
sites (D-177). `StandupDraftModel` holds both stages as opaque closures; it is a view model in
`Features/`, not the AI layer, and it already held `polish` this way.

---

## D-176 — The staleness label is app-side only; the clipboard text is untouched

§5.2 requires an offline report to be "clearly labeled as stale". The label goes in the draft
sheet — a banner reading, for example, "Jira data is 2 days old — couldn't reach Jira", built
from the outcome's `oldestFetch` and its failures' `displayName` —
and nowhere else. `SlackMarkdown`'s output, the clipboard, and `StandupReport.markdownBody` are
unchanged.

The label exists so the user knows how much to trust the draft before reading it out; the
audience of the stand-up does not need fetch timestamps. FR-4 step 6 makes the draft editable, so
a user who *wants* to say "Jira may be behind" can type it. A line injected into the markdown
would travel to Slack on every report generated while any ref is stale — which, with the launch
pass running on a 30-minute rule, is most reports.

The launch pass shows nothing at all: §5.5 makes it a warm-the-cache background job, and a
visible indicator invites the user to wait for something designed not to be waited on. It logs
counts only (§8-safe: no summaries, no identifiers).

---

## D-177 — `withDeadline` moves to `Support/` with its timeout error injected

`StenoKit/AI/Deadline.swift` → `StenoKit/Support/Deadline.swift`, with the timeout error passed
in: `AIError.timedOut` from the AI call sites, `SourceError.timedOut` from the refresh service.

The source layer needs a per-fetch deadline for the same reason the AI layer does, and cannot
use this function where it stands: it throws `AIError`, and §13 forbids the source layer naming
an AI type. The alternatives were duplicating forty lines of cooperative-cancellation semantics
whose doc comment records a review round and a CI flake — two copies, and the next fix lands on
one of them — or a source-layer deadline that reinvents the same race. Neither is worth it for a
function whose entire content is "which error does the loser throw".

A pure refactor: no behaviour change, the doc comment moves with the function, and the existing
AI deadline and budget tests are the check.

---

## D-178 — Four fetches in flight, an 8-second per-fetch deadline, a 10-second pass budget

- **Four in flight.** A `periodic` window under D18's 20-task cap can carry ~20 refs. Serial at
  a second each is 20 seconds of a stand-up the user is already late for; 20-wide is how a
  connector gets rate-limited by Atlassian on the first pass. Four puts the common case around
  five seconds.
- **8 seconds per fetch.** One unresponsive ticket must not consume the whole pass.
- **10 seconds per pass**, after which unfetched refs are counted `skipped` and whatever was
  already fetched is applied. The user is standing in a meeting with a usable raw report already
  on screen; ten seconds is the most that is worth spending before polishing what we have. The
  AI budget that follows is D-145's twenty seconds, and both stages are non-blocking.

All three are injected, and tests pass millisecond values — an 8-second hang in `make test` is
how a suite stops being run.

---

## D-179 — The production registry is empty, and the refresh UI is visually unverified until M4-02

No connector conforms to `SourceConnector` in the shipping target this milestone. The registry is
built empty at the composition root, every ref dispatches `.unhandled`, and the launch pass is a
no-op. The sheet's "Refreshing…" line and stale banner are therefore unreachable in the running
app: their state is covered by `StandupDraftModel` tests, and nobody can look at the pixels until
M4-02 supplies real data.

Three alternatives were considered and declined: an env-gated stub connector inside `StenoKit`
(precedent exists in `KeychainSelftest` and `ModelsSelftest`, but it puts a fake connector in the
shipping bundle to verify a view that M4-02 will exercise anyway); a `refresh-selftest` CLI
subcommand (writes to the real store, and still shows nothing about the sheet); and shipping the
UI later (breaks §13's "degradation ships with the feature").

**What this means for the PR body:** it says plainly that the refresh affordance is verified at
the view-model level and not visually, and that M4-02's first manual run is where the pixels get
checked. Claiming otherwise would be the kind of unmeasured assertion D-025 already cost this
project once.

**The launch pass is called from the GUI app's composition root, not from
`MainWindowModel.init`.** The CLI bundle builds a store too, and `steno export` must not open
network connections — §9.4 denies them in tests, and a CLI subcommand that reached Atlassian
would be a surprise in a tool the user runs from a script. M4-05 wraps this same call in its
timer.

---

## Layout

**New — `StenoKit/Integrations/`** (named for §5's own title, "Integrations (Source Layer)", and
FR-6's Integrations pane; `Sources/` would collide with SwiftPM's meaning):

| File | Contents |
|---|---|
| `SourceConnector.swift` | the protocol, `SourceUpdate`, `SourceRefSnapshot` |
| `SourceError.swift` | the enum, `LocalizedError`, `metricsLabel` |
| `SourceRegistry.swift` | `SourceRegistry`, `SourceDispatch` |
| `RefreshPolicy.swift` | `due`, `launchStaleness` |
| `RefreshOutcome.swift` | `RefreshOutcome`, `RefreshedWindow` |
| `SourceRefreshService.swift` | the pass: dispatch, group, apply, save, notify |
| `ExternalUpdateBody.swift` | the pure body formatter |
| `ExternalUpdatePayload.swift` | the `Codable` payload, `.sortedKeys` |

**Moved:** `StenoKit/AI/Deadline.swift` → `StenoKit/Support/Deadline.swift` (D-177).

**Modified:**

| File | Change |
|---|---|
| `StenoKit/AI/Anthropic/AnthropicProvider*.swift` | pass `AIError.timedOut` to `withDeadline` |
| `StenoKit/Features/MainWindow/StandupDraftModel.swift` | the refresh stage, `isRefreshing`, `sourceNotice`, window replacement |
| `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift` | `static func sourceRefresh(...)`, injected beside `standupPolish` |
| `Steno/Features/MainWindow/StandupDraftSheet.swift` | "Refreshing…" line, stale banner |
| `Steno/App/StenoApp.swift` | build the (empty) registry; fire the launch pass |
| `docs/REQUIREMENTS.md` | §5.2 amendment, v1.22, changelog line |
| `docs/DECISIONS.md` | D-164 … D-179 |
| `docs/ARCHITECTURE.md` | the source-layer rows: where the never-block invariant is enforced |
| `docs/tasks/README.md` | tick M4-01 |

**New tests — `StenoTests/Integrations/`:** `StubSourceConnector.swift`,
`SourceRegistryTests.swift`, `RefreshPolicyTests.swift`, `SourceRefreshServiceTests.swift`,
`RefreshNeverBlocksTests.swift`, `ExternalUpdateTests.swift`; plus additions to
`StenoTests/Features/MainWindow/StandupDraftModelTests.swift`.

---

## Verification

`make build && make test && make lint`, all green, before the PR. Beyond that:

**Doubles** (tests only — nothing fake ships, following `StubAIProvider`):
`StubSourceConnector`, scripted per identifier to succeed with a given `SourceUpdate`, throw a
given `SourceError`, or hang, recording every `(identifier, since)` it was asked for; and
`AlwaysFailingConnector` for the headline criterion.

**Each acceptance criterion, and the mutation that must break its test:**

| Criterion | Test | Mutation |
|---|---|---|
| A failed integration never blocks a report | throwing connector → `refresh` returns; `ReportGatherer` then produces a non-empty window from cache | make the task group's `try` propagate |
| One failure does not stop others | A throws, B succeeds → B's cache written *and* B's event appended, A in `failures` | `break` on the first failure in the apply loop |
| Offline report, labeled stale | nothing configured → window still gathers; `sourceNotice` non-nil from `oldestFetch` | drop the `oldestFetch` plumbing |
| A change appends `externalUpdate` | first fetch → event with the summary body; second with empty `changes` → no new event **and** `lastFetchedAt` advanced | append unconditionally |
| Progress visible, non-blocking | `isRefreshing` true before the stage completes; Copy live throughout; refresh ordered before polish | `await` the refresh inside `prepareStandup` |
| `make test` with networking disabled | every conformance is a double; no `URLSession` in this PR | — |

**Six hazards this repo has already paid for, planned around explicitly:**

1. **Both directions, always.** "No event was appended" passes trivially if the fetch never
   happened, so the same test asserts `lastFetchedAt` advanced. The non-done filter test includes
   one ref that *must* be fetched, so it cannot pass by fetching nothing.
2. **The rollback test needs a later save.** After the injected throwing save, a second
   successful pass must show no phantom events — otherwise "the store is empty" is unfalsifiable.
3. **`.sortedKeys` gets a test that can fail.** The fixture payload's sorted key order is the
   reverse of its declaration order and the assertion is on exact bytes, so removing
   `.sortedKeys` fails in nearly every run rather than one in six.
4. **Async stages need real suspension.** The dismiss-during-refresh test awaits the stub's
   actual suspension before dismissing; a `Task` has not started when `begin` returns.
5. **Millisecond budgets** in tests, never the 8-second default.
6. **Mutation results are read for `✘`/`❌`, not `error:`**, and new untracked test files get
   explicit cleanup — `git checkout` does not revert them, which produced twelve false "caught"
   results on an earlier milestone.

**Also asserted, because review would not see them:** `task.modifiedAt` unchanged across a pass
(D-173); `.stenoDidWrite` posted exactly once for a writing pass and not at all for an empty one
(via `WriteCounter`); the `since` handed to the connector equals the row's previous
`lastFetchedAt`; the registry's order-decides-priority rule tested with the expectation order
*disagreeing* with registration order, so a reordering mutation is detectable.

**Not verified here:** the sheet's refresh affordance, visually (D-179).

---

## Out of scope

- **Jira and Confluence** — M4-02, M4-03. No `URLSession` call, no Atlassian URL, no credential
  read in this PR.
- **Background scheduling** — M4-05. `refreshDue()` exists and is called once at launch; the
  timer, the catch-up rule and the 08:00 setting are that task's.
- **MCP** — M5.
- **Credential entry UI and the expiry warning** — M4-04. `isConfigured` is a protocol
  requirement here; nothing reads a token.
- **Source state in the report text or the AI prompt** — D-168.
- **Retry suppression for permanently-missing refs** — D-165.
- **Fetch coalescing** — D-170.
- **Q(M4)** (auto-transitioning a task when its ticket closes) stays open and unimplemented; D5
  makes it a read-side question only.

---

## Risks

| Risk | Mitigation |
|---|---|
| `StandupDraftModel` is a heavily-reviewed async file; a third stage is where a generation-counter bug would hide | The refresh stage reuses the existing counter and pristine guard rather than adding a parallel mechanism; the dismiss-during-refresh test awaits real suspension |
| The window-replacement rule is subtle and its failure is silent — a lost event, noticed weeks later | Pristine-gated, replaced at most once, before polish; asserted in both directions (pristine replaces, typed does not) |
| `Deadline.swift`'s move touches code whose semantics cost a review round and a CI flake | Pure refactor, no behaviour change; the existing AI deadline and budget tests are the gate, and the doc comment moves intact |
| The subsystem is inert in production, so a reviewer may read the criteria as unverified | D-179 says so in the PR body, and every criterion names the double that discharges it |
| §5.2's amendment is a requirement change inside an implementation PR | Stated in the PR body per CLAUDE.md, version bumped, changelog line written; nothing about the offline guarantee changes, only where the data appears |
| 16 decision numbers reserved from a log another branch may also be appending to | Re-check `DECISIONS.md`'s maximum before writing them — a duplicate number is invisible in a diff |

---

## Proposed REQUIREMENTS.md amendment — v1.22

§5.2's cache bullet currently reads:

> **Cache:** persist `cachedSummary` so a report can be generated offline with last-known state,
> clearly labeled as stale.

Amended to say where that state appears:

> **Cache:** persist `cachedSummary` as the durable last-known state of the resource. It has two
> jobs: it is the baseline a later fetch's changes are described against, and it is what the app
> shows when it tells the user their integration data is stale. **Last-known state reaches a
> *report* as `externalUpdate` events** (§3.3), which the report engine already collects for the
> window — not by injecting the cached summary into the report text or the AI prompt, which would
> couple the source layer to §7.3 and breach §13. A report therefore generates fully offline, and
> the staleness label is an app surface, not a line in the copied markdown.

Changelog line:

> *v1.22* — §5.2 says where cached external state appears in a report. Read literally, "a report
> can be generated offline with last-known state" required the source layer to reach into
> M2-02's renderer and §7.3's prompt, which §13 and M4-01's own scope forbid — and putting it in
> the renderer alone would make an AI-polished draft strictly worse than the offline fallback,
> breaching the coverage rule D-156 settled. The route is the event log: a fetch that finds a
> change appends an `externalUpdate`, which `ReportGatherer` already collects. Nothing about
> caching, degradation, or the offline guarantee changes. Found while designing M4-01; the
> implementation choice is `DECISIONS.md` D-168, which points here.
