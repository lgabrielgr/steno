# M1-03 — Global Hotkey & Floating Capture Window

**Milestone:** M1 — Capture
**Depends on:** M1-02
**Blocks:** nothing
**Requirements:** FR-1.1, D15, §9.3, §1.1
**Branch:** `feat/global-hotkey-capture`

## Goal

A system-wide hotkey that opens a floating capture window above all apps, from any application,
with no mouse.

## In scope

- Global hotkey registration, default `⌥Space`, user-configurable.
- **Conflict detection and warning** — FR-1.1 requires this explicitly.
- A small floating window above all apps, text field focused on open.
- `Return` saves and dismisses. `Esc` dismisses without saving.
- ~~Accessibility (TCC) permission request with a clear explanation, and graceful behavior when
  permission is absent or revoked.~~ Dropped: `RegisterEventHotKey` is not TCC-gated, so this
  permission is never requested (D-029, REQUIREMENTS.md §9.3 v1.12).

## Out of scope

- The capture logic itself — M1-02 owns it. This task is a surface over that path.
- The hotkey rebinding UI in Settings — FR-6. Note where it will attach.

## Acceptance criteria

- [ ] From a different application, hotkey → type → `Return` creates the task and returns focus,
      **in under 3 seconds with no mouse use and no modal interruption** (FR-1.1 acceptance).
- [ ] `Esc` dismisses with nothing saved.
- [ ] The text field has focus the instant the window appears — no click required.
- [ ] Binding a hotkey already claimed by the system or another app produces a warning rather
      than silent failure.
- [ ] No Accessibility (TCC) permission is ever requested, and Steno does not appear in System
      Settings → Privacy & Security → Accessibility. `RegisterEventHotKey` is not TCC-gated; a
      permission prompt here means the mechanism was changed (D-029, REQUIREMENTS.md §9.3 v1.12).
- [ ] Capture latency has not regressed against the M1-02 measurement.

## Notes for the spec/plan phase

- **Signing stability still matters, but not for the reason this file originally gave.** §9.3
  claimed the hotkey needs Accessibility permission granted by TCC against the code signature.
  It does not (D-029). Keep M0-01's stable Personal Team identity anyway: ad-hoc signing makes
  every rebuild a new app to macOS, which resets any per-signature state the app does acquire.
- The floating window must appear above full-screen apps and must not steal the user's place in
  whatever they were doing. Returning focus correctly on dismiss is part of the 3-second
  budget, not polish.
- This surface exists precisely for the moment the user would otherwise reach for the pen. Any
  friction here — a beat of delay, a window that opens unfocused — is the failure mode §1.1
  describes.