<!--
REQUIREMENTS.md §9.5 specifies what a PR body must contain. This template is that list.
Delete any section that genuinely does not apply — but "Findings" and "Deliberately left out"
are usually not empty, and an empty "How it was verified" means the PR isn't ready.
-->

## Requirement IDs

<!-- Which requirements this implements: FR-1.1, D17, §10.1, etc. Plus the task file and
     milestone, e.g. "Task: M0-03 · Milestone: M0 — Skeleton". -->

## What was done

<!-- What changed and why. Not a file list — the diff already shows that. -->

## How it was verified

<!-- §9.5 step 4 and §13: "verify, don't assert". Paste or describe actual results.
     - [ ] make build
     - [ ] make test
     - [ ] make lint
     Plus anything task-specific: capture latency measured (M1-*), headless + no-network
     confirmed (§9.4), round-trip properties tested (§10.6). -->

## Findings

<!-- §9.5: if implementation revealed that REQUIREMENTS.md is wrong, ambiguous, or impossible,
     say so HERE. Do not silently deviate — a PR that quietly contradicts the spec is worse
     than one that pauses to ask. If you amended the spec, note the version bump.
     Also record any decision this task settled that DECISIONS.md tracks as open (O-N). -->

None.

## Deliberately left out

<!-- What's out of scope and where it lands instead. The task file's "Out of scope" list is
     the starting point. -->

---

<!-- Checks before requesting review — §9.5 -->

- [ ] Branched from current `main`, not from another task branch
- [ ] One task per PR — if this grew a second change, it should be two PRs
- [ ] `make build && make test && make lint` all pass
- [ ] No secrets, tokens, `Local.xcconfig`, or generated `.xcodeproj` in the diff
- [ ] Commit messages explain *why*, with a Conventional Commits prefix
- [ ] **I am not merging this.** The user reviews and merges.