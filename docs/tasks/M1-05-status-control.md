# M1-05 — Status Control & Transitions

**Milestone:** M1 — Capture
**Depends on:** M0-05
**Blocks:** M1-06, M2-01
**Requirements:** §3.2, §3.3, D11, FR-3
**Branch:** `feat/status-control`

## Goal

One code path for changing a task's status, appending a `statusChanged` event every time, with
a keyboard shortcut and UI in every surface that shows a task.

## In scope

- Status mutation service: updates `status`, sets `statusChangedAt`, appends a `statusChanged`
  event with a body like `"IN-PROGRESS → BLOCKED"`.
- `completedAt` handling — set on entering `done`, cleared on leaving it (§3.2).
- Optional `blockedReason` event when moving to `blocked` (§3.3 EventKind), without making it
  mandatory.
- Status control in the detail pane and task rows; cycle-status keyboard shortcut (FR-3).

## Out of scope

- Notes — M1-06.
- Stale detection, which reads `statusChangedAt` — M6-01.
- Auto-transition from Jira ticket state. That is **open question Q(M4)** in §12 and is not
  settled; do not implement it.

## Acceptance criteria

- [ ] Any status can move to any other status — no enforced workflow (§3.2, D11).
- [ ] Every transition appends exactly one `statusChanged` event. No transition is silent.
- [ ] Entering `done` sets `completedAt`; leaving `done` clears it. Tested.
- [ ] `statusChangedAt` updates on every transition — M6-01's stale rule depends on it.
- [ ] The four statuses are the only four (D11). No custom statuses, no workflow engine.
- [ ] Cycling status is reachable by keyboard from a selected task.

## Notes for the spec/plan phase

- **The event is not optional.** §3.3 and §13 make the append-only log the source of truth;
  M2.5-02 goes further and *derives* `TaskItem.status` from the newest `statusChanged` event during
  a merge, treating the stored field as a cache. A transition that skips its event will
  silently revert after an import — a bug that will look inexplicable months later.
- Making `blockedReason` mandatory would add friction to the moment the user is most frustrated.
  §3.3 marks it optional; keep it optional.
- This path is called from the detail pane, task rows, and M1-04's popover. Build it as a
  service the surfaces call, not as view code.
- **Close the mutation hole M0-05 left open (D-019).** The main window's view model publishes live
  `@Model` objects, and `Project`/`TaskItem` expose `public` mutators — so a view *can* call
  `setStatus` directly, skipping the event, and `save(context)` would commit it on the next
  unrelated write. Nothing does this today, but this task is where it becomes dangerous, because
  this task is the one adding status controls to view code. Reducing the domain mutators from
  `public` to `internal` compiles as of M0-05 (the only production caller is inside `StenoKit`,
  and tests use `@testable import`) and makes the service the sole route by construction rather
  than by convention. Decide it here deliberately; M0-05 declined to change M0-03's API from a
  UI task.
