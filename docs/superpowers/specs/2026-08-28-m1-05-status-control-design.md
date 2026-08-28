# M1-05 — Status Control & Transitions — Design

**Task:** [`docs/tasks/M1-05-status-control.md`](../../tasks/M1-05-status-control.md)
**Requirements:** [§3.2](../../REQUIREMENTS.md#32-taskitem),
[§3.3](../../REQUIREMENTS.md#33-event-append-only),
[FR-3](../../REQUIREMENTS.md#fr-3-main-window-p0),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents),
[D11, D15, D18](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/status-control`
**Date:** 2026-08-28

## Goal

One code path for changing a task's status, appending a `statusChanged` event every time, with
a keyboard shortcut and a control in every surface that shows a task.

M0-05 built the window that displays status as a label. M1-02 built `CaptureService` — the
shape this task copies. Nothing here invents a second way to write to the store: if this design
produces two routes to a status change, it is wrong.

---

## 1. Why this task is being built before M1-04

M1-04 was next in the README's order. Its third acceptance criterion is "inline status toggles
update the task and append a `statusChanged` event", and its own task file forbids writing a
second status-mutation path — so M1-04 cannot be built honestly until this exists. M1-05
depends only on M0-05, which merged, so the swap costs nothing and each PR stays
single-purpose. The README's checkbox order is unchanged; only the build order moved.

This is recorded because the next reader will find M1-05 merged before M1-04 and wonder.

---

## 2. The units

| File | What it is | Testable headless |
|---|---|---|
| `StenoKit/Status/StatusTransition.swift` | **Create.** The transition as a value, and the cycle | Pure — no container |
| `StenoKit/Status/StatusService.swift` | **Create.** The single write path | Container, no window server |
| `StenoKit/Support/WriteNotifications.swift` | **Move + rename** of `Capture/CaptureNotifications.swift` | Yes |
| `StenoKit/Capture/CaptureService.swift` | Posts the renamed notification | Yes |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | Calls the service; observes the renamed notification | Yes |
| `StenoKit/Features/MainWindow/MainWindowActions.swift` | Three additions for the menu | Yes |
| `StenoKit/Models/TaskItem.swift`, `Project.swift`, `Event.swift` | Mutators reduced to `internal` | Yes |
| `Steno/Features/MainWindow/StatusControl.swift` | **Create.** One control, two call sites | No — window server |
| `Steno/Features/MainWindow/TaskDetailView.swift` | Label becomes the control | No |
| `Steno/Features/MainWindow/TaskListView.swift` | Rows gain the control as a context menu | No |
| `Steno/Features/MainWindow/MainWindowView.swift` | Hosts the blocked-reason sheet | No |
| `Steno/App/MainWindowCommands.swift` | Two menu items | No |

`StenoKit/Status/` is a new directory. XcodeGen's manifest globs whole target directories
(`sources: - path: StenoKit`), so no `project.yml` edit is needed — but `make generate` still
has to run before the new files build, which `make build` does for us.

**Why a new directory rather than `Capture/`.** Status transitions are not capture. Putting
them in `Capture/` would be the first step toward a `Capture/` that means "writes", which is
the drift ARCHITECTURE §5 exists to prevent.

---

## 3. `StatusService` — the one path

```swift
@MainActor
public struct StatusService {
    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    )

    @discardableResult
    public func setStatus(_ new: Status, on task: TaskItem) throws -> Bool

    @discardableResult
    public func addBlockedReason(_ text: String, to task: TaskItem) throws -> Bool
}
```

Same shape as `CaptureService`, for the same three reasons: `@MainActor` because
`ModelContext` is not `Sendable`; `now` injected so timestamps are assertable; `save` injected
because a real `ModelContext` cannot be made to fail on demand, and the rollback path is the
one that most needs a test.

`setStatus` mutates the task, inserts **exactly one** `statusChanged` event, saves, and posts.
On a save failure it calls `context.rollback()` and rethrows — without that, a failed save
leaves a status the store never accepted sitting in memory, where the next reload finds it and
the window shows a task state that is not on disk. That is D-018's lie in a new place.

### 3.1 Three rulings the spec does not make

**A non-transition writes nothing and returns `false`.** `TaskItem.setStatus` already no-ops
when the status is unchanged, and its doc comment explains why: re-stamping would reset a
completed task's `completedAt` and would hand this task a `statusChanged` event describing a
transition that never happened — which flows into a stand-up report as work that did not occur.
The service inherits that rule and adds to it: no transition, no event, no save, no post. The
return value exists so callers can make follow-up UI conditional on a transition having
actually happened.

**`blockedReason` is a second method, not a parameter on the first.** The parameter form
(`setStatus(_:on:blockedReason:)`) was drafted first and rejected: the chosen UX commits the
transition *before* asking for a reason, so nothing would ever pass the parameter, and it would
ship as an unused argument waiting for M1-06 to justify it. Two methods also make the two
events independently testable, which the parameter form does not.

`addBlockedReason` requires the task to be currently `blocked` and the text to be non-empty
after trimming; otherwise it writes nothing and returns `false`. That guard is what keeps the
sheet's Cancel path from appending an empty event.

**The event body uses U+2192.** `"IN-PROGRESS → BLOCKED"`, built from `Status.displayName`, and
the arrow is the same character §3.3's example table uses — verified at the byte level
(`e2 86 92`) rather than assumed, because a hyphen-arrow here would be a silent divergence
between the spec's example and every event ever written.

### 3.2 Ordering inside `setStatus`

1. `let transition = StatusTransition(from: task.status, to: new)` — captured **before** the
   mutation, or the event body reads `"BLOCKED → BLOCKED"`.
2. `guard task.status != new else { return false }`.
3. `task.setStatus(new, at: stamp)`.
4. `context.insert(Event(taskID:timestamp:kind:.statusChanged, body: transition.eventBody))`.
5. `try save(context)`, `catch { context.rollback(); throw }`.
6. `NotificationCenter.default.post(name: .stenoDidWrite, object: nil)` — after the save, never
   before, for the reason `CaptureService` states: an observer that reloads must not be able to
   read a context whose write has not landed.

Step 1 before step 3 is deliberate ordering in the *code*, not just in this prose. Reading
`task.status` after the mutation is the single easiest mistake here, it compiles, and it
produces `"BLOCKED → BLOCKED"` in a log that is never corrected because it is never editable.

---

## 4. The cycle

```swift
extension Status {
    public static let cycle: [Status] = [.todo, .inProgress, .done]
    public var next: Status { ... }
}
```

**`.blocked` is not in the cycle, and `.blocked.next` is `.inProgress`.**

FR-3 requires a "cycle status" shortcut and does not say what it cycles through. Including all
four statuses in declaration order means marking a TODO done takes three presses and writes
three `statusChanged` events — each individually truthful, collectively describing a task that
was blocked for 40 milliseconds. M2-02 renders the event log into a stand-up; this tool exists
so the user can say out loud what they did, and "blocked, then unblocked, in the same
keystroke" is noise it would have to read past.

Excluding `.blocked` also matches what blocked *is*: the one status §3.3 pairs with a reason,
and the one a user enters deliberately. It stays reachable from the status control and from its
own menu item — one keystroke, not zero.

`.blocked.next` is the case no array can express, and the one a test has to pin. Cycling out of
blocked goes to `IN-PROGRESS`, because the thing you do after being unblocked is the work.

---

## 5. Closing D-019's mutation hole

`TaskItem` and `Project` expose `public` mutators, and `MainWindowModel` publishes live
`@Model` objects to views. A view can therefore call `task.setStatus(...)` directly, skip the
event, and have the next unrelated `save(context)` commit it — the hole M0-05 left open and
D-019 named. Nothing does this today. This task is where it becomes dangerous, because this
task is the one putting status controls into view code.

**Reduce every domain mutator from `public` to `internal`:** `TaskItem.setStatus`, `.rename`,
`.move`, `.setArchived`; `Project.rename`, `.setJiraProjectKeys`, `.setArchived`; and
`Event.redact()`. Initialisers and stored properties stay `public`.

Verified this compiles rather than assumed: no file in the `Steno` app target calls a domain
mutator or constructs a model — the app target reaches the store only through `MainWindowModel`
and the two services, all of which live inside `StenoKit` — and all 32 files in `StenoTests`
use `@testable import StenoKit`, none a plain `import`.

The result is that `StatusService` is the only route to a status change **by construction**.
The alternative is a doc comment asking future view code not to call `setStatus`, which is a
promise, and this repo's review history is largely a record of comments that promised things
the code did not enforce.

`Event.redact()` is included because it is the same class of hole for M1-06 and M2-04, and
because reducing it now costs one line while reducing it later costs a conversation about why
only some mutators were closed.

---

## 6. `.stenoDidCapture` becomes `.stenoDidWrite`

D-031 established one notification, posted at the write rather than per surface, so that
manually-fetched view models refresh when another surface writes. Its own doc comment says it
is meant to cover "M1-05's and M1-06's future writes" — but the name says capture, and a status
change is not a capture.

Rename the name, its raw value (`com.lgabrielgr.steno.didWrite`), the `CaptureObservation` type
(→ `WriteObservation`), and move the file from `StenoKit/Capture/` to `StenoKit/Support/`, which
is where a cross-feature primitive belongs. `StatusService` posts it too. Five source files and
one test file; `MainWindowModel`'s observer changes only in the name it registers for.

**Why not a second notification.** `.stenoDidChangeStatus` alongside `.stenoDidCapture` leaves
M1-03's code untouched, but every future write kind then adds a name and every observer adds a
registration — the count grows with features, and the first observer to forget one is a
staleness bug that looks like SwiftData being flaky.

**Why not post `.stenoDidCapture` from `StatusService`.** It is free and the name would then
assert something false. That is the exact defect class the previous branch shipped five times.

Documents referenced under `docs/superpowers/` are historical records of what those tasks did
and are left alone; CLAUDE.md already says `DECISIONS.md` supersedes them where they disagree.
`ARCHITECTURE.md`'s invariant table and `DECISIONS.md`'s D-031 are current and are amended.

---

## 7. The view model and the menu

`MainWindowActions` gains three members, so that a menu item without an implementation is a
compile error rather than a menu item that silently does nothing — that file's stated reason
for existing:

```swift
var canChangeStatus: Bool { get }   // false when nothing is selected
func cycleStatusOnSelection()
func markSelectionBlocked()
```

`MainWindowModel` implements them over a `StatusService` built on its own context, plus
`setStatus(_:on:)` for the controls. Every one of them routes through the service and surfaces
a thrown error as `lastError` in the same words `perform` uses ("Could not change the status.
Your change was not saved."), then reloads — status is a grouping key, so the row moves
sections and the change has to be visible immediately.

`MainWindowCommands` gains **Cycle Status (⌘⇧S)** and **Mark Blocked (⌘⇧B)**, both disabled
when `canChangeStatus` is false. Steno is not a document app and has no Save item, so ⌘⇧S is
free here; neither chord shadows a default text-field binding, which rules out the otherwise
natural arrow-key shortcuts — a menu item bound to ⌘⇧→ would shadow "extend selection to end of
line" inside the capture field, and the capture field is the one thing §1.1 says must not
degrade.

### 7.1 The blocked-reason flow

`setStatus(.blocked, on:)` commits the transition first. **Only if it returns `true`** does the
model set `activeSheet = .blockedReason(taskID)`. `ActiveSheet` gains that case — it is already
one optional rather than a `Bool` per sheet, for the reason its own doc gives.

The sheet is the existing `TextEntrySheet`, which already disables its confirm button on empty
input and dismisses on Esc. So "no reason" costs one keystroke, the status is already changed
either way, and the moment the user is most frustrated is never blocked on typing — which is
what M1-05's task file asks for.

---

## 8. The views

One `StatusControl` view, used by both the detail pane and the task rows:

```swift
struct StatusControl: View {
    let current: Status
    let onSelect: (Status) -> Void
}
```

A `Picker`/`Menu` over `Status.allCases`, labelled with `Status.displayName`. **One view, two
call sites**, so the two surfaces cannot spell the four statuses differently, and so M1-04's
popover inherits a control rather than building a third — the same argument `CaptureFieldView`'s
`style` parameter makes for capture, and the reason `Status.displayName` was put in StenoKit in
the first place.

- **Detail pane:** the static capsule label becomes the control. Its doc comment currently says
  "The status is a label, not a control. Status changes are M1-05" — that comment is now false
  and is rewritten, not left.
- **Task rows:** `.contextMenu { StatusControl(...) }`. Not an always-visible per-row picker:
  the list is already grouped *by* status, so an inline picker on every row restates the section
  header 20 times, and D18 caps the list at a size where right-click plus a keyboard shortcut is
  enough. M1-04's popover is where an always-visible toggle earns its space, because that list
  has no section headers.

---

## 9. Testing

Headless, no window server, no network. Every acceptance criterion in the task file gets at
least one test.

**`StatusTransition` / `Status.cycle`** — pure, against literals:
- Every `from`/`to` pair produces `"FROM → TO"` with U+2192 and `displayName` spellings.
- `cycle` is `[.todo, .inProgress, .done]` and `next` walks it, wrapping at `.done`.
- `.blocked.next == .inProgress` — the case no array expresses.

D11's "the four statuses are the only four" needs no new test: `EnumTests` and
`StatusDisplayTests` already each assert `Status.allCases.count == 4`. A third would be
duplication, not coverage.

**`StatusService`:**
- Any status moves to any other — a parameterised table over all 12 ordered pairs, each
  asserting one `statusChanged` event with the right body. (Note: `make test` does not print
  parameterised cases; absence from the log is not failure.)
- Setting the status a task already has writes **nothing** — no event, and `statusChangedAt`
  unmoved.
- Entering `done` sets `completedAt`; leaving `done` clears it.
- `statusChangedAt` is stamped from the injected clock on every transition.
- `addBlockedReason` appends one `blockedReason` event when the task is blocked and the text is
  non-empty; writes nothing when the task is not blocked, and nothing for whitespace-only text.
- One `.stenoDidWrite` post per successful call, and **none** on a no-op.
- **Save failure:** assert on the *service's own context*, not a sibling — after a thrown save,
  that context's task still has the old status and the event is gone. A sibling context shows
  the old value whether or not the rollback ran, so asserting there would pass against a
  service with no rollback at all. This is the vacuous-assertion trap the previous branch hit,
  written down so it is not walked into again.

**`MainWindowModel`:**
- `cycleStatusOnSelection` moves the selected task and is a no-op with no selection.
- `canChangeStatus` tracks the selection.
- `markSelectionBlocked` sets `activeSheet` to `.blockedReason` on a real transition and
  leaves it `nil` when the task was already blocked.
- A failed save surfaces `lastError` and leaves the group untouched.

**Existing tests updated:** `CaptureNotificationTests` for the rename. `TaskItemTests`,
`TaskGroupingTests`, `MainWindowModelTasksTests` and `PersistedInvariantsTests` call
`setStatus`/`setArchived` directly; they use `@testable` and keep compiling against `internal`.

---

## 10. Manual verification

Agents cannot see or click this app (D-010): views need a window server, and the test bundle is
headless. These are for the user, after `make run`:

1. Select a task, press ⌘⇧S repeatedly — status walks TODO → IN-PROGRESS → DONE → TODO, and the
   row moves between sections each time.
2. ⌘⇧S never produces BLOCKED.
3. Press ⌘⇧B — the task moves to BLOCKED and a "Why is this blocked?" sheet appears.
4. Press Esc on that sheet — the task is still BLOCKED, and the timeline shows one
   `statusChanged` event and no reason event.
5. Repeat and type a reason — the timeline shows both events, reason second.
6. Right-click a task row — the four statuses appear; picking one moves the row.
7. Open the detail pane, change status there — the list row moves to match.
8. With no task selected, Cycle Status and Mark Blocked are greyed out in the menu.

---

## 11. Scope

**In:** the status service; the transition value and the cycle; the mutator visibility
reduction; the notification rename; the detail-pane control, the row context menu, and the two
menu items; the blocked-reason sheet.

**Out:**
- Notes and the redact-and-reappend grace window — M1-06.
- Stale detection reading `statusChangedAt` — M6-01.
- Auto-transition from Jira ticket state — open question Q(M4) in §12, explicitly not settled.
- The menu bar popover and its inline toggles — M1-04, which consumes `StatusControl` and
  `StatusService` rather than adding to them.
- Guarding `ModelContext.delete` on `Event`, which `Event`'s own doc comment names as an open
  seam. It belongs to whoever owns the context and is not made worse by this task.

---

## 12. Documents amended by this PR

- **`docs/ARCHITECTURE.md`** — the invariant table's `.stenoDidCapture` row becomes
  `.stenoDidWrite` with `StatusService` as a second poster; §5's tree gains `Status/`; a new
  invariant row for "a status change never happens without its event".
- **`docs/DECISIONS.md`** — D-033 (the service is the sole path, and mutators reduced to
  `internal`), D-034 (the cycle skips BLOCKED), D-035 (the notification rename, superseding
  D-031's name), D-036 (blocked reason: transition first, then offer). D-031 gains a pointer
  line rather than being rewritten.
- **`docs/tasks/M1-05-status-control.md`** — acceptance criteria ticked.
- **`docs/tasks/M1-04-menu-bar.md`** — a line recording that M1-05 landed first and what M1-04
  now inherits.
- **`docs/tasks/README.md`** — M1-05 ticked.

**`docs/REQUIREMENTS.md` is not amended.** Nothing here contradicts it: FR-3 asks for a cycle
shortcut and does not specify its order, §3.3 marks `blockedReason` optional, and §3.2's
transition rules are implemented as written. The cycle's exclusion of BLOCKED is an
implementation choice inside a silent spec, which `DECISIONS.md` says is exactly what belongs
there and not in the requirements.
