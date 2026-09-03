# M1-06 — Progress Notes & Timeline

**Milestone:** M1 — Capture
**Depends on:** M1-05
**Blocks:** M2-01
**Requirements:** FR-2, §3.3, D10
**Branch:** `feat/progress-notes`

## Goal

Append-only progress notes, a reverse-chronological timeline, and the 5-minute correction
window implemented as redaction rather than mutation.

## In scope

- Add a note: appends a `note` event with the current timestamp; runs M1-01 extraction over the
  body (FR-1.5 covers note bodies too).
- Reverse-chronological timeline in the detail pane, excluding redacted events.
- The FR-2 correction window: within 5 minutes, "editing" a note sets `isRedacted` on the
  original and appends a **new** `note` event carrying the corrected body and the **original
  timestamp**.
- After 5 minutes, redaction only.
- Note entry reachable in one keystroke from a selected task (FR-2 suggests `N`).

## Out of scope

- Summarizing notes — M3.
- External update events — M4-01 appends `externalUpdate`.

## Acceptance criteria

- [x] Adding a note appends a `note` event; the timeline shows it newest-first.
- [x] **No code path mutates an existing `Event` row except to flip `isRedacted`.** This is the
      invariant; assert it in tests, not just in review.
- [x] A correction within 5 minutes redacts the original and appends a replacement carrying the
      original timestamp — so the timeline does not reorder under the user mid-correction.
- [x] After 5 minutes, editing is unavailable and only redaction is offered.
- [x] Redacted events are hidden from the timeline and from summaries, but the rows still exist.
- [x] `N` (or the chosen key) opens note entry for the selected task.

Criteria 1–5 are ticked against named tests, listed below. **Criterion 6 was ticked by the user's
manual pass on 2026-09-03**, not by a test — no agent in this environment can drive the GUI, and
`.onKeyPress` scoping is precisely the kind of thing that typechecks and still misbehaves. The
hypothesis that `List`'s type-select would swallow the keystroke did not hold: bare `N` focuses the
composer, and it does not fire while typing "n" into the capture field, the New Task sheet, or the
composer itself. See **Manual verification**.

**1 — Adding a note appends a `note` event; the timeline shows it newest-first.**
`NoteServiceTests.addingANoteAppendsOneEvent` pins the append: one row, `kind == .note`, the body
verbatim, `timestamp` from the injected clock, `taskID` the task's, `isRedacted` false.
`EventQueriesTests.theTimelineQueryExcludesRedactedRows` pins the order — three events on one task
plus a decoy on another, asserted as exactly `["newer", "older"]`, so both the sort direction and
the task filter are load-bearing. The window reads that same descriptor and nothing else
(`MainWindowModel.swift:178`), which
`MainWindowModelTasksTests.selectingATaskPublishesItsTimeline` and `.reloadRefreshesTheSelectedTimeline`
pin from the model's side. `NoteComposerModelTests.committingANewNoteClearsTheDraft` covers the
same path end-to-end from the composer.

**2 — No code path mutates an existing `Event` row except to flip `isRedacted`.**
`EventLogInvariantTests.appendOnlyHoldsAcrossEveryWritePath` snapshots the whole event table before
and after **every** write this milestone can produce — `setStatus`, `addBlockedReason`, `addNote`,
`correct` on a note, `correct` on a blocked reason, `redact` — and fails on any change to an
existing row or any deletion. `EventSnapshot` deliberately omits `isRedacted`, which is what makes
a redaction the one permitted write. The guard is the load-bearing test of this task, so it has its
own self-checks: `theInvariantGuardCanActuallyFail` (an in-place body rewrite) and
`theInvariantGuardCatchesDeletion` (a removed row) both assert the guard *reports* — via
`withKnownIssue`, so they start failing the day it stops noticing — and
`theInvariantGuardAcceptsARedaction` pins the shape of the exemption. Those two `withKnownIssue`
cases are the "2 expected failures" in `make test`'s summary.

**3 — A correction within 5 minutes redacts the original and appends a replacement carrying the
original timestamp.** `NoteServiceTests.aCorrectionRedactsAndReappends` asserts both halves on one
store: the original row survives with `isRedacted` set and its body untouched, and the replacement
is a separate row whose `timestamp` is the *original's*, not the correction's.
`.correctingABlockedReasonKeepsItsKind` covers the amended half of FR-2 (D-046) — the replacement
is a `blockedReason`, not a relabelled `note`. `.theWindowDoesNotRestart` pins the consequence
(D-047): a correction of a correction is still measured from the original instant.

**4 — After 5 minutes, editing is unavailable and only redaction is offered.**
`NoteServiceTests.pastTheWindowNothingIsWritten` is the refusal at the service: `correct` returns
`.windowExpired`, the store still holds one unredacted row with its original body, and no
`.stenoDidWrite` was posted. `NoteCorrectionTests.theWindowClosesAtFiveMinutes` pins the boundary
as half-open — open at 299s, closed at exactly 300s. `NoteComposerModelTests.correctabilityFollowsTheClock`
pins the affordance disappearing on its own: the same event is in `correctableEventIDs` at T+0 and
out of it at T+301s. `.beginningACorrectionPrefills` pins the composer refusing to *open* a
correction past the window rather than opening one whose commit is guaranteed to be refused, and
`.refusedCorrectionPostsANotice` pins the notice shown when the window closes between render
and click. Redaction stays available at any age because `NoteService.redact` never consults `now`
at all — its only guards are `isUserAuthored` and "not already redacted"
(`NoteService.swift:123`) — so `redactingKeepsTheRow` and `systemEventsAreNotCorrectable` cover
every age, not just the one they run at.

**5 — Redacted events are hidden from the timeline and from summaries, but the rows still exist.**
`NoteServiceTests.redactingKeepsTheRow` asserts all three clauses on one store: the timeline
descriptor comes back empty, an unfiltered `FetchDescriptor<Event>` still returns the row, and its
body is still the text the user typed. `EventQueriesTests.theTimelineQueryExcludesRedactedRows`
pins the exclusion in the query itself, and `NoteComposerModelTests.redactingStopsACorrectionOfTheSameRow`
covers it through the composer. **The "and from summaries" clause is structural, not measured:**
there are no summaries yet — M2-01's gathering and M3-03's prompt do not exist — so nothing can be
tested against them. What this task delivers is the precondition the criterion is really asking
for: the redaction filter lives in `EventQueries`, one shared descriptor, rather than in each
caller. M2-01 and M3-03 honour it by using that query; if either writes its own predicate instead,
this clause is no longer covered and the criterion should be reopened.

## Manual verification

GUI automation is unavailable in this environment, so everything below needs a person. **Nothing in
`Steno/` is covered by any test** (D-010) — the whole SwiftUI layer's automated evidence is that it
compiles and lints. Run `make run` and work down the list; it is ordered to find problems fastest.

**Run 2026-09-03 by the user: all six items passed**, plus the two closing questions. One cosmetic
defect was found and fixed in the same pass — the placeholder's `.padding(.top, 8)` sat it 8pt below
the insertion point, so the caret floated above the words it was meant to precede.

Item 1 came first because it decided whether acceptance criterion 6 was met at all.

1. **Does bare `N` fire at all?** `.onKeyPress` is attached to the task column's outer `Group`
   (`TaskListView.swift:57`), but the focused view is the `List`, which on macOS is
   `NSTableView`-backed and does type-select on plain characters. If the `List` consumes the
   keydown, the ancestor's handler never runs and FR-2's one-keystroke affordance is dead on
   arrival. This is an unresolved hypothesis, not a known defect — nobody has been able to press
   the key. **Test:** select a task, press `N`, confirm the note composer takes focus. If it does
   not, ⌘⇧A still works and the fix is to move the handler onto the `List`'s rows or to a
   `NSTableView` responder, not to promote `N` to a menu key equivalent — see D-048 for why that
   route is closed.
2. **If it does fire, does it break list navigation?** The handler returns `.handled` when a task
   is selected and `.ignored` when none is, so type-select on "n" may work in one state and not the
   other. **Test:** with no task selected, press `N` and see whether the list jumps to a task whose
   title starts with "n"; then repeat with a task selected.
3. **The §1.1 negative cases — `N` must NOT fire while typing "n".** Try it in the quick-capture
   panel, in the New Task sheet, and in the note composer itself. Review reasoned all three are
   safe (a separate window, an ancestor-presented sheet, and a sibling column respectively), but
   reasoning is not the evidence CLAUDE.md's non-negotiable #4 asks for. A failure here is worse
   than item 1 failing: item 1 costs a shortcut, this costs a character out of the capture field.
4. **The `Correct` affordance's timing.** It should vanish on its own within ~15 seconds of the
   five-minute deadline (a `Timer.publish` drives `refreshCorrectability`; the scheduling itself is
   untested, only the recompute it drives). Clicking `Correct` inside that gap must show a notice
   rather than doing nothing.
5. **Right-click a `created` row.** Its context menu builder yields no items; confirm AppKit
   suppresses the empty menu rather than flashing one.
6. **⌘⇧A while the New Task sheet is open.** It stays enabled and bumps the composer's focus
   counter behind the sheet. Confirm nothing visibly odd happens when the sheet closes.

Also unverified by anything automated, and worth a glance while you are here: the composer's focus
behaviour on open and after commit, and whether a draft lost to a task switch (D-052) is a surprise
in practice or goes unnoticed.

## Notes for the spec/plan phase

- **The UI may present this as editing; storage must not implement it as such.** FR-2 (v1.7)
  is explicit, and §3.3/§13 make it absolute: the append-only invariant has no exceptions
  anywhere in the system. This task is where that is most tempting to violate, because
  in-place editing is three lines shorter.
- The reason for keeping the original timestamp is user-visible: the note stays where the user
  expects it in the timeline instead of jumping to the top mid-correction.
- Notes are the raw material for every report from M2 onward. §7.3 requires preserving the
  user's exact technical vocabulary; nothing here should normalize, trim, or reformat what was
  typed.
- Redaction hides an event from summaries (§3.3). M2-01's gathering and M3-03's prompt both
  need to honor that — make the exclusion a property of the query, not of each caller.
