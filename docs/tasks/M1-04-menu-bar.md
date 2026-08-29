# M1-04 — Menu Bar Item & Popover

**Milestone:** M1 — Capture
**Depends on:** M1-02
**Blocks:** nothing
**Requirements:** FR-1.2, D15
**Branch:** `feat/menu-bar-popover`

## Goal

A persistent menu bar icon whose popover offers quick-add, today's in-progress tasks with
inline status toggles, and a way into the main window.

## In scope

- Persistent menu bar item.
- Popover containing exactly what FR-1.2 lists: the quick-add field, today's in-progress tasks
  with inline status toggles, and an "Open Main Window" action.
- Launch-at-login behavior, or the hook for it (FR-6 owns the setting).

## Out of scope

- Capture logic — M1-02.
- Status transition logic — M1-05. This surface toggles status through that path; it does not
  reimplement it.
- Notes — M1-06.

## Acceptance criteria

- [ ] The icon persists across relaunch and is present without the main window open.
- [ ] The popover's quick-add goes through the M1-02 path — verified by the auto-routing chip
      behaving identically to the main window.
- [ ] Inline status toggles update the task and append a `statusChanged` event.
- [ ] "Open Main Window" works when the window is closed, minimized, or on another Space.
- [ ] Capture latency has not regressed against the M1-02 measurement.

## Notes for the spec/plan phase

- **M1-05 merged first, so its status path exists.** The popover's inline toggles call
  `StatusService.setStatus(_:on:)` through a view model; they do not mutate `TaskItem` and
  cannot — its mutators are `internal` as of M1-05 (D-033). The popover also inherits
  `StatusMenuItems` from `Steno/Features/MainWindow/StatusControl.swift`, and
  `CaptureFieldView`'s `.bar` style from M1-03. Build none of those a second time.
- "Today's in-progress tasks" needs a definition. In-progress across all projects, or the
  selected one? FR-1.2 does not say. Decide, state it in the PR body, and prefer the reading
  that keeps the popover glanceable at D18's scale.
- The popover is the surface the user sees most often without opening the app. It should be
  fast and quiet — it is not a second main window.