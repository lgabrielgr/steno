# M0-03 — Domain Models

**Milestone:** M0 — Skeleton
**Depends on:** M0-02
**Blocks:** M0-04
**Requirements:** §3 (all of it), §6, D10, D11
**Branch:** `feat/domain-models`

## Goal

The five SwiftData models — `Project`, the task model, `Event`, `SourceRef`, `StandupReport` —
with CloudKit-compatible schemas, matching §3's field tables exactly.

## Why this is its own task

This is the highest-leverage task in the project and the most expensive to get wrong. Every
later milestone reads these types; a field missed here becomes a store migration later. It gets
its own review gate for that reason alone.

## In scope

- All five models, every field from §3.1–§3.5, including the v1.7 additions: `modifiedAt` on
  both `Project` and the task model, `id` + `taskID` on `SourceRef`, `isUndone` on
  `StandupReport`.
- `Status` and `EventKind` enums (D11 — exactly four statuses, no custom ones).
- The `SourceRef` dedup rule from §3.4: unique per `(taskID, kind, identifier)`, enforced in
  code.
- Status transition rules from §3.2: any status to any other; `done` sets `completedAt`,
  leaving `done` clears it.
- Unit tests for all of the above.

## Out of scope

- The model container and store — M0-04.
- Any UI — M0-05.
- Event *creation* on user actions — M1-05, M1-06. This task defines the types and their
  invariants, not the flows that produce them.

## Acceptance criteria

- [ ] Every field in §3.1–§3.5 exists with the specified type and optionality.
- [ ] **CloudKit-compatible schema (§6):** every property has a default or is optional; no
      `@Attribute(.unique)` anywhere; no unique constraint beyond `id`. A test asserts this
      rather than a reviewer eyeballing it.
- [ ] Setting status to `done` sets `completedAt`; moving off `done` clears it. Tested.
- [ ] Re-extracting an existing `(taskID, kind, identifier)` is a no-op, not a duplicate row.
      Tested.
- [ ] `Event` exposes no mutating API except toggling `isRedacted` (§3.3, §13).

## Notes for the spec/plan phase

- **The task model's Swift type is `TaskItem`** — settled in §3.2 as of v1.8, because a type
  named `Task` shadows `_Concurrency.Task` in every file that can see it, and this app runs
  async integration fetches from M4 onward. Only the Swift identifier changed: prose, UI copy,
  the export key `"tasks"`, and the `taskID` field name all stay as written. Use `TaskItem`
  consistently from this task forward — every later task file's `taskID` references assume it.
- **Do not strip the CloudKit constraint** because sync is cancelled. §6 anticipates exactly
  this and forbids it: the constraint costs nothing, is independently required by M2.5's merge,
  and is the difference between enabling sync as a config change versus a data migration.
- §3 models relationships as explicit UUID foreign keys (`projectID`, `taskID`), not SwiftData
  relationship macros. Follow the spec — the UUID keys are what make M2.5-02's merge-by-UUID
  tractable. Note the reasoning in the PR body so a later reviewer does not "fix" it.
- `modifiedAt` exists solely for §10.1's conflict resolution. Define now what updates it, or
  M2.5-02 inherits an ambiguity.