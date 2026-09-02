# M1-04 — Menu Bar Item & Popover — Design

**Task:** [`docs/tasks/M1-04-menu-bar.md`](../../tasks/M1-04-menu-bar.md)
**Requirements:** [FR-1.2](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-1.4](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[§1.1](../../REQUIREMENTS.md#11-the-core-problem),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents),
[D15, D18](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/menu-bar-popover`
**Date:** 2026-08-31

## Goal

A persistent menu bar icon whose popover offers the quick-add field, the in-progress tasks with
inline status toggles, and a way back into the main window.

This is the third of D15's three capture surfaces, and the last one. It is also the surface the
user sees most often without opening the app, which sets its whole character: it is glanceable
and quiet, not a second main window.

---

## 1. What this task inherits, and must not rebuild

Four things already exist. Every one of them is consumed here, not reimplemented, and the
acceptance criteria are written so that rebuilding any of them would fail them.

| Inherited | From | Why it must be reused |
|---|---|---|
| `CaptureFieldView` and its `.bar` style | M1-03 | Criterion 2 is "the chip behaves identically to the main window". One chip is the only way to guarantee that |
| `CaptureFieldModel` / `CaptureService` | M1-02 | D15's one code path. The popover writes tasks the same way the panel and the window do |
| `StatusMenuItems` | M1-05 | The four statuses cannot acquire a per-surface spelling |
| `StatusService.setStatus(_:on:)` | M1-05 | Criterion 3 needs the `statusChanged` event, and `TaskItem`'s mutators are `internal` as of D-033 — this surface *cannot* mutate a task even if it tried |

`QuickCaptureController` is not inherited but it is the template: this task copies its shape,
its residency argument, and its file split.

---

## 2. The units

| File | What it is | Testable headless |
|---|---|---|
| `StenoKit/Features/MenuBar/MenuBarModel.swift` | **Create.** The popover's state: the capture field, the in-progress list, the status action | Container, no window server |
| `StenoKit/Support/LoginItem.swift` | **Create.** The launch-at-login hook and its fake | Protocol yes; `SMAppService` no |
| `Steno/Features/MenuBar/MenuBarController.swift` | **Create.** `NSStatusItem`, `NSPopover`, activation, residency | No — AppKit surface |
| `Steno/Features/MenuBar/MenuBarPopoverView.swift` | **Create.** The popover's SwiftUI content and its task rows | No — view |
| `Steno/App/MainWindowReveal.swift` | **Create.** Bring the main window forward from closed, minimized, or another Space | No — AppKit |
| `Steno/App/StenoApp.swift` | **Amend.** `WindowGroup` → `Window(id:)`; build the controller; app delegate adaptor | No — `@main` |
| `Steno/Features/Capture/CaptureFieldView.swift` | **Amend.** `CaptureFieldStyle` gains `.popover` | No — view |
| `StenoKit/Features/MainWindow/Status+Display.swift` | **Amend.** `Status.menuOrder`, named rather than inherited from the enum | Pure — no container |
| `Steno/Features/MainWindow/StatusControl.swift` | **Amend.** `StatusMenuItems` iterates `menuOrder`, not `allCases` | No — view |

The split follows D-010's rule as ARCHITECTURE §5 states it: the model is testable without a
window server so it lives in `StenoKit`; the `NSStatusItem` that feeds it cannot and does not.
This is the same line M1-03 drew between `CarbonHotkeyMonitor` and `CapturePanel`.

---

## 3. `MenuBarModel` — the popover's state

`@Observable @MainActor`, built once at launch over `container.mainContext` — the same context
`MainWindowView` and `QuickCaptureModel` read, so a capture from the popover and the window's
own fetches agree without relying on cross-context visibility.

**It does not reach `MainWindowModel`.** The popover must open, list, route and write when no
main window exists at all; that is most of the point of a menu bar item. It shares the *code
path* with the main window per D15, not the main window's state. `QuickCaptureModel`'s doc
comment makes this argument already and this type inherits it verbatim.

It holds:

- `field: CaptureFieldModel` — built exactly as `QuickCaptureModel` builds its own, including
  `preferred: { nil }`. The popover has no surface context to prefer, so FR-1.4's ladder falls
  through to the ticket key and then to last-used. `CaptureService`'s own documentation
  specifies `nil` for exactly this shape of surface.
- `inProgress: [TaskItem]` — the list, refreshed by `reload()`.
- `lastError: String?` — a failed status write says so in the popover rather than silently
  reverting, matching what `MainWindowModel` does with its own bar.

### 3.1 The list, and O-6

**Every `IN-PROGRESS` task, across every non-archived project, with no date filter.** This
closes O-6, which `DECISIONS.md` assigns to this task.

FR-1.2's phrase is "today's in-progress tasks", and the tempting literal reading is
`statusChangedAt >= startOfToday`. That reading is wrong for this product: a task you started
Monday and are still on is precisely what you say at Thursday's stand-up, and a date cut would
hide it on the one surface built for glancing. `IN-PROGRESS` already means "current" — the date
filter would remove information without removing noise. D18 caps the whole dataset under 20
live tasks, so the unfiltered list is short by construction.

The project filter is rejected for a structural reason as well as a product one: mirroring the
main window's selection would couple the popover to state that does not exist when the window
is closed, which is the coupling this section's opening rule exists to
prevent.

Rows are ordered newest `statusChangedAt` first — the same ordering `TaskGrouping` gives each
of its sections, so a task does not sit in one place in the window and another in the popover.

**The status filter runs in memory, not in the `#Predicate`.** The fetch asks only for
`!$0.isArchived`; status, and membership of a non-archived project, are filtered afterwards.
This mirrors `MainWindowModel.fetchTasks` exactly, and for its stated reason — D18 makes the
fetch the cost, not the filter — with a second reason of its own: a `#Predicate` comparing a
SwiftData-stored enum is the kind of expression that compiles and then fails at runtime, and
there is no reason to find out here.

Archived projects take their tasks with them, as they do in the window (§3.1).

### 3.2 Status from the popover

`setStatus(_ new: Status, on taskID: UUID)` resolves the task from `inProgress`, calls
`StatusService.setStatus`, and reloads only when the service reports an actual transition —
the same guard `MainWindowModel+Status` uses, for the same reason: a no-op transition wrote
nothing, so refetching would fetch state that cannot have moved.

On a thrown save it logs, sets `lastError`, and reloads anyway. That reload is not cosmetic:
`StatusService` documents that `rollback()` restores the store but leaves the held task
reporting the rejected status, and the refetch is what corrects it.

**Blocking from the popover commits the transition and does not offer D-036's reason sheet.**
Three reasons, in order of weight: §3.3 makes `blockedReason` optional, so nothing is lost that
the spec requires; a sheet presented from a `.transient` popover dismisses the popover that
spawned it, so the interaction is incoherent as well as unnecessary; and the detail pane still
offers the reason for the same task a moment later. Recorded as D-039.

A task moved to any other status leaves the list on the next reload, which is the surface's own
confirmation that the toggle took effect.

### 3.3 Freshness, without a project cache

`MenuBarModel` observes `.stenoDidWrite` through `WriteObservation`, exactly as
`MainWindowModel` does, so a status change or a capture made in the window updates the popover
and the reverse. `CaptureService` and `StatusService` both post it after their save (D-031,
D-035).

The task file warns that `.stenoDidWrite` does not yet cover project writes —
`MainWindowModel.perform` saves `createProject`, `updateProject` and `archive(projectID:)`
without posting — and asks this task to decide whether to close that gap.

**This design does not close it, and does not need to.** `prepareForShow()` refetches projects
on every open, the same way `QuickCaptureModel.prepareForShow` does, so the popover holds no
project cache that could go stale. Adding the post to `perform` would make that method re-enter
`reload()` through its own observer before its own `reload()` runs; the task file is right that
this needs its own analysis, and this task has no need that would pay for it. The gap stays
documented where it already is, in `WriteNotifications.swift`, and belongs to whichever task
first caches projects outside the window.

### 3.4 The one thing this task fixes in what it inherits

`StatusMenuItems` iterates `Status.allCases`, so the menu's order is the enum's declaration
order. `TaskGrouping` refuses exactly that coupling one directory away: it names `order` as a
`public static let`, asserts it in a test, and says why — "reordering the enum for any other
reason cannot silently reorder the user's window."

The popover is the second surface to render that menu, which is the moment the coupling stops
being theoretical: a reorder of `Status` for an unrelated reason would move the items under the
user's cursor in two places at once. So `Status.menuOrder` joins `displayName` in
`Status+Display.swift`, asserted in a test, and `StatusMenuItems` iterates it.

`menuOrder` is `[.todo, .inProgress, .blocked, .done]` — today's rendering, unchanged. It is
deliberately **not** `TaskGrouping.order`: that order answers "what should I look at first" and
is right for a list of sections, while a picker reads best in workflow order. Two orders that
differ is the correct outcome, and naming both is what makes the difference inspectable rather
than accidental. Recorded as D-042.

---

## 4. The AppKit surface

`MenuBarController` owns an `NSStatusItem` (`squareLength`, an SF Symbol image with an
accessibility description) and an `NSPopover` whose `contentViewController` is an
`NSHostingController` wrapping `MenuBarPopoverView`. `behavior = .transient`, so clicking
outside dismisses it without the controller arranging anything.

`sizingOptions = [.preferredContentSize]` lets the popover take its height from the SwiftUI
content, so an empty list and a list of six are both correctly sized and neither is scrolled.

### 4.1 Activation — the one deliberate deviation from M1-03

Opening the popover calls `model.prepareForShow()`, then
`NSApp.activate(ignoringOtherApps: true)`, then `show(relativeTo:of:preferredEdge:)`, then
`makeKey()` on the popover's window.

The refresh goes first, matching `QuickCaptureController.show`: preparing after the show would
render one frame with a stale chip, and FR-1.4's chip is a claim about where the task will
land.

`CapturePanel`'s doc comment says, emphatically, not to activate — and it is right for the
panel. The two surfaces are opposites. The panel appears over the application the user is
working in, and never taking focus is what removes the entire restore-focus problem from the
3-second budget. The menu bar item is reached by *leaving* that application to click the
system menu bar; the user has already changed context, and activation is what makes the text
field first responder without a second click. §1.1 treats a capture field that needs a click as
a defect, so this is the requirement talking, not preference. Recorded as D-038 so the next
reader does not "fix" one surface to match the other.

`makeKey()` after `show` rather than relying on `.onAppear` alone: `CaptureFieldView` sets
`@FocusState` in `onAppear`, and that only lands if the popover's window is key by then.

`.onAppear` also needs help to fire more than once. The hosting controller is resident, so the
field's view identity never changes and its focus would run on the first open of a launch and no
other. `MenuBarModel` counts opens and the view keys the field on that count, which re-creates
the *view* — never the model, so the draft is untouched — on every open.

### 4.2 Residency, and what an open actually costs

The status item, the popover, the hosting controller and the model are all built once in
`StenoApp.init` and held for the process — `QuickCaptureController`'s argument, unchanged:
building an `NSHostingController` and running a fetch inside the *first* click of every launch
puts the cost on the click that matters most and is hardest to measure.

Per-open cost is therefore `prepareForShow()` alone: refetch projects, refetch tasks,
`field.refreshChip()`. The chip refresh is not optional — the draft survives a dismissal, so the
project list can change underneath it, and FR-1.4's chip is a claim about where the task will
land. `QuickCaptureModel.prepareForShow` documents this and this method matches it.

The open is wrapped in a `popoverShow` signpost interval alongside M1-03's `hotkeyShow`, read
with the same `log show --signpost` command that file already documents.

### 4.3 `CaptureFieldStyle` gains a third case

`.bar` hard-codes `width: 560`. That is right for a Spotlight-style panel and too wide for a
menu bar popover, which should hang under a 22-point status item rather than span a third of
the screen.

`CaptureFieldStyle` gains `.popover`: it takes `.bar`'s behaviour — no button row, the hidden
`Esc` button — and differs only in width (360) and padding. The chip view, the `isBlank`
definition and the guarded `onSubmit` stay literally shared, which is what criterion 2 asks
for. The existing `style == .sheet` comparisons are unaffected because the new case falls into
the same `else` branch `.bar` already takes.

An associated value on `.bar` was considered and rejected: it turns every `style == .sheet`
comparison into a pattern match for one number.

`Return` commits and closes the popover; `Esc` closes it without saving. The draft survives a
dismissal that is neither — clicking away mid-thought is not a decision to discard, which is
`PanelDelegate`'s rule and is right here too.

---

## 5. "Open Main Window", and the three states

Criterion 4 names three states — closed, minimized, on another Space — and they need different
things.

### 5.1 The scene change

`StenoApp`'s `WindowGroup` becomes `Window("Steno", id: "main")`.

This is not a behaviour change: the main window is already single-instance in practice, because
`MainWindowCommands` replaces `.newItem` and nothing else opens a second one. It is what makes
a reopen-by-identity possible at all — a `WindowGroup` answers a reopen by minting another
window, which is the wrong answer for a recall tool with one window. `Window` also contributes
its own item to the Window menu, so "open the main window" acquires a keyboard-reachable second
route for free.

`StenoApp` also gains an `NSApplicationDelegateAdaptor` whose only job is to return `false`
from `applicationShouldTerminateAfterLastWindowClosed`. **This is what makes criterion 1 true**
— "present without the main window open" is a claim about process lifetime, and stating it
explicitly costs three lines and removes a dependency on a framework default.

The app stays a regular, Dock-icon application. Nothing in FR-1.2 asks for an agent app, and
`LSUIElement` would remove ⌘Tab and the Dock icon — a product change this task is not entitled
to make, and one that would oblige the popover to grow a Quit item.

### 5.2 The reveal

`MainWindowReveal.reveal()`:

1. `NSApp.activate(ignoringOtherApps: true)` — required for all three states.
2. Find the main window among `NSApp.windows`. It is tagged with a stable
   `NSUserInterfaceItemIdentifier` set from `MainWindowView` through a tiny `NSViewRepresentable`
   that reads `view.window`, rather than matched by title or by class — a title is localizable
   and a class match would catch the `CapturePanel`.
3. If found: `deminiaturize(nil)` then `makeKeyAndOrderFront(nil)`. Deminiaturize covers the
   minimized case; activating and ordering front is what moves the user to the window's Space.
4. If not found — the user closed it with ⌘W — reopen the scene by identity.

The popover closes first, so the window does not appear behind a popover that is about to
dismiss itself.

### 5.3 What is verified, and what is not

Every API shape above typechecks under Swift 6 for macOS 14 with no warnings: the `Window(id:)`
scene, the status item and popover, `sizingOptions`, the deminiaturize sweep, `SMAppService`,
and the termination guard.

**Typechecking is not evidence that the closed-window branch works,** and this document does not
claim it is. GUI automation is unavailable in this environment — the agent cannot click a menu
bar icon — so step 4 is the one item here whose behaviour is established by the user's manual
pass rather than by a test. The implementation logs which branch fired, at `info`, so the
manual check reads a log line rather than an inference. This is called out because M1-03's panel
positioning was found by exactly this route and it is cheaper to expect than to be surprised by.

---

## 6. Launch at login — the hook, with no caller

`StenoKit/Support/LoginItem.swift`: a `LoginItem` protocol (`isEnabled`, `enable()`,
`disable()`), an `SMAppServiceLoginItem` implementation over `SMAppService.mainApp`, and a fake
for tests.

**Nothing in this PR calls `enable()`, and no UI exposes it.** The task file scopes this task to
"launch-at-login behavior, or the hook for it", and says FR-6 owns the setting — whose own list
places it in the Capture pane, which is M1-08. Registering the user for launch-at-login
without asking is a product decision this task is not entitled to make, and a toggle here would
be the second place the setting lives the day M1-08 ships the first.

This is the same posture `QuickCaptureModel.rebind` shipped in with M1-03: present from day one
so that M1-08 adds a pane rather than redesigning a type.

A registration failure — an unsigned or relocated bundle, which a debug build from `.build/` may
well be — is logged and returned, never trapped.

---

## 7. Testing

Headless, in `StenoTests/Features/MenuBar/MenuBarModelTests.swift`, all over a
`ModelContext(container)` built from `inMemoryContainer()` and never `mainContext` — that context
does not retain its container, so a test whose container is a local would dangle:

- The list is exactly the `IN-PROGRESS` tasks, and spans projects.
- Archived tasks are excluded; tasks of an archived project are excluded.
- Ordering is newest `statusChangedAt` first.
- `setStatus` appends exactly one `statusChanged` event and the row leaves the list.
- A no-op transition writes nothing: no event, no save, no reload.
- A failed save sets `lastError` and refetches, leaving the displayed status matching the store.
- A `.stenoDidWrite` posted by another surface refreshes the list — asserted with `WriteCounter`,
  the helper M1-05 added.
- A capture through the popover's field lands in the right project, exercising the shared
  `CaptureFieldModel` rather than a second routing path.
- `LoginItem` against the fake: enable, disable, and a throwing registration.
- `Status.menuOrder` is asserted literally, the way `TaskGrouping.order` already is, so a
  reorder of the enum fails a test rather than moving a menu item.

Latency (criterion 5), in `StenoTests/Features/MenuBar/MenuBarPerformanceTests.swift`, XCTest
per D-011's `measure` exception:

- One `measure` case over `prepareForShow()` at D18 scale, asserting against the worst of ten
  iterations rather than the last — `CapturePerformanceTests`' convention.
- `CapturePerformanceTests` itself is re-run unchanged and its numbers quoted in the PR body.
  That file's own comment says "M1-03 and M1-04 diff against this file", and criterion 5 is a
  claim about no regression, which is a comparison and not a measurement.

Read the real numbers with the raw `xcodebuild | grep measured` command
`CapturePerformanceTests` documents — `make test` compresses `measure` output to an average and
hides the worst-of-ten the assertions gate on.

---

## 8. Manual verification

The list for the user, in the order that finds problems fastest:

1. Quit and relaunch — the icon is in the menu bar, with no window open.
2. Close the main window with ⌘W — the icon is still there and the app is still running.
3. Click the icon — the popover opens and the field is focused. Type without clicking first.
4. Type text containing a ticket key whose prefix matches a project — the chip names the same
   project the main window's New Task sheet names for the same text.
5. `Return` — the popover closes; the task is in the main window under TODO.
6. `Esc` on a half-typed line — the popover closes; reopening shows the draft still there.
7. Click away mid-typing — same: the draft survives.
8. A task set to IN-PROGRESS in the main window appears in the popover without reopening it.
9. Toggle a row to DONE from the popover — the row leaves the list, and the task's timeline in
   the main window shows one `statusChanged` event.
10. Toggle a row to BLOCKED — the status changes and no reason sheet appears (D-039).
11. "Open Main Window" from each of: window closed, window minimized, window on another Space.
12. Capture through the popover feels no slower than the hotkey panel.

---

## 9. Scope

**In:** the status item and popover; the popover's model, list, and inline status toggles; the
`.popover` capture style; `Status.menuOrder` and the `StatusMenuItems` change that consumes
it; the `Window` scene change and the termination guard; the main-window reveal; the
launch-at-login hook; the tests above.

**Out:**
- Capture logic — M1-02. This surface calls it.
- Status transition logic — M1-05. This surface calls it; D-033 makes anything else impossible.
- Notes and the timeline — M1-06.
- The Settings window and the launch-at-login *toggle* — M1-08 and FR-6.
- Posting `.stenoDidWrite` from `MainWindowModel.perform` — section 3.3 above explains why this
  removes the need rather than taking on the re-entrancy analysis.
- Any agent-app / `LSUIElement` change — §5.1.
- A Quit item in the popover, which only an agent app would need.

---

## 10. Documents amended by this PR

- **`docs/ARCHITECTURE.md`** — §5's tree gains `StenoKit/Features/MenuBar/` and
  `Steno/Features/MenuBar/`, and `Support/` gains `LoginItem.swift`; §4's capture data-flow
  diagram already names the menu bar and needs no change.
- **`docs/DECISIONS.md`** — D-037 (the popover lists every IN-PROGRESS task, closing O-6),
  D-038 (the menu bar activates Steno and the panel does not), D-039 (blocking from the popover
  commits without offering the reason), D-040 (the main window becomes a `Window` scene and the
  app outlives it), D-041 (launch at login ships as a hook with no caller), D-042 (the status
  menu's order is named, not inherited from the enum). O-6 moves out of the open table.
- **`docs/tasks/M1-04-menu-bar.md`** — acceptance criteria ticked.
- **`docs/tasks/README.md`** — M1-04 ticked once merged; ` — PR #N` while the PR is open.

**`docs/REQUIREMENTS.md` is not amended.** Nothing here contradicts it. FR-1.2 lists three
things in the popover and this builds those three; its "today's in-progress tasks" is silent on
the set, which is why `DECISIONS.md` carries O-6 as an implementer's call rather than a spec
defect. FR-6's Settings list keeps launch-at-login, and this task ships no setting.

**Update, later in the branch: that call did not survive final review.** The reasoning above —
that FR-1.2's silence on the set makes this an implementer's call, not a spec defect — was correct
about O-6 but missed a second-order problem: FR-1.2 read on its own, with `DECISIONS.md` unread,
would lead a future implementer straight to a date filter, since "today's" is the plain reading of
the words actually in the requirement. The fix landed as a pointer rather than a rewrite — FR-1.2's
wording is unchanged, but it now names `DECISIONS.md` D-037 as the reading to use — in
`docs/REQUIREMENTS.md` v1.13 (changelog entry same version), with D-037 carrying the return
pointer. So `docs/REQUIREMENTS.md` *is* amended by this PR after all; the paragraph above is left
as written because it records what this design believed at the time, not because it is still
true.
