# M0-05 — Main Window Shell

**Milestone:** M0 — Skeleton
**Depends on:** M0-04
**Blocks:** M0 exit criterion, M1-05
**Requirements:** FR-1.3, FR-3, D9, D18
**Branch:** `feat/main-window-shell`

## Goal

The three-column main window, able to create and list projects and tasks — the M0 exit
criterion made visible.

## In scope

- Three-column layout per FR-3: sidebar (flat project list with an "All" pseudo-project),
  task list, detail pane.
- Create a project; create a task; both persist.
- Task list grouped by status in the FR-3 order: IN-PROGRESS, BLOCKED, TODO, DONE.
- Detail pane showing title, status, and an empty event timeline.

## Out of scope

- Quick capture and the hotkey — M1-02, M1-03.
- Status *changes* — M1-05. This task displays status; it does not mutate it.
- Notes and a populated timeline — M1-06.
- Stale badges — M6-02.
- The "Prepare Stand-up" button — M2-03.

## Acceptance criteria

- [ ] A project created in the sidebar persists across relaunch.
- [ ] A task created under a project appears in the correct status group.
- [ ] The "All" pseudo-project shows tasks across every project.
- [ ] Archived projects are hidden but not deleted.
- [ ] `make build && make test && make lint` green.

## Notes for the spec/plan phase

- **Build the simple thing.** D18 caps this at under 20 live tasks, and FR-3 is emphatic: a
  plain `List`, no pagination, no virtualization, no search, no filter chips. "If the task list
  ever needs a scrollbar the user has a workflow problem, not a UI problem." Resist adding
  these; a PR that includes them should be trimmed.
- FR-3 requires a shortcut for every primary action. Not all actions exist yet — establish the
  keyboard-handling pattern here so M1-05 and M1-06 extend it rather than inventing a second
  one.
- D9: flat list, no epics, no nesting. There is no hierarchy to model.
- Keep view models separate from views. §14 lists this separation as deliberately retained and
  not to be stripped — it is justified on testability grounds alone (§9.4).
- DONE is collapsed by default and shows only items completed within the current report window
  (FR-3). The window computation does not exist until M2-01; for now, scope it to a
  simple recent-completions rule and leave a note pointing at M2-01.