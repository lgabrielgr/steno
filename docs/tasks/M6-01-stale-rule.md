# M6-01 — Stale Task Detection Rule

**Milestone:** M6 — Stale detection
**Depends on:** M5-03
**Blocks:** M6-02
**Requirements:** FR-5, D12, D17, FR-6
**Branch:** `feat/stale-rule`

## Goal

The deterministic staleness rule and its threshold resolution order — a pure function, no AI.

## In scope

- The FR-5 rule. A task is stale when:
  - `status ∈ {inProgress, blocked}`, **and**
  - no event of kind `note` or `statusChanged` in the last **N** days.
- The v1.7 resolution order for N — first non-`nil` wins:
  1. `project.staleThresholdDays` (per-project override)
  2. The cadence default: `daily` → 3 days, `periodic` → 10 days (D17)
  3. The global default in Settings (FR-6)
- The global default setting and the per-project override control.

## Out of scope

- Badges and the needs-attention view — M6-02.
- Any AI call. See below.

## Acceptance criteria

- [ ] Stale detection is a pure function — free, instant, offline, deterministic.
- [ ] `todo` and `done` tasks are never stale, regardless of age (FR-5's status condition).
- [ ] A `note` **or** a `statusChanged` event resets staleness; other event kinds do not.
- [ ] Resolution order is honored exactly. Tested: a project with an override ignores its
      cadence default; a project without one uses the cadence default, not the global.
- [ ] **The Settings global value never silently overrides a project that set its own** (FR-5).
- [ ] A `daily` project goes stale at 3 days, a `periodic` project at 10.

## Notes for the spec/plan phase

- **This is deliberately not an AI call** (FR-5): "free, instant, offline-capable, and cannot
  be wrong." D12 caps AI scope at summarizing the event log and detecting stale tasks, and FR-5
  narrows the AI's role here to optional phrasing when the user asks. Do not call a model to
  decide staleness.
- **A fixed global threshold is the trap FR-5 exists to avoid.** A 3-day rule applied to a
  biweekly EM project would badge nearly every task as stale on a normal week — "and a warning
  that always fires is a warning the user learns to ignore."
- Redacted events must not count as activity (§3.3). A redacted note should not keep a task
  looking fresh.
- `statusChangedAt` is maintained by M1-05; this rule depends on it being correct.
