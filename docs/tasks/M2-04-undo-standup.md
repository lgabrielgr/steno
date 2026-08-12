# M2-04 — Undo Last Stand-up

**Milestone:** M2 — Report (no AI)
**Depends on:** M2-03
**Blocks:** nothing
**Requirements:** FR-4.1, §3.3, §3.5
**Branch:** `feat/undo-standup`

## Goal

An "Undo last stand-up" action that reverses all three of Copy's side effects — by redaction,
never deletion.

## Why this is its own task

FR-4.1 exists because "users will misclick, and an unrecoverable window advance destroys a day
of recall." It is small, but it is the safety net under M2-03 and deserves its own gate.

## In scope

Reverse each of Copy's effects per FR-4.1's table:

| Side effect | Undo |
|---|---|
| `lastStandupAt` advanced | Restore the previous value — read it from the `StandupReport.windowStart` being undone |
| `standupReported` events appended | Set `isRedacted = true`. **Never delete** (§3.3) |
| `StandupReport` persisted | Set `isUndone = true`. Retain the row |

Plus: the action is available only for the most recent report of that project, and only while
it remains the most recent.

## Out of scope

- Undoing anything else — notes, status changes, task creation. FR-4.1 is scoped to stand-ups.
- Undo history or a redo stack.

## Acceptance criteria

- [ ] After undo, `lastStandupAt` equals its pre-Copy value, recovered from
      `StandupReport.windowStart`.
- [ ] Regenerating after undo produces the same window as before the mistaken Copy — the
      round-trip loses nothing.
- [ ] `standupReported` events are redacted, **not deleted**. Row count is unchanged. Tested.
- [ ] The `StandupReport` row survives with `isUndone = true`.
- [ ] Undo is unavailable once a newer report exists for that project.
- [ ] Redacted `standupReported` events do not appear in timelines or feed later summaries.

## Notes for the spec/plan phase

- **`windowStart` is the recovery mechanism.** §3.5 defines it as the previous `lastStandupAt`,
  which is exactly the value undo needs — no separate "previous value" field is required. This
  is why M2-03 must persist the report faithfully.
- Deleting the events would be the obvious implementation and is forbidden. §3.3 and §13 permit
  no exceptions: every feature that seems to need mutation actually needs a new event or a
  redaction.
- The user-facing promise is recovering a misclick, so the affordance should be easy to find
  right after a Copy and should not require hunting through settings.
