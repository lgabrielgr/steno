# M2-04 — Undo Last Stand-up: design

**Task:** [`docs/tasks/M2-04-undo-standup.md`](../../tasks/M2-04-undo-standup.md)
**Requirements:** FR-4.1, §3.3 (append-only), §3.5 (`StandupReport`), FR-3 (keyboard-first), D16
**Branch:** `feat/undo-standup`
**Date:** 2026-09-10

The safety net under M2-03. Copy has four effects and three of them touch the store; undo
reverses all three, atomically, by redaction and never by deletion. It is the smallest task in
M2 and the one with the most ways to be quietly wrong.

---

## 1. What M2-03 already decided, so this task does not relitigate it

Four constraints arrive from the merged code rather than from FR-4.1, and each one closes off
the obvious implementation:

| Constraint | Source | Consequence here |
|---|---|---|
| Undo cannot reuse `NoteService.redact` | D-044 | That method guards on `event.kind.isUserAuthored`, which is `false` for `standupReported` — it refuses precisely the events FR-4.1 must redact, and refuses by returning `false`, so the misuse would be silent. §2 gives undo its own path |
| Undo cannot get its events from a `GatheredWindow` | D-066 | `ReportGatherer` drops `standupReported` unconditionally, so the kind never appears in a window. §3 queries for them directly |
| `StandupReportedPayload(reportID:)` is how an event names its report | D-079, `StandupReportedPayload.swift` | M2-03 built this type *for this task* and explicitly rejected matching on `timestamp == report.generatedAt` as coupling undo to a coincidence. §3 honours that |
| `windowStart <= windowEnd` holds for every persisted report | D-067 | `ReportWindow.bounds` clamps an inverted window, so restoring `lastStandupAt = windowStart` can never install a *future* timestamp and turn a transient clock skew into a permanent one |

M2-03 also kept the draft sheet open after Copy specifically so this task would have somewhere
to put the button (D-080). §8 uses it.

---

## 2. `StandupUndoService`: a sibling of `StandupService`, not a method on it

A new type in `StenoKit/Report/`, shaped like `StandupService` and `NoteService` — `@MainActor`
because `ModelContext` is not `Sendable`, `context` and `save` injected because a real
`ModelContext` cannot be made to fail on demand and the rollback is the path that most needs a
test.

It takes no `now` and no `copy`. Undo reads its timestamps out of the report being undone rather
than off the clock, and it touches no clipboard — see §7.

### Rejected: `undo()` on `StandupService`

One type for both directions of FR-4 step 7 is the tidier-sounding option and is wrong on three
counts. That type's `init` carries a `copy: @MainActor (String) -> Bool` seam undo has no use
for, so every undo test would have to supply a clipboard stub for a method that never reaches
one. Its doc comment declares it "the one place the stand-up clock advances," which undo makes
false in a way no reader would expect from the name. And D-044 states the eligibility rules
differ in kind: `StandupService` guards on *project identity*, undo guards on *report recency*.

### Rejected: the logic on `MainWindowModel+Standup`

D-044's own reasoning, applied again: the guard is about reports and events, not about what is
on screen. A window model is the wrong owner for a rule that has nothing to do with a window,
and it would put a store write behind a surface the headless bundle cannot reach (§9.4).

---

## 3. Finding the events: the payload discriminates, the timestamp only narrows

Neither `kind` nor `payload` is expressible in a SwiftData `#Predicate` — the enum case is the
wall `EventQueries.timeline` documents, and `Data` comparison is not a predicate operation — so
the work splits in two:

1. **Fetch**, through a new `EventQueries.notRedacted(atOrAfter:)`:
   `#Predicate { $0.timestamp >= date && !$0.isRedacted }`, called with `report.windowEnd`.
2. **Match**, in memory: `kind == .standupReported`, and
   `StandupReportedPayload.decoded(from: $0.payload)?.reportID == report.id`.

**The payload is the discriminator, not the timestamp.** D-079 rejected `timestamp ==
report.generatedAt` even though it works today, because it couples undo to a coincidence
`StandupService` is free to stop honouring. Since the payload match is exact and unique, the
fetch bound exists only to keep the result set small; `windowEnd` is what D-066 named, and being
over-broad costs nothing because the match, not the bound, decides.

**The redaction filter stays in `EventQueries`.** §3.3 hides a redacted event from summaries and
that rule already lives in one place, rewritten by nobody. A bespoke `!isRedacted` predicate in
the undo service would be the second copy, and the first one to drift. Excluding already-redacted
rows here is also the honest set: re-redacting is idempotent, but "redact 4 rows" reading as
"redact the 4 rows that needed it" keeps §5's log line meaningful.

### The test that makes this decision falsifiable

Two reports for one project whose event sets overlap in time, undoing the **second**. Under
payload matching only the second report's events are redacted; under timestamp matching the
fetch bound alone would take both. A test that undoes a project's only report passes under either
rule and therefore proves nothing — see the standing hazard in `steno-tests-that-cannot-fail`.

---

## 4. Eligibility: one query answers both acceptance criteria

```
undoableReport(for project: Project) -> StandupReport?
```

Fetches `StandupReport` where `projectID == project.id`, sorted by `generatedAt` descending,
`fetchLimit = 1`, and returns it only when `!isUndone`.

That single query satisfies both of FR-4.1's rules. "Undo applies only to the most recent report"
falls out of the sort and the limit — an older report is never the row returned. "Only while it
is the most recent" falls out of the same fact evaluated at call time rather than cached at Copy
time. And a report already undone yields `nil`, so undo is not itself undoable, matching
`Event.redact()`'s deliberate one-way design (there is no `unredact()`).

**A `generatedAt` tie cannot be broken and does not need to be.** `SortDescriptor` has no
secondary key available — `UUID` is not `Comparable`, the same wall `EventQueries.timeline`
documents for its own tie case — but two Copies stamped at the same instant are unreachable:
`StandupDraftModel.canCopy` is `false` once `phase` leaves `.editing`, and a second report
requires a second sheet.

**Nothing fetched `StandupReport` before this task.** M2-03 only inserted. This is the first
read path, and it lives on the service beside the rule it serves rather than in a new query
vocabulary type that would have one caller.

---

## 5. The transaction

```
undo(_ report: StandupReport, for project: Project) throws -> Int
```

Returns the number of events redacted, which the service logs — a count, never event bodies,
matching `ReportGatherer`'s convention of logging dates but never task content.

1. **Guard the pair.** `report.projectID == project.id`, else
   `StandupUndoError.reportBelongsToAnotherProject`. `StandupService.commit` guards its own pair
   for this reason and `NoteService.correct` before it: a mismatch would restore one project's
   clock from another project's window, which is exactly what D16 forbids.
2. **Guard recency.** `undoableReport(for: project)?.id == report.id`, else
   `StandupUndoError.reportIsNoLongerUndoable`. This covers both "a newer report exists" and
   "already undone" with one comparison, because §4's query already folds them together.
3. `report.markUndone()`
4. `event.redact()` for each event matched in §3.
5. `project.lastStandupAt = report.windowStart`
6. **One save.** On throw, `context.rollback()` and rethrow.
7. `NotificationCenter.default.post(name: .stenoDidWrite, ...)`, after the save and never before
   (D-019).

Steps 3–5 are field writes into a single `ModelContext` committed by a single `save`, so "a
failure partway must not leave the clock restored with the events still live" is a property of
the transaction boundary rather than of careful ordering — `StandupService.commit`'s argument,
unchanged. It matters more here, because the compensating write for a redaction is an
`unredact()` that §3.3 does not permit to exist.

### Taking the report explicitly rather than resolving it internally

`undo(for: project)` resolving its own report is one fewer parameter and one fewer error case.
Rejected: it turns "undo is unavailable once a newer report exists" from a refusal the caller can
observe into a silent substitution of a *different* report, and that acceptance criterion is then
testable only by inspecting which rows changed. The explicit pair also mirrors
`commit(_:of:for:)`, so the two halves of FR-4 step 7 read the same way.

---

## 6. Restoring `lastStandupAt` on a project's first report

`Project.lastStandupAt` is `Date?` and is `nil` until a project's first Copy. Undoing that first
report restores `windowStart` — a frozen "24h before the moment Prepare ran" — not `nil`.

**This is the right direction, not an acceptable approximation.** The alternative is
unimplementable and worse if it were not: `StandupReport` records no "was this the first" flag, so
`nil` could only be inferred, and restoring `nil` would make the next Prepare compute a *sliding*
24h window that silently loses everything between the original `T − 24h` and the new `now − 24h`.
Restoring the frozen instant yields a window that is a superset of the one the user would have got
had they never pressed Copy. FR-4.1's promise is that undo loses nothing; a slightly wider window
keeps it and a sliding one breaks it.

The task's acceptance criterion — "regenerating after undo produces the same window as before the
mistaken Copy" — is therefore exactly true for every report after the first, and true in the
"loses nothing" sense for the first. §9 tests both cases separately rather than asserting one
sentence that only holds for one of them.

---

## 7. What undo does not do

- **It does not touch the clipboard.** The markdown is already in the user's paste buffer and
  may already be in Slack. Restoring the previous clipboard contents is not among FR-4.1's three
  effects, is not observable to the store, and would mean the app silently mutating a system
  resource the user may have moved on from.
- **It appends no event.** §3.3's `EventKind` has no case for "a report was undone" and adding
  one is a schema change with export consequences (§10.2), for a fact already recorded by
  `StandupReport.isUndone`.
- **It is not itself undoable.** §4's query refuses an already-undone report, and `Event.redact()`
  is one-way by design — its doc comment names FR-4.1 as the reason there is no `unredact()`.

---

## 8. Surfaces

### The sheet — a third phase

`StandupDraftPhase` gains `.undone`. `StandupDraftModel` gains:

- `committedReport: StandupReport?`, set from `StandupCommit.report` on a successful commit. M2-03
  discards that value today; the sheet's Undo button is what needs it.
- `canUndo: Bool { committedReport != nil && phase == .copied }`
- `undo(to project: Project) -> Bool`, mirroring `commit(to:)`: never throws, returns whether the
  window must refetch, sets `lastError` on failure while staying `.copied` so the user can retry.

`StandupDraftSheet`'s `.copied` case gets `Undo` beside `Close`; the new `.undone` case shows the
headline "Stand-up undone" and `Close` alone. Undo cannot be pressed twice and Copy stays dead —
the sheet already keys its headline on three states rather than two, so this is the pattern it has.

Dismissing on undo was rejected: the user would watch three store effects reverse with no
acknowledgement, and the sheet is the only surface that could report an undo *failure*.

### The menu — undo survives the sheet

FR-4.1 exists because "users will misclick," and the realistic misclick is noticing after the
sheet is closed. `MainWindowModel` gains:

- `undoableStandupReport: StandupReport?`, refreshed in `reload()` alongside `projects` and
  `groups`. Cached rather than fetched on demand because `canUndoStandup` is read from
  `MainWindowCommands.body`, and a fetch per SwiftUI update pass is a store read on the render
  path — the hazard `selectedTaskEvents` documents at length.
- `canUndoStandup: Bool { undoableStandupReport != nil && activeSheet == nil }`
- `undoLastStandup()`, which resolves the project from the report's `projectID` (not from
  `selection`, for `copyStandup()`'s reason) and reloads on every outcome.

`MainWindowActions` gains both; `MainWindowCommands` gains one `Button("Undo Last Stand-up")` in
the `Task` menu beside Prepare Stand-up. **No key equivalent.** ⌘Z is the system's text-editing
undo and binding it to a store transaction that the app's own `TextEditor`s sit inside would be a
trap; FR-3 asks for keyboard paths to the primary actions, and this is a recovery action.

`activeSheet == nil` in the gate is deliberate: while the sheet is up it owns undo, so the menu
path cannot fire behind it and leave `phase` reading `.copied` over a report that is now undone.
Gating this way rather than reconciling two paths is the same choice `canPrepareStandup` makes.

### Why a reload is load-bearing

Undo moves `lastStandupAt` *backwards*, which moves FR-3's DONE cutoff for that project — so the
task list is stale until `reload()` runs, exactly as it is after a Copy. The `.stenoDidWrite` post
in §5 step 7 already triggers one; the explicit reload in `undoLastStandup()` is the second, known
and harmless, matching the shape `MainWindowModel+Notes` documents.

---

## 9. Verification

Every acceptance criterion, and what makes each test capable of failing:

| Criterion | Test | Why it can fail |
|---|---|---|
| `lastStandupAt` restored from `windowStart` | Commit against a known `lastStandupAt`, undo, assert equality with the pre-Copy value | The pre-Copy value is a literal distinct from both `windowEnd` and `now` |
| Round-trip loses nothing (later reports) | gather → commit → undo → gather; assert identical bounds *and* identical task set | Bounds alone would pass if the task set silently narrowed |
| Round-trip on a project's **first** report | Same, from `lastStandupAt == nil`; assert the second window's `start` equals the first's `start` (§6) | Restoring `nil` gives a later `start`; a literal clock makes the difference assertable |
| Events redacted, **not deleted** | Count *all* events with a descriptor that does **not** exclude redacted rows, before and after | A count that filtered redaction would drop to zero either way and prove nothing |
| Only *this* report's events redacted | Two reports for one project, overlapping in time, undo the second (§3) | Fails under timestamp matching — the point of the test |
| `StandupReport` row survives with `isUndone` | Refetch through a second `ModelContext` | A same-context fetch returns the object already held (`steno-swiftdata-refetch-is-not-independent`) |
| Unavailable once a newer report exists | Commit, commit again, undo the first → `reportIsNoLongerUndoable`; assert `lastStandupAt` unmoved | Asserting only the throw would pass over a service that threw *after* writing |
| Redacted events leave the timeline | `EventQueries.timeline(forTaskID:)` before and after | The kind is in the timeline before undo, so the assertion has two distinct states |
| Redacted events feed no later summary | `ReportGatherer` over a window containing them | Already true via D-066; asserted so a future change to that exclusion breaks here too |
| Rollback on save failure | Injected throwing save, then a **later successful save**, then refetch | Without the later save "the store is unchanged" is unfalsifiable (`steno-rollback-tests-need-a-later-save`) |
| Project mismatch refused | `undo(reportOfA, for: projectB)` | Distinct projects, distinct clocks |

Plus `StandupDraftModel` phase transitions and `canUndo`, and `MainWindowModel.canUndoStandup`
gating across `.all` selection, an undone report, and an open sheet.

`make build && make test && make lint` before the PR. **What cannot be verified here:** the
button and menu item are not clickable by an agent on this machine (TCC), so the PR body states
plainly which checks are the user's — press Undo in the sheet, confirm the headline changes and
the timeline entry disappears; close the sheet and confirm the menu item greys out afterwards.

---

## 10. Files

**New — StenoKit**
- `Report/StandupUndoService.swift`

**New — StenoTests**
- `Report/StandupUndoServiceTests.swift`
- `Report/StandupUndoRoundTripTests.swift`

**Changed — StenoKit**
- `Models/EventQueries.swift` — `notRedacted(atOrAfter:)`
- `Report/StandupReportedPayload.swift` — no change expected; `decoded(from:)` gets its first
  caller, so its doc comment stops describing a future
- `Features/MainWindow/StandupDraftModel.swift` — `.undone`, `committedReport`, `canUndo`,
  `undo(to:)`
- `Features/MainWindow/MainWindowModel.swift` — `undoableStandupReport`, refreshed in `reload()`
- `Features/MainWindow/MainWindowModel+Standup.swift` — `canUndoStandup`, `undoLastStandup()`
- `Features/MainWindow/MainWindowActions.swift` — both of the above

**Changed — app target**
- `Features/MainWindow/StandupDraftSheet.swift` — the Undo button and the `.undone` case
- `App/MainWindowCommands.swift` — "Undo Last Stand-up"

**Changed — docs**
- `DECISIONS.md` — D-084 onward, one entry per decision in §2–§8
- `tasks/README.md` — tick M2-04, and clear the outstanding debt: **M2-03's row is unticked**
  despite merging as PR #26, and M1-08 / M2-01 / M2-02 are missing the `— PR #nn` suffix the
  M1-04/06/07 rows carry

No `REQUIREMENTS.md` amendment. FR-4.1 is implementable exactly as written.

---

## 11. Out of scope

- **Undoing anything else** — notes, status changes, task creation. FR-4.1 is scoped to stand-ups
  and the task file says so.
- **Undo history or a redo stack.** §4's query refuses an undone report; there is no path back.
- **Report history browsing.** This task adds the first `StandupReport` read path, which makes a
  history view look adjacent. It is not: Q(M3) is an open product question raised by M2-03 and
  still unresolved.
- **Import/merge semantics for `isUndone`** — **O-8**, owned by `M2.5-02`. Worth recording as a
  known gap rather than fixing here: §10.1 merges `lastStandupAt` by "take the later timestamp,"
  so exporting a project whose report was undone and importing it onto a machine holding the
  pre-undo value would resurrect the advanced clock. The undo is correct locally; the interchange
  rule that would keep it correct across machines does not exist yet in any form, and inventing
  half of it here would pre-empt M2.5-02's decision.
- **A keyboard shortcut for undo** (§8).
