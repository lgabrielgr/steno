# M4-05 — Scheduled Background Refresh

**Milestone:** M4 — Atlassian
**Depends on:** M4-04
**Blocks:** M4 exit criterion
**Requirements:** §5.5, FR-6
**Branch:** `feat/background-refresh`

## Goal

A scheduled refresh at a user-set time — default 08:00 — so the morning view is instant rather
than waiting on the network.

## In scope

- Scheduled refresh at a configurable time, defaulting to 08:00 (§5.5).
- Refreshing refs on non-done tasks.
- Appending `externalUpdate` events for changes found.
- Setting exposed in the Capture or Integrations pane (FR-6).
- Sensible behavior when the Mac is asleep or the app is not running at the scheduled time.

## Out of scope

- The refresh mechanics — M4-01 owns them. This is scheduling over that path.
- Push or webhook-driven updates. Not in scope anywhere in §5.

## Acceptance criteria

- [ ] A refresh runs at the configured time and populates caches before the user looks.
- [ ] Missing the window (asleep, app closed) is handled gracefully — a catch-up on next launch
      rather than a skipped day or a thundering herd of requests.
- [ ] Failures are silent to the user but visible in logs. This runs unattended; it must not
      interrupt.
- [ ] The refresh does not wake or spin the machine unnecessarily.
- [ ] `externalUpdate` events created here appear correctly in the next report.

## Notes for the spec/plan phase

- The purpose in §5.5 is narrow and worth keeping in view: "so the morning view is instant
  rather than waiting on network." This is a latency optimization, not a data-integrity
  mechanism — §5.5's launch-time and report-time refreshes already guarantee correctness.
- Because it is unattended, it must never surface a modal, a permission prompt, or an auth
  dialog. An expired Atlassian token discovered here should set the warning state that M4-04
  displays, not interrupt.
- Best-effort remains the rule (§5.5). A failed background refresh is a non-event.
