# M1-02 — Quick Capture Core

**Milestone:** M1 — Capture
**Depends on:** M1-01
**Blocks:** M1-03, M1-04
**Requirements:** FR-1, FR-1.4, FR-1.5, D15, §1.1
**Branch:** `feat/quick-capture-core`

## Goal

The single shared code path that turns typed text into a persisted task — used by all three
capture surfaces, built once.

## Why this is its own task

D15 specifies "three entry points, one code path." Building the path before either of its two
new surfaces (M1-03, M1-04) is what prevents three divergent implementations. It is reviewable
on its own through the existing main window.

## In scope

- A capture service: text in, task created, `created` event appended, refs extracted via M1-01.
- Project resolution per FR-1.4, in order:
  1. If the text contains a ticket key whose prefix matches a `Project.jiraProjectKeys` entry,
     assign that project and surface a **dismissible inline chip**.
  2. Otherwise, default to the last-used project.
  3. Never block on selection.
- Wiring the existing main window's task creation to this path.
- Latency measurement, kept as a test or a recorded benchmark.

## Out of scope

- The floating hotkey window — M1-03.
- The menu bar popover — M1-04.
- Changing a task's project after the fact — that is a task-row affordance; note it and land it
  wherever it fits M1-05's UI work.

## Acceptance criteria

- [ ] Typing text and confirming creates a task with a `created` event and any extracted refs.
- [ ] A ticket key matching a project's `jiraProjectKeys` auto-assigns that project and shows a
      dismissible chip.
- [ ] With no key match, the last-used project is selected.
- [ ] **Project selection is never required before text entry.** No modal, no picker, no
      validation error on save.
- [ ] Capture latency is measured and recorded in the PR body.

## Notes for the spec/plan phase

- **This is the task where the product lives or dies.** §1.1 is unambiguous: the paper notebook
  wins on capture latency, and if capture exceeds ~3 seconds or forces a modal project
  selection, the user reverts to paper and the product fails. §1.1 states that any design
  decision trading capture speed for data cleanliness is wrong. Treat a proposal to validate,
  disambiguate, or confirm at capture time as a defect.
- §13 flags any change to this path as performance-sensitive and requires measurement, not
  assumption. Establish how latency is measured here — M1-03 and M1-04 will need to prove they
  did not regress it.
- "Last-used project" needs somewhere to live and a defined behavior on first ever launch.
  Decide both; FR-6 also exposes a configurable default project.
- Extraction and persistence both happen on save. If either is slow enough to be felt, move it
  off the critical path rather than accepting the latency.