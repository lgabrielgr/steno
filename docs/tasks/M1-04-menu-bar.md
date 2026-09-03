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

- [x] The icon persists across relaunch and is present without the main window open.
- [x] The popover's quick-add goes through the M1-02 path — verified by the auto-routing chip
      behaving identically to the main window.
- [x] Inline status toggles update the task and append a `statusChanged` event.
- [x] "Open Main Window" works when the window is closed, minimized, or on another Space.
- [x] Capture latency has not regressed against the M1-02 measurement.

**All five are now met.** The user ran the manual GUI pass below on **2026-09-02** and reported
criteria 1, 2 and 4 — the three that needed a person — passing. Those three are ticked on that
report; M1-06's PR carries the tick, because M1-04's own PR (#16, `8edf106`) merged before the pass
was run and CLAUDE.md step 4 makes the next PR responsible for the sweep.

Criteria 3 and 5 were ticked earlier from automated evidence alone, and that reasoning is still
worth reading. No agent in this environment can drive the GUI (TCC blocks `screencapture`, Screen
Recording is denied to `osascript`), so at the time nothing listed above had been observed running.
Those two were ticked because they are exercised by automated tests that were strengthened until
they could actually fail, not because they were watched: criterion 3 by `MenuBarModelTests` (its
failed-save and no-op tests were both hardened to pin the model's state, not just the surface
symptom), and criterion 5 by `MenuBarPerformanceTests` plus an unchanged re-run of
`CapturePerformanceTests`.

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

**Run by the user on 2026-09-02.** They reported acceptance criteria 1, 2 and 4 passing. They did
not report per-step findings, so where a step below raises a question nobody in this environment
could settle — whether a `Window` scene's `NSWindow` survives ⌘W, whether the **Window** menu
carries a Steno item — the tick records that the step was run and did not block the criterion it
serves. It is **not** an answer to the question, and those questions stay open. Anyone who needs
one answered should re-run that step and look specifically.

- [x] Quit and relaunch. The icon is in the menu bar, with no window open.
- [x] Close the main window with ⌘W. The icon is still there and the app is still running.
- [x] Click the icon. The popover opens and the field is focused — type without clicking first.
- [x] Close and reopen it. The field is focused **again** (the `showCount` fix). **If clicking the
      icon while the popover is open re-opens it instead of closing it**, the cause is
      `NSPopover.willCloseNotification` arriving too late, not the `.id(model.showCount)` key —
      `popover.animates = false` is the next lever to try, not the focus key.
- [x] Type text with a ticket key matching a project. The chip names the same project the main
      window's New Task sheet names for the same text — this is criterion 2.
- [x] `Return`. The popover closes; the task is in the main window under TODO.
- [x] `Esc` on a half-typed line. The popover closes; reopening shows the draft still there.
- [x] Click away mid-typing. Same — the draft survives.
- [x] Set a task to IN-PROGRESS in the main window. It appears in the popover without reopening.
- [x] Toggle a row to DONE from the popover. The row leaves the list, and the task's timeline in
      the main window shows one `statusChanged` event. (Criterion 3 is already covered by
      `MenuBarModelTests`; this step is a sanity check against the real app, not new evidence.)
- [x] Toggle a row to BLOCKED. The status changes and **no** reason sheet appears (D-039).
- [x] "Open Main Window" with the window **closed**. Check the log line —
      `/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.lgabrielgr.steno"' | grep reveal` —
      but judge this case by whether the window actually comes forward, not by which line it logs.
      Whether a `Window` scene's `NSWindow` survives ⌘W and stays in `NSApp.windows` is something
      nobody in this environment has been able to determine, so **either** log line is consistent
      with correct behaviour here: `reveal: bringing the existing main window forward` if the
      `NSWindow` survived closing, or `no main window found` (falling through to the reopen
      branch) if it did not — both end with the window on screen, which is the only thing this
      step is checking. This case cannot tell you whether `WindowTagger` stamped the identifier;
      the minimized case below is the one that can.
- [x] With the main window closed, open the **Window** menu. It contains a Steno item that
      reopens the window. This is the stated fallback if "Open Main Window" misbehaves
      (`StenoApp.swift`'s comment on the `Window` scene) — if the menu has no such item, that comment
      is wrong and the popover's button is the only way back. The 2026-09-02 pass did not report on
      this either way, so the comment is still unconfirmed.
- [x] "Open Main Window" with the window **minimized**. Unlike the closed case, a minimized
      window is definitely still in `NSApp.windows`, so this is the real discriminator: the log
      **must** read `reveal: bringing the existing main window forward`. If it instead reads
      `no main window found`, `WindowTagger` never stamped the identifier on the `NSWindow` (it
      stamps in `updateNSView`, which requires the view to actually be attached to a window), and
      every reveal is silently falling through to the reopen branch — a real defect here, not the
      "not a bug" case above.
- [x] "Open Main Window" with the window **on another Space**.
- [x] Immediately after using "Open Main Window" (or any popover close), click the menu bar icon
      within about 200ms. It is a no-op. Deliberate — the transient-toggle guard's window after
      any close — not a bug.
- [x] Look at "Open Main Window"'s hit area by eye. It is the text glyphs plus padding, not the
      popover's full width, with no hover state or border marking it clickable. Judge whether that
      reads as clickable rather than filing it as a defect to fix blind; the 2026-09-02 pass
      raised no complaint about it, which is not the same as a considered verdict.
- [x] Capture through the popover feels no slower than the hotkey panel — this is criterion 5's
      subjective half; `MenuBarPerformanceTests` and `CapturePerformanceTests` are its objective
      half (see the PR body for both sets of numbers).

## Known limitations

Deferred deliberately, not gaps the plan missed — recorded here so a later task does not mistake
pre-existing behaviour for a regression it introduced.

- **`MenuBarModel.readError` and `.writeError` have no in-popover Dismiss control.** What was one
  `lastError` property is now two, split because a single property could not be cleared correctly
  from both directions: a read failure's message needed to survive exactly until the next
  `reload()`, and a write failure's message needed to survive that same `reload()` (its own catch
  calls one) while still clearing on reopen — one property cannot obey both rules at once.
  `readError` (`MenuBarModel.swift:38`) is set by the
  generic `fetch<T>` helper (`:263`), which every `reload()` reaches through `fetchProjects()` and
  `fetchTasks()`, and cleared at the top of every `reload()` (`:155`) — a later successful reload
  clears it purely by running. `writeError` (`:48`) is set by `setStatus`'s catch (`:213`) and
  cleared by `setStatus`'s success path (`:206`) and by `prepareForShow()` (`:144`); `reload()`
  never touches it, because `setStatus`'s catch calls `reload()` immediately after setting it
  (`:213` then `:216`), and clearing it there would erase the message in the same call that set
  it. `MenuBarModelTests.aFailedStatusSaveIsReportedAndRefetched` pins that survival, and
  `.aFailedReadIsClearedByTheNextSuccessfulReload` pins the read side's opposite rule. Both are
  read at `MenuBarPopoverView.swift:37` and `:42`, which show them as up to two separate captions,
  and again at `:64`, which withholds "Nothing in progress." only while `readError` is set — a
  `writeError` alone leaves the list readable, so the empty state may be truthful even then.
  Closing and reopening the popover clears a stale `writeError`; a later successful `reload()` —
  from `prepareForShow()`, from another surface's write, or from a status change succeeding here —
  clears a stale `readError` the same way. `prepareForShow()`'s clear of `writeError` is safe
  because nothing on the failure path calls it, which
  `MenuBarModelTests.reopeningThePopoverClearsAStaleError` pins.
- **The `statusChangedAt` sort has no tiebreak.** `MenuBarModel.reload()` sorts live tasks by
  `$0.statusChangedAt > $1.statusChangedAt` alone (`:171`), so two tasks transitioned in the same
  instant order arbitrarily between reloads, depending on the store's own fetch order.
- **A store failure can leave a running process with no window and no status item.** On a store
  that fails to open, `StenoApp.init` sets `menuBar = nil` (`StenoApp.swift:97`), but
  `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` still returns `false`
  unconditionally (`AppDelegate.swift:11`). Closing the `StoreFailureView` window therefore leaves
  the app running with nothing on screen and no menu bar icon to reopen it from. Recoverable via
  the Dock icon — nothing sets `LSUIElement`, so AppKit's default reopen handling still applies.
- **An unknown `taskID`, or a task whose project has since vanished, silently no-ops.**
  `MenuBarModel.setStatus`'s guard (`:202`) returns with neither `readError` nor `writeError` set
  if the id is not found among the tasks `reload()` last built, and that same `reload()`'s project
  join (`:176`) silently drops any task whose `projectID` no longer resolves. Neither is a
  regression — it matches
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