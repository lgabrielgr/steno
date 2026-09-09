# M2-03 — Report UI & Copy: design

**Task:** [`docs/tasks/M2-03-report-ui-and-copy.md`](../../tasks/M2-03-report-ui-and-copy.md)
**Requirements:** FR-4 (full flow), FR-3 (keyboard-first, DONE window), D6, D16, §3.3, §3.5
**Branch:** `feat/report-ui-and-copy`
**Date:** 2026-09-09

M2's exit criterion: "Prepare Stand-up" → editable draft → Copy, with all of Copy's side
effects applied atomically, and none of them applied on generate.

---

## 1. The spec is wrong about the clock, and this task corrects it

FR-4 step 7 says Copy sets `project.lastStandupAt = now`. The window the draft was built from
ends at *generate* time. Those are different instants, and the difference is a hole:

```
09:00  generate   → window [yesterday 09:00, 09:00], draft rendered
09:15  capture    "found the race in setUp"
09:30  Copy       → lastStandupAt = 09:30   (FR-4 as written)

tomorrow's window = [09:30, now]
```

The 09:15 capture is in neither today's draft nor tomorrow's window. No report will ever
contain it. For a tool whose entire promise is that nothing captured is lost, that is the worst
available failure mode — and FR-4's own note shows the requirement was written without noticing
it: "a user who previews at 09:00, gets pulled into a meeting, and reports at 09:30 must get the
full window" reasons carefully about the *start* of the interval and not at all about the end.

**Copy sets `lastStandupAt = window.end`** — the generate instant, the same value written to
`StandupReport.windowEnd`. Everything captured between generate and Copy falls into the next
window instead of into a gap.

Three properties follow, and each is worth more than literal compliance:

- Nothing is unreportable. The gap closes with no special case.
- `windowStart`/`windowEnd` describe exactly the interval the stored `markdownBody` covers,
  rather than an interval wider than the text. M2-04 reads `windowStart` back as the recovery
  value, and M2.5's export ships these rows; both want the honest pair.
- A draft left open for hours is *safe* rather than merely stale. The frozen window is a
  snapshot of what the user reviewed, and the clock advances to match it, so the cost of
  leaving the sheet open is a thinner report today — never a lost note.

Amended in this PR: REQUIREMENTS.md → **v1.15**, FR-4 step 7 and §3.5's `windowEnd` row, with a
changelog line. Recorded as **D-076**.

### Rejected: re-gather at Copy

Makes the window genuinely end at `now`, and destroys the feature it is protecting. The user's
edits are either discarded or contradicted by the freshly rendered text — so FR-4 step 6's
editable draft becomes a lie, and §7.3's "the user's phrasing wins" is broken to satisfy a
sentence about a timestamp.

---

## 2. `StandupService`: one owner for four effects

`StenoKit/Report/StandupService.swift`. Shaped like `NoteService` and `StatusService` —
`@MainActor` because `ModelContext` is not `Sendable`, `now` injected so timestamps are
assertable, `save` injected because a real `ModelContext` cannot be made to fail on demand and
the rollback is the path that most needs a test — plus one seam its siblings do not have: the
clipboard.

```swift
public struct StandupCommit {
    public let report: StandupReport
    public let didReachClipboard: Bool
}

public func commit(_ body: String, of window: GatheredWindow, for project: Project)
    throws -> StandupCommit
```

### Order of operations

1. **Guard `window.projectID == project.id`.** `NoteService.correct`'s guard, for its reason: a
   mismatched pair would advance one project's clock against another project's window. D16 made
   unreachable rather than merely untested.
2. **One `stamp = now()`**, used for `report.generatedAt` and every event's `timestamp`. Two
   calls would let a report and the events it produced disagree about when it happened.
3. **Insert the `StandupReport`** — `windowStart: window.start`, `windowEnd: window.end`,
   `markdownBody: body` (the *edited* text), `wasAIGenerated: false`, `modelUsed: nil`.
4. **Insert one `standupReported` `Event` per task in `window.tasks`**, body
   `"Reported to standup"`, payload carrying the report id (§4).
5. **`project.lastStandupAt = window.end`** (§1).
6. **`try save(context)`**; on failure `context.rollback()` and rethrow.
7. **Post `.stenoDidWrite`** — after the save, never before, per D-019: an observer that reloads
   must not read a context whose write has not landed.
8. **Then the clipboard.**

### Why this is atomic

Steps 3–5 are inserts and one field write into a single `ModelContext`, committed by a single
`save`. There is no partial state to reach: either the transaction lands or `rollback()` returns
the context to where it started. The acceptance criterion — "Copy applies all three side
effects, or none of them. A failure partway must not leave `lastStandupAt` advanced with no
report persisted" — is a property of the transaction boundary, not of defensive ordering.

The rejected alternative was four separate saves with compensating writes. It cannot satisfy the
criterion at all: the compensation for an appended `Event` is a delete, which §3.3 forbids
outright.

### Why the clipboard is last

If the save fails, the user gets nothing on the clipboard and retries; their draft is still on
screen and nothing was lost. The alternative — clipboard first — hands the user text to read
aloud at a stand-up the app has no record of, and gives them no signal that the record is
missing. For a recall tool that is strictly worse than refusing the copy.

**The residual case is real and is reported, not reversed.** If the save succeeds and
`NSPasteboard.setString` returns `false`, the store is advanced with nothing on the clipboard.
That cannot be rolled back without deleting an `Event`. So `didReachClipboard` is a second
channel alongside `throws`, because the two failures need different responses from the user:

| Failure | Store | Clipboard | Safe to retry? |
|---|---|---|---|
| `save` threw | untouched | untouched | **Yes** — nothing happened |
| `copy` returned `false` | committed | empty | **No** — retry double-reports |

The sheet stays open in both cases (§6), which is also where M2-04's Undo will live — the
recovery for the second row is undo, not retry.

### The clipboard seam

`StenoKit/Support/SystemClipboard.swift`: a small `enum` wrapping `NSPasteboard.general`
(`clearContents()` then `setString(_:forType: .string)`), and the only place in StenoKit that
imports AppKit. Injected as `copy: (String) -> Bool`, defaulting to it, so `make test` never
touches the real pasteboard — §9.4's headless bundle has no business mutating the developer's
clipboard, and a test that did would be order-dependent on anything else that copies.

---

## 3. What "included" means

**The `standupReported` events go to every task in `window.tasks`, regardless of what the user
did to the text.** If they delete a bullet from the draft, that task still gets its event.

The alternative is parsing the edited markdown back to task IDs. It is not merely hard, it is
ill-defined — the draft is free-form text with no identifiers in it, and D6's Slack `mrkdwn`
carries no structure to recover. Making the append-only log depend on a reverse-parse of
user-edited prose would be the least reliable thing in the system.

The frozen window is the record of what was reported on; the text is the user's phrasing of it.
Those are different facts and only one of them is machine-readable.

---

## 4. `Event.payload` links each event to its report

Each `standupReported` event carries `payload` = JSON `{"reportID": "<uuid>"}`, encoded from:

```swift
struct StandupReportedPayload: Codable { let reportID: UUID }
```

M2-04 must redact "the `standupReported` events appended by *this* report". This is the link
that makes that a precise query. §3.3 specifies `payload` as a "JSON blob for structured
external data"; this is its first use, and a report id is exactly structured data about the row.

**Rejected: matching on `timestamp == report.generatedAt`.** It works — step 2 stamps both from
one `now()` — but it couples M2-04 to a coincidence rather than to a statement. A later change
that stamps events independently would silently break undo, with nothing in either file
recording why the two values had to agree.

---

## 5. Generate writes nothing, by construction

`MainWindowModel.prepareStandup()`:

1. Resolve the selected project; return if there is none (§7).
2. `try ReportGatherer(context:now:).gather(for: project)`.
3. `SlackMarkdown.render(RawReportSections.build(from: window))`.
4. Hand both to `StandupDraftModel`; set `activeSheet = .standupDraft`.

There is no write path on this route to fail on. `ReportGatherer` has no `save` parameter and no
`commit()` — M2-01 states that absence *is* the design (D-065) — and steps 3 and 4 touch pure
functions and view state. The acceptance criterion "generating a preview has zero side effects"
holds because there is nothing in the path that could have one, not because each caller
remembers to avoid it.

**A failed gather does not open the sheet.** The error goes to the main window's existing inline
banner (`lastError`) and the modal never appears. A sheet whose only content is an error message
is worse than no sheet: it asks the user to dismiss something they did not summon.

---

## 6. `StandupDraftModel` and the sheet

`StenoKit/Features/MainWindow/StandupDraftModel.swift` — `@Observable`, `@MainActor`:

```swift
public enum StandupDraftPhase: Equatable { case editing, copied }

public var text: String                     // bound by the sheet's TextEditor
public private(set) var phase: StandupDraftPhase
public private(set) var window: GatheredWindow?
public private(set) var lastError: String?  // a write failed
public private(set) var notice: String?     // nothing failed to save; the clipboard refused
```

Modelled on `NoteComposerModel`, including the part that matters: **it holds no reference back to
`MainWindowModel`.** Its inputs — the window, the project — arrive as parameters from a thin
`MainWindowModel+Standup.swift`, which is also what reloads afterward. No closure web to
initialise, no retain cycle to weaken, and the state machine sits in the framework the headless
bundle can reach (D-010 puts view state beyond it).

`lastError` and `notice` are separate properties for `NoteComposerModel`'s reason: one means a
write failed, the other means nothing failed and the user still needs telling. Merging them
would make the sheet unable to decide whether retrying is safe.

### The sheet's two phases

**`.editing`** — a header line (window bounds, task count, cadence), a `TextEditor` bound to
`text`, and `Cancel` / `Copy`. Cancel discards: the draft belongs to the moment it was
generated, and regenerating is free of side effects by construction, so there is nothing to
preserve. No "Regenerate" button — closing and pressing ⌘R again is the same action with fewer
states to get wrong.

**`.copied`** — a confirmation, the text still selectable, and `Close`. The sheet does **not**
dismiss on Copy, and that is load-bearing: M2-04's task file requires undo to "be easy to find
right after a Copy and not require hunting through settings". This is that place. Dismissing on
Copy would leave M2-04 to invent a home for Undo under time pressure — a menu item or a
transient banner — after the affordance it belongs next to has already disappeared.

On a save failure the phase stays `.editing` and **the text is kept**, which is
`CaptureFieldModel`'s contract for the same reason: the user retries, never retypes.

### An empty window is not a special case

D-074 renders every section, so a window with nothing in it is three headings that each say
`_None_`. Copying it is legitimate — "nothing to report since yesterday" is a thing people say
at stand-ups — and it appends zero events while still advancing the clock, which is correct.

---

## 7. Placement and gating

**"Prepare Stand-up" is a prominent, full-width button pinned to the bottom of the task list
column** via `.safeAreaInset(edge: .bottom)`. FR-4 calls it "prominent, always-visible" and "the
core value delivery"; the existing toolbar renders New Task as a bare `+`, which is the
opposite. Pinned rather than in the list, so scrolling cannot hide it. In the task list column
rather than the toolbar, so "which project am I reporting on" is answered by what is directly
above the button.

**Gated on a single project being selected.** A fourth `can*` property on `MainWindowActions`,
`canPrepareStandup`, joining `canCreateTask` / `canChangeStatus` / `canAddNote` — true only when
`selection` is `.project(id)` and that project is still visible. D16 says each meeting covers
exactly one project, and `lastStandupAt` is per-project; there is no coherent answer for the
"All" pseudo-project. The button and the menu item both read this property so they cannot
disagree about when the action is live.

**⌘R**, as a real menu item in the Task menu — FR-3 lists "generate report" among the actions
needing a shortcut, and D-020's rule stands: shortcuts are menu-bar commands reached through
`@FocusedValue`, never in-view `.keyboardShortcut` bindings, because the latter are enumerated
nowhere. ⌘R is unused in this app and carries no conflicting system meaning here.

---

## 8. FR-3's DONE window, which this task breaks

`MainWindowModel.doneCutoff()` returns `now() - 24h` unconditionally. Its comment says this is
correct "for every state reachable today" **because `lastStandupAt` stays nil until M2-03 ships
the Copy action that advances it**. This task is what makes that false. FR-3 requires the DONE
section to show "only items completed within the current report window"; the first Copy silently
starts violating it, in a file this task would not otherwise touch.

A documented exception of that shape is a bug filed against whichever task makes it reachable.
This is that task, so it is fixed here.

**`TaskGrouping.groups(from:doneSince:)` takes `(TaskItem) -> Date` instead of a flat `Date`**,
and `MainWindowModel` resolves each task's cutoff through the rule M2-01 already owns:

```swift
groups = TaskGrouping.groups(from: fetchTasks()) { task in
    ReportWindow.bounds(
        lastStandupAt: project(withID: task.projectID)?.lastStandupAt,
        now: now()
    ).start
}
```

Per-task rather than per-view, because of the "All" pseudo-project: tasks there span projects
with different `lastStandupAt` values and different cadences. A single cutoff has to pick one,
and the only safe pick — the earliest across visible projects — leaks a `periodic` project's
fortnight-wide window into a `daily` project's DONE section.

Reusing `ReportWindow.bounds` rather than restating the rule also keeps the first-run case
right for free: a project that has never been reported on still gets 24 hours, from the one
place that decision lives.

---

## 9. Verification

`make build && make test && make lint` before the PR (§9.5 step 4, §13).

Four of these are tests that could compile, pass, and prove nothing. Each gets a mutation that
**must** make it fail before the test is believed:

| Criterion | Test | Mutation that must break it |
|---|---|---|
| Generate has zero side effects | Generate 3× through `MainWindowModel`; assert `WriteCounter.posts == 0`, `lastStandupAt` still nil, `StandupReport` count 0 | Add a stray `save` to the generate path |
| All-or-none | Inject a throwing `save`; refetch through a **second `ModelContext`** and assert 0 reports, 0 events, `lastStandupAt` unchanged | Move `project.lastStandupAt = …` after the save |
| Edited text wins | Set `text` to a string the renderer would never produce, commit, assert `markdownBody` equals it exactly | Re-render from the window inside `commit` |
| D16 | Two projects with tasks; copy A; assert B's `lastStandupAt` is nil and B's tasks carry no `standupReported` | Drop the `window.projectID == project.id` guard |
| Clock lands on `windowEnd` | `now` returns T1 at gather and T2 at commit; assert `lastStandupAt == T1` | Change it to `stamp` |
| Per-task DONE cutoff | Two projects, different `lastStandupAt`, one DONE task each — one inside its window, one outside | Revert to a flat cutoff |
| Clipboard refused | Inject `copy` returning `false`; assert the store committed and `didReachClipboard == false` | Make the service throw instead |
| Payload round-trips | Decode a committed event's `payload`; assert `reportID == report.id` | Encode `project.id` instead of the report's |
| Append-only holds | `EventLogInvariant` over the copy path | — (existing harness) |

SwiftData discipline, from prior tasks in this repo: `ModelContext(container)` in tests, never
`mainContext` (it does not retain its container); a **second** context for any refetch meant to
prove something about the store rather than about the object being held; and no `EventKind`
inside a `#Predicate` — filter kinds in memory, as `EventQueries` and `ReportGatherer` already
do.

Pasting into Slack (D6) is a manual check; agents cannot verify it. Called out in the PR body as
outstanding rather than claimed.

---

## 10. Files

**New — StenoKit**
- `Report/StandupService.swift`
- `Report/StandupReportedPayload.swift`
- `Support/SystemClipboard.swift`
- `Features/MainWindow/StandupDraftModel.swift`
- `Features/MainWindow/MainWindowModel+Standup.swift`

**New — app target**
- `Features/MainWindow/StandupDraftSheet.swift`

**Changed — StenoKit**
- `Features/MainWindow/MainWindowActions.swift` — `ActiveSheet.standupDraft`,
  `canPrepareStandup`, `prepareStandup()`
- `Features/MainWindow/MainWindowModel.swift` — holds the draft model; `doneCutoff` → per-task
- `Features/MainWindow/TaskGrouping.swift` — `doneSince` becomes `(TaskItem) -> Date`

**Changed — app target**
- `MainWindowView.swift` — the sheet case
- `TaskListView.swift` — the pinned footer button
- `App/MainWindowCommands.swift` — ⌘R

**Changed — docs**
- `REQUIREMENTS.md` → v1.15 (§1)
- `DECISIONS.md` — D-076 onward, one entry per decision in §1–§8
- `tasks/README.md` — no outstanding tick debt; M2-01 and M2-02 are both already ticked

---

## 11. Out of scope

- **Undo (FR-4.1) — M2-04.** This design hands it the two things it needs: `windowStart` as the
  recovery value, and the `reportID` payload to find its events.
- **AI generation — M3-03**, substituting at the `[ReportSection]` seam. `wasAIGenerated` is
  `false` for every report this task produces.
- **Ref refreshing (FR-4 step 4) — M4-01**, which inserts its progress indicator into
  `prepareStandup()`.
- **Report history browsing.** Q(M3) in §12 is a product question and unresolved; raised in the
  PR body, not decided here.
