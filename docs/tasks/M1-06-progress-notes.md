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

- [ ] Adding a note appends a `note` event; the timeline shows it newest-first.
- [ ] **No code path mutates an existing `Event` row except to flip `isRedacted`.** This is the
      invariant; assert it in tests, not just in review.
- [ ] A correction within 5 minutes redacts the original and appends a replacement carrying the
      original timestamp — so the timeline does not reorder under the user mid-correction.
- [ ] After 5 minutes, editing is unavailable and only redaction is offered.
- [ ] Redacted events are hidden from the timeline and from summaries, but the rows still exist.
- [ ] `N` (or the chosen key) opens note entry for the selected task.

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
