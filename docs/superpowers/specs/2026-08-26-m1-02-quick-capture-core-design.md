# M1-02 — Quick Capture Core — Design

**Task:** [`docs/tasks/M1-02-quick-capture-core.md`](../../tasks/M1-02-quick-capture-core.md)
**Requirements:** [FR-1](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-1.4](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-1.5](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-3](../../REQUIREMENTS.md#fr-3-main-window-p0),
[FR-6](../../REQUIREMENTS.md#fr-6-settings-p0),
[§1.1](../../REQUIREMENTS.md#11-primary-risk),
[§3.2](../../REQUIREMENTS.md#32-taskitem),
[§3.3](../../REQUIREMENTS.md#33-event-append-only),
[§3.4](../../REQUIREMENTS.md#34-sourceref),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents),
[D15](../../REQUIREMENTS.md#2-decisions-made-locked),
[D18](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/quick-capture-core`
**Date:** 2026-08-26

## Goal

The one code path that turns typed text into a persisted task, built before either of the two
surfaces that will consume it (M1-03, M1-04). D15 says "three entry points, one code path"; this
is the code path.

It resolves a project without ever asking (FR-1.4), extracts references via M1-01 (FR-1.5),
appends the `created` event (§3.3), and writes all of it in one save — inside a latency budget
that §1.1 makes a P0 functional requirement rather than polish.

---

## 1. The units

Split by what each can be tested *without*, which is the same test ARCHITECTURE §5 applies to
target membership.

| File | Responsibility | Tested against |
|---|---|---|
| `StenoKit/Capture/RoutingDecision.swift` | `RoutingDecision`, `KeyMatch` — value types | Literal values |
| `StenoKit/Capture/ProjectRouter.swift` | FR-1.4's ladder; ticket-key matching | Literal arrays, no container |
| `StenoKit/Capture/CaptureService.swift` | Route → extract → insert → one save; `CaptureError` | Container |
| `StenoKit/Features/Capture/CaptureFieldModel.swift` | Draft text, live chip, dismissal | Container |
| `StenoKit/Persistence/StenoStore.swift` | `seedDefaultProjectIfEmpty(in:)` | Container |
| `Steno/Features/Capture/CaptureFieldView.swift` | The field and its chip | Not testable (D-010) |
| `Steno/Features/MainWindow/ProjectEditSheet.swift` | Name and Jira keys | Not testable (D-010) |

`StenoKit/Capture/` is where ARCHITECTURE §5 already reserves the capture core, alongside
M1-01's extractor.

### 1.1 Why the chip's state lives in `StenoKit`, not in the view

`CaptureFieldModel` is an `@Observable @MainActor` class in the framework, not `@State` in a
SwiftUI view. That is a deliberate cost — one more type than the task file implies — paid for one
reason: **M1-04's acceptance criterion is "the auto-routing chip behaving identically to the main
window."** Chip state held in a view lives in `Steno/`, where D-010 puts it beyond the reach of
the headless bundle, and where M1-03 and M1-04 would each rebuild it by hand. Three
hand-rolled chips that drift is precisely the failure D15 names and this task exists to prevent.

The division is: `ProjectRouter` decides, `CaptureService` writes, `CaptureFieldModel` holds the
in-progress capture, and the view renders it. A surface is then a window plus a `CaptureFieldView`.

---

## 2. Project routing (FR-1.4)

```swift
public struct KeyMatch: Equatable, Sendable {
    public let key: String        // "PAY-421"
    public let projectID: UUID
}

public struct RoutingDecision: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case ticketKey(String)    // the key that decided it
        case preferred            // the surface's own context
        case lastUsed
        case configuredDefault    // FR-6; nil until M1-08
        case firstProject
        case none
    }
    public let projectID: UUID?
    public let source: Source
}

public enum ProjectRouter {
    public static func ticketKeyMatch(text: String, projects: [Project]) -> KeyMatch?

    public static func route(
        text: String,
        projects: [Project],
        preferred: UUID?,
        lastUsed: UUID?,
        defaultProjectID: UUID?,
        ignoringTicketKey: Bool
    ) -> RoutingDecision
}
```

Pure: no store, no clock, no I/O. `projects` is the caller's live (non-archived) list in
`sortOrder` order — the same array `MainWindowModel.projects` already publishes.

**The ladder, in order:**

1. Ticket key whose prefix matches a `Project.jiraProjectKeys` entry — FR-1.4's rule.
2. `preferred` — the surface's own context. The main window passes its sidebar selection; the
   hotkey window and the popover pass `nil`.
3. `lastUsed` — FR-1.4's specified default, derived in §3.2.
4. `defaultProjectID` — FR-6's configurable default. **A parameter from day one, `nil` until
   M1-08 fills it.** M1-08's acceptance criterion ("the default project set here is what M1-02
   falls back to") is then satisfied by passing an argument, not by editing this function.
5. First project by `sortOrder`.
6. `nil` — see §4.2, the single state where this happens.

### 2.1 Why `preferred` outranks `lastUsed`

Capture into PAY from the hotkey, then click "EM — Hiring" in the sidebar and press ⌘N. The
sidebar selection wins. Filing a task into a project other than the one on screen is the kind of
surprise that costs trust in a recall tool, and FR-1.4's "change it after the fact" escape hatch
does not land until M1-05.

This is also what keeps the shared path genuinely shared: the three surfaces differ by one
argument, never by logic.

### 2.2 Four matching rules the spec does not state

REQUIREMENTS.md says "a ticket key whose prefix matches" and stops. Each of these is decided here.

- **First *matching* key wins, not first key.** `"UTF-8 fix for PAY-421"` routes to Payments:
  `UTF` matches no configured project, so the scan continues to `PAY`. This absorbs M1-01's
  documented false positives (`UTF-8`, `COVID-19`, `ISO-8601`, `M1-01`) at no cost — they can
  only misroute if the user configures a project with that literal prefix.
- **Ties break by `sortOrder`.** Two projects both claiming `PAY` is a configuration mistake, but
  it must resolve deterministically rather than by fetch order.
- **Comparison is uppercase-normalised on both sides.** `JiraKey.pattern` only matches uppercase,
  but `jiraProjectKeys` is user-entered. §7's editor normalises on save as well, so the router
  never depends on the editor having done its job.
- **The prefix is everything before the final `-`.** `JiraKey.pattern` is
  `\b[A-Z][A-Z0-9]{1,9}-\d+\b`, so there is exactly one separating hyphen.

### 2.3 Routing scans keys directly; it does not call `ReferenceExtractor`

`ticketKeyMatch` runs `JiraKey.pattern` over the text with an early exit on the first match that
resolves to a project. It does **not** call `ReferenceExtractor.extract`. Two independent reasons,
either of which is sufficient:

**Cost.** The chip re-derives on every keystroke. `NSDataDetector` is the expensive half of
extraction — 180 µs on a capture string, but M1-01's own benchmarks put a 250 KB paste at 180 ms.
Paid per keystroke after such a paste, that is felt, and §1.1 is unambiguous about what the user
does when capture is felt. A bare regex scan with early exit has no such cliff.

**Correctness, and this one is counterintuitive.** M1-01's overlap rule suppresses keys that sit
inside links, so that a browse URL yields one ref instead of two. That rule is right for
*extraction* and wrong for *routing*: `https://acme.atlassian.net/browse/PAY-421` should route to
Payments. Routing wants every key the text mentions; extraction wants every key the text mentions
*once*. They are different questions and get different scans.

Full extraction still runs exactly once, at save, for the refs. See §3.1.

---

## 3. `CaptureService`

```swift
public enum CaptureError: Error, Equatable {
    /// Every project is archived — §4.2, the one state where capture refuses.
    case noProjectAvailable
}

@MainActor
public struct CaptureService {
    public init(context: ModelContext, now: @escaping () -> Date = Date.init,
                save: @escaping (ModelContext) throws -> Void = { try $0.save() })

    @discardableResult
    public func capture(
        text: String,
        preferred: UUID?,
        defaultProjectID: UUID? = nil,
        ignoringTicketKey: Bool = false
    ) throws -> TaskItem?
}
```

`@MainActor` because `ModelContext` is not `Sendable`. `now` and `save` are injected for the same
reasons `MainWindowModel` injects them (D-019): a testable clock, and a save that can be made to
fail on demand.

Returns `TaskItem?` — `nil` for empty-after-trim text, which is a no-op rather than an error.
Throws for a routing failure (§4.2) and for a save failure.

### 3.1 The sequence

1. Trim. Empty → return `nil`, touching nothing.
2. Fetch live projects; derive `lastUsed` (§3.2); `ProjectRouter.route(...)`.
3. `ReferenceExtractor.extract(from: trimmed)` — M1-01's full path, once.
4. Insert `TaskItem(title:projectID:createdAt:)`.
5. Insert `Event(taskID:timestamp:kind: .created, body: "Task created")` — §3.3's table. A task
   without one is a hole in the append-only log that M2-01's gathering would skip.
6. For each `ExtractedRef`: build via `sourceRef(taskID:)`, insert, **and set `ref.task`**.
7. One `save`. On failure, `context.rollback()` and rethrow.

Steps 4–7 are one transaction: a task whose refs failed to persist is worse than a refused
capture, because the loss surfaces at a stand-up weeks later.

### 3.2 Deriving "last-used", and the D-021 trap

FR-1.4's "last-used project" is **derived, never stored**: it is the project of the most recently
created `TaskItem`. No new field, no `UserDefaults` key, no settings row. It cannot drift from
reality, every surface agrees by construction, and it round-trips through §10's JSON export for
free because it is not a separate fact at all.

The implementation must re-apply the visible-projects filter:

```swift
// Non-archived tasks, newest first; then the first belonging to a LIVE project.
```

**A bare `fetchLimit = 1` is wrong here.** D-021 names this exact trap: `TaskItem` has no archived
bit of its own, and "a project's tasks disappear when it archives" is an emergent property of one
in-memory filter in `MainWindowModel.fetchTasks()`, not a stored fact. Limiting the fetch to one
row returns a task belonging to an archived project, and capture routes into a project the user
cannot see. D18 caps the dataset under 20 live tasks, so fetching them all and filtering costs
nothing.

### 3.3 Two things deliberately not done

**`SourceRef.newRefs(from:existing:)` is not called.** For a brand-new task `existing` is empty,
and `ReferenceExtractor.merged` has already collapsed duplicates by `(kind, identifier)` — which
is `SourceRef.DedupKey` minus the `taskID` that is constant across one pass. It is provably a
no-op here. M1-06's note path, where refs accumulate across saves, is its real caller. A comment
at the call site says so, because its absence otherwise reads as an oversight.

**Rollback lives in the service, not in `MainWindowModel.perform(_:_:)`.** D-018 requires that a
failed save never leave the window displaying a task that is not on disk. Putting the rollback in
the service means M1-03 and M1-04 inherit that guarantee instead of each having to remember it.
`MainWindowModel` keeps its `perform` for project mutations and catches the service's throw to set
`lastError`.

---

## 4. First launch, and the one state that still blocks

### 4.1 Seeding

```swift
extension StenoStore {
    /// Inserts a single default project when the store holds none.
    @discardableResult
    public static func seedDefaultProjectIfEmpty(in context: ModelContext) throws -> Project?
}
```

Called from `StenoApp` immediately after the container opens. Inserts `Inbox`, colour
`ProjectPalette.hex(forIndex: 0)`, `sortOrder` 0, no Jira keys — an ordinary project, renameable
and archivable like any other.

**Why seed at all.** On a fresh install there are zero projects, so a task has no `projectID` to
take, and M0-05 handles that by gating New Task off (`canCreateTask == false`). That is a capture
surface refusing text, which is the thing §1.1 forbids — and it gets materially worse in M1-03,
where the hotkey window would open above every other app into a field whose `Return` does nothing.
Seeding makes "capture always has a target" true on first launch rather than nearly true.

The check is "zero projects", archived included, so seeding happens once in the store's life and
never resurrects itself.

### 4.2 Every project archived

If the user archives every project, routing returns `projectID: nil`, `canCreateTask` goes false,
and the empty state says so. `CaptureService.capture` throws `CaptureError.noProjectAvailable`.

**This is the one state where capture blocks, and it is deliberate.** Re-seeding would resurrect a
project the user archived on purpose. Unlike a fresh install, this is a state they navigated into
deliberately, with a visible and immediate undo — unarchive — and §3.1 is explicit that archived
projects are hidden but never deleted. Choosing to hide every project is a legitimate thing to
have done, and quietly undoing it is worse than the empty state that names the problem.

Recorded as a decision rather than left implicit, because "capture never blocks" appears in
ARCHITECTURE §3's invariant table and this is its one documented exception.

---

## 5. The chip (FR-1.4)

```swift
public struct CaptureChip: Equatable, Sendable {
    public let key: String          // "PAY-421"
    public let projectID: UUID
    public let projectName: String
    public let colorHex: String
}

@Observable @MainActor
public final class CaptureFieldModel {
    public var text: String = "" { didSet { refreshChip() } }
    public private(set) var chip: CaptureChip?
    public func dismissChip()
    public func commit()
    public func reset()
}
```

The chip appears **live, while typing** — the moment a key resolves to a project — beside the
field. It is feedback before commitment, which is what makes dismissal cost one click and zero
modals. FR-1.4's alternative reading, a chip on the created row afterwards, tells the user where
their task went only after it has gone, and makes "dismiss" mean a project change, which the task
file explicitly defers to M1-05.

### 5.1 Dismissal is keyed to the key, not a flag

`CaptureFieldModel` holds `dismissedKey: String?`. A chip is suppressed only while the current
match equals the dismissed key. Type on so that a *different* key matches, and a new chip appears.

This is the difference between "drop this auto-assignment" and "pin the fallback for this
capture", and the first is what FR-1.4 describes: dismissing routes down the ladder to `preferred`
or `lastUsed`, it does not permanently disable routing for a capture still being typed. On commit,
`ignoringTicketKey` is passed `true` iff the current match is still the dismissed one — so the
save re-runs the same decision the chip is displaying.

`text.didSet` re-runs `ticketKeyMatch` per keystroke. Per §2.3 that is a regex scan with early
exit and no `NSDataDetector`, so the cost stays flat even on a large paste.

---

## 6. Wiring the main window

- `MainWindowModel.createTask(titled:)` (`MainWindowModel.swift:242`) delegates to
  `CaptureService.capture`, keeping its `lastError` handling and its `reload()`. The comment at
  `MainWindowModel.swift:253` already anticipates this: *"M1-02's capture service takes over this
  call site."*
- **`targetProjectID()` is deleted**, not superseded in place. It is D-021's second interim
  behaviour ("the first project by `sortOrder`") and this task owns its replacement.
- The `.newTask` sheet renders a new `CaptureFieldView` rather than `TextEntrySheet`.
  `TextEntrySheet` stays as-is for `.newProject`: the two sheets' contracts have genuinely
  diverged, and parameterising one view over "has a chip" would serve neither.
- `canCreateTask` stays, now false only in §4.2's state.

---

## 7. Out of scope by the task file, added anyway: the Jira keys editor

**No task in the 36-task plan owns editing `Project.jiraProjectKeys`.** The field and its mutator
`setJiraProjectKeys(_:at:)` exist from M0-03; `MainWindowModel.createProject(named:)` always
constructs projects with the default `[]`; and grepping `docs/tasks/` finds the field named in
exactly two places, both inside M1-02's own file. M1-08's Settings scope is hotkey, launch at
login, and default project — and per-project keys are not Settings-shaped anyway.

Without an editor, this task's second acceptance criterion is verifiable only in the headless
bundle. In the running app every project holds `[]` forever, the chip can never appear, and
M1-04's "verified by the chip behaving identically to the main window" has nothing to compare.

So M1-02 adds the minimum that makes routing reachable: a sheet on the sidebar's project row with
a name field and a comma-separated keys field, calling the existing `rename(to:at:)` and
`setJiraProjectKeys(_:at:)` through a `MainWindowModel` method. Keys are uppercased, trimmed,
emptied, and deduped on save, so `ProjectRouter` never depends on the editor's diligence.

This widens the PR past the task file's In-scope list. Per CLAUDE.md it is called out in the PR
body rather than done quietly, and it carries a REQUIREMENTS amendment: no FR currently grants
any way to edit a project after creation. FR-3 gains it, the document goes to v1.11, and the
changelog records why.

---

## 8. Latency (§1.1, §13)

§13 makes any change to this path a performance-sensitive change and requires measurement, not
assumption. M1-03 and M1-04 must each prove they did not regress it, so the measurement has to be
something they can mechanically re-run.

**The gate:** `StenoTests/Capture/CapturePerformanceTests.swift`, XCTest per D-011's `measure`
exception, in the house style M1-01 established — worst of ten iterations, not the last one, with
a ceiling set well above the measured value so a real regression fails while a loaded machine does
not.

Measured against a **real on-disk store in a temp directory**, not `StenoStore.inMemory()`. The
in-memory store skips the fsync, which is the entire question being asked. `ModelContext(container)`,
never `mainContext` — `mainContext` does not retain its container.

**The end-to-end number:** an `os_signpost` interval around `capture`, read back with
`log show --info` after a `make run` session, recorded in the PR body. With GUI automation
unavailable on this machine that is the only route to a real-app figure, and the signpost stays in
the source as the instrument M1-03 uses to measure the hotkey path including window presentation.

**Contingency, deliberately not built.** If measurement shows the save is felt, the task file's own
remedy applies: save task and event first, extract and insert refs in a second save off the
critical path. That is a real cost — refs would briefly not exist on a task that does — and paying
it before measuring would contradict the instruction that produced the measurement. Measure,
report, then decide.

---

## 9. Test plan

Headless, network-denied (§9.4), Swift Testing except where noted.

**`ProjectRouterTests`** — literal arrays, no container:
- A configured key routes; the chip's `source` carries the key.
- First *matching* key wins: `"UTF-8 fix for PAY-421"` → Payments.
- A key inside a URL routes (§2.3's deliberate divergence from M1-01's overlap rule).
- No key → `preferred`; no preferred → `lastUsed`; then `configuredDefault`; then `firstProject`.
- `preferred` outranks `lastUsed` when both are present.
- Two projects claiming one prefix → lower `sortOrder`.
- Case-insensitive prefix comparison.
- `ignoringTicketKey: true` skips rung 1 and lands on rung 2.
- Empty `projects` → `projectID == nil`, `source == .none`.

**`CaptureServiceTests`** — container-backed:
- One capture yields one `TaskItem`, exactly one `created` `Event`, and one `SourceRef` per
  distinct extracted ref.
- Every `SourceRef` has both `taskID` and `task` set and agreeing (D-016).
- Empty and whitespace-only text write nothing at all.
- An injected failing `save` leaves the store empty — nothing partially written.
- Last-used derivation ignores a newer task belonging to an archived project (§3.2's D-021 trap).
- Last-used follows the newest task across several projects.
- No live project → throws `noProjectAvailable`, writes nothing.

**`CaptureFieldModelTests`** — container-backed:
- Typing a matching key raises a chip carrying the project's name and colour.
- `dismissChip()` clears it; continuing to type the same key does not raise it again.
- Typing a *different* matching key after a dismissal raises a new chip (§5.1).
- `commit()` on a dismissed chip routes down the ladder, not to the key's project.
- `commit()` resets the field.

**`StenoStoreSeedingTests`:**
- Seeds one project into an empty store; the second call is a no-op.
- A store holding only archived projects is not re-seeded.

**`CapturePerformanceTests`** (XCTest) — §8's gate.

**Updated:** `MainWindowModelTasksTests` — `createTask` now routes by the ladder, and the
`targetProjectID` stand-in's tests are replaced rather than deleted.

---

## 10. What this lands beyond code

- **DECISIONS.md:** last-used is derived, not stored; routing scans keys directly rather than
  through the extractor (§2.3); Inbox seeding plus the all-archived gate (§4); the keys editor as
  a declared scope widening (§7).
- **D-021:** its second interim behaviour is retired — `targetProjectID()` is deleted.
- **ARCHITECTURE.md:** §3's "Capture never blocks" row gains its enforcement site and its one
  documented exception; §5's `Capture/` line gains the capture core.
- **REQUIREMENTS.md:** FR-3 gains project editing; version to v1.11 with a changelog line (§7).
- **tasks/README.md:** tick M1-02. No rows from earlier PRs are outstanding.

---

## 11. Out of scope

- The floating hotkey window (M1-03) and the menu bar popover (M1-04). This task builds the path;
  they build surfaces over it.
- Changing a task's project after the fact — a task-row affordance the task file assigns to M1-05.
- Status transitions and `statusChanged` events — M1-05.
- The FR-6 default-project *setting*. Its parameter exists here and stays `nil`; M1-08 fills it.
- Reducing M0-03's domain mutators from `public` to `internal` — D-019 names it as M1-05's, and
  it changes the domain API, which deserves its own review.

---

## 12. Risks

- **The latency figure is the point of the task, and it is not known until it is measured.** If the
  save proves expensive, §8's contingency is a real design change landing late in the branch.
  Mitigated by measuring first, before the surfaces exist to complicate it.
- **The keys editor widens the PR.** Mitigated by keeping it minimal — one sheet, one model
  method, existing mutators — and by declaring it rather than smuggling it.
- **`CaptureFieldModel` is built for two consumers that do not exist yet.** If M1-03 and M1-04
  need something materially different, this is the type that absorbs the change. It is small, and
  the alternative is the divergence D15 exists to prevent.
- **Chip behaviour cannot be verified in the running app** — no GUI automation on this machine. The
  headless tests cover its state machine; what they cannot cover is that the chip is legible and
  its dismiss target is hittable. Flagged for the user's own review pass.
