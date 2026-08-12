# M2-03 — Report UI & Copy

**Milestone:** M2 — Report (no AI)
**Depends on:** M2-02
**Blocks:** M2-04
**Requirements:** FR-4 (full flow), D6, §3.5
**Branch:** `feat/report-ui-and-copy`

## Goal

"Prepare Stand-up" → editable draft → Copy, with all three of Copy's side effects applied
atomically. **This is the M2 exit criterion: the user can run a real DSU from the app.**

## In scope

- A prominent, always-visible "Prepare Stand-up" button on the project view (FR-4).
- An **editable** text view showing the draft (FR-4 step 6).
- Copy (FR-4 step 7), which must do all three:
  1. Place Slack-flavored markdown on the clipboard.
  2. Set `project.lastStandupAt = now`.
  3. Append a `standupReported` event to each included task.
  ...and persist the `StandupReport` (`windowStart`, `windowEnd`, `markdownBody`,
  `wasAIGenerated = false`, `isUndone = false`).
- Keyboard shortcut for generating a report (FR-3).

## Out of scope

- Undo — M2-04, immediately after.
- AI generation — M3-03 substitutes into this same UI.
- Ref refreshing (FR-4 step 4) — M4-01 inserts the progress indicator into this flow.
- Report history browsing. That is **open question Q(M3)** in §12 and unresolved.

## Acceptance criteria

- [ ] Generating a preview has **zero side effects**. The user can generate repeatedly, close
      the sheet, and their window is untouched. FR-4: "The clock only advances on Copy, never
      on generate."
- [ ] Copy applies all three side effects, or none of them. A failure partway must not leave
      `lastStandupAt` advanced with no report persisted.
- [ ] The draft is editable, and the **edited** text is what reaches the clipboard and
      `markdownBody` — not the original generated text.
- [ ] Pasting into Slack produces correctly formatted output (D6).
- [ ] Copying for Project A does not advance Project B (D16).

## Notes for the spec/plan phase

- **The generate/Copy split is the most important behavior here.** FR-4 calls out that
  generating must be free of side effects "so the user can peek without corrupting their
  window." A user who previews at 09:00, gets pulled into a meeting, and reports at 09:30 must
  get the full window — not a window truncated by their own preview.
- Copy's three effects plus the persisted report are what M2-04 has to reverse. Structure them
  as one unit now so undo is tractable, and so a partial failure cannot desynchronize the clock
  from the log.
- `wasAIGenerated` is `false` for every report this task produces. M3-03 sets it true.
- The draft being editable matters: the user's own last-second correction is the final word,
  and §7.3's whole philosophy is that the user's phrasing wins.
