# M2-01 — Report Window Computation: design

**Task:** [`docs/tasks/M2-01-report-window.md`](../../tasks/M2-01-report-window.md)
**Branch:** `feat/report-window`
**Requirements:** D8, D16, D17, FR-4 steps 2–3, §3.3, §3.5, §7.3, §7.4
**Date:** 2026-09-07

Given a project, compute the report window and gather every event inside it — pure, headless,
and side-effect free. This is the first code in `StenoKit/Report/`, and the type it produces is
the interface M2-02, M2-03, and M3-03 all consume.

---

## 1. Two units, three files

`ARCHITECTURE.md` §5 already reserves `StenoKit/Report/` for "window computation, renderers
(M2-01, M2-02)". This task fills the first half.

| File | Responsibility | Depends on |
|---|---|---|
| `Report/ReportWindow.swift` | The window **rule**: the 24h first-run fallback and the clamp | nothing — no store, no clock |
| `Report/GatheredWindow.swift` | The three `Sendable` snapshot types | domain enums only |
| `Report/ReportGatherer.swift` | Fetch, filter, snapshot | `ModelContext`, injected `now` |

The rule is split out from the gatherer because `NoteCorrection` / `NoteService` is this
repository's existing precedent for exactly that shape — a pure rule, described in its own doc
comment as "FR-2's five-minute typo window, as a rule with no store and no clock", extracted so
every branch is testable against literals rather than against a fixture. Two of this task's six
acceptance criteria are statements about window arithmetic and nothing else, which is the same
condition that justified the split in M1-06.

```swift
/// FR-4 step 2's window, as a rule with no store and no clock.
public enum ReportWindow {
    /// FR-4 step 2 / §3.5 as corrected in v1.7: a project's first report looks
    /// back 24 hours.
    public static let firstRunLookback: TimeInterval = 24 * 60 * 60

    public static func bounds(lastStandupAt: Date?, now: Date) -> (start: Date, end: Date)
}
```

A caseless `enum` with statics, matching `NoteCorrection` and `StenoStore`: no instance state,
so strict concurrency has nothing to reason about.

**24 hours is `TimeInterval` arithmetic, not `Calendar` arithmetic.** FR-4 says "24h before
now", not "yesterday" and not "the start of the previous day". `addingTimeInterval(-86400)` is
that sentence; `Calendar.date(byAdding: .day, value: -1)` is a different one that shifts by an
hour across a DST boundary. The literal reading is also the one that cannot surprise a user in
March.

### Naming: `ReportGatherer`, not `ReportWindowService`

The three existing `*Service` types — `CaptureService`, `StatusService`, `NoteService` — share a
shape: they inject `save`, they mutate, and they post `.stenoDidWrite`. This type does none of
those things, and doing any of them would break FR-4's central guarantee. A name that says
"Service" is an invitation for a future agent to add the `save` parameter its siblings all have,
by symmetry, without noticing what that symmetry costs here. The name is the first line of
defence and the cheapest one.

---

## 2. The API

```swift
@MainActor
public struct ReportGatherer {
    private let context: ModelContext
    private let now: () -> Date

    public init(context: ModelContext, now: @escaping () -> Date = Date.init)

    /// D8's window for one project, with every event inside it. Writes nothing.
    public func gather(for project: Project) throws -> GatheredWindow
}
```

`@MainActor` because `ModelContext` is not `Sendable`, and `now` injected so timestamps are
assertable — both for the reasons the sibling services already record.

**There is deliberately no `save` parameter.** Its absence is the design. FR-4 is explicit that
"generating a preview must be free of side effects, so the user can peek without corrupting
their window", and the type that cannot be handed a save closure is a stronger statement of that
than a comment asking future callers not to write. `throws` covers `context.fetch` failing, and
nothing else.

### The output shape

```swift
public struct GatheredWindow: Sendable {
    public let projectID: UUID
    public let cadence: ReportCadence
    public let start: Date
    public let end: Date
    public let tasks: [GatheredTask]
}

public struct GatheredTask: Sendable {
    public let id: UUID
    public let title: String
    public let status: Status
    public let ticketKeys: [String]
    public let events: [GatheredEvent]
}

public struct GatheredEvent: Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: EventKind
    public let body: String
}
```

**Value types, not live SwiftData models, and `Sendable` is the reason.** M3-03 sends this
across an async boundary into an `AIProvider`; `TaskItem` and `Event` are `@Model` classes,
which are neither `Sendable` nor safe to hand to another isolation domain. Returning live rows
would mean the snapshot types get built anyway — later, in a task whose review gate is about
prompt construction rather than about the shape of the report payload. Building them here puts
them in front of the reviewer who is thinking about exactly this question.

It is also half of "side-effect free" proved by the compiler rather than by a test: a caller
holding a `GatheredWindow` has nothing it *could* mutate. M2-03 still gets `GatheredTask.id`,
which is what it needs to re-fetch the live rows and append `standupReported` events at Copy
time.

Field-by-field justification, since every one of these is consumed by a task that does not exist
yet:

| Field | Who needs it | Why |
|---|---|---|
| `projectID` | M2-03 | `StandupReport.projectID` |
| `cadence` | M2-02, M3-03 | D17 selects the section set and the output schema |
| `start`, `end` | M2-03 | `StandupReport.windowStart` / `windowEnd` |
| `id` (task) | M2-03, M3-03 | appending `standupReported`; §7.3's `task_id` |
| `title`, `status` | M2-02, M3-03 | §7.3 lists both explicitly |
| `ticketKeys` | M3-03 | §7.3 lists "ticket key"; must survive verbatim |
| `events` | M2-02, M3-03 | §7.3: "all events in `[windowStart, now]` with timestamps" |
| `id` (event) | — | see below |

**`GatheredEvent.id` has no consumer in M2 or M3, and that is worth stating plainly** rather than
inventing one. It is not what M2-04 uses: undo redacts `standupReported` events, which §5.1
excludes from gathering entirely, so M2-04 must query them directly and this field could not help
it. The honest justification is narrower — a snapshot without identity cannot be traced back to
the log row it came from, which matters when a report renders something the user does not
recognise. If that is too thin, the field should be dropped now rather than carried: an unused
`public` field on a type three tasks depend on is a decision that gets harder to reverse with
each of them.

**`ticketKeys` is plural where §7.3 says "ticket key" singular.** A task can carry several
`jiraIssue` refs — FR-1.5's extractor creates one per key found, and a note mentioning two
tickets produces two. Keeping only one would silently drop a key the user has to say out loud,
which is the failure mode §7.3's "preserve verbatim" constraint exists to prevent. Sorted, for
determinism.

**Two deliberate omissions,** named here so M2-02 does not rediscover them as gaps:

- **No project name.** M2-03's UI already knows which project it is displaying. If M2-02 wants a
  markdown heading, it can take the `Project` alongside the window, or this type grows a field
  in that PR. Adding it now would be speculative.
- **No `SourceRef` payloads beyond the keys** — no `cachedSummary`, no `lastFetchedAt`. FR-4
  step 4's ref refresh is M4-01, and it is explicitly out of scope here. Carrying empty cache
  fields through M2 and M3 would invite a renderer to depend on data nothing populates yet.

---

## 3. The algorithm

```
end   = now()
start = ReportWindow.bounds(project.lastStandupAt, end).start
        ├─ lastStandupAt ?? end - 24h        (FR-4 step 2, §3.5 v1.7)
        └─ if start > end { start = end }    (clamp — see §5)

fetch  tasks:  projectID == project.id && !isArchived      ← D16 lives here
fetch  events: timestamp >= start && timestamp <= end && !isRedacted
               sorted by timestamp ascending

group  events by taskID, in memory
       drop kind == .standupReported                       ← a report is not work
       keep only events whose taskID is in the task set

keep   task if it has events, or status ∈ {inProgress, blocked}
sort   tasks by (createdAt, id.uuidString) ascending
```

### Why a project's events are found through its tasks

`Event` has no `projectID`. Its only link is `taskID` — deliberately, per §3.3 and the M0-03
design. So "events for this project" is necessarily "events for the tasks whose `projectID`
matches", and **that is where D16's per-project independence is enforced**: the task fetch is
scoped by `project.id`, so no row belonging to another project can reach the output. There is no
global "last stand-up" anywhere in this design, and no code path reads another project's
`lastStandupAt`.

### One event fetch, not one per task

The event predicate stays `Date && Date && !Bool`. Both the `EventKind` filter and the
task-scoping happen **in memory, after the fetch**:

- An `EventKind` inside a SwiftData `#Predicate` does not compile in either spelling.
  `EventQueries.timeline` already records this and already handles kind filtering in memory for
  the same reason.
- A `taskIDs.contains($0.taskID)` predicate is the other thing worth not betting on. Filtering a
  small in-memory array is free and cannot fail at fetch time.

D18 caps a project under 20 tasks, so the fetch is the cost and the filtering is free — the same
trade `EventQueries` documents. The event fetch is scoped by date, so it does read rows belonging
to other projects before discarding them; on a personal single-user store with a one-day or
two-week window that is a rounding error, and it buys a predicate with no constructs that can
surprise SwiftData.

### The window predicate belongs in `EventQueries`

`EventQueries`'s doc comment already states its own purpose:

> Redaction is excluded here, not by each caller. §3.3 hides a redacted event from summaries, and
> **M2-01's gathering** and M3-03's prompt both have to honour that — so the predicate lives in one
> place rather than being rewritten, and eventually mis-written, per call site.

This task is the caller that comment was written for. `EventQueries` gains
`inWindow(start:end:)`; the redaction rule stays in one file.

### Explicit sort, not fetch order

M2-02's acceptance criterion is "same window, same markdown, every time". SwiftData's fetch order
without a `SortDescriptor` is not specified, so relying on it produces a renderer that is
deterministic on one machine and a coin flip on CI. Tasks sort by `createdAt` ascending,
tie-broken by `id.uuidString` — `UUID` is not `Comparable`, which `EventQueries` also records.
Events sort ascending by timestamp in the fetch descriptor, and grouping preserves that order, so
a task's events read oldest-first: the order a person narrates them in.

---

## 4. Inclusion: active **or** open

A task is included when it is not archived **and** either it has at least one non-redacted event
in the window, or its current status is `inProgress` or `blocked`. A quiet open task appears with
an empty `events` array.

The obvious reading of FR-4 step 3 — "gathers all events in `[windowStart, now]`" — implies
activity-only gathering, and it is wrong, because FR-4's own report structure two paragraphs
later needs more than activity:

> *Daily cadence* — **Since last stand-up**: completed and progressed work · **Today**: current
> IN-PROGRESS tasks · **Blockers**: BLOCKED tasks with reasons

**Today** and **Blockers** are defined by *current status*, not by window activity. A task set to
in-progress on Friday and left quiet over the weekend is exactly what Monday's stand-up is for;
activity-only gathering drops it, and Monday's report would omit the thing the user is actually
working on.

The alternative — letting M2-02 query the store for open tasks itself — puts a second, unreviewed
read path inside the renderer, splits "what is in the report" across two files, and reopens the
side-effect question in a task whose gate is about markdown. Deciding it here keeps it in one
place.

Including *every* non-archived task was rejected for the opposite reason: it pushes the
"what counts as reportable" judgement downstream into M3-03's prompt, shipping every long-finished
task to the model as context it must learn to ignore. That is the prompt noise §7.3 exists to
prevent.

**Consequence for M2-02, stated here so it is not a surprise:** `GatheredTask.events` may be
empty, and the renderer must produce something honest for that task rather than a blank bullet.
That is already M2-02's fourth acceptance criterion ("an empty window produces something honest
and usable"), now with a concrete case behind it.

---

## 5. Two declared interpretations

Neither of the following is stated in FR-4. Per `CLAUDE.md`'s "say so, do not silently deviate",
both are recorded here, will be repeated in the PR body, and will be added to `DECISIONS.md`.

### 5.1 `standupReported` events are not gathered

**FR-4's boundary has a guaranteed collision, and it is measured, not theorised.** Copy sets
`project.lastStandupAt = now` *and* appends `standupReported` events stamped `now`. The next
report's `windowStart` therefore equals those events' timestamps exactly — and FR-4 step 3
specifies a **closed** interval `[windowStart, now]`.

A runtime probe against SwiftData on this branch confirmed the closed interval behaves as
written: an event stamped at exactly `windowStart` and an event stamped at exactly `windowEnd`
are both returned by `timestamp >= start && timestamp <= end`. So every report after a project's
first one would open with "a report was generated" as work done. This fires every time, not
rarely.

**The fix is to exclude `standupReported` from gathering, and the interval stays closed exactly
as FR-4 specifies.** The exclusion stands on its own merits rather than on the clock tie: *a
report is not work*. "Yesterday I generated a stand-up" is not something the user says at today's
stand-up, so the kind should never reach the renderer or the prompt regardless of timestamps —
including when two reports happen in one day and the earlier one's event sits in the middle of
the window, where an interval change would not help.

Rejected alternatives:

- **A half-open interval `(windowStart, now]`.** It deviates from FR-4's stated interval, silently
  drops a legitimate note stamped at exactly `windowStart`, and leaves `standupReported` events
  flowing in from mid-window — narrowing the problem rather than solving it.
- **Both.** Two deviations where one suffices, and the interval change becomes *untestable*: once
  the kind is excluded, no fixture can distinguish half-open from closed, so it would be a line of
  code nothing can verify. This repository has already shipped four tests in one PR that compiled,
  passed, and could not detect anything; adding an unfalsifiable branch is the same defect in
  another shape.

**M2-04 is unaffected, but it does inherit a constraint.** Undo must redact the `standupReported`
events Copy appended, and this gathering path deliberately never returns them — so M2-04 has to
find them by its own query, not from a `GatheredWindow`. `StandupReport` stores `projectID`,
`windowStart`, and `windowEnd` but no event IDs, so that query is "`standupReported` events for
this project's tasks at or after the report's `windowEnd`". Naming it here is cheaper than M2-04
discovering mid-task that the type it expected to reuse withholds exactly the rows it needs.

### 5.2 An inverted window is clamped, not fatal

If `windowStart > windowEnd`, `windowStart` is set to `windowEnd`. The window is a zero-length
instant, gathers no events, and open tasks still appear per §4 — so the user gets a
"Today / Blockers" report rather than a crash or a fabricated 24-hour window. The clamp is
logged; §8 permits metadata in logs, and the values here are dates, not task content.

**This is reachable through a supported path, not defensive padding.** §10.1 merges
`lastStandupAt` by "take the later timestamp". Report on Mac B whose clock runs a few minutes
fast, export, import onto Mac A, and Mac A's stored `lastStandupAt` is genuinely ahead of its own
`now`. M2.5 is core rather than optional (§10), so this arrives by design rather than by
accident. `NoteCorrection` already reasons about the same class of skew from the same cause, and
resolves it the same way: pick the less-bad failure rather than reject the input.

It also preserves an invariant M2-03 and M2-04 both depend on: every persisted `StandupReport`
satisfies `windowStart <= windowEnd`, so undo restoring `lastStandupAt` from `windowStart` cannot
propagate the anomaly forward.

Rejected alternatives:

- **Fall back to 24h.** It silently re-reports up to a day of work the user already said out loud
  on the other Mac. Duplicating a stand-up is a worse failure than a thin one, and it is
  invisible. It also overloads the first-run rule: 24h means "never reported", not "reported
  recently somewhere else".
- **Throw.** §7.4's posture is that the user must never arrive at a stand-up empty-handed. Failing
  the app's core feature because two Macs' clocks disagree by ninety seconds is a bad trade.
- **Ignore it.** The inverted interval does gather nothing on its own, but M2-03 then persists
  `windowStart > windowEnd` and M2-04 restores a future `lastStandupAt` from it — the anomaly
  becomes permanent instead of absorbed.

---

## 6. Purity: proved, not asserted

This is the acceptance criterion with the most teeth and the easiest one to write an
unfalsifiable test for. Four independent gates, each of which must be **mutation-checked** — the
behaviour deliberately broken, the test confirmed red, then restored — before it is kept.

| # | Gate | What it catches |
|---|---|---|
| 1 | `WriteCounter` observes **zero** `.stenoDidWrite` posts across a gather | a future `commit()` creeping in |
| 2 | `context.hasChanges == false` afterwards, on a context that had none before | an uncommitted mutation |
| 3 | `project.lastStandupAt` unchanged, read back through a **second `ModelContext`** | the clock advancing |
| 4 | Gather for A leaves B's `lastStandupAt` and B's events untouched, also via a second context | D16 violations |

**Gate 3's second context is load-bearing, not ceremony.** A same-context refetch returns the
object already held, so the assertion would pass even if the value had been mutated in memory.
The independent context is what makes it a real read of the store.

Gates 1 and 2 test different failures and neither subsumes the other: a write that never posts
the notification passes gate 1, and a write that posts and then saves passes gate 2.

---

## 7. Test plan

Mapped to the task's acceptance criteria, plus the cases this design introduces.

| Criterion | Test |
|---|---|
| First run produces a 24h window | `ReportWindow.bounds(nil, now)` against literals |
| Subsequent runs use that project's own `lastStandupAt` | gather with a set timestamp |
| Generating changes nothing | the four gates in §6 |
| A report for A does not alter B | gate 4, two projects |
| Redacted events excluded (§3.3) | fixture with a redacted note inside the window |
| A 3-day and a 2-week gap both work, no special-casing | one parameterized table, one code path |
| §5.1 | `standupReported` stamped at exactly `windowStart` does not appear |
| §5.1 | a non-`standupReported` event at exactly `windowStart` **does** appear |
| §5.2 | inverted window → clamped, zero events, open tasks survive, `start == end` |
| §4 | a quiet `inProgress` task survives with an empty `events` array |
| §4 | a quiet `done` task with no window events is dropped |
| §4 | an archived task is dropped even with events in the window |
| §3 | task ordering is stable across repeated gathers |
| §2 | `ticketKeys` carries every `jiraIssue` ref, sorted, and no other kind |

The weekend/vacation criterion is one parameterized table deliberately: its point is that a
three-day gap and a fourteen-day gap traverse *the same code* with no branch between them. Two
hand-written tests would pass just as well against an implementation that special-cased one of
them, which is precisely what D8 says must not exist.

---

## 8. Verification of this design

The algorithm in §3 was written as a compiling probe in `StenoKit/Report/` and built with
`make build` before this document was written, then exercised at runtime by two tests under
`make test`. Both probe files have been removed; the working tree is clean.

What that established, rather than assumed:

1. `#Predicate<TaskItem> { $0.projectID == id && !$0.isArchived }` compiles **and** executes,
   excluding archived tasks.
2. `#Predicate<Event> { $0.timestamp >= start && $0.timestamp <= end && !$0.isRedacted }` compiles
   **and** executes — a predicate that compiles can still throw at fetch time, so this needed
   running, not reading.
3. The closed interval is genuinely inclusive at both ends, which is what makes §5.1's collision a
   measured fact.
4. `(createdAt, id.uuidString) < (...)` tuple comparison, `for … where` with an `EventKind`
   comparison, and the `sourceRefs` filter all compile in module scope.

This is the practice `DECISIONS.md` records from M1-04 onward: building the code before writing it
down finds defects that reviewing prose does not.

---

## 9. Out of scope

Per the task file, and worth restating because each is a plausible place to overreach:

- **Rendering** — M2-02. Nothing here emits markdown.
- **Advancing `lastStandupAt`** — M2-03. Computation is side-effect free; §6 is how that is
  enforced.
- **Refreshing external refs** (FR-4 step 4) — M4-01. `ticketKeys` carries identifiers only.
- **Any AI concern** — M3. `Report/` must not reference the AI layer; `ARCHITECTURE.md` §2 rule 3
  is what makes §7.4's fallback a first-class path rather than an error handler.
