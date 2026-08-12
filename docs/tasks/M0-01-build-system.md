# M0-01 — Build System & Project Generation

**Milestone:** M0 — Skeleton
**Depends on:** nothing
**Blocks:** every other task
**Requirements:** §9.1, §9.2, §9.3
**Branch:** `chore/build-system`

## Goal

A SwiftUI macOS app that builds, runs, and cleans entirely from the command line, from a
generated Xcode project that is never committed.

## Why this is its own task

Nothing else can be verified until this exists. §9 is explicit that an agent which cannot
compile what it wrote is guessing — this task is what removes that excuse.

## In scope

- `project.yml` for XcodeGen. Use the fixed facts in §9.1 verbatim: product/scheme `Steno`,
  bundle ID `com.lgabrielgr.steno`, minimum deployment target macOS 14.0.
- `Makefile` with `bootstrap`, `generate`, `build`, `run`, `clean`, `release`. Every target
  exits non-zero on failure — agents and CI gate on this.
- A minimal SwiftUI app target that launches and shows an empty window.
- `Local.xcconfig.example` committed; the real `Local.xcconfig` gitignored and holding
  `DEVELOPMENT_TEAM`.
- README section on first-time setup: `make bootstrap`, copy the example xcconfig, `make run`.

## Out of scope

- `make test`, `make lint`, `make format` → M0-02
- Any domain model or persistence → M0-03, M0-04
- CI → M1-07

## Deliverables

- `project.yml`, `Makefile`, `Local.xcconfig.example`, minimal app sources.
- `Steno.xcodeproj` is generated and **must not appear in `git status`** — `.gitignore`
  already covers it.

## Acceptance criteria

- [ ] `make bootstrap` installs xcodegen, xcbeautify, swiftlint via Homebrew and is idempotent
      — running it twice is a no-op, not an error.
- [ ] `make generate && make build` succeeds from a clean checkout.
- [ ] `make run` kills any running instance, builds, and launches with `stdout`/`stderr`
      streaming to the terminal — exec the binary directly, not via `open` (§9.2).
- [ ] `make clean` removes `.build/` and the generated project.
- [ ] Every target exits non-zero on failure. Verify by deliberately breaking a source file.
- [ ] `git status` is clean after a full build.

## Notes for the spec/plan phase

- **Signing is the subtle part.** §9.3 requires a *stable* Personal Team identity, not ad-hoc
  (`-`) signing. M1-03's global hotkey needs Accessibility permission, which macOS grants
  against the code signature; ad-hoc signing mints a new identity per build, so the user would
  re-authorize on every single run. Getting this wrong is not discovered until M1, by which
  point it looks like a hotkey bug.
- No paid Apple Developer membership is needed or wanted (§6.1). A free "Personal Team" is the
  target. Do not add capabilities that require enrollment.
- `make release` can be a thin variant of `make build`; it does not need notarization
  (§6.1 — not distributing).