# M1-06 — Progress Notes & Timeline — Design

**Task:** [`docs/tasks/M1-06-progress-notes.md`](../../tasks/M1-06-progress-notes.md)
**Requirements:** [FR-2](../../REQUIREMENTS.md#fr-2-progress-notes-p0),
[FR-1.5](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-3](../../REQUIREMENTS.md#fr-3-main-window-p0),
[§3.3](../../REQUIREMENTS.md#33-event-append-only),
[§3.4](../../REQUIREMENTS.md#34-sourceref),
[§1.1](../../REQUIREMENTS.md#11-primary-risk),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents),
[D10, D18](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/progress-notes`
**Date:** 2026-09-02

## Goal

Append-only progress notes, a reverse-chronological timeline, and FR-2's five-minute correction
window implemented as redact-and-reappend rather than mutation.

This is the task where the append-only invariant is most tempting to violate, because in-place
editing is genuinely three lines shorter. The design's job is to make the shorter path
unavailable rather than merely discouraged.

---

## 1. What this task inherits, and must not rebuild

| Inherited | From | Why it is reused rather than rebuilt |
|---|---|---|
| `Event` with every field `private(set)` and `redact()` its only mutator | M0-03 | The invariant is already expressed as API. Nothing here adds a setter |
| `StatusService`'s shape — `@MainActor` struct, injected `now`/`save`, `commit()` that rolls back and posts | M1-05 (D-033) | `NoteService` is its sibling. A second, differently-shaped write path is how the two drift |
| `ReferenceExtractor.extract(from:)` | M1-01 | FR-1.5 covers note bodies. Extraction is not re-implemented for notes |
| `SourceRef.newRefs(from:existing:)` | M0-03 | Its doc comment already names this task: "M1-06's note path is its real first caller" |
| `MainWindowModel.selectedTaskEvents` and `selectedTaskTimelineFailed` | M0-05 | Both were built for this task. `reload()` already calls `reloadSelectedTaskEvents()` unconditionally, with a comment saying "M1-06 appending a note is exactly that case" |
| `MainWindowActions` + `MainWindowCommands` | M0-05 | Its doc comment: "M1-06 adds 'Add Note': one method on `MainWindowActions`, one `Button` here" |
| `CaptureFieldModel`'s "logic in StenoKit, layout in `Steno/`" split | M1-02 | D-010: views need a window server, so anything a test must reach lives outside them |

---

## 2. The units

| File | What it is | Testable headless |
|---|---|---|
| `StenoKit/Models/EventKind.swift` | **Amend.** `isUserAuthored` | Pure — no container |
| `StenoKit/Models/EventQueries.swift` | **Create.** The redaction-excluding descriptors | Container |
| `StenoKit/Notes/NoteCorrection.swift` | **Create.** FR-2's window as a pure rule | Pure — no container, no clock |
| `StenoKit/Notes/NoteService.swift` | **Create.** Add, correct, redact | Container |
| `StenoKit/Features/MainWindow/NoteComposerMode.swift` | **Create.** Adding vs correcting | Pure |
| `StenoKit/Features/MainWindow/MainWindowModel+Notes.swift` | **Create.** The window's note actions and composer state | Container |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | **Amend.** `fetchEvents` routes through `EventQueries`; correctability recomputed on reload | Container |
| `StenoKit/Features/MainWindow/MainWindowActions.swift` | **Amend.** `addNoteToSelection()`, `canAddNote` | — |
| `Steno/Features/MainWindow/NoteComposerView.swift` | **Create.** The multi-line composer | No — view |
| `Steno/Features/MainWindow/TimelineRowView.swift` | **Create.** One event row with its affordances | No — view |
| `Steno/Features/MainWindow/TaskDetailView.swift` | **Amend.** Hosts the composer above the timeline | No — view |
| `Steno/Features/MainWindow/TaskListView.swift` | **Amend.** `.onKeyPress("n")` | No — view |
| `Steno/App/MainWindowCommands.swift` | **Amend.** "Add Note" ⌘⇧A in the Task menu | No — view |

`MainWindowModel+Notes.swift` is a separate file for the reason `+Status.swift` already is:
SwiftLint's `file_length` limit, not a change in what belongs to the type.

`StenoKit/Notes/` is a new directory and needs no `project.yml` change — XcodeGen globs
`path: StenoKit` wholesale. `make generate` picks it up.

---

## 3. `NoteCorrection` — FR-2's window as a rule

```
public enum NoteCorrection {
    public static let window: TimeInterval = 5 * 60
    public static func isCorrectable(
        kind: EventKind, timestamp: Date, isRedacted: Bool, at instant: Date
    ) -> Bool
}
```

Pure, container-free, clock-free. It takes the four facts it needs rather than an `Event`, so
every branch is testable against literals — which matters because two acceptance criteria are
statements about this function and nothing else.

The rule: `kind.isUserAuthored && !isRedacted && instant.timeIntervalSince(timestamp) < window`.

**There is deliberately no lower bound on the age.** An event timestamped slightly in the future
— clock jitter, or a §10 import from a Mac whose clock runs fast — yields a negative interval and
stays correctable. Rejecting negative ages instead would make a note one second in the future
permanently uncorrectable, which is both more likely and worse than the alternative it prevents.

**`EventKind.isUserAuthored`** is `true` for `.note` and `.blockedReason`, `false` for `created`,
`statusChanged`, `externalUpdate`, and `standupReported`. It is a single computed property with a
`switch` over every case — never a `default` — so adding a kind in M4-01 is a compile error here
rather than a silent "not user-authored".

That list is the only place the answer lives — the service, the view, and the tests all read it
rather than each spelling out a pair of cases. It earns a `DECISIONS.md` entry during
implementation; the number is assigned then, since this task raises several and D-043 is the
current high-water mark.

### 3.1 The window does not restart, and that is free

The replacement event carries the **original's timestamp** (FR-2), and eligibility is measured
from `event.timestamp`. So a note written at T and corrected at T+2m leaves three minutes, not
five, and no chain of corrections reaches past T+5m.

This is the correct behaviour and it required no code. The alternative — restarting the clock per
correction — is not merely undesirable, it is unrepresentable: `Event` has no field distinguishing
"when this row was written" from "when the note happened", and adding one to enable a worse
behaviour is not a trade worth making.

---

## 4. `NoteService` — the writes

`@MainActor` struct, `context` / `now` / `save` injected, exactly as `StatusService` and
`CaptureService` are, and for the same three reasons: `ModelContext` is not `Sendable`, timestamps
must be assertable, and a real `ModelContext` cannot be made to fail its save on demand.

```
@discardableResult addNote(_ text: String, to task: TaskItem) throws -> Event?
                   correct(_ event: Event, to text: String, on task: TaskItem) throws -> CorrectionOutcome
@discardableResult redact(_ event: Event) throws -> Bool
```

### 4.1 `addNote`

Trim; empty returns `nil` having written nothing — a surface committing an untouched field is not
a failure worth reporting, matching `CaptureService.capture`. Otherwise: stamp once from `now()`,
insert one `.note` event, run extraction, `commit()`.

**It does not stamp `task.modifiedAt`.** `TaskItem.setStatus` already declines to, on the grounds
that status is derived from the event log; a note is the same kind of fact. Stamping it would make
a task that only gained a note outrank, in §10.1's "later `modifiedAt` wins" merge, a task whose
title was genuinely edited on another Mac.

### 4.2 `correct`

```
public enum CorrectionOutcome: Equatable {
    case corrected        // original redacted, replacement appended
    case unchanged        // blank, or identical to the original — nothing written
    case windowExpired    // nothing written; the caller still holds the user's text
    case notCorrectable   // wrong kind, or already redacted
}
```

The body, in order:

1. `guard NoteCorrection.isCorrectable(...)` — `.windowExpired` if the age failed,
   `.notCorrectable` if the kind or the redaction flag did. Two outcomes rather than one because
   the UI's response differs: expiry keeps the draft and offers to append it; a wrong kind is a
   programming error the UI should never have offered.
2. Trim. Blank or byte-identical to `event.body` → `.unchanged`, nothing written. An emptied
   correction is **not** silently converted into a redaction: making the destructive, one-way
   operation the outcome of clearing a text field is exactly the kind of surprise `Event` has no
   `unredact()` to recover from.
3. `event.redact()`.
4. Insert a **new** `Event` with a fresh `id`, `taskID: event.taskID`,
   `timestamp: event.timestamp`, `kind: event.kind`, `body: trimmed`.
5. Extract refs from the corrected body; insert the ones `newRefs` says are new.
6. `commit()`.

**Step 4 carries the original's `kind`, not `.note`.** FR-2 says "append a new `note` event"
because it was written before `blockedReason` was correctable. Hard-coding `.note` would turn a
corrected blocked reason into a note, which changes what M2-02 renders it under and what §3.3 says
the row means. See §9.1 — this is a spec deviation and the PR body must say so.

**The original is untouched.** `id`, `taskID`, `timestamp`, `kind`, `body`, and `payload` are all
`private(set)` on `Event`, so writing to any of them from `NoteService` is a compile error, not a
convention. `redact()` is `internal`, so it is reachable from StenoKit and unreachable from the app
target.

### 4.3 `redact`

Guards `kind.isUserAuthored && !isRedacted`, flips the flag, commits, returns whether it wrote.
Returning `false` rather than throwing for an ineligible event matches `StatusService.setStatus`'s
no-op contract: nothing written, nothing to reload.

### 4.4 `commit()`

Verbatim `StatusService.commit()`: `save`, `context.rollback()` and rethrow on failure, post
`.stenoDidWrite` **after** the save lands. The rollback is what keeps the `isRedacted` flip off
disk when the save fails — see §7.1 for the half of that which rollback does not solve.

---

## 5. `EventQueries` — the exclusion as a property of the query

The task file is explicit: redaction "hides an event from summaries (§3.3). M2-01's gathering and
M3-03's prompt both need to honor that — make the exclusion a property of the query, not of each
caller."

Today `MainWindowModel.fetchEvents(forTaskID:)` inlines `!$0.isRedacted`. It moves:

```
public enum EventQueries {
    public static func timeline(forTaskID id: UUID) -> FetchDescriptor<Event>
}
```

`MainWindowModel` calls it instead of building its own descriptor, and M2-01 adds its
window-gathering descriptor beside it rather than re-deriving the rule. That task names its own
API; what this one fixes is the location. One predicate, one place to get the exclusion wrong.

The predicate stays `UUID == UUID && !Bool`. It does **not** filter on `kind`: an enum inside a
SwiftData `#Predicate` does not compile — both spellings fail, with different errors — so any
kind-based filtering happens in memory after the fetch. D18 caps the dataset, so the fetch is the
cost and the filter is free.

**Ties are possible and benign.** A correction gives its replacement the original's timestamp, so
two rows can share one instant — but the original is redacted and this descriptor excludes it, so
the two never both appear. `SortDescriptor` cannot break the tie by `id` regardless: `UUID` is not
`Comparable`. Left alone deliberately rather than papered over.

---

## 6. The window's state and its UI

### 6.1 `MainWindowModel+Notes`

```
public var noteDraft: String
public private(set) var noteMode: NoteComposerMode   // .adding | .correcting(eventID: UUID)
public private(set) var noteNotice: String?          // the expiry fallback message
public private(set) var correctableEventIDs: Set<UUID>
public var canCommitNote: Bool
public var canAddNote: Bool

public func beginCorrection(of eventID: UUID)
public func cancelNoteEntry()
public func commitNote()
public func redactEvent(_ eventID: UUID)
public func refreshCorrectability()
```

`correctableEventIDs` is recomputed from `selectedTaskEvents` and `now()` inside
`reloadSelectedTaskEvents()`, so it can never describe a task other than the selected one.

`commitNote()` switches on `noteMode`: `.adding` calls `addNote`, `.correcting` calls `correct`
and interprets the outcome. Both paths clear the draft **only** on a write that actually happened.

### 6.2 The composer

An always-visible multi-line `TextEditor` above the timeline whenever a task is selected. No
modal at any point — §1.1 treats a modal interruption as a defect, and while a note is not the
quick-capture path, the same reasoning applies to the surface the user reaches for all day.

`⌘↩` commits. In `.correcting` mode the composer shows which note it is correcting, alongside a
Cancel.

**Who discards the draft, and who keeps it, follows one rule: the user cancelling discards, the
system refusing does not.**

| Event | Draft | Mode after |
|---|---|---|
| `Esc` while adding | Cleared, focus returns to the task list | `.adding` |
| `Esc` or Cancel while correcting | Cleared — the abandoned correction does not become a new note's draft | `.adding` |
| Save failed (§7.1) | **Kept** — retry, don't retype | unchanged |
| Window expired (§7.2) | **Kept** — offered as a new note | `.adding` |

The asymmetry is the point. A user who pressed Esc has said what they want; a user whose write was
refused has not.

### 6.3 The timeline rows

`TimelineRowView` renders body, timestamp, and — for user-authored, non-redacted rows only:

- **"Correct"**, present only while the row's id is in `correctableEventIDs`, and gone after five
  minutes. This makes the criterion "after 5 minutes, editing is unavailable" visible, not merely
  true.
- **"Redact…"** in a context menu, always available, behind a confirmation. `Event` has no
  `unredact()`; a one-way action reachable by a single misclick is a defect. The context menu
  follows `TaskListView`'s precedent of a context menu over an always-visible per-row control.

For the button to vanish on time, something must tick. `MainWindowModel` holds a `Timer` started
only when `correctableEventIDs` is non-empty and invalidated when it empties; its fire calls
`refreshCorrectability()`. The rule and the recompute are unit-tested with an injected clock. **The
timer's scheduling is not tested** — it needs a live run loop — and §8 says so rather than implying
coverage that does not exist.

### 6.4 The shortcuts

FR-2 asks for note entry in one keystroke and suggests `N`.

A plain-letter **menu** key equivalent is not usable here. On macOS the main menu gets first crack
at key-downs and `NSTextView` does not consume plain characters as key equivalents, so a bare `N`
in the Task menu would fire while the user typed the letter "n" into the quick-capture field, the
New Task sheet, or the note composer itself — the §1.1 degradation this repo forbids.

So the keystroke lands in two places:

- **`N`** on `TaskListView` via `.onKeyPress`, which routes through the responder chain and so
  fires only when the list itself holds focus. No text field is ever hijacked. Typechecked against
  the macOS 14.0 floor before this was written down.
- **⌘⇧A "Add Note"** in the Task menu beside Cycle Status and Mark Blocked — one method on
  `MainWindowActions`, one `Button` in `MainWindowCommands`, exactly as that file anticipated.

Both do the same thing: focus the composer. This is a documented deviation from
`MainWindowCommands`'s "shortcuts belong in menus" convention; see §9.2.

---

## 7. Failure handling

Two failures lose the user's text if handled naively. Neither may.

### 7.1 The save fails

`commit()` rolls back, so nothing reaches disk — but **`rollback()` does not restore the in-memory
object**. As `StatusService`'s doc comment already records, the held instance keeps the rejected
value until a fetch refreshes it. For a correction that means the in-memory `Event` still reports
`isRedacted == true`, and the timeline would hide a note the store still has.

Every catch block in `MainWindowModel+Notes` therefore calls `reload()`, and it is that refetch,
not the rollback, that makes the row reappear. This is the same trap `MainWindowModel+Status`
documents; it is restated here because the consequence is different and worse — a status reverts
visibly, a note simply vanishes.

The draft is kept on failure, mirroring `CaptureFieldModel`: "the text is kept when this is
non-nil, so the user can retry rather than retype."

### 7.2 The window expires mid-correction

The user begins correcting at 4m58s and types for a minute. `correct` returns `.windowExpired`
having written nothing.

The composer keeps the text, drops to `.adding`, and sets `noteNotice`:

> That note can no longer be corrected — ⌘↩ adds this as a new note instead.

Nothing is lost, the original stays visible and unredacted, and the invariant is untouched. The
alternative — extending the window because the sheet was open — makes the five minutes mean
nothing.

---

## 8. Testing

Container tests build their own `ModelContext(container)`; never `mainContext`, which does not
retain its container.

### 8.1 The invariant test

Acceptance criterion 2 is the reason this task exists, and asserting it per-method is too weak.
Instead: a helper snapshots `(id, taskID, timestamp, kind, body, payload)` for **every** `Event`
row in the store, and a test runs each operation — `addNote`, `correct`, `redact`,
`StatusService.setStatus`, `addBlockedReason` — asserting that across the whole store the only
field that ever differs between snapshots is `isRedacted`, and that no row ever disappears.

**This test will be verified by mutation before it is trusted:** `correct` is temporarily changed
to write the corrected body in place, and the test must go red. A test that cannot fail is this
repo's recurring defect, and this is the single test most likely to be one.

### 8.2 The rest

| Area | What is asserted |
|---|---|
| `NoteCorrection` | Inside/at/outside the boundary; each `EventKind`; already-redacted; the negative-age case |
| Add | One `.note` event at `now()`; blank writes nothing; timeline newest-first |
| Extraction | A note mints `SourceRef` rows; re-noting the same key mints no second row |
| Correct | Original retained, flagged, otherwise unchanged; replacement has a new `id`, the **same timestamp and kind**, the new body |
| Correct | A `.blockedReason` correction reappends `.blockedReason` |
| Correct | Correcting a correction at T+4m succeeds, at T+6m does not — the window did not restart |
| Correct | Expiry writes nothing: event count and every `isRedacted` unchanged |
| Correct | Blank or identical body → `.unchanged`, nothing written |
| Redact | Row absent from `EventQueries.timeline`, present in an unfiltered fetch |
| Redact | `created` and `statusChanged` are neither correctable nor redactable |
| Failure | Injected save failure: nothing on disk, `lastError` set, draft preserved, `reload()` restores the in-memory row |
| Model | `selectedTaskEvents` goes through `EventQueries`; a note appended elsewhere refreshes it via `.stenoDidWrite` |

Not tested, and stated rather than implied: the `Timer`'s scheduling, and everything in `Steno/`
(D-010 — no window server in the headless bundle).

---

## 9. Deviations from REQUIREMENTS.md

Both go in the PR body. Neither is a silent deviation.

### 9.1 The replacement carries the original's kind, not `.note`

FR-2: "append a new `note` event carrying the corrected body". Taken literally, correcting a
`blockedReason` would emit a `note`, changing what the row means to §3.3 and to M2-02's renderer.
FR-2 predates `blockedReason` being correctable. **Proposed amendment:** "append a new event of
the same kind, carrying the corrected body."

### 9.2 The one keystroke is scoped, not global

FR-2 suggests `N`. A bare-letter menu key equivalent would break typing "n" in every text field in
the app, including the field §1.1 protects. `N` is therefore bound to the task list's focus scope,
with ⌘⇧A as the menu-discoverable equivalent. FR-2's requirement — one keystroke from a selected
task — is met exactly; its suggested mechanism is not.

---

## 10. Out of scope, and one debt taken deliberately

Out of scope per the task file: summarizing notes (M3), `externalUpdate` events (M4-01).

**Orphan `SourceRef` rows are left in place.** Redacting a note does not remove refs that note
minted, so correcting "fixed PAY-42" to "fixed PAY-421" leaves a `PAY-42` ref behind, which the M5
Jira connector will fetch and cache a 404 for.

Taken knowingly. Reconciling would introduce the first code path in the app that *deletes* a
persisted row — immediately beside the invariant this task exists to defend — and would discard
`cachedSummary` / `lastFetchedAt` that §10.1 wants preserved. The cleanup has a natural home in M5,
where fetching exists and a dead ref is observable. Recorded as an open decision, not as a defect.
