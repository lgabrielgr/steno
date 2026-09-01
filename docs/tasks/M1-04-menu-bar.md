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
- [x] Inline status toggles update the task and append a `statusChanged` event.
- [ ] "Open Main Window" works when the window is closed, minimized, or on another Space.
- [x] Capture latency has not regressed against the M1-02 measurement.

The other three await the manual pass below — no agent in this environment can drive the GUI
(TCC blocks `screencapture`, Screen Recording is denied to `osascript`), so no user-visible
behaviour listed above has actually been observed running. The two ticked above are ticked
because they are exercised by automated tests that were strengthened until they could actually
fail, not because they were watched: criterion 3 by `MenuBarModelTests` (its failed-save and
no-op tests were both hardened to pin the model's state, not just the surface symptom), and
criterion 5 by `MenuBarPerformanceTests` plus an unchanged re-run of `CapturePerformanceTests`.

## Manual verification

GUI automation is unavailable in this environment, so everything below needs a person. Run
`make run` and work down the list — it is ordered to find problems fastest.

- [ ] Quit and relaunch. The icon is in the menu bar, with no window open.
- [ ] Close the main window with ⌘W. The icon is still there and the app is still running.
- [ ] Click the icon. The popover opens and the field is focused — type without clicking first.
- [ ] Close and reopen it. The field is focused **again** (the `showCount` fix). **If clicking the
      icon while the popover is open re-opens it instead of closing it**, the cause is
      `NSPopover.willCloseNotification` arriving too late, not the `.id(model.showCount)` key —
      `popover.animates = false` is the next lever to try, not the focus key.
- [ ] Type text with a ticket key matching a project. The chip names the same project the main
      window's New Task sheet names for the same text — this is criterion 2.
- [ ] `Return`. The popover closes; the task is in the main window under TODO.
- [ ] `Esc` on a half-typed line. The popover closes; reopening shows the draft still there.
- [ ] Click away mid-typing. Same — the draft survives.
- [ ] Set a task to IN-PROGRESS in the main window. It appears in the popover without reopening.
- [ ] Toggle a row to DONE from the popover. The row leaves the list, and the task's timeline in
      the main window shows one `statusChanged` event. (Criterion 3 is already covered by
      `MenuBarModelTests`; this step is a sanity check against the real app, not new evidence.)
- [ ] Toggle a row to BLOCKED. The status changes and **no** reason sheet appears (D-039).
- [ ] "Open Main Window" with the window **closed**. Check the log line —
      `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.lgabrielgr.steno"' | grep reveal` —
      and require it to read `reveal: bringing the existing main window forward`. If it instead
      reads `no main window found`, `WindowTagger` never stamped the identifier on the `NSWindow`
      (it stamps in `updateNSView`, which requires the view to actually be attached to a window),
      and every reveal is silently falling through to the reopen branch. Note also: a `Window`
      scene's `NSWindow` can survive ⌘W and stay in `NSApp.windows` — if it does here, the
      "closed" case takes the *first* branch instead of the reopen one, `makeKeyAndOrderFront`
      still does the right thing, and the log will not read the way an earlier design draft
      predicted. That is not a bug.
- [ ] "Open Main Window" with the window **minimized**.
- [ ] "Open Main Window" with the window **on another Space**.
- [ ] Immediately after using "Open Main Window" (or any popover close), click the menu bar icon
      within about 200ms. It is a no-op. Deliberate — the transient-toggle guard's window after
      any close — not a bug.
- [ ] Look at "Open Main Window"'s hit area by eye. It is the text glyphs plus padding, not the
      popover's full width, with no hover state or border marking it clickable. Nobody has been
      able to look at it; judge whether that reads as clickable rather than filing it as a defect
      to fix blind.
- [ ] Capture through the popover feels no slower than the hotkey panel — this is criterion 5's
      subjective half; `MenuBarPerformanceTests` and `CapturePerformanceTests` are its objective
      half (see the PR body for both sets of numbers).

## Known limitations

Deferred deliberately, not gaps the plan missed — recorded here so a later task does not mistake
pre-existing behaviour for a regression it introduced.

- **`MenuBarModel.lastError` is undismissable.** It is cleared only on `setStatus`'s success path
  (`MenuBarModel.swift:155`) and set on its catch path (`:162`); nothing else writes it, and
  `MenuBarPopoverView.swift:28` is its only reader. A transient read or write failure therefore
  leaves the message showing until the next *successful* status change — the popover has no
  Dismiss control, where the main window's own error banner has one. The obvious fix, clearing
  `lastError` at the top of a successful `reload()`, is wrong: `setStatus`'s catch block calls
  `reload()` immediately after setting the message (`:162` then `:165`), so that would erase the
  message in the same call that set it. `MenuBarModelTests.aFailedStatusSaveIsReportedAndRefetched`
  asserts the message survives exactly that reload, which is what would break.
- **The `statusChangedAt` sort has no tiebreak.** `MenuBarModel.reload()` sorts live tasks by
  `$0.statusChangedAt > $1.statusChangedAt` alone (`:120`), so two tasks transitioned in the same
  instant order arbitrarily between reloads, depending on the store's own fetch order.
- **A store failure can leave a running process with no window and no status item.** On a store
  that fails to open, `StenoApp.init` sets `menuBar = nil` (`StenoApp.swift:97`), but
  `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` still returns `false`
  unconditionally (`AppDelegate.swift:11`). Closing the `StoreFailureView` window therefore leaves
  the app running with nothing on screen and no menu bar icon to reopen it from. Recoverable via
  the Dock icon — nothing sets `LSUIElement`, so AppKit's default reopen handling still applies.
- **An unknown `taskID`, or a task whose project has since vanished, silently no-ops.**
  `MenuBarModel.setStatus`'s guard (`:151`) returns with no `lastError` if the id is not found
  among the tasks `reload()` last built, and that same `reload()`'s project join (`:125`) silently
  drops any task whose `projectID` no longer resolves. Neither is a regression — it matches
  `MainWindowModel+Status.setStatus`'s existing convention of a silent no-op — but it means a race
  between a delete elsewhere and a toggle here fails invisibly rather than with a message.

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
- **`.stenoDidWrite` does not cover project writes yet.** `MainWindowModel.perform` saves
  `createProject`, `updateProject`, and `archive(projectID:)` without posting — it is the only
  surface that shows projects today, so nothing depends on it. If the popover caches a project
  list, do not assume this notification will keep it fresh. Adding the post to `perform` is this
  task's call to make, not something M1-05 did for you: it would make `perform` re-enter
  `reload()` through the observer before its own `reload()` runs, which needs its own analysis.