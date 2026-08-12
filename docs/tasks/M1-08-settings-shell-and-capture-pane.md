# M1-08 — Settings Shell & Capture Pane

**Milestone:** M1 — Capture
**Depends on:** M1-04
**Blocks:** M3-04, M4-04, M6-01 (each attaches a pane here)
**Requirements:** FR-6, FR-1.1, FR-1.4
**Branch:** `feat/settings-shell-capture-pane`

## Goal

The Settings window and its **Capture** pane — hotkey binding, launch at login, default
project. This is also the shell every later Settings pane attaches to.

## Why this is its own task

FR-6 lists five Settings areas that land across four different milestones. Building the shell
once, here, is what stops M3-04, M4-04, and M6-01 from each inventing their own window
structure. The Capture pane belongs with it because its settings are the only ones whose
features already exist.

## In scope

- The Settings window and its pane/tab structure, with a documented way to add a pane.
- **Capture pane** (FR-6): hotkey binding, launch at login, default project.
- Hotkey rebinding with the conflict detection M1-03 built — deferred there to here.
- Launch at login, using the hook M1-04 left.

## Out of scope

- AI pane — M3-04. Integrations pane — M4-04. Stale threshold — M6-01. Data pane — M2.5.
  Each of those tasks adds its own pane to this shell.

## Acceptance criteria

- [ ] Rebinding the hotkey takes effect without relaunch, and a conflicting binding warns
      rather than failing silently (FR-1.1).
- [ ] Launch at login survives reboot.
- [ ] The default project set here is what M1-02 falls back to when no ticket key matches and
      there is no last-used project (FR-1.4).
- [ ] Adding a new pane requires no change to existing panes — verify by sketching where
      M3-04's pane will attach.

## Notes for the spec/plan phase

- FR-6's five areas are Capture, AI provider, Integrations, Stale threshold, and Data. Only
  Capture is buildable now; the rest arrive with their milestones. Design the shell for five
  panes, build one.
- The default project interacts with M1-02's resolution order — ticket-key match, then
  last-used, then this. Make sure adding this setting does not introduce a prompt or a modal on
  the capture path; §1.1 forbids blocking capture on project selection under any circumstances.
- Keep Settings unobtrusive. This is a recall tool, and time spent in configuration is time not
  spent capturing.
