# M0-03 — Domain Models — Design

**Task:** [`docs/tasks/M0-03-domain-models.md`](../../tasks/M0-03-domain-models.md)
**Requirements:** [§3](../../REQUIREMENTS.md#3-core-domain-model),
[§6](../../REQUIREMENTS.md#6-data--sync),
[§10.1](../../REQUIREMENTS.md#101-merge-not-replace),
[D10, D11](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/domain-models`
**Date:** 2026-08-19

## Goal

The five SwiftData models — `Project`, `TaskItem`, `Event`, `SourceRef`, `StandupReport` — with
CloudKit-compatible schemas matching §3's field tables, and the three invariants those tables
imply made unbypassable rather than documented.

Every later milestone reads these types. A field missed here is a store migration later, which
is why the task carries its own review gate.

---

## 1. Two spec tensions, resolved

Both were found while reading §3 against the task file. Both are decided here and carried into
the PR body; neither is a silent deviation.

### 1.1 `TaskItem.sourceRefs` — relationship *and* foreign key

§3.2's field table lists `sourceRefs: [SourceRef]` and calls it "a relationship, not an embedded
value." §3.4 independently gives `SourceRef` its own `taskID`, and the task file's notes state
that §3 models relationships as explicit UUID foreign keys rather than SwiftData relationship
macros, because M2.5-02's merge-by-UUID depends on it.

Read literally, both hold at once: the link is recorded twice, and after a merge the two
representations can disagree.

**Decision: keep both, with `taskID` authoritative.** The relationship exists for call-site
ergonomics; `taskID` is what export, import, and merge read. Coherence is not left to
discipline — §5's test 6 asserts `ref.taskID == ref.task?.id` across a save and fetch, so a code
path that wires one without the other fails the suite.

**Consequence that follows from §6, not from taste.** CloudKit-compatible schemas require every
relationship to be optional and to have an inverse. So the shape is `TaskItem.sourceRefs:
[SourceRef]?` plus an inverse `SourceRef.task: TaskItem?` *alongside* `SourceRef.taskID` — three
properties expressing one fact. That is the price of the literal reading, and it is accepted
knowingly.

**Alternative rejected:** `taskID` alone, with no stored array (one source of truth, nothing for
merge to reconcile). Rejected because it needs a §3.2 amendment, and the ergonomic cost lands on
every task that reads a task's refs.

### 1.2 `Event` has no inverse relationship

§3.2's field table lists `sourceRefs` and lists no `events`. So `Event` links to its task by
`taskID` only, and the asymmetry with `SourceRef` is deliberate rather than an oversight. It is
recorded here so a later reviewer does not "restore symmetry" and hand M2.5-02 a second dual
representation to reconcile.

---

## 2. Enums

Four, all `String`-backed, `Codable`, `CaseIterable`, `Sendable`, one small file each.

| Enum | Cases | Source |
|---|---|---|
| `Status` | `todo`, `inProgress`, `blocked`, `done` | §3.2, D11 |
| `EventKind` | `created`, `note`, `statusChanged`, `blockedReason`, `externalUpdate`, `standupReported` | §3.3 |
| `SourceRefKind` | `jiraIssue`, `confluencePage`, `githubPR`, `url`, `mcpResource` | §3.4 |
| `ReportCadence` | `daily`, `periodic` | §3.1, D17 |

`Status` has exactly four cases, no `custom`, and no associated values — D11 and §2.1 both forbid
custom statuses, and an enum that cannot express one is a cheaper guarantee than a rule.

String raw values (rather than `Int`) because §10.2's export is specified as human-readable,
greppable JSON; a report of `"status": "inProgress"` is inspectable before import in a way that
`"status": 1` is not, and reordering cases can never silently rewrite stored data.

**Deliberately excluded:** FR-5's cadence→staleness table (3 days / 10 days). It is a
stale-detection rule, and the task's scope does not include FR-5. `ReportCadence` ships as a bare
enum; the task that implements staleness owns the mapping.

---

## 3. The five models

House rules applied throughout, both from §6: every non-optional property carries a default,
and no property anywhere is `@Attribute(.unique)` — including `id`. §5's test 1 asserts this by
reflection rather than leaving it to a reviewer's eye.

`private(set)` marks a field only a mutator may write. Every property is `var`; SwiftData
persists no `let`.

### 3.1 `Project` (§3.1)

| Property | Type | Default | Access |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | `private(set)` |
| `name` | `String` | `""` | `private(set)` |
| `colorHex` | `String` | `""` | `private(set)` |
| `jiraProjectKeys` | `[String]` | `[]` | `private(set)` |
| `isArchived` | `Bool` | `false` | `private(set)` |
| `sortOrder` | `Int` | `0` | `private(set)` |
| `lastStandupAt` | `Date?` | `nil` | **`var`** |
| `reportCadence` | `ReportCadence` | `.daily` | `private(set)` |
| `staleThresholdDays` | `Int?` | `nil` | `private(set)` |
| `modifiedAt` | `Date` | `.now` | `private(set)` |

`lastStandupAt` is a plain `var`, and that is the design rather than an omission. §10.1 gives it
its own merge rule — take the later timestamp — so it must *not* bump `modifiedAt` (see §4). A
plain property gets that by construction; a mutator would get it by remembering.

### 3.2 `TaskItem` (§3.2)

| Property | Type | Default | Access |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | `private(set)` |
| `title` | `String` | `""` | `private(set)` |
| `projectID` | `UUID` | `UUID()` | `private(set)` |
| `status` | `Status` | `.todo` | `private(set)` |
| `createdAt` | `Date` | `.now` | `private(set)` |
| `statusChangedAt` | `Date` | `.now` | `private(set)` |
| `completedAt` | `Date?` | `nil` | `private(set)` |
| `sourceRefs` | `[SourceRef]?` | `[]` | `var`, `@Relationship(inverse: \SourceRef.task)` |
| `isArchived` | `Bool` | `false` | `private(set)` |
| `modifiedAt` | `Date` | `.now` | `private(set)` |

### 3.3 `Event` (§3.3)

| Property | Type | Default |
|---|---|---|
| `id` | `UUID` | `UUID()` |
| `taskID` | `UUID` | `UUID()` |
| `timestamp` | `Date` | `.now` |
| `kind` | `EventKind` | `.note` |
| `body` | `String` | `""` |
| `payload` | `Data?` | `nil` |
| `isRedacted` | `Bool` | `false` |

**Every property is `private(set)`, and the type exposes exactly one mutator: `redact()`.** This
is the append-only invariant (D10, §3.3, §13) expressed as API rather than as a rule agents are
asked to honour. The initialiser is the only place any field but `isRedacted` is ever written.

`redact()` is one-way — there is no `unredact()` and no `setRedacted(_:)`. Nothing in the spec
needs to reverse a redaction: FR-4.1's undo redacts `standupReported` events and is itself not
undoable, and M1-06's note correction is specified as redact-and-reappend. A reversible setter
can be added by the task that finds it needs one; it cannot easily be taken away.

### 3.4 `SourceRef` (§3.4)

| Property | Type | Default | Access |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | `private(set)` |
| `taskID` | `UUID` | `UUID()` | `private(set)` |
| `task` | `TaskItem?` | `nil` | `var` (inverse of `TaskItem.sourceRefs`) |
| `kind` | `SourceRefKind` | `.url` | `private(set)` |
| `identifier` | `String` | `""` | `private(set)` |
| `url` | `String?` | `nil` | `private(set)` |
| `lastFetchedAt` | `Date?` | `nil` | `private(set)` |
| `cachedSummary` | `String?` | `nil` | `private(set)` |

`taskID`, `kind`, and `identifier` have no mutators at all: they are the dedup identity (§6), and
a ref whose identity can change is a ref that can collide with one that already exists.

`lastFetchedAt` and `cachedSummary` move together through a single `recordFetch(summary:at:)`.
§10.1 resolves them as a pair — later `lastFetchedAt` wins, and `nil` loses to any value — so a
caller able to set the summary without the timestamp could produce a record the merge cannot
order.

### 3.5 `StandupReport` (§3.5)

| Property | Type | Default | Access |
|---|---|---|---|
| `id` | `UUID` | `UUID()` | `private(set)` |
| `projectID` | `UUID` | `UUID()` | `private(set)` |
| `generatedAt` | `Date` | `.now` | `private(set)` |
| `windowStart` | `Date` | `.now` | `private(set)` |
| `windowEnd` | `Date` | `.now` | `private(set)` |
| `markdownBody` | `String` | `""` | `private(set)` |
| `wasAIGenerated` | `Bool` | `false` | `private(set)` |
| `modelUsed` | `String?` | `nil` | `private(set)` |
| `isUndone` | `Bool` | `false` | `private(set)`, `markUndone()` |

A report is a record of something that happened, so nothing but `isUndone` changes after
creation. FR-4.1 requires the row be retained and marked, never deleted.

---

## 4. `modifiedAt`, closing O-4

DECISIONS.md O-4 assigns this task the question of what updates `modifiedAt`, because M2.5-02's
conflict resolution inherits any ambiguity.

**Decision: `modifiedAt` is stamped only by mutations to fields whose merge rule is "later
`modifiedAt` wins."** Nothing else touches it.

| Model | Stamps `modifiedAt` | Does not |
|---|---|---|
| `Project` | `name`, `colorHex`, `jiraProjectKeys`, `isArchived`, `sortOrder`, `reportCadence`, `staleThresholdDays` | `lastStandupAt` (§10.1: take the later) |
| `TaskItem` | `title`, `projectID`, `isArchived` | `status`, `statusChangedAt`, `completedAt` (§10.1: derive from the event log); `createdAt` (immutable) |

**Why the narrow rule.** `modifiedAt` is per *record*, not per field. Under a broad rule — every
mutation stamps it — a machine that only changes a task's status still advances the record's
timestamp, and at merge time that later stamp wins the *title* too, silently reverting a retitle
made on the other machine. The append-only log makes that recoverable only by hand. The narrow
rule removes the failure mode by keeping the timestamp attached to exactly the fields it
arbitrates, and it matches how §3.1 and §3.2 already word it: "last mutation of a mutable field
(`name`, `colorHex`, …)".

**Alternatives rejected:** stamping on every mutation (the lost update above); per-field
timestamps (exact at merge, but it contradicts §3.1/§3.2's field tables, grows the schema, and
hands M2.5-02 more cases rather than fewer).

---

## 5. Mutation API

The models expose small, explicit mutators; the fields behind them are `private(set)`. Each
`Project` and `TaskItem` mutator takes an `at date: Date` so tests control the clock rather than
sleeping. **The parameter carries no `= .now` default** — a caller must state the timestamp it
means. `modifiedAt` arbitrates import conflicts (§4), and a defaulted clock is how a caller ends
up stamping wall-clock time inside an import that is replaying someone else's history.

**`Project`** — `rename(to:at:)`, `setColorHex(_:at:)`, `setJiraProjectKeys(_:at:)`,
`setArchived(_:at:)`, `setSortOrder(_:at:)`, `setCadence(_:at:)`,
`setStaleThresholdDays(_:at:)`. Each writes its field and stamps `modifiedAt`.

**`TaskItem`** — `rename(to:at:)`, `move(toProject:at:)`, `setArchived(_:at:)` stamp
`modifiedAt`; `setStatus(_:at:)` does not, and is specified below.

**`Event`** — `redact()`. **`SourceRef`** — `recordFetch(summary:at:)`. **`StandupReport`** —
`markUndone()`.

### 5.1 `setStatus`, and the case §3.2 does not cover

```
func setStatus(_ new: Status, at date: Date) {
    guard new != status else { return }
    status = new
    statusChangedAt = date
    completedAt = (new == .done) ? date : nil
}
```

§3.2 specifies transitions ("any status to any other; moving to `done` sets `completedAt`, moving
out of `done` clears it") but is **silent on setting a task to the status it already has**. That
gap is closed here, explicitly, and flagged in the PR body:

**A redundant `setStatus` is a complete no-op.** `completedAt` and `statusChangedAt` are left
untouched. The alternative — re-stamping — would let a redundant call reset a completed task's
completion time, and would hand M1-05 a `statusChanged` event describing a transition that never
occurred, which then flows into a stand-up report as work that did not happen.

Because the same-status case returns early, `completedAt` needs no special handling for
`done → done`, and the assignment above reads as §3.2 words it.

### 5.2 The half of the invariant this task cannot enforce

ARCHITECTURE §3 requires every status transition to append a `statusChanged` event, and assigns
that to M1-05's status service. Appending needs a `ModelContext`, which M0-04 owns — so
`setStatus` maintains `completedAt` and `statusChangedAt`, and cannot guarantee the event.

This is a real seam: a caller that reaches for `setStatus` directly gets correct fields and no
event, and §10.1 warns that such a transition surfaces much later as an inexplicable revert after
an import. `setStatus`'s doc comment therefore names M1-05 as the sanctioned caller. M0-03 ships
the half it can enforce and does not pretend to the other.

---

## 6. `SourceRef` dedup (§3.4)

The rule — unique per `(taskID, kind, identifier)`, enforced in code, never `@Attribute(.unique)`
because §6 forbids those — lands as a value type plus a pure function, so M1-01's extraction can
reuse it with no store:

```
extension SourceRef {
    struct DedupKey: Hashable {
        let taskID: UUID
        let kind: SourceRefKind
        let identifier: String
    }
    var dedupKey: DedupKey { .init(taskID: taskID, kind: kind, identifier: identifier) }

    static func newRefs(from candidates: [SourceRef], existing: [SourceRef]) -> [SourceRef]
}
```

`newRefs` drops candidates whose key is already present **and** collapses duplicates within the
candidate batch. The second half is not hypothetical: extraction runs on the title and on every
note (FR-1.5), so one pass over a task legitimately yields the same ticket key several times.
Callers insert only what it returns — that is what makes re-extraction a no-op rather than a new
row.

`identifier` matches exactly, byte for byte. Normalizing case or whitespace belongs to extraction
(M1-01); doing it in both places would mean two components decide what "the same ticket" means,
and they would eventually disagree.

Being pure and store-free is what lets M0-03 test the rule at all without owning the container
(M0-04's job), and what lets M1-01 apply it before anything is inserted.

---

## 7. Test plan

Swift Testing throughout, parameterized where the cases form a table (D-011) so a failing row
names itself. Tests needing a live context build an `isStoredInMemoryOnly` `ModelConfiguration`;
that is a test fixture, and **M0-04 still owns the application's real store configuration** — the
fixture carries a comment saying so.

Tests 1 and 2 need the list of the five model types to build a `Schema`. Since the shipped list
belongs to M0-04 (§8), **the test bundle declares its own** and there is nothing in `StenoKit`
for it to import. The consequence is worth naming because M0-04 inherits it: a model type absent
from *M0-04's* list is not caught by anything here, so M0-04's own tests have to assert that the
schema it ships covers every model.

| # | Asserts | Substrate |
|---|---|---|
| 1 | **§6 CloudKit conformance:** for every attribute of every entity, `!isUnique` and (`isOptional` or a default exists) — no attribute is unique, `id` included | `Schema` reflection, parameterized per entity |
| 2 | **§3.1–§3.5 field coverage:** attribute names and optionality match a table transcribed from the spec | `Schema` reflection |
| 3 | **Status transitions:** all 16 `(from, to)` pairs — `completedAt` set entering `done`, cleared leaving it, `statusChangedAt` advanced, same-status pairs no-op, `modifiedAt` untouched | pure |
| 4 | **`modifiedAt` (§4):** every governed mutator stamps it; `setStatus`, `lastStandupAt`, and `recordFetch` provably do not | pure |
| 5 | **Dedup (§6):** an existing key yields nothing, a new key yields one, an intra-batch duplicate collapses | pure, then repeated against an in-memory container |
| 6 | **Relationship coherence (§1.1):** `ref.taskID == ref.task?.id` across a save and fetch | in-memory container |
| 7 | **Redaction:** `redact()` sets the flag and leaves `body`, `timestamp`, and `payload` intact | pure |

Test 2 is what catches a field silently dropped by a later refactor — the failure mode that makes
this task expensive to get wrong.

### 7.1 What the tests do not cover

Acceptance criterion "`Event` exposes no mutating API except toggling `isRedacted`" is enforced at
**compile** time by `private(set)`, not by any test: a test cannot assert the absence of a setter
that would not compile. Test 7 asserts the positive behaviour; the negative half rests on the
access modifier and on review.

Stated rather than glossed, following D-012's precedent of describing what a mechanism actually
covers instead of what a green run appears to prove.

---

## 8. Layout

```
StenoKit/Models/
  Project.swift
  TaskItem.swift
  Event.swift
  SourceRef.swift
  StandupReport.swift
  Status.swift
  EventKind.swift
  SourceRefKind.swift
  ReportCadence.swift
StenoTests/Models/         // one test file per model, plus SchemaConformanceTests
```

Matches ARCHITECTURE §5's `StenoKit/Models/` slot and D-006's rule that XcodeGen takes the
directory whole — no `project.yml` change.

**This task ships model types and nothing that enumerates them.** There is no `StenoSchema`, no
`static let models: [any PersistentModel.Type]`: the list of model types is what a `ModelContainer`
is built from, so it goes with the container in M0-04. The cost lands in §7 — this task's tests
declare their own list — and it is the right side of the line to pay it on, because a list living
here would be a second declaration of the schema that M0-04's container could silently disagree
with.

---

## 9. Risks, with responses decided in advance

| Risk | Response |
|---|---|
| **`private(set)` under the `@Model` macro.** The macro rewrites persisted properties into computed accessors, and every invariant here rests on this compiling | **Built first**, before any model is fleshed out. If it does not hold, fall back to `internal(set)` with public mutators — weaker, since StenoKit-internal code could bypass it — and record it as a decision, never as a silent downgrade |
| **Swift 6 strict concurrency (D-009).** D-009 hands this task the job of revisiting `SWIFT_VERSION` if `@Model` plus actor isolation is real friction. `@Model` types are not `Sendable`, so friction appears where a test moves a model across isolation domains | Keep each test's context and its models on a single actor. **`SWIFT_VERSION` is not lowered to 5.** If that ever looks necessary it stops being an implementation detail and goes back to the user |
| **`Schema` reflection surface.** Test 1 assumes `Schema.Attribute` exposes `isUnique`, `isOptional`, and a default | Verified in the same first spike as `private(set)`. If the API is thinner, assert through a CloudKit-configured `ModelConfiguration` and let SwiftData's own validation fail the test |

---

## 10. Out of scope

Per the task file, and repeated because each is a plausible thing to drift into:

- **The model container and store** — M0-04. The in-memory container in §7 is a test fixture, not
  a store configuration.
- **Any shipped enumeration of the model types** — M0-04, with the container it feeds (§8).
- **Any UI** — M0-05.
- **Event creation on user actions** — M1-05, M1-06. This task defines the types and their
  invariants, not the flows that produce them.
- **FR-5's staleness thresholds** — the cadence→days mapping belongs to stale detection (§2).

---

## 11. What this lands beyond code

- **DECISIONS.md:** an entry closing **O-4** (§4), and an entry recording the dual
  `taskID` + relationship shape (§1.1) so a later reviewer does not "fix" it.
- **PR body:** the redundant-`setStatus` no-op as a §3.2 gap (§5.1); the UUID-foreign-key
  reasoning the task file asks be recorded; the note that M0-04 owns both the model-type list and
  the test asserting its container covers every model (§7, §8).
