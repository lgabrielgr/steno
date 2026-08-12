# M0-04 — Persistence Container

**Milestone:** M0 — Skeleton
**Depends on:** M0-03
**Blocks:** M0-05
**Requirements:** §6, D2
**Branch:** `feat/persistence-container`

## Goal

A local SwiftData store, wired into the app, that survives relaunch — plus an in-memory
container for tests.

## In scope

- `ModelContainer` configuration backed by a local store, registering all five models.
- App-level injection so views and view models receive a context.
- An in-memory container factory for tests, so unit tests never touch the user's real store.
- Basic CRUD helpers only where the model layer needs them.

## Out of scope

- UI — M0-05.
- Export/import — M2.5.
- Any CloudKit container or entitlement. Sync is cancelled (D1, §14); this is a **local store**.

## Acceptance criteria

- [ ] Data written in one launch is readable in the next. Verify by running the app, adding a
      record, quitting, relaunching.
- [ ] Tests use an in-memory container and leave no artifacts on disk.
- [ ] `make test` still passes headless with networking disabled.
- [ ] No CloudKit entitlement is added to the app.

## Notes for the spec/plan phase

- Keep the container construction separate from the app entry point so tests can build one
  without launching the app. §9.4's headless requirement depends on this.
- Decide and record where the store file lives — this becomes relevant at M2.5-03, whose
  Replace mode must wipe it, and at §8's "delete my data".
- Do not add a migration plan yet, but do not do anything that makes adding one hard. The
  schema is fresh as of M0-03; the first real migration risk arrives whenever a field is added
  after the user has live data.