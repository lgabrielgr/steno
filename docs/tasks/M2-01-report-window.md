# M2-01 — Report Window Computation

**Milestone:** M2 — Report (no AI)
**Depends on:** M1-06
**Blocks:** M2-02
**Requirements:** D8, D16, D17, FR-4 steps 2–3, §3.5
**Branch:** `feat/report-window`

## Goal

Given a project, compute the report window and gather every event inside it — pure, headless,
and side-effect free.

## Why this is its own task

This is the logic D8 calls the answer to Mondays, vacations, and sick days. It is entirely
testable without UI, and getting it wrong corrupts every report downstream. It deserves its own
review gate.

## In scope

- `windowStart` = `project.lastStandupAt`; **on first run for a project, 24h before now**
  (FR-4 step 2, and §3.5 as corrected in v1.7).
- `windowEnd` = now.
- Gather all non-redacted events in `[windowStart, now]` for tasks in that project.
- Per-project independence (D16): the window for Project A never consults Project B.

## Out of scope

- Rendering — M2-02.
- Advancing `lastStandupAt` — M2-03. **Computation must be side-effect free.**
- Refreshing external refs (FR-4 step 4) — M4-01.

## Acceptance criteria

- [ ] First run for a project produces a 24h window.
- [ ] Subsequent runs start from that project's own `lastStandupAt`.
- [ ] Generating a window **changes nothing** — no writes, no clock advance. FR-4: "Generating
      a preview must be free of side effects, so the user can peek without corrupting their
      window."
- [ ] A report for Project A does not alter Project B's window. Tested with two projects.
- [ ] Redacted events are excluded (§3.3).
- [ ] A three-day gap (weekend) and a two-week gap (vacation) both produce correct windows with
      no special-casing.

## Notes for the spec/plan phase

- **The whole design rests on D8.** The window is "since the user's last stand-up *for that
  project*" — which is why `lastStandupAt` is per-project (§3.1) and why the user attending
  multiple different DSUs needs no special handling. Do not introduce a global "last stand-up"
  anywhere.
- D17's cadence affects *report style and staleness*, not the window rule. Both cadences use
  the same computation; only the rendering differs (M2-02).
- Keep this a pure function over the store. M3-03 will feed its output to the AI, and M2-02 to
  the fallback renderer — both need to call it without triggering writes.
