# M6-02 — Badges & Needs-Attention View

**Milestone:** M6 — Stale detection
**Depends on:** M6-01
**Blocks:** nothing — **this is the finish line**
**Requirements:** FR-5, FR-3, D12
**Branch:** `feat/needs-attention-view`

## Goal

Surface stale tasks where the user will see them: badges in the UI and a "Needs attention"
section. **Completes M6, the last milestone.**

## In scope

- Stale badges on task rows.
- Stale counts on sidebar projects (FR-3 specifies "unread/stale badge counts").
- A "Needs attention" section listing stale tasks (FR-5).
- Optional AI phrasing when the user explicitly asks about a stale task — and only then (FR-5).

## Out of scope

- The rule itself — M6-01.
- Prioritization, ranking, or "what should I work on." **D12 and §2.1 forbid this outright.**
  A needs-attention list is not a priority list.

## Acceptance criteria

- [ ] Stale tasks are badged, and sidebar counts match the rule's output.
- [ ] The needs-attention section lists exactly the tasks M6-01 marks stale — no second,
      divergent definition of staleness in the view layer.
- [ ] Nothing here requires the network or an API key; badges appear offline.
- [ ] The list is not ordered by any inferred importance. It is a list of forgotten tasks, in a
      neutral order.
- [ ] Exit criterion met: forgotten tasks surface without the user prompting.

## Notes for the spec/plan phase

- **This is where scope creep will feel most reasonable.** A list of tasks needing attention
  invites sorting by urgency, suggesting a next action, or nudging. D12 excludes focus
  suggestions and prioritization; §2.1 lists "what should I work on" recommendations as a
  non-goal; §13 says such proposals "should be declined with reference to this document." The
  product's value comes from what it refuses to do.
- FR-5 permits the AI exactly one role here — phrasing, when the user asks. Not detection, not
  ranking, not unsolicited commentary.
- With M6 done, check the §1.2 success criteria honestly: has the paper notebook been
  abandoned, is stand-up prep under 60 seconds, and does the summary contain specific detail
  rather than ticket keys? Those, not the milestone table, are what "finished" means.
