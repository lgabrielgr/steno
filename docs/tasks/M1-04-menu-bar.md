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

Criterion 5's evidence is specifically this. The resident `MenuBarModel` observes `.stenoDidWrite`,
which `CaptureService` posts synchronously before `capture()` returns, so **every** capture — from
the hotkey panel, the New Task sheet, or the popover — now pays one `MenuBarModel.reload()`, opened
popover or not. `CapturePerformanceTests` cannot see that cost, because nothing there is observing.
`MenuBarPerformanceTests.testCaptureWithNoMenuBarModelObserving` and
`testCaptureWithTheMenuBarModelObserving` measure the same capture both ways against the same
fixture: over five isolated runs the observer costs roughly **0.2–1.4 ms per capture**, near 0.9 ms
at the median, on captures that themselves take about 2 ms warm. Three orders of magnitude inside
§1.1's ~3-second budget, so the tick stands. Those are ranges from one machine, not constants —
the test's own doc comment carries the full figures and why the worst-of-ten numbers must not be
compared across the two cases.

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
- [ ] With the main window closed, open the **Window** menu. It contains a Steno item that
      reopens the window. This is the stated fallback if "Open Main Window" misbehaves
      (`StenoApp.swift`'s comment on the `Window` scene) and it has never been looked at — if the
      menu has no such item, that comment is wrong and the popover's button is the only way back.
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

- **`MenuBarModel.lastError` has no in-popover Dismiss control.** It is cleared in two places —
  `prepareForShow()` (`MenuBarModel.swift:117`) and `setStatus`'s success path (`:174`) — and set
  in two: `setStatus`'s catch (`:181`) and a failed read inside the generic `fetch<T>` helper
  (`:226`), which every `reload()` reaches through `fetchProjects()` and `fetchTasks()`. It is
  read at `MenuBarPopoverView.swift:28`, which shows the message, and again at `:51`, which
  withholds "Nothing in progress." while it is set so a failed read cannot pass for an empty
  store. Closing and reopening the popover is one dismissal gesture; a successful status change is
  the other, because `setStatus`'s success path clears the message too. Only a message left by a
  failed read or a failed write, with the popover never closed and no other status change
  succeeding since, stays on screen — where the main window's own error banner offers a Dismiss
  button. Note that the clear cannot move into `reload()` — `setStatus`'s catch calls `reload()`
  immediately after setting the message (`:181` then `:184`), so clearing there would erase it in
  the same call that set it, and
  `MenuBarModelTests.aFailedStatusSaveIsReportedAndRefetched` asserts it survives exactly that
  reload. `prepareForShow()` is safe because nothing on the failure path calls it, which
  `MenuBarModelTests.reopeningThePopoverClearsAStaleError` pins.
- **The `statusChangedAt` sort has no tiebreak.** `MenuBarModel.reload()` sorts live tasks by
  `$0.statusChangedAt > $1.statusChangedAt` alone (`:139`), so two tasks transitioned in the same
  instant order arbitrarily between reloads, depending on the store's own fetch order.
- **A store failure can leave a running process with no window and no status item.** On a store
  that fails to open, `StenoApp.init` sets `menuBar = nil` (`StenoApp.swift:97`), but
  `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` still returns `false`
  unconditionally (`AppDelegate.swift:11`). Closing the `StoreFailureView` window therefore leaves
  the app running with nothing on screen and no menu bar icon to reopen it from. Recoverable via
  the Dock icon — nothing sets `LSUIElement`, so AppKit's default reopen handling still applies.
- **An unknown `taskID`, or a task whose project has since vanished, silently no-ops.**
  `MenuBarModel.setStatus`'s guard (`:170`) returns with no `lastError` if the id is not found
  among the tasks `reload()` last built, and that same `reload()`'s project join (`:144`) silently
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