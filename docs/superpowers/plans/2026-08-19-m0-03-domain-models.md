# M0-03 Domain Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the five SwiftData models — `Project`, `TaskItem`, `Event`, `SourceRef`,
`StandupReport` — with CloudKit-compatible schemas matching REQUIREMENTS.md §3, and with §3's
invariants enforced by the type system rather than by convention.

**Architecture:** Each model is a `@Model final class` in `StenoKit/Models/`, one file per type.
Fields carrying an invariant are `public private(set)` and are written only by explicit mutators
in the same file — Swift enforces that a `private(set)` setter is unreachable from any other
file, so the invariants cannot be bypassed even from inside StenoKit. Relationships between
records are explicit UUID foreign keys; `TaskItem`↔`SourceRef` additionally carries a SwiftData
relationship, with `taskID` authoritative and a test asserting the two never disagree.

**Tech Stack:** Swift 6, SwiftData, Swift Testing (`@Test`/`#expect`), XcodeGen, SwiftLint,
swift-format. macOS 14.0 deployment floor.

**Spec:** [`docs/superpowers/specs/2026-08-19-m0-03-domain-models-design.md`](../specs/2026-08-19-m0-03-domain-models-design.md)

**Task file:** [`docs/tasks/M0-03-domain-models.md`](../../tasks/M0-03-domain-models.md)

**Branch:** `feat/domain-models` (already created, spec already committed)

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Never commit to `main`.** Work on `feat/domain-models`, open a PR, do not merge (CLAUDE.md,
  §9.5). `main` is protected; a direct push fails anyway.
- **`make build && make test && make lint` must all pass** before the PR (§9.5 step 4, §13).
  "This should compile" is not acceptable.
- **No `@Attribute(.unique)` anywhere**, and every property is either optional or has a default
  (§6). This is asserted by Task 7's tests, not by review.
- **Enum property defaults must be fully qualified.** Write `EventKind.note`, never `.note`. The
  `@Model` macro copies the default into an `Any?` context, so the shorthand fails to compile
  with `type 'Any?' has no member 'note'`. Same for `Date.now`, not `.now`. (Verified — see
  "Environment as verified" below.)
- **Mutators live in the same file as the properties they write.** `private(set)` scopes the
  setter to the declaring file; an extension in another file cannot write it.
- **Everything is `public`.** `StenoKit` is a framework and the app target (M0-05) must see these
  types. The pattern is `public private(set) var`.
- **Swift Testing**, not XCTest. XCTest is reserved for `measure` only, and a PR introducing an
  XCTest case must say why (D-011).
- **SwiftLint runs `--strict`** with `force_unwrapping` enabled. **No `!` force-unwraps and no
  `try!` in tests** — use `try #require(...)`, which returns the unwrapped value.
- **swift-format:** 4-space indent, 100-column lines.
- `make test` regenerates the Xcode project every run (D-014), so new `.swift` files are picked
  up automatically. No `project.yml` change is needed for any task in this plan — XcodeGen takes
  `StenoKit/` and `StenoTests/` whole (D-006).

### Environment as verified

Checked empirically on the build machine before this plan was written, by compiling probes
against the macOS SDK with `-swift-version 6`. These close all three risks in spec §9.

| Question | Answer |
|---|---|
| Does `public private(set)` compile under `@Model`? | **Yes**, in Swift 6 language mode |
| Is the setter really unreachable from another file in the same module? | **Yes** — `error: cannot assign to property: 'title' setter is inaccessible`. The `internal(set)` fallback in spec §9 is **not needed**; enforcement is stronger than the spec assumed |
| Does `Schema.Attribute` expose what Task 7 needs? | **Yes** — `.name`, `.isOptional`, `.isUnique`, `.defaultValue`, `.valueType`; `Schema.Entity` exposes `.attributes`, `.relationships`, `.attributesByName` |
| Is `defaultValue` populated from a property initializer? | **Yes.** `var count: Int = 0` reports `defaultValue = 0`. An optional with no initializer reports `isOptional = true`, `defaultValue = nil` |
| Is `isUnique` false by default, including for `id`? | **Yes** — nothing is unique unless `@Attribute(.unique)` is written |
| Does `@Relationship(inverse:)` with `[Child]? = []` work? | **Yes**, and the inverse is populated after `save()` |
| Swift 6 strict concurrency friction? | **None observed** for this shape. The rule in spec §9 still stands: keep a test's context and its models on one actor, and **do not lower `SWIFT_VERSION`** — that goes back to the user |

---

## File Structure

**Created in `StenoKit/Models/`** — one responsibility each:

| File | Responsibility |
|---|---|
| `Status.swift` | The fixed four statuses (D11) |
| `EventKind.swift` | The six event kinds (§3.3) |
| `SourceRefKind.swift` | The five external-reference kinds (§3.4) |
| `ReportCadence.swift` | `daily` / `periodic` (§3.1, D17) |
| `Event.swift` | Append-only event; every field `private(set)`, `redact()` the only mutator |
| `SourceRef.swift` | External reference, plus `DedupKey` and the pure `newRefs(from:existing:)` rule |
| `TaskItem.swift` | Task, `setStatus` and the `modifiedAt`-stamping mutators |
| `Project.swift` | Project, seven `modifiedAt`-stamping mutators |
| `StandupReport.swift` | Report record, `markUndone()` the only mutator |

**Created in `StenoTests/Models/`:**

| File | Responsibility |
|---|---|
| `EnumTests.swift` | Case counts and raw-value stability |
| `EventTests.swift` | Redaction |
| `SourceRefTests.swift` | Dedup rule, pure |
| `TaskItemTests.swift` | Status transitions, `modifiedAt` |
| `ProjectTests.swift` | `modifiedAt` stamping and non-stamping |
| `StandupReportTests.swift` | `markUndone` |
| `TestContainer.swift` | In-memory container fixture + the model-type list |
| `SchemaConformanceTests.swift` | §6 CloudKit rules and §3 field coverage, by reflection |
| `PersistedInvariantsTests.swift` | Relationship/FK coherence and dedup against a live context |

**Modified:** `docs/DECISIONS.md`, `docs/ARCHITECTURE.md` (Task 8).

**Not created:** anything enumerating the model types in `StenoKit` — no `StenoSchema`. That list
belongs to M0-04 with the container (spec §8). The test bundle declares its own.

---

## Task 1: Enums

**Files:**
- Create: `StenoKit/Models/Status.swift`, `StenoKit/Models/EventKind.swift`,
  `StenoKit/Models/SourceRefKind.swift`, `StenoKit/Models/ReportCadence.swift`
- Test: `StenoTests/Models/EnumTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum Status: String, Codable, CaseIterable, Sendable` with cases `todo`,
  `inProgress`, `blocked`, `done`; `public enum EventKind: String, Codable, CaseIterable,
  Sendable` with `created`, `note`, `statusChanged`, `blockedReason`, `externalUpdate`,
  `standupReported`; `public enum SourceRefKind: String, Codable, CaseIterable, Sendable` with
  `jiraIssue`, `confluencePage`, `githubPR`, `url`, `mcpResource`; `public enum ReportCadence:
  String, Codable, CaseIterable, Sendable` with `daily`, `periodic`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Models/EnumTests.swift`:

```swift
import Testing

@testable import StenoKit

@Test("D11: exactly four statuses, no custom ones")
func statusHasExactlyFourCases() {
    #expect(Status.allCases.count == 4)
}

// Raw values are the export format (§10.2), so renaming a case silently
// breaks every file already written. Pinning them makes that a test failure
// instead of a bug found on import.
@Test("Status raw values are stable")
func statusRawValues() {
    #expect(Status.todo.rawValue == "todo")
    #expect(Status.inProgress.rawValue == "inProgress")
    #expect(Status.blocked.rawValue == "blocked")
    #expect(Status.done.rawValue == "done")
}

@Test("§3.3: six event kinds")
func eventKindHasSixCases() {
    #expect(EventKind.allCases.count == 6)
}

@Test("EventKind raw values are stable")
func eventKindRawValues() {
    #expect(EventKind.created.rawValue == "created")
    #expect(EventKind.note.rawValue == "note")
    #expect(EventKind.statusChanged.rawValue == "statusChanged")
    #expect(EventKind.blockedReason.rawValue == "blockedReason")
    #expect(EventKind.externalUpdate.rawValue == "externalUpdate")
    #expect(EventKind.standupReported.rawValue == "standupReported")
}

@Test("§3.4: five source-ref kinds")
func sourceRefKindHasFiveCases() {
    #expect(SourceRefKind.allCases.count == 5)
}

@Test("SourceRefKind raw values are stable")
func sourceRefKindRawValues() {
    #expect(SourceRefKind.jiraIssue.rawValue == "jiraIssue")
    #expect(SourceRefKind.confluencePage.rawValue == "confluencePage")
    #expect(SourceRefKind.githubPR.rawValue == "githubPR")
    #expect(SourceRefKind.url.rawValue == "url")
    #expect(SourceRefKind.mcpResource.rawValue == "mcpResource")
}

@Test("D17: two cadences")
func reportCadenceHasTwoCases() {
    #expect(ReportCadence.allCases.count == 2)
    #expect(ReportCadence.daily.rawValue == "daily")
    #expect(ReportCadence.periodic.rawValue == "periodic")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — compile errors, `cannot find 'Status' in scope` and the same for the other three
enums.

- [ ] **Step 3: Write the four enums**

`StenoKit/Models/Status.swift`:

```swift
/// Task status — the fixed four (REQUIREMENTS.md §3.2, D11).
///
/// There is deliberately no `custom` case and no associated value: §2.1 rules
/// out custom statuses and workflow engines, and an enum that cannot express
/// one is a cheaper guarantee than a rule someone has to remember.
public enum Status: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress
    case blocked
    case done
}
```

`StenoKit/Models/EventKind.swift`:

```swift
/// What an `Event` records (REQUIREMENTS.md §3.3).
public enum EventKind: String, Codable, CaseIterable, Sendable {
    /// Task was created.
    case created
    /// User added progress.
    case note
    /// Status transition.
    case statusChanged
    /// Optional note on why a task is blocked.
    case blockedReason
    /// An integration fetch found a change.
    case externalUpdate
    /// A report was generated and copied.
    case standupReported
}
```

`StenoKit/Models/SourceRefKind.swift`:

```swift
/// The kind of external system a `SourceRef` points at (REQUIREMENTS.md §3.4).
public enum SourceRefKind: String, Codable, CaseIterable, Sendable {
    case jiraIssue
    case confluencePage
    case githubPR
    case url
    case mcpResource
}
```

`StenoKit/Models/ReportCadence.swift`:

```swift
/// How often a project is reported on (REQUIREMENTS.md §3.1, D17).
///
/// The cadence-to-staleness mapping (FR-5's 3 days / 10 days) deliberately
/// does not live here — it is a stale-detection rule and belongs to the task
/// that implements FR-5.
public enum ReportCadence: String, Codable, CaseIterable, Sendable {
    case daily
    case periodic
}
```

All four use `String` raw values rather than `Int` because §10.2 specifies a human-readable,
greppable export, and because reordering cases can then never silently rewrite stored data.

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, all enum tests green.

- [ ] **Step 5: Lint and format**

Run: `make format && make lint`
Expected: exit 0, no diff churn beyond your own files.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Models/Status.swift StenoKit/Models/EventKind.swift \
        StenoKit/Models/SourceRefKind.swift StenoKit/Models/ReportCadence.swift \
        StenoTests/Models/EnumTests.swift
git commit -m "feat: add the domain enums

String raw values because §10.2's export is specified as human-readable and
greppable, and because reordering cases can then never silently rewrite stored
data. The raw values are pinned by tests for the same reason: renaming a case
would otherwise break every export file already written, and be found on import
rather than in CI.

Status has exactly four cases with no custom case and no associated value —
D11 and §2.1 rule out custom statuses, and an enum that cannot express one is
cheaper than a rule.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: `Event` — the append-only model

Built before the other models because it is the smallest and it establishes the
`private(set)` + mutator pattern every later task follows.

**Files:**
- Create: `StenoKit/Models/Event.swift`
- Test: `StenoTests/Models/EventTests.swift`

**Interfaces:**
- Consumes: `EventKind` (Task 1).
- Produces: `public final class Event` with `public private(set)` properties `id: UUID`,
  `taskID: UUID`, `timestamp: Date`, `kind: EventKind`, `body: String`, `payload: Data?`,
  `isRedacted: Bool`; initialiser
  `init(id: UUID = UUID(), taskID: UUID, timestamp: Date, kind: EventKind, body: String, payload: Data? = nil)`;
  one mutator `public func redact()`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Models/EventTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

@Test("§3.3: redact() hides the event without destroying it")
func redactRetainsTheRow() {
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let payload = Data("{\"key\":\"PAY-421\"}".utf8)
    let event = Event(
        taskID: UUID(),
        timestamp: timestamp,
        kind: .note,
        body: "Repro'd the race condition, it's in the retry handler",
        payload: payload
    )

    #expect(!event.isRedacted)

    event.redact()

    #expect(event.isRedacted)
    // Soft delete: the row is retained in full. §3.3 permits hiding an event
    // from summaries, never erasing what it said.
    #expect(event.body == "Repro'd the race condition, it's in the retry handler")
    #expect(event.timestamp == timestamp)
    #expect(event.payload == payload)
    #expect(event.kind == .note)
}

@Test("redact() is idempotent")
func redactIsIdempotent() {
    let event = Event(taskID: UUID(), timestamp: .now, kind: .note, body: "note")
    event.redact()
    event.redact()
    #expect(event.isRedacted)
}

@Test("the initialiser is the only place a field but isRedacted is set")
func initialiserPopulatesEveryField() {
    let id = UUID()
    let taskID = UUID()
    let timestamp = Date(timeIntervalSince1970: 42)
    let event = Event(
        id: id,
        taskID: taskID,
        timestamp: timestamp,
        kind: .statusChanged,
        body: "IN-PROGRESS → BLOCKED"
    )

    #expect(event.id == id)
    #expect(event.taskID == taskID)
    #expect(event.timestamp == timestamp)
    #expect(event.kind == .statusChanged)
    #expect(event.body == "IN-PROGRESS → BLOCKED")
    #expect(event.payload == nil)
    #expect(!event.isRedacted)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'Event' in scope`.

- [ ] **Step 3: Write `Event`**

Create `StenoKit/Models/Event.swift`:

```swift
import Foundation
import SwiftData

/// An immutable record of something that happened to a task
/// (REQUIREMENTS.md §3.3, D10).
///
/// **This type is the append-only invariant expressed as API.** Every stored
/// property is `private(set)`, so the initialiser is the only place any field
/// but `isRedacted` is ever written, and `redact()` is the only mutator.
/// Swift enforces this: a `private(set)` setter is unreachable from any other
/// file, including elsewhere in StenoKit.
///
/// A feature that appears to need an event mutated actually needs a new event
/// or a redaction (§13). Do not add a setter here.
///
/// The link to the task is `taskID` alone — no relationship, deliberately, and
/// asymmetrically with `SourceRef`. §3.2's field table lists `sourceRefs` and
/// lists no `events`; see the M0-03 design doc §1.2 before "restoring
/// symmetry".
@Model
public final class Event {
    public private(set) var id: UUID = UUID()
    public private(set) var taskID: UUID = UUID()
    public private(set) var timestamp: Date = Date.now
    public private(set) var kind: EventKind = EventKind.note
    public private(set) var body: String = ""
    public private(set) var payload: Data?
    public private(set) var isRedacted: Bool = false

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        timestamp: Date,
        kind: EventKind,
        body: String,
        payload: Data? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.payload = payload
    }

    /// Hide this event from summaries while retaining the row (§3.3).
    ///
    /// One-way by design: there is no `unredact()`. Nothing in the spec
    /// reverses a redaction — FR-4.1's undo redacts `standupReported` events
    /// and is not itself undoable, and note correction is specified as
    /// redact-and-reappend. A reversible setter can be added by the task that
    /// needs one; it could not easily be taken away.
    public func redact() {
        isRedacted = true
    }
}
```

Note the fully-qualified defaults `Date.now` and `EventKind.note`. The shorthand `.now` / `.note`
fails to compile inside `@Model` — see Global Constraints.

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Confirm the invariant is real, then undo it**

Temporarily add this to `StenoTests/Models/EventTests.swift` and run `make test`:

```swift
func proveSetterIsInaccessible(_ event: Event) {
    event.body = "rewritten"
}
```

Expected: FAIL to compile with `error: cannot assign to property: 'body' setter is inaccessible`.
**Delete these four lines and re-run `make test` to confirm green.** This is the one moment the
append-only guarantee is demonstrated rather than asserted; the design doc §7.1 records that no
permanent test can cover it, because a test asserting the absence of a setter would not compile.

- [ ] **Step 6: Lint, format, commit**

```bash
make format && make lint && make test
git add StenoKit/Models/Event.swift StenoTests/Models/EventTests.swift
git commit -m "feat: add the append-only Event model

Every stored property is private(set) and redact() is the only mutator, which
makes §3.3's append-only rule a compile-time guarantee rather than a convention
agents are asked to honour — Swift makes the setter unreachable from any other
file, including elsewhere in StenoKit.

redact() is one-way. Nothing in the spec reverses a redaction: FR-4.1's undo
redacts standupReported events and is not itself undoable, and note correction
is specified as redact-and-reappend. A reversible setter can be added by the
task that needs one; it could not easily be taken away.

Event links to its task by taskID alone, with no relationship, asymmetrically
with SourceRef — §3.2's field table lists sourceRefs and lists no events.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: `SourceRef` and the dedup rule

**Files:**
- Create: `StenoKit/Models/SourceRef.swift`
- Test: `StenoTests/Models/SourceRefTests.swift`

**Interfaces:**
- Consumes: `SourceRefKind` (Task 1).
- Produces: `public final class SourceRef` with `public private(set)` properties `id: UUID`,
  `taskID: UUID`, `kind: SourceRefKind`, `identifier: String`, `url: String?`,
  `lastFetchedAt: Date?`, `cachedSummary: String?`, plus `public var task: TaskItem?`;
  initialiser
  `init(id: UUID = UUID(), taskID: UUID, kind: SourceRefKind, identifier: String, url: String? = nil)`;
  mutator `public func recordFetch(summary: String?, at date: Date)`; nested
  `public struct DedupKey: Hashable, Sendable`; `public var dedupKey: DedupKey`; and
  `public static func newRefs(from candidates: [SourceRef], existing: [SourceRef]) -> [SourceRef]`.

> `SourceRef.task` refers to `TaskItem`, which Task 4 creates. **This task will not compile
> until Task 4 lands.** Write `SourceRef.swift` and `TaskItem.swift` in the same working session:
> do Task 3's steps 1–3, then Task 4's steps 1–3, then run the tests for both. The commits stay
> separate. This is the one place in the plan where two tasks are compile-coupled, and it is
> inherent in the relationship the spec chose (design doc §1.1).

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Models/SourceRefTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private func ref(
    taskID: UUID,
    kind: SourceRefKind = .jiraIssue,
    identifier: String
) -> SourceRef {
    SourceRef(taskID: taskID, kind: kind, identifier: identifier)
}

@Test("§3.4: re-extracting an existing ref yields nothing")
func existingRefIsNotDuplicated() {
    let taskID = UUID()
    let existing = [ref(taskID: taskID, identifier: "PAY-421")]
    let candidates = [ref(taskID: taskID, identifier: "PAY-421")]

    #expect(SourceRef.newRefs(from: candidates, existing: existing).isEmpty)
}

@Test("§3.4: a genuinely new ref is returned")
func newRefIsReturned() {
    let taskID = UUID()
    let existing = [ref(taskID: taskID, identifier: "PAY-421")]
    let candidates = [ref(taskID: taskID, identifier: "BILL-7")]

    let result = SourceRef.newRefs(from: candidates, existing: existing)

    #expect(result.count == 1)
    #expect(result.first?.identifier == "BILL-7")
}

// Extraction runs on the title and on every note (FR-1.5), so one pass over a
// task legitimately yields the same key several times.
@Test("§3.4: duplicates within one batch collapse to one")
func intraBatchDuplicatesCollapse() {
    let taskID = UUID()
    let candidates = [
        ref(taskID: taskID, identifier: "PAY-421"),
        ref(taskID: taskID, identifier: "PAY-421"),
        ref(taskID: taskID, identifier: "PAY-421"),
    ]

    let result = SourceRef.newRefs(from: candidates, existing: [])

    #expect(result.count == 1)
}

@Test("§3.4: the key is (taskID, kind, identifier) — each part discriminates")
func everyKeyComponentDiscriminates() {
    let taskA = UUID()
    let taskB = UUID()
    let existing = [ref(taskID: taskA, kind: .jiraIssue, identifier: "PAY-421")]

    // Same identifier, different task.
    #expect(
        SourceRef.newRefs(
            from: [ref(taskID: taskB, kind: .jiraIssue, identifier: "PAY-421")],
            existing: existing
        ).count == 1
    )
    // Same identifier and task, different kind.
    #expect(
        SourceRef.newRefs(
            from: [ref(taskID: taskA, kind: .url, identifier: "PAY-421")],
            existing: existing
        ).count == 1
    )
}

// Normalizing case or whitespace belongs to extraction (M1-01). Doing it here
// too would mean two components decide what "the same ticket" means, and they
// would eventually disagree.
@Test("§3.4: identifiers match exactly, without normalization")
func identifierMatchIsExact() {
    let taskID = UUID()
    let existing = [ref(taskID: taskID, identifier: "PAY-421")]

    let result = SourceRef.newRefs(
        from: [ref(taskID: taskID, identifier: "pay-421")],
        existing: existing
    )

    #expect(result.count == 1)
}

@Test("§10.1: recordFetch moves the summary and the timestamp together")
func recordFetchSetsBothFields() {
    let fetched = Date(timeIntervalSince1970: 5_000)
    let sourceRef = ref(taskID: UUID(), identifier: "PAY-421")

    #expect(sourceRef.lastFetchedAt == nil)
    #expect(sourceRef.cachedSummary == nil)

    sourceRef.recordFetch(summary: "In Review; 2 new comments", at: fetched)

    #expect(sourceRef.cachedSummary == "In Review; 2 new comments")
    #expect(sourceRef.lastFetchedAt == fetched)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'SourceRef' in scope`.

- [ ] **Step 3: Write `SourceRef`**

Create `StenoKit/Models/SourceRef.swift`:

```swift
import Foundation
import SwiftData

/// A reference from a task to an external system (REQUIREMENTS.md §3.4).
///
/// A first-class model rather than an embedded value: it carries its own `id`
/// so it participates in merge-by-UUID import like every other record, and so
/// `lastFetchedAt` / `cachedSummary` survive a round-trip.
@Model
public final class SourceRef {
    public private(set) var id: UUID = UUID()

    /// The authoritative link to the owning task.
    ///
    /// `task` below is the same fact expressed as a SwiftData relationship,
    /// kept for call-site ergonomics. **This field is what export, import, and
    /// M2.5-02's merge read** — see the M0-03 design doc §1.1, and the test
    /// asserting the two never disagree.
    public private(set) var taskID: UUID = UUID()

    public var task: TaskItem?

    public private(set) var kind: SourceRefKind = SourceRefKind.url
    public private(set) var identifier: String = ""
    public private(set) var url: String?
    public private(set) var lastFetchedAt: Date?
    public private(set) var cachedSummary: String?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        kind: SourceRefKind,
        identifier: String,
        url: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.identifier = identifier
        self.url = url
    }

    /// Record an observation of the external source (§5, §10.1).
    ///
    /// The summary and the timestamp move together because §10.1 resolves them
    /// as a pair — later `lastFetchedAt` wins, and `nil` loses to any value. A
    /// caller able to set the summary without the timestamp could produce a
    /// record the merge cannot order.
    public func recordFetch(summary: String?, at date: Date) {
        cachedSummary = summary
        lastFetchedAt = date
    }
}

extension SourceRef {
    /// The identity a ref is unique on (§3.4).
    ///
    /// This is a uniqueness rule enforced in code, never an
    /// `@Attribute(.unique)` — §6 forbids those.
    public struct DedupKey: Hashable, Sendable {
        public let taskID: UUID
        public let kind: SourceRefKind
        public let identifier: String

        public init(taskID: UUID, kind: SourceRefKind, identifier: String) {
            self.taskID = taskID
            self.kind = kind
            self.identifier = identifier
        }
    }

    public var dedupKey: DedupKey {
        DedupKey(taskID: taskID, kind: kind, identifier: identifier)
    }

    /// The refs in `candidates` that are not already in `existing`, with
    /// duplicates inside `candidates` collapsed.
    ///
    /// Callers insert only what this returns — that is what makes
    /// re-extraction a no-op rather than a new row. Extraction runs on the
    /// title and on every note (FR-1.5), so both halves of the rule earn their
    /// place: the same ticket key recurs across saves *and* within one pass.
    ///
    /// Pure and store-free on purpose, so extraction (M1-01) can apply it
    /// before anything is inserted, and so it is testable without a container.
    ///
    /// `identifier` matches exactly. Normalizing case or whitespace belongs to
    /// extraction; doing it in both places would mean two components decide
    /// what "the same ticket" means.
    public static func newRefs(
        from candidates: [SourceRef],
        existing: [SourceRef]
    ) -> [SourceRef] {
        var seen = Set(existing.map(\.dedupKey))
        var result: [SourceRef] = []
        for candidate in candidates {
            guard seen.insert(candidate.dedupKey).inserted else { continue }
            result.append(candidate)
        }
        return result
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`

Expected: **still FAIL**, now with `cannot find type 'TaskItem' in scope`. That is the documented
compile coupling. Go do Task 4 steps 1–3, then return here.

- [ ] **Step 5: Re-run after Task 4's model exists**

Run: `make test`
Expected: PASS — all `SourceRefTests` green.

- [ ] **Step 6: Lint, format, commit**

```bash
make format && make lint
git add StenoKit/Models/SourceRef.swift StenoTests/Models/SourceRefTests.swift
git commit -m "feat: add SourceRef and the dedup rule

The (taskID, kind, identifier) uniqueness from §3.4 lands as a pure, store-free
function rather than an @Attribute(.unique), which §6 forbids. Pure so that
M1-01's extraction can apply it before anything is inserted, and so it is
testable without owning a container — M0-04 owns that.

newRefs collapses duplicates within one batch as well as against existing rows,
because extraction runs on the title and on every note (FR-1.5), so a single
pass over a task legitimately yields the same ticket key several times.

Identifiers match byte for byte. Normalizing case or whitespace belongs to
extraction; doing it in both places would mean two components decide what the
same ticket means, and they would eventually disagree.

recordFetch moves cachedSummary and lastFetchedAt together because §10.1
resolves them as a pair.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: `TaskItem`

**Files:**
- Create: `StenoKit/Models/TaskItem.swift`
- Test: `StenoTests/Models/TaskItemTests.swift`

**Interfaces:**
- Consumes: `Status` (Task 1), `SourceRef` (Task 3).
- Produces: `public final class TaskItem` with `public private(set)` properties `id: UUID`,
  `title: String`, `projectID: UUID`, `status: Status`, `createdAt: Date`,
  `statusChangedAt: Date`, `completedAt: Date?`, `isArchived: Bool`, `modifiedAt: Date`, plus
  `public var sourceRefs: [SourceRef]?`; initialiser
  `init(id: UUID = UUID(), title: String, projectID: UUID, createdAt: Date)`; mutators
  `rename(to: String, at: Date)`, `move(toProject: UUID, at: Date)`,
  `setArchived(_: Bool, at: Date)`, `setStatus(_: Status, at: Date)`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Models/TaskItemTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let created = Date(timeIntervalSince1970: 0)
private let firstMove = Date(timeIntervalSince1970: 100)
private let secondMove = Date(timeIntervalSince1970: 200)

private func task() -> TaskItem {
    TaskItem(title: "Repro the retry-handler race", projectID: UUID(), createdAt: created)
}

// All 16 (from, to) pairs. §3.2 allows any status to move to any other, so the
// table is the whole space rather than a sampled workflow.
@Test(
    "§3.2 + design §5.1: status transitions",
    arguments: Status.allCases, Status.allCases
)
func statusTransition(from: Status, to: Status) {
    let item = task()
    item.setStatus(from, at: firstMove)

    let statusChangedBefore = item.statusChangedAt
    let completedBefore = item.completedAt
    let modifiedBefore = item.modifiedAt

    item.setStatus(to, at: secondMove)

    #expect(item.status == to)

    if to == from {
        // A redundant set is a complete no-op. Re-stamping would reset a
        // completed task's completion time and hand M1-05 a statusChanged
        // event describing a transition that never happened.
        #expect(item.statusChangedAt == statusChangedBefore)
        #expect(item.completedAt == completedBefore)
    } else {
        #expect(item.statusChangedAt == secondMove)
        #expect(item.completedAt == (to == .done ? secondMove : nil))
    }

    // §4 of the design doc: status is event-governed, so it never stamps
    // modifiedAt. A broad rule here would let a status-only change on one
    // machine win the title at merge time and revert a retitle made on another.
    #expect(item.modifiedAt == modifiedBefore)
}

@Test("§3.2: entering done sets completedAt, leaving it clears it")
func completedAtFollowsDone() {
    let item = task()

    item.setStatus(.done, at: firstMove)
    #expect(item.completedAt == firstMove)

    item.setStatus(.inProgress, at: secondMove)
    #expect(item.completedAt == nil)
}

@Test("a new task starts in todo with its timestamps seeded from createdAt")
func initialState() {
    let item = task()
    #expect(item.status == .todo)
    #expect(item.createdAt == created)
    #expect(item.statusChangedAt == created)
    #expect(item.modifiedAt == created)
    #expect(item.completedAt == nil)
    #expect(!item.isArchived)
}

@Test("design §4: rename stamps modifiedAt")
func renameStampsModifiedAt() {
    let item = task()
    item.rename(to: "Fix the retry-handler race", at: firstMove)
    #expect(item.title == "Fix the retry-handler race")
    #expect(item.modifiedAt == firstMove)
}

@Test("design §4: move stamps modifiedAt")
func moveStampsModifiedAt() {
    let item = task()
    let destination = UUID()
    item.move(toProject: destination, at: firstMove)
    #expect(item.projectID == destination)
    #expect(item.modifiedAt == firstMove)
}

@Test("design §4: setArchived stamps modifiedAt")
func setArchivedStampsModifiedAt() {
    let item = task()
    item.setArchived(true, at: firstMove)
    #expect(item.isArchived)
    #expect(item.modifiedAt == firstMove)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'TaskItem' in scope`.

- [ ] **Step 3: Write `TaskItem`**

Create `StenoKit/Models/TaskItem.swift`:

```swift
import Foundation
import SwiftData

/// A single line of work (REQUIREMENTS.md §3.2).
///
/// Named `TaskItem`, not `Task`, because `Task` shadows `_Concurrency.Task` in
/// every file that can see it, and this app runs async integration fetches from
/// M4 onward (§3.2). Only the Swift identifier changed: prose, UI copy, the
/// export key `"tasks"`, and the `taskID` field name all still say "task".
///
/// `status` here is a **cache**, not the truth. The truth is the newest
/// `statusChanged` event — which is why M2.5-02's merge derives status from the
/// log rather than copying this field.
@Model
public final class TaskItem {
    public private(set) var id: UUID = UUID()
    public private(set) var title: String = ""
    public private(set) var projectID: UUID = UUID()
    public private(set) var status: Status = Status.todo
    public private(set) var createdAt: Date = Date.now
    public private(set) var statusChangedAt: Date = Date.now
    public private(set) var completedAt: Date?

    @Relationship(inverse: \SourceRef.task)
    public var sourceRefs: [SourceRef]? = []

    public private(set) var isArchived: Bool = false

    /// Last mutation of a field whose import conflict rule is
    /// "later `modifiedAt` wins" (§10.1).
    ///
    /// Deliberately **not** stamped by `setStatus` — see that method.
    public private(set) var modifiedAt: Date = Date.now

    public init(id: UUID = UUID(), title: String, projectID: UUID, createdAt: Date) {
        self.id = id
        self.title = title
        self.projectID = projectID
        self.createdAt = createdAt
        self.statusChangedAt = createdAt
        self.modifiedAt = createdAt
    }

    public func rename(to newTitle: String, at date: Date) {
        title = newTitle
        modifiedAt = date
    }

    public func move(toProject newProjectID: UUID, at date: Date) {
        projectID = newProjectID
        modifiedAt = date
    }

    public func setArchived(_ archived: Bool, at date: Date) {
        isArchived = archived
        modifiedAt = date
    }

    /// Move the task to `new`, maintaining `statusChangedAt` and `completedAt`
    /// (§3.2). Any status may move to any other; there is no workflow.
    ///
    /// **Setting the status a task already has is a complete no-op.** §3.2 does
    /// not cover that case; it is decided here. Re-stamping would let a
    /// redundant call reset a completed task's completion time, and would hand
    /// M1-05 a `statusChanged` event describing a transition that never
    /// happened — which then flows into a stand-up report as work that did not
    /// occur.
    ///
    /// **This does not append the `statusChanged` event**, which needs a
    /// `ModelContext` that M0-04 owns. M1-05's status service is the sanctioned
    /// caller and appends it. A transition that skips its event is a real bug
    /// that surfaces much later as an inexplicable revert after an import
    /// (§10.1) — so call the service, not this, once M1-05 exists.
    ///
    /// Does not stamp `modifiedAt`: status is derived from the event log at
    /// merge time, so it has no claim on the timestamp that arbitrates `title`.
    public func setStatus(_ new: Status, at date: Date) {
        guard new != status else { return }
        status = new
        statusChangedAt = date
        completedAt = (new == .done) ? date : nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS — `TaskItemTests` green, and `SourceRefTests` (Task 3) now compiles and passes too.

- [ ] **Step 5: Lint, format, commit**

```bash
make format && make lint
git add StenoKit/Models/TaskItem.swift StenoTests/Models/TaskItemTests.swift
git commit -m "feat: add TaskItem with status and modifiedAt invariants

setStatus maintains completedAt and statusChangedAt but deliberately does not
stamp modifiedAt: §10.1 derives status from the event log at merge time, so it
has no claim on the timestamp that arbitrates title. Under a broad rule a
status-only change on one machine would win the title too and silently revert a
retitle made on the other, recoverable only by hand.

§3.2 is silent on setting a task to the status it already has, so this closes
it: a redundant setStatus is a complete no-op. Re-stamping would reset a
completed task's completion time and hand M1-05 a statusChanged event for a
transition that never happened, which would then flow into a stand-up report as
work that did not occur.

setStatus cannot append the statusChanged event — that needs a ModelContext
M0-04 owns, and M1-05's service is the sanctioned caller. The doc comment says
so, because a transition that skips its event surfaces much later as an
inexplicable revert after an import.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: `Project`

**Files:**
- Create: `StenoKit/Models/Project.swift`
- Test: `StenoTests/Models/ProjectTests.swift`

**Interfaces:**
- Consumes: `ReportCadence` (Task 1).
- Produces: `public final class Project` with `public private(set)` properties `id: UUID`,
  `name: String`, `colorHex: String`, `jiraProjectKeys: [String]`, `isArchived: Bool`,
  `sortOrder: Int`, `reportCadence: ReportCadence`, `staleThresholdDays: Int?`,
  `modifiedAt: Date`, plus `public var lastStandupAt: Date?`; initialiser
  `init(id: UUID = UUID(), name: String, colorHex: String, jiraProjectKeys: [String] = [], sortOrder: Int = 0, reportCadence: ReportCadence = .daily, staleThresholdDays: Int? = nil, modifiedAt: Date)`;
  mutators `rename(to:at:)`, `setColorHex(_:at:)`, `setJiraProjectKeys(_:at:)`,
  `setArchived(_:at:)`, `setSortOrder(_:at:)`, `setCadence(_:at:)`,
  `setStaleThresholdDays(_:at:)`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Models/ProjectTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let created = Date(timeIntervalSince1970: 0)
private let changed = Date(timeIntervalSince1970: 100)

private func project() -> Project {
    Project(name: "Payments Platform", colorHex: "#3B82F6", modifiedAt: created)
}

@Test("a new project carries its seeded values")
func initialState() {
    let subject = Project(
        name: "EM — Hiring",
        colorHex: "#F59E0B",
        jiraProjectKeys: ["PAY", "BILL"],
        sortOrder: 3,
        reportCadence: .periodic,
        staleThresholdDays: 14,
        modifiedAt: created
    )

    #expect(subject.name == "EM — Hiring")
    #expect(subject.colorHex == "#F59E0B")
    #expect(subject.jiraProjectKeys == ["PAY", "BILL"])
    #expect(subject.sortOrder == 3)
    #expect(subject.reportCadence == .periodic)
    #expect(subject.staleThresholdDays == 14)
    #expect(subject.modifiedAt == created)
    #expect(subject.lastStandupAt == nil)
    #expect(!subject.isArchived)
}

@Test("design §4: every governed mutator stamps modifiedAt")
func governedMutatorsStampModifiedAt() {
    var subject = project()
    subject.rename(to: "Payments", at: changed)
    #expect(subject.name == "Payments")
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setColorHex("#EF4444", at: changed)
    #expect(subject.colorHex == "#EF4444")
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setJiraProjectKeys(["PAY"], at: changed)
    #expect(subject.jiraProjectKeys == ["PAY"])
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setArchived(true, at: changed)
    #expect(subject.isArchived)
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setSortOrder(9, at: changed)
    #expect(subject.sortOrder == 9)
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setCadence(.periodic, at: changed)
    #expect(subject.reportCadence == .periodic)
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setStaleThresholdDays(7, at: changed)
    #expect(subject.staleThresholdDays == 7)
    #expect(subject.modifiedAt == changed)
}

// §10.1 gives lastStandupAt its own merge rule — take the later timestamp — so
// it must not stamp modifiedAt. It is a plain var precisely so this holds by
// construction rather than by a mutator remembering not to.
@Test("design §4: advancing lastStandupAt does not stamp modifiedAt")
func lastStandupAtDoesNotStampModifiedAt() {
    let subject = project()
    subject.lastStandupAt = changed
    #expect(subject.lastStandupAt == changed)
    #expect(subject.modifiedAt == created)
}

@Test("FR-6: staleThresholdDays can be cleared back to nil")
func staleThresholdCanBeCleared() {
    let subject = project()
    subject.setStaleThresholdDays(7, at: changed)
    subject.setStaleThresholdDays(nil, at: changed)
    // nil means "derive from cadence, then the global default" (FR-5), so
    // clearing it has to be expressible.
    #expect(subject.staleThresholdDays == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'Project' in scope`.

- [ ] **Step 3: Write `Project`**

Create `StenoKit/Models/Project.swift`:

```swift
import Foundation
import SwiftData

/// A project or a non-project activity — "Payments Platform", "EM — Hiring"
/// (REQUIREMENTS.md §3.1).
///
/// Flat: no epics, no nesting, no hierarchy (D9).
@Model
public final class Project {
    public private(set) var id: UUID = UUID()
    public private(set) var name: String = ""
    public private(set) var colorHex: String = ""
    public private(set) var jiraProjectKeys: [String] = []
    public private(set) var isArchived: Bool = false
    public private(set) var sortOrder: Int = 0

    /// When this project was last reported on — the report window per D8.
    ///
    /// The user attends multiple different stand-ups, so each project tracks
    /// its own timestamp: a report for project A must not advance the clock for
    /// project B.
    ///
    /// A plain `var`, not `private(set)`, and that is the design. §10.1 gives
    /// this field its own merge rule — take the later timestamp — so it must
    /// **not** stamp `modifiedAt`. A plain property gets that by construction;
    /// a mutator would get it by remembering.
    public var lastStandupAt: Date?

    public private(set) var reportCadence: ReportCadence = ReportCadence.daily

    /// Per-project staleness override. `nil` means derive from cadence, then
    /// fall back to the global default (FR-5).
    public private(set) var staleThresholdDays: Int?

    /// Last mutation of a field whose import conflict rule is
    /// "later `modifiedAt` wins" (§10.1). See `lastStandupAt` for what is
    /// excluded and why.
    public private(set) var modifiedAt: Date = Date.now

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        jiraProjectKeys: [String] = [],
        sortOrder: Int = 0,
        reportCadence: ReportCadence = .daily,
        staleThresholdDays: Int? = nil,
        modifiedAt: Date
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.jiraProjectKeys = jiraProjectKeys
        self.sortOrder = sortOrder
        self.reportCadence = reportCadence
        self.staleThresholdDays = staleThresholdDays
        self.modifiedAt = modifiedAt
    }

    public func rename(to newName: String, at date: Date) {
        name = newName
        modifiedAt = date
    }

    public func setColorHex(_ newColorHex: String, at date: Date) {
        colorHex = newColorHex
        modifiedAt = date
    }

    public func setJiraProjectKeys(_ keys: [String], at date: Date) {
        jiraProjectKeys = keys
        modifiedAt = date
    }

    public func setArchived(_ archived: Bool, at date: Date) {
        isArchived = archived
        modifiedAt = date
    }

    public func setSortOrder(_ order: Int, at date: Date) {
        sortOrder = order
        modifiedAt = date
    }

    public func setCadence(_ cadence: ReportCadence, at date: Date) {
        reportCadence = cadence
        modifiedAt = date
    }

    public func setStaleThresholdDays(_ days: Int?, at date: Date) {
        staleThresholdDays = days
        modifiedAt = date
    }
}
```

Note the default parameter `reportCadence: ReportCadence = .daily` in the *initialiser* — the
shorthand is fine there. Only the `@Model` **property** defaults need qualification.

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Lint, format, commit**

```bash
make format && make lint
git add StenoKit/Models/Project.swift StenoTests/Models/ProjectTests.swift
git commit -m "feat: add Project with per-field modifiedAt discipline

The seven mutators that write modifiedAt-governed fields stamp it; lastStandupAt
is a plain var and does not. §10.1 gives lastStandupAt its own merge rule — take
the later timestamp, because reporting is a historical fact and taking the
earlier one would re-report work already spoken aloud — so it has no business
advancing the timestamp that arbitrates name. Leaving it a plain property gets
that by construction rather than by a mutator remembering not to.

staleThresholdDays stays clearable to nil, which FR-5 needs: nil means derive
from cadence, then fall back to the global default.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: `StandupReport`

**Files:**
- Create: `StenoKit/Models/StandupReport.swift`
- Test: `StenoTests/Models/StandupReportTests.swift`

**Interfaces:**
- Consumes: nothing beyond Foundation.
- Produces: `public final class StandupReport` with `public private(set)` properties `id: UUID`,
  `projectID: UUID`, `generatedAt: Date`, `windowStart: Date`, `windowEnd: Date`,
  `markdownBody: String`, `wasAIGenerated: Bool`, `modelUsed: String?`, `isUndone: Bool`;
  initialiser
  `init(id: UUID = UUID(), projectID: UUID, generatedAt: Date, windowStart: Date, windowEnd: Date, markdownBody: String, wasAIGenerated: Bool, modelUsed: String? = nil)`;
  mutator `public func markUndone()`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Models/StandupReportTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let windowStart = Date(timeIntervalSince1970: 0)
private let windowEnd = Date(timeIntervalSince1970: 86_400)

private func report() -> StandupReport {
    StandupReport(
        projectID: UUID(),
        generatedAt: windowEnd,
        windowStart: windowStart,
        windowEnd: windowEnd,
        markdownBody: "*Since last stand-up*\n- Fixed the retry-handler race",
        wasAIGenerated: true,
        modelUsed: "claude-opus-5"
    )
}

@Test("§3.5: a report carries its window and provenance")
func initialState() {
    let subject = report()
    #expect(subject.windowStart == windowStart)
    #expect(subject.windowEnd == windowEnd)
    #expect(subject.wasAIGenerated)
    #expect(subject.modelUsed == "claude-opus-5")
    #expect(!subject.isUndone)
}

// FR-4.1: undo restores the previous lastStandupAt by reading it from the
// report's windowStart, so the row has to survive being undone.
@Test("FR-4.1: markUndone retains the row and its window")
func markUndoneRetainsTheRow() {
    let subject = report()

    subject.markUndone()

    #expect(subject.isUndone)
    #expect(subject.windowStart == windowStart)
    #expect(subject.markdownBody.contains("retry-handler race"))
}

@Test("§7.4: a fallback report records that no model was used")
func fallbackReportHasNoModel() {
    let subject = StandupReport(
        projectID: UUID(),
        generatedAt: windowEnd,
        windowStart: windowStart,
        windowEnd: windowEnd,
        markdownBody: "- Fixed the retry-handler race",
        wasAIGenerated: false
    )

    #expect(!subject.wasAIGenerated)
    #expect(subject.modelUsed == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'StandupReport' in scope`.

- [ ] **Step 3: Write `StandupReport`**

Create `StenoKit/Models/StandupReport.swift`:

```swift
import Foundation
import SwiftData

/// A stand-up report as it was copied (REQUIREMENTS.md §3.5).
///
/// A record of something that happened, so nothing but `isUndone` changes after
/// creation. FR-4.1 requires the row be retained and marked, never deleted —
/// and undo reads the previous `lastStandupAt` back out of `windowStart`, so
/// the window has to survive too.
@Model
public final class StandupReport {
    public private(set) var id: UUID = UUID()
    public private(set) var projectID: UUID = UUID()
    public private(set) var generatedAt: Date = Date.now

    /// The previous `lastStandupAt`, or 24h before now on a project's first
    /// report (FR-4 step 2).
    public private(set) var windowStart: Date = Date.now
    public private(set) var windowEnd: Date = Date.now

    /// The final text as copied.
    public private(set) var markdownBody: String = ""

    /// False when §7.4's deterministic fallback produced this report.
    public private(set) var wasAIGenerated: Bool = false

    /// For debugging quality regressions; nil for a fallback report.
    public private(set) var modelUsed: String?

    /// Set by FR-4.1's undo. The row is retained and excluded from history.
    public private(set) var isUndone: Bool = false

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        generatedAt: Date,
        windowStart: Date,
        windowEnd: Date,
        markdownBody: String,
        wasAIGenerated: Bool,
        modelUsed: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.markdownBody = markdownBody
        self.wasAIGenerated = wasAIGenerated
        self.modelUsed = modelUsed
    }

    /// Mark this report undone, retaining the row (FR-4.1).
    public func markUndone() {
        isUndone = true
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Lint, format, commit**

```bash
make format && make lint
git add StenoKit/Models/StandupReport.swift StenoTests/Models/StandupReportTests.swift
git commit -m "feat: add StandupReport

A record of something that happened, so every field but isUndone is fixed at
creation. FR-4.1 requires the row be retained and marked rather than deleted,
and undo reads the previous lastStandupAt back out of windowStart — so the
window has to survive being undone, which the test asserts.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 7: The §6 and §3 conformance gates

The acceptance criteria that say "a test asserts this rather than a reviewer eyeballing it".
Needs all five models, so it comes last.

**Files:**
- Create: `StenoTests/Models/TestContainer.swift`,
  `StenoTests/Models/SchemaConformanceTests.swift`,
  `StenoTests/Models/PersistedInvariantsTests.swift`
- Test: those files are the tests.

**Interfaces:**
- Consumes: all five models.
- Produces: `func stenoModelTypes() -> [any PersistentModel.Type]` and
  `func inMemoryContainer() throws -> ModelContainer`, both test-only.

- [ ] **Step 1: Write the test fixture**

Create `StenoTests/Models/TestContainer.swift`:

```swift
import Foundation
import SwiftData

@testable import StenoKit

/// The five model types.
///
/// **This list is test-only.** The list the application ships belongs to M0-04
/// with the `ModelContainer` it feeds — a list here as well would be a second
/// declaration of the schema that M0-04's container could silently disagree
/// with. The consequence M0-04 inherits: a model type missing from *its* list
/// is caught by nothing in M0-03, so M0-04 needs its own test asserting the
/// container it builds covers every model.
///
/// A function rather than a global `let` so there is no shared mutable state
/// for strict concurrency to reason about.
func stenoModelTypes() -> [any PersistentModel.Type] {
    [Project.self, TaskItem.self, Event.self, SourceRef.self, StandupReport.self]
}

/// An in-memory store for tests that need a live context.
///
/// **A test fixture, not a store configuration.** M0-04 owns where the
/// application's store actually lives (open question O-3).
func inMemoryContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema(stenoModelTypes()),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}
```

- [ ] **Step 2: Write the failing conformance tests**

Create `StenoTests/Models/SchemaConformanceTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let entityNames = ["Project", "TaskItem", "Event", "SourceRef", "StandupReport"]

private func entity(named name: String) throws -> Schema.Entity {
    let schema = Schema(stenoModelTypes())
    return try #require(
        schema.entities.first { $0.name == name },
        "no entity named \(name) — is it missing from stenoModelTypes()?"
    )
}

// §6, and the standing instruction in §14 not to strip it: keeping the schema
// CloudKit-compatible costs nothing and is independently required by M2.5's
// merge. Reinstating it later would be a data migration on a live store.
@Test("§6: no attribute is unique, id included", arguments: entityNames)
func noAttributeIsUnique(name: String) throws {
    for attribute in try entity(named: name).attributes {
        #expect(
            !attribute.isUnique,
            "\(name).\(attribute.name) is unique — §6 forbids @Attribute(.unique)"
        )
    }
}

@Test("§6: every attribute is optional or has a default", arguments: entityNames)
func everyAttributeIsOptionalOrDefaulted(name: String) throws {
    for attribute in try entity(named: name).attributes {
        #expect(
            attribute.isOptional || attribute.defaultValue != nil,
            "\(name).\(attribute.name) is neither optional nor defaulted — §6 requires one"
        )
    }
}

@Test("§6: every relationship is optional", arguments: entityNames)
func everyRelationshipIsOptional(name: String) throws {
    for relationship in try entity(named: name).relationships {
        #expect(
            relationship.isOptional,
            "\(name).\(relationship.name) is a non-optional relationship — CloudKit forbids it"
        )
    }
}

// The field tables from §3.1–§3.5, transcribed. This is what catches a field
// silently dropped by a later refactor — the failure mode that makes M0-03
// expensive to get wrong, because a field missed here is a store migration.
private let expectedAttributes: [String: [String: Bool]] = [
    "Project": [
        "id": false, "name": false, "colorHex": false, "jiraProjectKeys": false,
        "isArchived": false, "sortOrder": false, "lastStandupAt": true,
        "reportCadence": false, "staleThresholdDays": true, "modifiedAt": false,
    ],
    "TaskItem": [
        "id": false, "title": false, "projectID": false, "status": false,
        "createdAt": false, "statusChangedAt": false, "completedAt": true,
        "isArchived": false, "modifiedAt": false,
    ],
    "Event": [
        "id": false, "taskID": false, "timestamp": false, "kind": false,
        "body": false, "payload": true, "isRedacted": false,
    ],
    "SourceRef": [
        "id": false, "taskID": false, "kind": false, "identifier": false,
        "url": true, "lastFetchedAt": true, "cachedSummary": true,
    ],
    "StandupReport": [
        "id": false, "projectID": false, "generatedAt": false, "windowStart": false,
        "windowEnd": false, "markdownBody": false, "wasAIGenerated": false,
        "modelUsed": true, "isUndone": false,
    ],
]

private let expectedRelationships: [String: [String]] = [
    "Project": [],
    "TaskItem": ["sourceRefs"],
    "Event": [],
    "SourceRef": ["task"],
    "StandupReport": [],
]

@Test("§3.1–§3.5: every specified field exists, with the specified optionality",
      arguments: entityNames)
func fieldsMatchTheSpec(name: String) throws {
    let entity = try entity(named: name)
    let expected = try #require(expectedAttributes[name])

    let actualNames = Set(entity.attributesByName.keys)
    #expect(
        actualNames == Set(expected.keys),
        """
        \(name) attributes drifted from §3.
        missing: \(Set(expected.keys).subtracting(actualNames).sorted())
        unexpected: \(actualNames.subtracting(Set(expected.keys)).sorted())
        """
    )

    for (attributeName, isOptional) in expected {
        let attribute = try #require(entity.attributesByName[attributeName])
        #expect(
            attribute.isOptional == isOptional,
            "\(name).\(attributeName) optionality differs from §3"
        )
    }
}

@Test("§3: relationships are exactly the ones the spec names", arguments: entityNames)
func relationshipsMatchTheSpec(name: String) throws {
    let entity = try entity(named: name)
    let expected = try #require(expectedRelationships[name])
    #expect(Set(entity.relationshipsByName.keys) == Set(expected))
}
```

- [ ] **Step 3: Run to verify the conformance tests pass**

Run: `make test`
Expected: PASS. If `fieldsMatchTheSpec` fails, the message names the missing or unexpected
attribute — fix the model to match §3, never the expectation table, unless you have decided the
spec is wrong and are amending it in this PR (§9.5).

- [ ] **Step 4: Write the failing persisted-invariant tests**

Create `StenoTests/Models/PersistedInvariantsTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

// The dual representation the design chose (design doc §1.1): taskID is
// authoritative for export, import, and M2.5-02's merge; the relationship is
// there for call-site ergonomics. This is the test that stops them diverging.
@Test("design §1.1: taskID and the relationship never disagree")
func foreignKeyMatchesRelationship() throws {
    let container = try inMemoryContainer()
    let context = ModelContext(container)

    let task = TaskItem(
        title: "Fix the retry-handler race",
        projectID: UUID(),
        createdAt: Date(timeIntervalSince1970: 0)
    )
    context.insert(task)

    let sourceRef = SourceRef(taskID: task.id, kind: .jiraIssue, identifier: "PAY-421")
    sourceRef.task = task
    context.insert(sourceRef)

    try context.save()

    let fetched = try context.fetch(FetchDescriptor<SourceRef>())
    let persisted = try #require(fetched.first)

    #expect(persisted.taskID == persisted.task?.id)
    #expect(persisted.taskID == task.id)
    #expect(task.sourceRefs?.count == 1)
}

@Test("§3.4: the dedup rule holds against a live context")
func dedupHoldsWithAContext() throws {
    let container = try inMemoryContainer()
    let context = ModelContext(container)

    let taskID = UUID()
    let first = SourceRef(taskID: taskID, kind: .jiraIssue, identifier: "PAY-421")
    context.insert(first)
    try context.save()

    // Extraction runs again over the same task and sees the same ticket key.
    let existing = try context.fetch(FetchDescriptor<SourceRef>())
    let candidates = [SourceRef(taskID: taskID, kind: .jiraIssue, identifier: "PAY-421")]
    for newRef in SourceRef.newRefs(from: candidates, existing: existing) {
        context.insert(newRef)
    }
    try context.save()

    #expect(try context.fetch(FetchDescriptor<SourceRef>()).count == 1)
}

@Test("models survive a save and fetch with their invariant fields intact")
func modelsRoundTrip() throws {
    let container = try inMemoryContainer()
    let context = ModelContext(container)

    let completedAt = Date(timeIntervalSince1970: 500)
    let task = TaskItem(
        title: "Fix the retry-handler race",
        projectID: UUID(),
        createdAt: Date(timeIntervalSince1970: 0)
    )
    task.setStatus(.done, at: completedAt)
    context.insert(task)

    let event = Event(
        taskID: task.id,
        timestamp: completedAt,
        kind: .statusChanged,
        body: "IN-PROGRESS → DONE"
    )
    event.redact()
    context.insert(event)

    try context.save()

    let fetchedTask = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first)
    #expect(fetchedTask.status == .done)
    #expect(fetchedTask.completedAt == completedAt)
    #expect(fetchedTask.statusChangedAt == completedAt)

    let fetchedEvent = try #require(try context.fetch(FetchDescriptor<Event>()).first)
    #expect(fetchedEvent.isRedacted)
    #expect(fetchedEvent.body == "IN-PROGRESS → DONE")
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

If strict concurrency complains about `ModelContext` crossing an isolation boundary, annotate the
failing test function `@MainActor` — that is the response the design doc §9 pre-agreed. **Do not
change `SWIFT_VERSION` in `project.yml`**; if lowering it ever looks necessary, stop and raise it
with the user (D-009).

- [ ] **Step 6: Verify the §6 gate actually bites**

Temporarily add `@Attribute(.unique)` above `id` in `StenoKit/Models/Event.swift` and run
`make test`.

Expected: FAIL with `Event.id is unique — §6 forbids @Attribute(.unique)`.

**Revert that change and re-run `make test` to confirm green.** A gate nobody has watched fail is
a gate nobody knows works — D-014 exists because a `make test` that could not see new files
passed green for a whole task.

- [ ] **Step 7: Lint, format, commit**

```bash
make format && make lint
git add StenoTests/Models/TestContainer.swift \
        StenoTests/Models/SchemaConformanceTests.swift \
        StenoTests/Models/PersistedInvariantsTests.swift
git commit -m "test: assert the §6 schema rules and §3 field coverage

The acceptance criteria ask for a test rather than a reviewer's eye, so these
read the SwiftData schema by reflection: no attribute is unique, every attribute
is optional or defaulted, every relationship is optional. Confirmed to bite by
adding @Attribute(.unique) and watching it fail.

fieldsMatchTheSpec transcribes §3.1–§3.5's field tables and names what drifted.
That is the guard on the failure mode that makes this task expensive: a field
dropped by a later refactor is a store migration, and nothing else would catch
it.

The model-type list here is test-only. M0-04 owns the one the app ships, and
inherits the need to assert that its container covers every model — a type
missing from that list is caught by nothing here.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 8: Record the decisions and open the PR

**Files:**
- Modify: `docs/DECISIONS.md` (add D-015, D-016; close O-4 in the open table)
- Modify: `docs/ARCHITECTURE.md` (mark `Models/` as landed)

- [ ] **Step 1: Add the decision entries**

In `docs/DECISIONS.md`, after the D-014 entry and before the `---` that precedes "## Open",
insert:

```markdown
### D-015 — `modifiedAt` is stamped only by the fields it arbitrates
**2026-08-19** · M0-03 · **Status:** accepted — closes O-4

`modifiedAt` is written only by mutations to fields whose §10.1 conflict rule is "later
`modifiedAt` wins": `Project.name`, `.colorHex`, `.jiraProjectKeys`, `.isArchived`, `.sortOrder`,
`.reportCadence`, `.staleThresholdDays`; `TaskItem.title`, `.projectID`, `.isArchived`. Fields
with their own authority never touch it — `status`, `statusChangedAt` and `completedAt` are
derived from the event log, and `lastStandupAt` takes the later timestamp. `Project.lastStandupAt`
is a plain `var` rather than a `private(set)` with a mutator, so this holds by construction.

**Why:** `modifiedAt` is per *record*, not per field. Under a broad rule — every mutation stamps
it — a machine that changes only a task's status still advances the record's timestamp, and at
merge time that later stamp wins the *title* too, silently reverting a retitle made on the other
machine. The append-only log makes that recoverable only by hand. The narrow rule keeps the
timestamp attached to exactly the fields it arbitrates, and matches how §3.1 and §3.2 already word
it: "last mutation of a mutable field (`name`, `colorHex`, …)".
**Alternatives:** stamping on every mutation (the lost update above); per-field timestamps (exact
at merge, but it contradicts §3.1/§3.2's field tables, grows the schema, and hands M2.5-02 more
cases rather than fewer).

### D-016 — `TaskItem`↔`SourceRef` carries both a relationship and the foreign key
**2026-08-19** · M0-03 · **Status:** accepted

`TaskItem.sourceRefs: [SourceRef]?` with `@Relationship(inverse: \SourceRef.task)`, alongside
`SourceRef.taskID`. **`taskID` is authoritative**: export, import, and M2.5-02's merge read it,
and a test asserts `ref.taskID == ref.task?.id` across a save and fetch. Every other link in the
domain — `Event.taskID`, `TaskItem.projectID`, `StandupReport.projectID` — is a UUID foreign key
with no relationship.

**Why:** §3.2's field table lists `sourceRefs` as a relationship while §3.4 gives `SourceRef` its
own `taskID`, and the M0-03 task file requires UUID foreign keys because merge-by-UUID depends on
them. Both were kept, at the user's direction, for call-site ergonomics. The cost is that one fact
has three representations — `taskID`, the relationship, and its CloudKit-required inverse — which
is why the coherence test exists rather than a convention.
**Alternatives:** `taskID` alone with no stored array (one source of truth, nothing for merge to
reconcile, but it needs a §3.2 amendment and every reader of a task's refs pays for it).
```

Then in the "## Open" table, delete the `O-4` row.

- [ ] **Step 2: Mark the models as landed in ARCHITECTURE.md**

In `docs/ARCHITECTURE.md` §5, change the `Models/` line from:

```
  Models/         SwiftData models, enums                (M0-03)
```

to:

```
  Models/         SwiftData models, enums                (exists, M0-03)
```

- [ ] **Step 3: Run the full gate**

Run: `make build && make test && make lint`
Expected: all three exit 0. This is §9.5 step 4; do not open the PR without it.

- [ ] **Step 4: Commit the docs**

```bash
git add docs/DECISIONS.md docs/ARCHITECTURE.md
git commit -m "docs: record M0-03's decisions and close O-4

D-015 closes O-4 with the narrow modifiedAt rule and the reasoning that argues
for it — the timestamp is per record, so a broad rule lets a status-only change
on one machine win the title and revert a retitle made on the other.

D-016 records why TaskItem carries both a relationship and taskID, and which of
the two is authoritative, so a later reviewer does not remove the one the merge
depends on.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin feat/domain-models
```

Open the PR with this body, filling the template's sections:

- **What and why:** the five models from §3, with §3's invariants enforced by `private(set)` plus
  mutators rather than by convention.
- **Verified:** paste the actual output of `make build && make test && make lint`. Not "should
  pass" (§13).
- **Spec observations — three, none of them silent deviations:**
  1. **§3.2 is silent on a redundant `setStatus`.** Decided here as a complete no-op, because
     re-stamping would reset a completed task's `completedAt` and hand M1-05 a `statusChanged`
     event for a transition that never happened.
  2. **§3.2 lists `sourceRefs` while the task file mandates UUID foreign keys.** Both kept,
     `taskID` authoritative, coherence asserted by a test (D-016). The UUID-foreign-key reasoning
     is recorded so a later reviewer does not "fix" it into relationship macros.
  3. **O-4 closed** by D-015, with the lost-update reasoning.
- **Boundary handed to M0-04:** this PR ships no enumeration of the model types — the test bundle
  declares its own. M0-04 owns the shipped list *and* a test asserting the container it builds
  covers every model, because a type missing from that list is caught by nothing here.
- **Not covered by tests:** the "`Event` exposes no mutating API except `isRedacted`" criterion is
  enforced at compile time by `private(set)`; no test can assert the absence of a setter that
  would not compile. Demonstrated once during Task 2 and reverted.

- [ ] **Step 6: Stop**

Do not merge. The user reviews and merges (CLAUDE.md, §9.5).

---

## Self-Review

**Spec coverage.** Every spec section maps to a task:

| Spec section | Task |
|---|---|
| §1.1 dual representation | 3, 4 (model), 7 (coherence test), 8 (D-016) |
| §1.2 `Event` has no inverse | 2 |
| §2 enums, and the excluded FR-5 table | 1 |
| §3.1–§3.5 the five models | 5, 4, 2, 3, 6 |
| §4 `modifiedAt` / O-4 | 4, 5 (tests), 8 (D-015) |
| §5 mutation API | 2, 3, 4, 5, 6 |
| §5.1 redundant `setStatus` | 4 |
| §5.2 the seam M1-05 owns | 4 (doc comment), 8 (PR body) |
| §6 dedup | 3 (pure), 7 (with a context) |
| §7 test plan, tests 1–7 | 1–7; test 1→Task 7, 2→Task 7, 3→Task 4, 4→Tasks 4 and 5, 5→Tasks 3 and 7, 6→Task 7, 7→Task 2 |
| §7.1 the untestable criterion | 2 (demonstrated then reverted), 8 (PR body) |
| §8 layout, no `StenoSchema` | File Structure, Task 7 |
| §9 risks | Environment as verified — all three closed empirically |
| §10 out of scope | respected; no task touches the container, UI, event creation, or FR-5 |
| §11 what lands beyond code | 8 |

**Placeholder scan.** No TBDs, no "add error handling", no "similar to Task N". Every code step
carries the actual code.

**Type consistency.** Checked across tasks: `setStatus(_:at:)`, `rename(to:at:)`,
`move(toProject:at:)`, `setArchived(_:at:)`, `recordFetch(summary:at:)`, `redact()`,
`markUndone()`, `newRefs(from:existing:)`, `dedupKey`, `stenoModelTypes()`, `inMemoryContainer()`
are spelled identically everywhere they appear. `TaskItem.init` takes `createdAt` and seeds
`statusChangedAt` and `modifiedAt` from it, which Task 4's `initialState` test asserts and Task
7's round-trip relies on. `Project.init` requires `modifiedAt` explicitly — there is no `.now`
default anywhere, per the spec's no-defaulted-clock rule.

**One known coupling**, called out in Task 3 rather than left to be discovered: `SourceRef.task`
refers to `TaskItem`, so Tasks 3 and 4 must be written before either compiles. Their commits stay
separate.
