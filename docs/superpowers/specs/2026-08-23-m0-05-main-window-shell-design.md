# M0-05 — Main Window Shell — Design

**Task:** [`docs/tasks/M0-05-main-window-shell.md`](../../tasks/M0-05-main-window-shell.md)
**Requirements:** [FR-1.3](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-3](../../REQUIREMENTS.md#fr-3-main-window-p0),
[§3.1](../../REQUIREMENTS.md#31-project), [§3.2](../../REQUIREMENTS.md#32-taskitem),
[§3.3](../../REQUIREMENTS.md#33-event-append-only),
[§9.4](../../REQUIREMENTS.md#94-test-constraints),
[D9, D18](../../REQUIREMENTS.md#2-decisions-made-locked),
[§14](../../REQUIREMENTS.md#14-explicitly-cancelled-ios--cloud-sync)
**Branch:** `feat/main-window-shell`
**Date:** 2026-08-23

## Goal

The three-column window from FR-3, able to create and list projects and tasks — the M0 exit
criterion made visible.

This is the first UI in the repository, so it lands two patterns that every later UI task copies
rather than reinvents:

1. **How a view model reaches the store** (§1). ARCHITECTURE §2 rule 2 says views do not touch
   the store; §14 lists that separation as deliberately retained and not to be stripped.
2. **How a keyboard shortcut reaches an action** (§4). FR-3 requires a shortcut for every primary
   action, and the task file is explicit that M1-05 and M1-06 must extend this mechanism rather
   than invent a second one.

Everything else here is small. FR-3 is emphatic that this window should be the simple thing, and
D18 caps the dataset at under 20 live tasks.

---

## 1. The view model owns the `ModelContext`; views get nothing

Views declare no `@Query` and no `@Environment(\.modelContext)`. A single `@Observable`
`@MainActor` class in `StenoKit` holds the context, performs the fetches, and publishes
ready-to-render arrays.

```swift
@Observable @MainActor
public final class MainWindowModel {
    private let context: ModelContext
    public private(set) var projects: [Project] = []
    …
}
```

**Why, given `@Query` is the idiomatic SwiftUI answer.** `@Query` puts the fetch in the view,
which is precisely what ARCHITECTURE rule 2 forbids and what §14 marks as not-to-be-stripped. The
justification there is testability (§9.4), and it is real: a view model in `StenoKit` is reachable
from the headless, network-denied test bundle, while a `@Query` in `Steno/` is reachable only with
a window server this project's tests deliberately do not have (D-010). Every behaviour in this
task — grouping, the DONE window, project scoping, archive filtering, event appending — becomes a
unit test instead of a click-through.

**The structural consequence, which is the point.** Because no view needs it, the
`.modelContainer(container)` modifier is **removed** from `StenoApp`. Rule 2 then holds by
construction rather than by discipline: there is no route from a view to the store for a later
task to take by accident.

**The cost, accepted and recorded.** `@Query` refreshes automatically on insert and delete; a
manual fetch does not. Mutations that go through `MainWindowModel` reload themselves, so the
window is correct for everything this task can do. It is **not** correct across surfaces: when
M1-03's floating hotkey window or M1-04's menu-bar popover inserts a task while the main window is
open, this window will not notice until something calls `reload()`.

That gap is left open deliberately. No second surface exists yet, the fix depends on which
mechanism M1-03 chooses, and building speculative change-notification machinery now means
verifying and maintaining it through three tasks that may not want it. **M1-03 and M1-04 must
address it**; a `reload()` on window activation is the likely minimum. This paragraph exists so
that task discovers the requirement here instead of discovering the bug.

### 1.1 The units

Five files in `StenoKit/Features/MainWindow/`, split so the parts that need no context are
testable with no setup at all:

| Unit | Kind | Responsibility |
|---|---|---|
| `ProjectSelection` | `enum`, `Hashable` | `.all` or `.project(UUID)` — the sidebar's selection type |
| `TaskGrouping` | pure functions | `[TaskItem]` + a cutoff → `[TaskGroup]` in FR-3 order |
| `ProjectPalette` | pure functions | `colorHex(forIndex:)` — a fixed palette that cycles |
| `MainWindowActions` | `@MainActor` protocol | the actions the menu bar can invoke |
| `MainWindowModel` | `@Observable @MainActor` | owns the context, the selection, and every mutation |

`TaskGrouping` and `ProjectPalette` are deliberately not methods on the model. The FR-3 ordering
rule and the DONE cutoff are the two pieces of logic here worth testing exhaustively, and as free
functions they are tested against literal arrays with no container, no context, and no clock.

---

## 2. The interface

```swift
@MainActor
public protocol MainWindowActions: AnyObject {
    func newTask()                 // ⌘N
    func newProject()              // ⌘⇧N
    func selectNextProject()       // ⌘⌥↓
    func selectPreviousProject()   // ⌘⌥↑
}

@Observable @MainActor
public final class MainWindowModel: MainWindowActions {
    public private(set) var projects: [Project]     // non-archived, by sortOrder
    public private(set) var groups: [TaskGroup]     // for the current selection
    public private(set) var lastError: String?

    public var selection: ProjectSelection { didSet { reload() } }
    public var selectedTaskID: UUID?
    public var isPresentingNewProject: Bool

    public init(context: ModelContext, now: @escaping () -> Date = Date.init)

    public func createProject(named name: String)
    public func createTask(titled title: String)
    public func archive(projectID: UUID)
    public func reload()
}
```

`archive(projectID:)` is a model method and **not** a protocol action: it is invoked from a
specific sidebar row's context menu rather than from the current selection, and FR-3's list of
actions needing a shortcut does not include it.

`MainWindowActions` exists so the menu commands in the app target depend on an abstraction rather
than on the concrete model — and so M1-05 and M1-06 extend the *protocol* when they add an action,
which makes a missing implementation a compile error rather than a dead menu item.

The injected `now` closure is what makes §3.2's DONE window testable without sleeping or waiting
24 hours.

---

## 3. Data flow

### 3.1 Selection drives the list

`selection` is `.all` or `.project(id)`. Changing it triggers `reload()`, which fetches tasks and
passes them through `TaskGrouping`.

**What the fetch includes**, stated precisely because "all" is doing real work here:

- Tasks whose own `isArchived` is false. Nothing in this task archives a task, so this is
  vacuously true today; the predicate is written now so M1-05's UI cannot introduce ghosts later.
- Under `.project(id)`, tasks with that `projectID`.
- Under `.all`, tasks belonging to **non-archived projects only**. A task whose project has been
  archived disappears with it. The alternative — archiving a project but leaving its tasks visible
  under "All" — makes archiving useless, since the point is to get a finished project out of the
  way (§3.1).

Groups come back in FR-3's order: **IN-PROGRESS, BLOCKED, TODO, DONE**. This order is a
requirement, not a preference, and it is asserted in a test rather than left to the reading of the
enum's declaration order.

**Empty groups are omitted.** A fresh install shows one empty state rather than four empty
headers. DONE renders in a `DisclosureGroup`, collapsed by default per FR-3.

### 3.2 The DONE window is a stated placeholder

FR-3 says DONE shows only items completed within the current report window. That computation is
**M2-01's**, and does not exist yet. This task uses a fixed rule:

> A DONE task appears if `completedAt` is within 24 hours of `now()`.

**Why this is not a guess.** `Project.lastStandupAt` — the field the real window starts from
(D8, §3.1) — stays `nil` until M2-03 ships the Copy action that advances it. FR-4 step 2 makes the
first-run window 24 hours before now. So for every state reachable before M2-03, the placeholder
and the real rule return *the same answer*; the difference is that this one is one expression.

A `// TODO(M2-01)` at the call site names the task that replaces it. Anticipating M2-01's rule
inline was rejected: it duplicates logic M2-01 is meant to own, and under `.all` each task's window
would come from a different project, which is real complexity bought for no behavioural difference.

### 3.3 Creating a project

⌘⇧N sets `isPresentingNewProject`. The sheet is a single focused text field; **Return creates, Esc
cancels** — the same contract FR-1.1 sets for the capture window, established here so the app is
consistent before there are two of them.

`colorHex` is assigned by `ProjectPalette` from the project count. §3.1 describes the field as
visual identification in lists; no requirement asks the user to choose it, and FR-6's Settings
list does not include project colour. A picker is chrome FR-3 tells this task not to add.

### 3.4 Creating a task appends a `created` event

⌘N resolves a target project, inserts the `TaskItem`, **and appends a `created` event in the same
save**.

**The event is required, not an extra.** §3.3's EventKind table specifies `created` as written
when a task is created. A task without one is a hole in the append-only log that M2-01's gathering
would silently skip and M2.5-02's merge would reason from.

**Project resolution**, in order:

1. The selected project, when the selection is `.project(id)`.
2. Under `.all`, the first project by `sortOrder`. The created row displays its project, so the
   assignment is visible rather than silent.
3. With zero projects, ⌘N is disabled and the empty state directs the user to create a project.

Step 2 is a placeholder for FR-1.4's real rule — default to the last-used project — which **M1-02
owns**, along with the first-launch behaviour that task is told to decide. A `// TODO(M1-02)`
names it. Disabling ⌘N under `.all` was rejected outright: requiring a project selection before
text entry is the exact behaviour §1.1 and FR-1.4 call a defect, and this window is one of M1-02's
three capture surfaces (D15).

### 3.5 Archiving

The sidebar's context menu calls the existing `Project.setArchived(true, at:)`. The fetch
predicate excludes archived projects, so the row disappears from the sidebar while the record
remains — §3.1's "hidden but never deleted". There is deliberately no delete.

No "Show Archived" toggle: FR-3 describes no such control, and unarchiving has no requirement yet.

---

## 4. Keyboard: menu commands plus `@FocusedValue`

`MainWindowView` publishes the model as a scene-level focused value; a `Commands` struct in the
app target reads it and drives real menu-bar items.

```swift
// Steno/Features/MainWindow/MainWindowView.swift
.focusedSceneValue(\.mainWindowActions, model)

// Steno/App/MainWindowCommands.swift
struct MainWindowCommands: Commands {
    @FocusedValue(\.mainWindowActions) private var actions: (any MainWindowActions)?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { actions?.newTask() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("New Project") { actions?.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Next Project") { actions?.selectNextProject() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Project") { actions?.selectPreviousProject() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
        // M1-05 appends "Cycle Status" here; M1-06 appends "Add Note".
    }
}
```

**Switch-project is here because FR-3 names it.** FR-3's list of actions requiring a shortcut is
"new task, cycle status, add note, generate report, switch project". Three of those belong to
later tasks, but *switch project* is an action this task builds, so its shortcut ships here rather
than leaving FR-3 partially unmet by the very window that owns the switcher. Selection cycles
through `.all` and the non-archived projects in `sortOrder` order, wrapping at both ends — a pure
function over `projects`, and therefore tested.

**Why menu items rather than `.keyboardShortcut` on in-view buttons.** macOS convention is that a
shortcut which exists is listed in a menu; shortcuts bound only to buttons are undiscoverable and
are enumerated nowhere, so collisions are found by hand. More importantly, each later surface
would re-declare its own — the divergence the task file warns about.

**What this task establishes** is the `@FocusedValue` plumbing, which is the fiddly part. Adding
an action afterwards is one protocol method and one `Button`.

Shortcuts landed here: **⌘N** new task, **⌘⇧N** new project, **⌘⌥↓ / ⌘⌥↑** next/previous project,
and Return/Esc in the sheet.

**Verified.** The whole shape — `@Observable @MainActor` model holding a `ModelContext`, a
`@MainActor` protocol as a `FocusedValueKey.Value`, `focusedSceneValue`, and `@FocusedValue` read
inside a `Commands` builder — type-checks clean under
`swiftc -swift-version 6 -target arm64-apple-macos14.0`, with no warnings. Bare-letter shortcuts
(FR-2 suggests `N` for notes) are **not** settled here; a no-modifier menu shortcut risks
intercepting keystrokes destined for a text field, and M1-06 should decide that against real UI.

---

## 5. Error handling: roll back, then say so

Every mutation runs through one helper: apply, `save()`, and on a throw **`context.rollback()`**,
log to `Log.app.error`, and set `lastError`. Reload either way.

**The rollback is the load-bearing part.** Without it, a failed save leaves the inserted task in
the context, the reload finds it, and the window displays a task that is not on disk. That is the
lie the deleted `ContentView`'s own comment worried about, and it is the failure mode D-018
rejected for the store: for a capture tool, silently accepting a write that evaporates is worse
than refusing it, because the loss surfaces at the next stand-up.

`lastError` renders as a dismissible inline row, not an alert — an alert during capture is a modal
interruption, and §1.1 treats those as defects.

---

## 6. Layout

```
StenoKit/Features/MainWindow/
  ProjectSelection.swift
  TaskGrouping.swift           TaskGroup + the pure grouping/ordering/cutoff logic
  ProjectPalette.swift
  MainWindowActions.swift
  MainWindowModel.swift

Steno/Features/MainWindow/
  MainWindowView.swift         NavigationSplitView, .focusedSceneValue
  SidebarView.swift            "All" + projects, context-menu Archive
  TaskListView.swift           grouped List, DONE in a collapsed DisclosureGroup
  TaskDetailView.swift         title, status label, timeline
  NewProjectSheet.swift

Steno/App/
  MainWindowCommands.swift     new
  StenoApp.swift               modified — builds the model, attaches .commands,
                               drops .modelContainer
  ContentView.swift            DELETED
```

`ContentView.swift` is removed wholesale, as its own comment instructs. Its placeholder "Add
sample project" button was the only way to exercise M0-04's acceptance criterion before this task;
that job now belongs to the real sidebar.

**The app-target seam.** `MainWindowView` takes the `ModelContainer` in its initialiser and builds
the model exactly once via `_model = State(initialValue: MainWindowModel(context:
container.mainContext))`, so it is not rebuilt on every render. `StenoApp`'s existing `Result`
switch and its `StoreFailureView` branch are untouched — the only changes there are constructing
`MainWindowView` in place of `ContentView`, attaching `.commands`, and dropping
`.modelContainer`. This shape type-checks clean under Swift 6 with `-parse-as-library`.

---

## 7. Test plan

Headless, in `StenoTests`, using Swift Testing per D-011 and `StenoStore.inMemory()` where a
context is needed.

**Pure — no container:**

- Groups come back in the FR-3 order IN-PROGRESS, BLOCKED, TODO, DONE.
- A task completed 1 hour ago appears in DONE; one completed 30 hours ago does not.
- Empty groups are omitted.
- `ProjectPalette` cycles and never returns an empty hex.
- Project cycling advances through `.all` and the projects in `sortOrder`, and wraps at both ends.

**With an in-memory container:**

- Creating a project makes it appear in `projects`, and it is present in a fresh fetch.
- A newly created task is `todo` (§3.2's default) and appears under the TODO group.
- Creating a task appends **exactly one** `created` event, whose `taskID` matches.
- `.all` shows tasks from two different projects; `.project(a)` shows only A's.
- An archived project leaves `projects` **and** is still found by an unfiltered fetch — hidden,
  not deleted (§3.1).
- Archiving a project also removes its tasks from `.all` (§3.1 above).
- Under `.all` with two projects, a created task lands in the first by `sortOrder`.
- With zero projects, `createTask` is a no-op and records no partial state.

### 7.1 What the tests do not cover, and cannot

Acceptance criteria 1–4 are written as click-throughs. The logic beneath each is covered above;
the pixels are not, and on this machine cannot be.

`osascript` returns `-1719` (no Accessibility permission) and `screencapture` cannot create an
image from the display (no Screen Recording permission), both confirmed during M0-04. An agent can
neither click a control nor read the window. This is a macOS security control, not an obstacle to
route around.

**So the following are unverified by this PR and will be stated as such in its body:** that the
sidebar's create action is wired to `createProject`, that ⌘N and ⌘⇧N are actually bound, that the
sheet's Return/Esc behave, and that the three columns render as intended.

**What will be verified below the pixels**, following M0-04's pattern: a throwaway harness
compiled against the built `StenoKit`, driving `MainWindowModel` against the *real* store at
`~/Library/Application Support/Steno/`, run as two separate processes — create in one, read in the
next. That is acceptance criterion 1's durability claim proven across processes, at the real path,
through the shipping code. Plus `/usr/bin/log show --predicate 'subsystem ==
"com.lgabrielgr.steno"' --last 5m --info` to confirm which branch the launched app took.

The remaining user check is then a glance at a running app, not a procedure.

---

## 8. A disagreement with the task file, for the PR body

The task file lists "Detail pane showing title, status, and an **empty** event timeline."

It cannot be empty. REQUIREMENTS §3.3 requires a `created` event on every task — which is why
§3.4 of this document appends one — so every task carries exactly one event from the moment it
exists. A pane rendering "no events" would state something false about the log.

**Resolution taken:** the timeline renders the task's real events, reverse-chronological,
excluding redacted ones — today exactly one row per task. M1-06 extends it with note entry, the
5-minute correction window, and redaction UI; it is unaffected by this, since it inherits a
timeline that already reads the log correctly.

Per CLAUDE.md this is raised in the PR body rather than deviated from silently. No REQUIREMENTS.md
amendment is needed: the task file is what is imprecise, and REQUIREMENTS.md wins.

---

## 9. Out of scope

Held to the task file's list, and named here so review can check the diff against it:

- Quick capture and the global hotkey — M1-02, M1-03.
- **Status changes.** This task *displays* status; it never mutates it. The detail pane's status
  is a label, not a control — M1-05.
- Notes and a populated timeline — M1-06. (The timeline structure lands here per §8; note entry
  does not.)
- Stale badges — M6-02. FR-3 mentions badge counts in the sidebar; staleness does not exist until
  M6-01, so no badge is rendered.
- The "Prepare Stand-up" button — M2-03.
- Pagination, virtualization, search, filter chips — excluded permanently by D18 and FR-3, not
  deferred.
- Reordering projects by drag. `sortOrder` exists and is honoured; no UI sets it.
- Editing a project's name or colour after creation.
- Cross-surface refresh — §1, deferred to M1-03 with the reason recorded.

---

## 10. Risks

| Risk | Response |
|---|---|
| `@FocusedValue` returns `nil` when the window is key but focus sits in a text field, silently disabling ⌘N | `.focusedSceneValue` is scene-scoped rather than view-scoped for exactly this reason. Cannot be verified without pixels; called out in the PR body as a user check. |
| Manual reload drifts from the store once a second surface exists | Recorded in §1 as M1-03's inherited requirement, with the likely fix named. |
| The 24h DONE rule diverges from FR-3 once M2-01 lands | Behaviourally identical until M2-03 advances `lastStandupAt` (§3.2); `TODO(M2-01)` at the call site. |
| The pattern established here is wrong and three tasks copy it | It is the pattern ARCHITECTURE §2 and §14 already prescribe; this task implements the existing decision rather than making a new one. |

---

## 11. What this lands beyond code

- The first entry in `Steno/Features/` and `StenoKit/Features/`, establishing the paired layout
  ARCHITECTURE §5 describes but nothing has yet used.
- ARCHITECTURE.md updated: the `Features/` rows move from planned to existing, per that file's
  standing instruction to update it in the PR that lands the structure.
- A DECISIONS.md entry for the view-model/store pattern and the `@FocusedValue` command
  mechanism — the two choices later tasks will otherwise relitigate.
- `docs/tasks/README.md`: M0-05 ticked once merged, and M0's exit criterion met.
