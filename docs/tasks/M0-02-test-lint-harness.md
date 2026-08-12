# M0-02 — Test & Lint Harness

**Milestone:** M0 — Skeleton
**Depends on:** M0-01
**Blocks:** M0-03
**Requirements:** §9.2, §9.4
**Branch:** `chore/test-lint-harness`

## Goal

`make test` and `make lint` exist, are green, and run headless with networking disabled — so
every later task has a real verification gate rather than an assertion.

## Why this is its own task

§13's "verify, don't assert" rule is unenforceable until this lands. It is separated from
M0-01 because a reviewer could reasonably accept a working build while rejecting the test
setup, or vice versa.

## In scope

- A unit test target wired into `project.yml`, plus one trivial passing test proving the
  harness works.
- `make test` running headless: no window server, no GUI session, no network.
- `.swiftlint.yml` and `make lint` / `make format`.

## Out of scope

- Tests for domain logic — those ship inside the task that writes the logic (§13:
  degradation and tests are never a follow-up).
- UI tests. §9.4 puts them in a separate scheme, excluded from default `make test`.
- CI → M1-07.

## Deliverables

- Test target, `.swiftlint.yml`, three new Makefile targets.
- `.swiftlint.yml` is committed and is the lint contract for every later PR.

## Acceptance criteria

- [ ] `make test` passes headless — verify over SSH or with the GUI session inactive, not just
      in a logged-in Terminal.
- [ ] `make test` passes with networking disabled (§9.4). Confirm it does not merely *succeed*
      offline but genuinely makes no network calls.
- [ ] `make lint` fails non-zero on a deliberate violation, then passes once fixed.
- [ ] `make format` is idempotent — running twice produces no diff on the second run.

## Notes for the spec/plan phase

- **Choose the test framework here and record the choice.** Swift Testing (`@Test`/`#expect`)
  ships with Xcode 16, which §9.1 already requires, and its parameterized cases suit the table
  -driven tests coming in M1-01 (regex extraction) and M2.5-02 (merge commutativity). XCTest is
  the conservative alternative. Whichever is chosen, every later task follows it — so state it
  in the PR body.
- §9.4 requires all external calls to sit behind protocols with test doubles. No such calls
  exist yet, but the lint config and target layout should not make that awkward later.
- Keep `make test` fast. It runs before every PR; if it becomes slow, agents will be tempted to
  skip it, and §9.5 step 4 stops being real.