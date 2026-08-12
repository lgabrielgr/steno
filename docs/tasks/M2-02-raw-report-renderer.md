# M2-02 — Raw Report Renderer

**Milestone:** M2 — Report (no AI)
**Depends on:** M2-01
**Blocks:** M2-03
**Requirements:** FR-4 report structure, §7.4, D6, D17
**Branch:** `feat/raw-report-renderer`

## Goal

Deterministic Slack-flavored markdown from a gathered window, in both cadence shapes, with no
AI involved.

## Why this exists before M3

§7.4 is explicit: the offline fallback is a **P0 requirement and should be built _before_ the
AI path, not after.** This task is that fallback. It is also the entire value of M2 — the MVP
that lets the user run a real stand-up with no API key and no network.

## In scope

- *Daily* cadence → three sections: **Since last stand-up**, **Today**, **Blockers**.
- *Periodic* cadence → **Completed**, **In flight**, **Blockers & risks**.
- Slack-flavored markdown (D6 — clipboard is the primary export).
- Grouping raw events by status under those headings, per §7.4.

## Out of scope

- Any AI call — M3. This renderer must never require one.
- The UI and clipboard — M2-03.
- Themed grouping and compression. That is a model behavior (§7.3); this renderer enumerates.

## Acceptance criteria

- [ ] Both cadences render their own section set, driven by `project.reportCadence`.
- [ ] Output is deterministic — same window, same markdown, every time. Tested with fixtures.
- [ ] Renders with no network and no API key configured.
- [ ] An empty window produces something honest and usable, not a crash or a blank string.
- [ ] Ticket keys, service names, function names, and error strings appear **verbatim** as the
      user typed them.

## Notes for the spec/plan phase

- **This output is spoken aloud.** §7.3's constraint that "fixed the flaky auth test" must not
  become "enhanced authentication reliability" is about the AI, but the same discipline applies
  here: this renderer must not editorialize, reformat, or normalize the user's words. It is a
  stenographer.
- §7.4's bar is "slightly rougher, entirely usable." The user must never arrive at a stand-up
  empty-handed because of a network error — so nothing in this path may depend on one.
- D17's distinction is real: a daily DSU is a status ping, a biweekly sync is a summary. This
  renderer cannot compress the way a model can, so a periodic window will be long. That is
  acceptable here; M3-03 is what makes it concise.
- Keep the renderer separate from the report UI so M3-03 can substitute AI output into the same
  rendering step (§7.3: "the app renders markdown from this structure").
