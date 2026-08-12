# M1-07 — CI Workflow

**Milestone:** M1 — Capture
**Depends on:** M1-06
**Blocks:** nothing
**Requirements:** §9.6, §9.5
**Branch:** `chore/ci-workflow`

## Goal

A GitHub Actions workflow running `make build && make test && make lint` on every pull request,
wired into branch protection as a required status check.

## Why now and not at M0

§9.6 places it here deliberately: "worth adding at M1, once there is enough code for it to mean
something." By this point there is a real test suite to gate on.

## In scope

- A minimal workflow on a macOS runner, triggered on pull requests targeting `main`.
- `make bootstrap` for toolchain deps, then build, test, lint.
- Adding the check to `main`'s branch protection via `required_status_checks`.

## Out of scope

- Release automation, notarization, artifact uploads. Not distributing (§6.1).
- UI tests (§9.4 excludes them from default `make test`).

## Acceptance criteria

- [ ] The workflow runs on every PR to `main` and fails the PR when any of the three commands
      fails. Verify with a deliberately broken commit on a throwaway branch.
- [ ] `main`'s branch protection lists the check under `required_status_checks`.
- [ ] The workflow needs no secrets. Nothing in build/test/lint requires credentials — §9.4
      mandates that tests pass with networking disabled.
- [ ] Runtime stays short enough that it does not discourage small PRs.

## Notes for the spec/plan phase

- **Signing will be the friction point.** M0-01 uses a Personal Team identity tied to the
  developer's Mac; a CI runner has no such identity. Expect to build unsigned or ad-hoc-signed
  in CI. That is fine *for CI only* — the §9.3 stable-identity requirement exists for local TCC
  persistence, which a runner has no stake in. Do not weaken local signing to make CI simpler.
- Branch protection already exists on `main` with `enforce_admins` on, force pushes and
  deletion blocked, and zero required approvals. This task adds the status check to that
  existing configuration rather than creating it.
- Keep the workflow readable. It is one of the few files the user will read without an agent
  present.
