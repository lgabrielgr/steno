# M2.5-03 — Import Preview & Replace Mode: design

**Date:** 2026-09-14 · **Task:** [`M2.5-03`](../../tasks/M2.5-03-import-preview-ui.md) ·
**Requirements:** §10.1, §10.2, §10.4, §10.5 · **Branch:** `feat/import-preview-ui`

## What this builds

`File ▸ Export…`, `File ▸ Import…`, and a separate `File ▸ Replace All Data from File…`.
Import shows §10.4's cancellable preview of exactly what it will change. Replace wipes the
local store, requires typed confirmation, and writes a backup export before touching a row.

M2.5-02 already built the engine. `ImportService.plan(_:)` returns an `ImportPlan` carrying
§10.4's three count categories per record type, the `statusChanged` list behind the
requirement's parenthetical, the write set `apply` will use, and `isEmpty` for "nothing to
import". `apply(_:)` writes that same plan's `merged` store in a scratch `ModelContext` and
refuses a plan whose store has moved. This task is the surface over that engine, plus the one
operation the product has never had: deletion.

## Two tensions, stated rather than resolved silently

**Replace deletes `Event` rows, and CLAUDE.md's non-negotiable #3 says the event log is
append-only with no exceptions.** §10.1 sanctions the wipe in as many words ("wipes the local
store first"), so the tension is between two parts of the source of truth, not between the
requirement and this design. It is handled as a sanctioned exception confined to the Replace
path: the deletion phase iterates `ImportPlan.deletions`, which merge mode cannot populate, and
a test asserts that emptiness across every merge fixture in the suite. A `DECISIONS.md` entry
records the exception rather than leaving a future reader to find a deletion in an append-only
store and conclude the invariant rotted.

**This task freezes §10.2's timestamp semantics.** It is the first thing in the product to
write export bytes to disk. From the moment it ships, `schemaVersion: 1` files exist in the
world and the millisecond-rounding rule D-101 established can no longer change meaning without
a version bump and a second quantizer retained permanently for v1 files. Nothing here changes
the quantizer; this is a note that the window for free changes closes with this PR.

## Architecture

### One plan type, one apply, two modes

`ImportMode` is a new public enum — `.merge` / `.replace` — and `ImportService.plan(_:mode:)`
takes it, defaulting to `.merge` so every M2.5-02 caller and test is unchanged.

In `.replace`, `plan` does everything it does today — the `hasChanges` guard, `ImportReader`,
`validateShape` on both sides, `wireNormalized` on the incoming side — and substitutes exactly
one input to the merge: `local` becomes an empty `MergedStore()`. Three consequences fall out
of that one substitution rather than being written separately:

- **Closure (D-102) is checked against the file alone.** Correct for Replace, because the store
  those references would otherwise resolve against is about to be gone.
- **`status` and `lastStandupAt` are still derived** (D-100, D-099), now over the file's own
  events and reports. A hand-edited file whose `status` field disagrees with its own event log
  installs the log's answer.
- **The sticky-true flag merge (D-098) is a no-op** against an empty side, which is what it
  should be when there is no local opinion to preserve.

`plan.source` still records the **real** local snapshot, so `apply`'s staleness check is
unchanged and still guards the gap while the confirmation sheet is open.

The alternative — a separate `ReplaceService` planning against an empty store — was rejected
because it cannot produce a useful preview. Diffing the file against an empty store reports
every record as new, including the ones already present, so Replace would either get a worse
preview than merge or need a second diff implementation. M2.5-04's CLI would then drive two
services instead of one.

### `ImportPlan` gains deletions and an origin

`ImportPlan.deletions` is a second `Writes` value: the local ids absent from the merged store.
`ImportPlan.diff` currently walks `merged` and buckets each record; it gains a pass over
`local` collecting ids the merged store lacks.

**In merge mode this set is empty by construction**, because the merged store is a union of
both sides. That turns §10.1's "non-destructive by default" from a promise in prose into a
value a test asserts on every merge fixture.

`Counts` is **unchanged** — it keeps `inserted`/`updated`/`unchanged` and gains no `deleted`
field. A per-type deletion count is already `deletions.<type>.count`, and storing it a second
time inside `Counts` would be two representations of one fact that can drift apart; the preview
reads the sets. What does change is `ImportPlan.isEmpty`, which now additionally requires every
`deletions` set to be empty — otherwise a Replace that only deletes rows reads as nothing to do,
and `isEmpty` would suppress the one preview that most needs showing.

`ImportPlan` also picks up the envelope's `exportedAt`, `exportedBy` and
`includesCachedExternalData`. The task asks the summary to be specific enough to catch
importing the wrong file, and counts alone are not: twelve new tasks looks identical whichever
file produced them. A provenance line is what catches last month's export.

### `apply` gains a deletion phase

Before the five write phases and inside the same scratch-context rollback, `apply` deletes the
ids in `plan.deletions`. Order is reports, refs, events, tasks, projects — children first, so
the one real SwiftData relationship (`TaskItem.sourceRefs` ⟷ `SourceRef.task`, default nullify
rule) never churns a row that is itself about to be deleted.

The phase is unreachable outside Replace because merge-mode plans cannot populate `deletions`.

### `BackupWriter`

New, small, in `StenoKit/Portability`. Resolves `~/Library/Application Support/Steno/Backups/`,
creates it, and writes `steno-backup-YYYY-MM-DD-HHmmss.json` from an `ExportEncoder` with
`includesCachedExternalData: true`. Directory and clock are injected so the headless bundle
writes to a temp directory and can assert the filename.

**`includesCachedExternalData: true` is not optional on this path.** A backup that silently
drops `cachedSummary` and `lastFetchedAt` is not a snapshot anyone can restore from, and
`ImportService.localStore()` already makes this exact argument for the same fields. It is
independent of the export panel's checkbox, which governs only user-initiated exports.

It **throws** rather than returning an optional. "Fails safe if the backup cannot be written"
means the Replace flow aborts on that throw with the store untouched, and a throw is the shape
that makes forgetting to check impossible.

### Surfaces

**`FilePanels`** — a protocol in `StenoKit/Portability` with two methods: choose an export
destination (given a default filename, returning a URL and the cached-data checkbox state) and
choose an import source (returning a URL). `AppKitFilePanels` implements it with `NSSavePanel`
and `NSOpenPanel` run via `runModal()`, the save panel carrying the accessory checkbox. App-modal
rather than sheeted, so the panels need no `NSWindow` reference.

The default injected everywhere except `StenoApp` is `UnavailableFilePanels`, which opens
nothing and reports an error. The test bundle is unhosted with no window server (D-010), and a
test reaching a real `NSOpenPanel` would **hang** the suite rather than fail it. The unavailable
implementation is loud rather than silent, so a wiring mistake in the app surfaces as a banner
instead of a dead menu item.

**`ImportPreviewModel`** — `StenoKit/Features/MainWindow/`, modelled on `StandupDraftModel`:
`@Observable`, `@MainActor`, holding no reference back to `MainWindowModel` and receiving its
inputs as parameters. It holds the `ImportPlan`, the source filename, the `ImportMode`, a
`phase` of `.previewing` / `.applied` / `.nothingToImport`, the typed `confirmation` string,
and separate `lastError` and `notice` properties — a failed apply and a succeeded apply with
something to say are different facts, and `StandupDraftModel` records why one field cannot
carry both.

`canApply` is `!plan.isEmpty` in merge mode, and additionally `confirmation == "REPLACE"` in
replace mode. Case-sensitive, and the word rather than the filename: retyping a filename is a
transcription exercise that trains the user to paste through the guard.

**`MainWindowModel+Portability.swift`** — a new extension file following the `+Standup` /
`+Notes` split. It owns `exportStore()` (panel → `ExportEncoder.encode()` → write → notice
carrying the path), `beginImport(mode:)` (panel → `plan(_:mode:)` → populate the preview model →
`activeSheet = .importPreview`), and the apply path, which calls `BackupWriter` first when the
mode is `.replace` and aborts on its throw.

`ActiveSheet` gains `.importPreview`, carrying no payload — the mode and plan live in the
preview model, for the reason `.standupDraft` carries no project id.

**`MainWindowActions`** gains `exportStore()`, `importStore()`, `replaceStoreFromFile()` and a
`canExchangeData` gate. The gate is `activeSheet == nil`: the store-failed case already disables
these items, because `StenoApp` builds no `MainWindowView` and the menu's `@FocusedValue` is then
nil. What it actually prevents is a keyboard shortcut opening a file panel on top of an open
sheet — including on top of the import preview itself.
**`MainWindowCommands`** gains a `CommandGroup(after: .newItem)` with
Export…, Import…, a divider, and Replace All Data from File…. Each button calls
`MainWindowReveal.reveal()` first, so the sheet has somewhere to render when the user lives in
the menu-bar popover with the main window closed.

**`MainWindowModel.lastNotice`** — new, rendered as a second inline row beside the existing
error banner, dismissible. Export's only output is "the file went here" and it needs a home
that is not `lastError`. Inline rather than an alert, per §1.1 and the existing banner's own
comment.

**`ImportPreviewSheet`** — `Steno/Features/MainWindow/`, layout only, no logic. GUI verification
is unavailable to agents, so anything assertable lives in the model.

## Data flow

**Export.** Menu → reveal → `FilePanels.chooseExportDestination(defaultName:)` with
`ExportFilename` supplying the name → `ExportEncoder(includesCachedExternalData:)` per the
checkbox → `encode()` → write → `lastNotice` carries the path. Cancelled panel does nothing
and says nothing.

**Import (merge).** Menu → reveal → choose source → read → `plan(data, mode: .merge)` → sheet
with the preview → Import → `apply(plan)` → `.stenoDidWrite` → the window reloads through the
path every write in this app already takes (D-019).

**Replace.** Menu → reveal → choose source → `plan(data, mode: .replace)` → sheet with the
destructive preview and the confirmation field → user types `REPLACE` → **`BackupWriter.write()`**
→ `apply(plan)` → `.stenoDidWrite`.

The ordering is the whole safety argument: the backup is a separate file write that completes
before a single row is touched, and its throw aborts with the store untouched. Nothing about the
wipe is reachable before that write returns.

## The preview

Merge, §10.4's shape, with zero-count types omitted:

```
Import steno-export-2026-08-10.json?
Written 10 Aug 2026 at 14:22 by steno/0.1.0 (macOS)
  + 12 new tasks, 3 new projects, 148 new events
  ~ 4 tasks updated (status changed on the other machine)
  = 61 records already present, skipped
```

The status parenthetical renders only when `plan.statusChanged` is non-empty — it is the plan's
own field, not an inference. References and reports appear on the same lines when they have
counts; §10.4's example illustrates three categories, not five types.

Replace, same counts, destructive framing, deletion first:

```
Replace everything on this Mac with steno-export-2026-08-10.json?
Written 10 Aug 2026 at 14:22 by steno/0.1.0 (macOS)
  − 74 tasks, 2 projects, 902 events, 12 references, 40 reports will be deleted
  + 12 new tasks, 3 new projects, 148 new events
  ~ 4 tasks updated
  = 61 records already present, kept as the file has them
A backup will be written first to
~/Library/Application Support/Steno/Backups/steno-backup-2026-09-14-142205.json
```

The backup path appears **before** the user commits, not only afterwards: that there is a way
back is information they need while deciding, not a consolation afterwards.

Replace is never the path of least resistance — it is a separate menu item below a divider, it
cannot be reached from the Import… flow at all, and its confirm button is dead until the word
is typed exactly.

## Error handling

| Failure | Where it surfaces | State of the store |
|---|---|---|
| Malformed / bad schema version / dangling ref / inconsistent record | Raised by `plan`; sheet never opens; `ImportError.message` in the error banner | Untouched, nothing attempted |
| Nothing to import | Sheet opens and says so | Untouched |
| Backup write fails | Error naming the path and reason; sheet stays open | Untouched, deletion phase never ran |
| Store moved while the sheet was up | `ImportError.storeChanged`, whose message already says to reopen the file | Untouched |
| Save fails mid-apply | Existing scratch-context rollback, `.saveFailed` | Untouched |
| Export panel cancelled | Nothing | Untouched |
| Export write fails | Error banner | Untouched |

In Replace, `.storeChanged` arrives after the backup was written, leaving a backup file for a
replace that did not happen. Accepted deliberately rather than pre-checked: a spare backup is
never the wrong outcome, and the alternative is a second staleness read that can itself go
stale between the check and the write.

**Cancel** dismisses the sheet and clears the preview model, as `StandupDraftModel.dismiss()`
does. No store access happens on that path at all, which is the strongest available form of
"cancelling changes nothing".

## Testing

GUI verification is unavailable to agents, so everything assertable lives in
`ImportPreviewModel` and the portability layer, and the sheet is layout with no logic.

- **Preview counts match what the import does.** The easy version of this is fake: comparing
  `plan.counts` against `ImportPlan.diff`'s own output proves nothing. The real test snapshots
  the store before and after `apply`, derives the actual per-type
  inserted/updated/unchanged/deleted from those snapshots by an independent route, and compares
  that to the plan. Both modes.
- **Cancelling changes nothing.** `plan()` against a populated store, then assert the snapshot
  is identical and `WriteCounter` saw zero saves. The absence of a save is the assertion.
- **Merge never deletes.** `deletions` empty across every merge fixture in the suite. This is
  §10.1's guarantee and the append-only guard in one property, stated over the fixture set
  rather than one case.
- **Replace installs the file exactly**, checked in **both directions**: nothing in the store
  the file lacks, and nothing in the file missing from the store. A one-directional check
  cannot see a row that should have been deleted and was not — precisely the Replace bug worth
  catching.
- **Replace fails safe.** Inject a throwing `BackupWriter`; assert the store is untouched and
  specifically that the deletion phase never ran.
- **The backup is full fidelity.** A fixture with `cachedSummary` and `lastFetchedAt`, asserted
  present in the backup file. This catches `includesCachedExternalData` defaulting to `false`
  on that path — silent data loss with no symptom until someone restores.
- **Typed confirmation.** `canApply` false for `"replace"`, `"Replace"`, `"REPLACE "`, empty;
  true only for `"REPLACE"`. False in replace mode regardless of confirmation when the plan is
  empty.
- **Preview strings.** Golden tests in the style of `RawReportGoldenTests`: zero-count omission,
  the `statusChanged` parenthetical appearing only when the plan has one, the provenance line.
- **Panels unreachable from tests.** The default `FilePanels` is `UnavailableFilePanels`,
  asserted, so no test can open a modal panel and hang the suite.

**Every new test gets a mutation pass**, with the mutation named per test in the implementation
plan — delete the deletion phase, flip `includesCachedExternalData` to false, relax the
confirmation comparison to case-insensitive, drop the second direction of the replace equality
check. The pass runs against a clean tree with untracked files accounted for and reads build
results by exit status rather than by grepping output.

**Ordering trap avoided:** fixtures whose input order already matches the expected order prove
nothing about ordering. Replace fixtures get input deliberately shuffled against expected
output.

## Manual verification (PR body)

Only the user can confirm these:

- The File menu items appear in the right places, with the divider above Replace.
- The save panel's checkbox renders and is off by default.
- Import… with the main window closed reveals it and then sheets.
- The Replace confirmation field does not let Return through to a default button.

## Out of scope

Merge logic (M2.5-02, done). CLI (M2.5-04). Auto-export scheduling (M2.5-05). No change to the
timestamp quantizer — see the freeze note above.
