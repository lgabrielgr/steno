# M1-02 Quick Capture Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the one shared code path that turns typed text into a persisted task — routing to a project without ever asking, extracting references, and appending the `created` event — inside a measured latency budget.

**Architecture:** A pure `ProjectRouter` decides which project a capture belongs to; a `@MainActor CaptureService` owning a `ModelContext` writes the task, its `created` event and its refs in one save with rollback; an `@Observable CaptureFieldModel` holds the in-progress capture and its dismissible chip so all three surfaces share it rather than each rebuilding it. The main window becomes the first consumer.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing (XCTest only for `measure`), XcodeGen, SwiftLint, swift-format.

**Spec:** [`docs/superpowers/specs/2026-08-26-m1-02-quick-capture-core-design.md`](../specs/2026-08-26-m1-02-quick-capture-core-design.md)

## Global Constraints

Every task's requirements implicitly include this section.

- **Never commit to `main`.** All work is on `feat/quick-capture-core`, already branched from `942742c`. Open a PR; do not merge it (CLAUDE.md, §9.5).
- **`make build && make test && make lint` must all pass before the PR.** "This should compile" is not acceptable (§13).
- **The event log is append-only.** Never mutate or delete an `Event` row. `Event` exposes no setters but `redact()`; do not add one (§3.3).
- **Capture latency is a P0 functional requirement.** No modal, no picker, no validation error before or during text entry (§1.1, FR-1.4).
- **The Swift type is `TaskItem`, never `Task`** — `Task` shadows `_Concurrency.Task` (§3.2).
- **Views get no store access.** No `@Query`, no `@Environment(\.modelContext)`, no `.modelContainer(_:)` on the scene (D-019).
- **Tests use `ModelContext(container)`, never `container.mainContext`** — `mainContext` does not retain its container, and the next insert traps inside SwiftData with `EXC_BREAKPOINT`.
- **Swift Testing (`@Test`/`#expect`) everywhere except `measure`**, which has no Swift Testing equivalent and stays XCTest (D-011).
- **SwiftLint runs `--strict`.** `force_unwrapping` is an opt-in rule that is ON: no `!` unwraps anywhere, including tests — use `try #require`. No `try!`.
- **swift-format owns layout, SwiftLint owns semantics** (D-013). Run `make format` before `make lint`. Do not hand-restructure code to satisfy a layout complaint.
- **`Logger` takes one interpolated literal.** `OSLogMessage` has no `+` operator, so `Log.app.error("a" + "b")` does not compile.
- **A `@Test` function taking a `private` type must itself be `private`.**
- **`make test` regenerates `Steno.xcodeproj` every run** by design (D-014). New files under `StenoKit/`, `Steno/` and `StenoTests/` are picked up by XcodeGen's directory globs — `project.yml` needs no edit.
- **`xcbeautify` hides parameterized test cases.** `make test` never prints individual table cases; their absence from output is not failure.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `StenoKit/Capture/RoutingDecision.swift` | `KeyMatch`, `RoutingDecision` — value types |
| `StenoKit/Capture/ProjectRouter.swift` | FR-1.4's ladder and ticket-key matching, pure |
| `StenoKit/Capture/CaptureService.swift` | `CaptureError`; route → extract → insert → one save |
| `StenoKit/Persistence/StoreBootstrap.swift` | `StenoStore.seedDefaultProjectIfEmpty(in:)` |
| `StenoKit/Features/Capture/CaptureChip.swift` | The chip's rendered facts |
| `StenoKit/Features/Capture/CaptureFieldModel.swift` | Draft text, live chip, dismissal, commit |
| `Steno/Features/Capture/CaptureFieldView.swift` | The capture field and its chip |
| `Steno/Features/MainWindow/ProjectEditSheet.swift` | Project name and Jira keys |
| `StenoTests/Capture/ProjectRouterTests.swift` | Router, against literal arrays |
| `StenoTests/Capture/CaptureServiceTests.swift` | Service, container-backed |
| `StenoTests/Capture/CapturePerformanceTests.swift` | The latency gate (XCTest) |
| `StenoTests/Persistence/StoreBootstrapTests.swift` | Seeding |
| `StenoTests/Features/Capture/CaptureFieldModelTests.swift` | Chip state machine |

**Modify:**

| Path | Change |
|---|---|
| `StenoKit/Support/Logging.swift` | Add the capture signposter |
| `StenoKit/Features/MainWindow/MainWindowModel.swift:242-268` | `createTask` delegates; `targetProjectID()` deleted; `updateProject` added |
| `Steno/App/StenoApp.swift` | Seed on launch |
| `Steno/Features/MainWindow/MainWindowView.swift` | `.newTask` renders `CaptureFieldView` |
| `Steno/Features/MainWindow/SidebarView.swift` | "Edit Project…" context-menu item |
| `StenoTests/Features/MainWindow/MainWindowModelTasksTests.swift` | Ladder replaces the `targetProjectID` stand-in |
| `docs/REQUIREMENTS.md` | FR-3 gains project editing; v1.11 |
| `docs/ARCHITECTURE.md` | §3 invariant row, §5 layout |
| `docs/DECISIONS.md` | D-024 … D-027 |
| `docs/tasks/README.md` | Tick M1-02 |

**Move:** `StenoKit/Features/MainWindow/ProjectPalette.swift` → `StenoKit/Support/ProjectPalette.swift` (Task 3 — the persistence layer needs it and must not depend on a feature).

---

### Task 1: `ProjectRouter` — FR-1.4's ladder

**Files:**
- Create: `StenoKit/Capture/RoutingDecision.swift`
- Create: `StenoKit/Capture/ProjectRouter.swift`
- Test: `StenoTests/Capture/ProjectRouterTests.swift`

**Interfaces:**
- Consumes: `Project` (`id`, `sortOrder`, `jiraProjectKeys`), `JiraKey.pattern` from M1-01.
- Produces: `KeyMatch(key:projectID:)`, `RoutingDecision(projectID:source:)`, `RoutingDecision.Source`, `ProjectRouter.ticketKeyMatch(text:projects:)`, `ProjectRouter.route(text:projects:preferred:lastUsed:defaultProjectID:ignoringTicketKey:)`. Tasks 2 and 4 both call these.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/ProjectRouterTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

private func makeProject(_ name: String, keys: [String] = [], order: Int = 0) -> Project {
    Project(
        name: name,
        colorHex: ProjectPalette.hex(forIndex: order),
        jiraProjectKeys: keys,
        sortOrder: order,
        modifiedAt: epoch
    )
}

@Test("a configured ticket key routes to its project")
func configuredKeyRoutes() throws {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let match = try #require(
        ProjectRouter.ticketKeyMatch(text: "PAY-421 fix the retry handler", projects: [payments, hiring])
    )

    #expect(match.key == "PAY-421")
    #expect(match.projectID == payments.id)
}

@Test("the first *matching* key wins, not the first key")
func firstMatchingKeyWins() throws {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)

    let match = try #require(
        ProjectRouter.ticketKeyMatch(text: "UTF-8 fix for PAY-421", projects: [payments])
    )

    // UTF-8 matches JiraKey.pattern but no configured project, so the scan
    // continues. This is what absorbs M1-01's documented false positives.
    #expect(match.key == "PAY-421")
}

@Test("a key inside a URL still routes")
func keyInsideURLRoutes() throws {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let text = "see https://acme.atlassian.net/browse/PAY-421"

    let match = try #require(ProjectRouter.ticketKeyMatch(text: text, projects: [payments]))

    // Deliberately unlike M1-01's extractor, whose overlap rule suppresses
    // keys inside links. That rule is right for refs and wrong for routing.
    #expect(match.key == "PAY-421")
}

@Test("an unconfigured prefix does not match")
func unconfiguredPrefixDoesNotMatch() {
    let hiring = makeProject("EM — Hiring", order: 0)

    #expect(ProjectRouter.ticketKeyMatch(text: "PAY-421", projects: [hiring]) == nil)
}

@Test("prefix comparison ignores case and surrounding space")
func prefixComparisonIsNormalised() throws {
    let payments = makeProject("Payments", keys: [" pay "], order: 0)

    let match = try #require(ProjectRouter.ticketKeyMatch(text: "PAY-421", projects: [payments]))

    #expect(match.projectID == payments.id)
}

@Test("two projects claiming one prefix resolve by sortOrder")
func contestedPrefixResolvesBySortOrder() throws {
    let second = makeProject("Second", keys: ["PAY"], order: 5)
    let first = makeProject("First", keys: ["PAY"], order: 1)

    // Passed out of order deliberately: the rule is sortOrder, not array order.
    let match = try #require(ProjectRouter.ticketKeyMatch(text: "PAY-1", projects: [second, first]))

    #expect(match.projectID == first.id)
}

@Test("a ticket key outranks every other rung")
func ticketKeyOutranksEverything() {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "PAY-421 fix it",
        projects: [payments, hiring],
        preferred: hiring.id,
        lastUsed: hiring.id,
        defaultProjectID: hiring.id,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == payments.id)
    #expect(decision.source == .ticketKey("PAY-421"))
}

@Test("with no key match, the surface's preference wins")
func preferredWinsWithoutAKey() {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "write the interview loop doc",
        projects: [payments, hiring],
        preferred: hiring.id,
        lastUsed: payments.id,
        defaultProjectID: nil,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .preferred)
}

@Test("with no preference, the last-used project wins")
func lastUsedWinsWithoutAPreference() {
    let payments = makeProject("Payments", order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments, hiring],
        preferred: nil,
        lastUsed: hiring.id,
        defaultProjectID: payments.id,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .lastUsed)
}

@Test("with no last-used, FR-6's configured default wins")
func configuredDefaultIsRungFour() {
    let payments = makeProject("Payments", order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments, hiring],
        preferred: nil,
        lastUsed: nil,
        defaultProjectID: hiring.id,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .configuredDefault)
}

@Test("the last resort is the first project by sortOrder")
func firstProjectIsTheLastResort() {
    let payments = makeProject("Payments", order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments, hiring],
        preferred: nil,
        lastUsed: nil,
        defaultProjectID: nil,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == payments.id)
    #expect(decision.source == .firstProject)
}

@Test("a rung naming an archived project is skipped, not honoured")
func staleRungIsSkipped() {
    let payments = makeProject("Payments", order: 0)
    let vanished = UUID()

    let decision = ProjectRouter.route(
        text: "plain text",
        projects: [payments],
        preferred: vanished,
        lastUsed: vanished,
        defaultProjectID: vanished,
        ignoringTicketKey: false
    )

    // `projects` is the live list; a rung pointing outside it is stale.
    #expect(decision.projectID == payments.id)
    #expect(decision.source == .firstProject)
}

@Test("ignoringTicketKey skips rung one and lands on rung two")
func dismissedChipFallsThrough() {
    let payments = makeProject("Payments", keys: ["PAY"], order: 0)
    let hiring = makeProject("EM — Hiring", order: 1)

    let decision = ProjectRouter.route(
        text: "PAY-421 fix it",
        projects: [payments, hiring],
        preferred: hiring.id,
        lastUsed: nil,
        defaultProjectID: nil,
        ignoringTicketKey: true
    )

    #expect(decision.projectID == hiring.id)
    #expect(decision.source == .preferred)
}

@Test("with no projects at all there is nowhere to route")
func noProjectsRoutesNowhere() {
    let decision = ProjectRouter.route(
        text: "PAY-421",
        projects: [],
        preferred: nil,
        lastUsed: nil,
        defaultProjectID: nil,
        ignoringTicketKey: false
    )

    #expect(decision.projectID == nil)
    #expect(decision.source == .none)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'ProjectRouter' in scope`.

- [ ] **Step 3: Write the value types**

Create `StenoKit/Capture/RoutingDecision.swift`:

```swift
import Foundation

/// A ticket key found in capture text, and the project its prefix named.
public struct KeyMatch: Equatable, Sendable {
    public let key: String
    public let projectID: UUID

    public init(key: String, projectID: UUID) {
        self.key = key
        self.projectID = projectID
    }
}

/// Where a capture is going, and which of FR-1.4's rungs decided it.
///
/// `source` is not decoration: the chip is shown for `.ticketKey` and for
/// nothing else, so the rung has to survive the call that computed it.
public struct RoutingDecision: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// FR-1.4 rung 1, carrying the key that decided it.
        case ticketKey(String)
        /// Rung 2 — the capturing surface's own context.
        case preferred
        /// Rung 3 — FR-1.4's specified default.
        case lastUsed
        /// Rung 4 — FR-6's configurable default. Unreachable until M1-08.
        case configuredDefault
        /// Rung 5 — the last resort.
        case firstProject
        /// Nowhere to route. See the design doc §4.2.
        case none
    }

    public let projectID: UUID?
    public let source: Source

    public init(projectID: UUID?, source: Source) {
        self.projectID = projectID
        self.source = source
    }
}
```

- [ ] **Step 4: Write the router**

Create `StenoKit/Capture/ProjectRouter.swift`:

```swift
import Foundation

/// FR-1.4's project assignment, as a pure function.
///
/// No store, no clock, no I/O — so every rule below is testable against
/// literal arrays, the same property that makes M1-01's extractor cheap to
/// reason about. `projects` is always the caller's **live** (non-archived)
/// list, in `sortOrder`; a rung naming anything outside it is stale and is
/// skipped rather than honoured.
public enum ProjectRouter {
    /// The first ticket key in `text` whose prefix names a live project.
    ///
    /// **This deliberately does not call `ReferenceExtractor`,** for two
    /// independent reasons (design §2.3).
    ///
    /// *Cost.* The chip re-derives on every keystroke, and `NSDataDetector` is
    /// the expensive half of extraction — 180 µs on a capture string but
    /// ~180 ms on a 250 KB paste, which would then be paid per keystroke. A
    /// bare regex scan with an early exit has no such cliff.
    ///
    /// *Correctness.* M1-01's overlap rule suppresses keys sitting inside
    /// links so that a browse URL yields one ref rather than two. That is
    /// right for extraction and wrong for routing:
    /// `https://acme.atlassian.net/browse/PAY-421` should route to Payments.
    /// Routing wants every key the text mentions; extraction wants each one
    /// once. Different questions, different scans.
    public static func ticketKeyMatch(text: String, projects: [Project]) -> KeyMatch? {
        guard !text.isEmpty else { return nil }
        let byPrefix = prefixTable(projects)
        guard !byPrefix.isEmpty else { return nil }

        // `firstMatch` in a loop rather than `matches(of:)`, which is eager:
        // the common case is a key in the first few words, and this returns
        // there instead of scanning to the end of a paste.
        var remainder = Substring(text)
        while let match = remainder.firstMatch(of: JiraKey.pattern) {
            let key = String(match.output)
            if let prefix = prefix(of: key), let projectID = byPrefix[prefix] {
                return KeyMatch(key: key, projectID: projectID)
            }
            // `JiraKey.pattern` cannot match empty, so `upperBound` always
            // advances and this terminates.
            remainder = remainder[match.range.upperBound...]
        }
        return nil
    }

    /// FR-1.4's ladder: ticket key, then the surface's own preference, then
    /// the last-used project, then FR-6's configured default, then the first
    /// project — and only then nothing.
    ///
    /// `defaultProjectID` is a parameter from day one and stays `nil` until
    /// M1-08 builds the setting. Its acceptance criterion is then met by
    /// passing an argument rather than by editing this function.
    public static func route(
        text: String,
        projects: [Project],
        preferred: UUID?,
        lastUsed: UUID?,
        defaultProjectID: UUID?,
        ignoringTicketKey: Bool
    ) -> RoutingDecision {
        if !ignoringTicketKey, let match = ticketKeyMatch(text: text, projects: projects) {
            return RoutingDecision(projectID: match.projectID, source: .ticketKey(match.key))
        }

        let live = Set(projects.map(\.id))
        if let preferred, live.contains(preferred) {
            return RoutingDecision(projectID: preferred, source: .preferred)
        }
        if let lastUsed, live.contains(lastUsed) {
            return RoutingDecision(projectID: lastUsed, source: .lastUsed)
        }
        if let defaultProjectID, live.contains(defaultProjectID) {
            return RoutingDecision(projectID: defaultProjectID, source: .configuredDefault)
        }
        if let first = projects.min(by: { $0.sortOrder < $1.sortOrder }) {
            return RoutingDecision(projectID: first.id, source: .firstProject)
        }
        return RoutingDecision(projectID: nil, source: .none)
    }

    /// Prefix → project, with the lowest `sortOrder` winning a contested one.
    ///
    /// Two projects claiming `PAY` is a configuration mistake, but it has to
    /// resolve the same way every time rather than by fetch order.
    private static func prefixTable(_ projects: [Project]) -> [String: UUID] {
        var table: [String: UUID] = [:]
        for project in projects.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            for key in project.jiraProjectKeys {
                let normalised = key.trimmingCharacters(in: .whitespaces).uppercased()
                guard !normalised.isEmpty, table[normalised] == nil else { continue }
                table[normalised] = project.id
            }
        }
        return table
    }

    /// `"PAY-421"` → `"PAY"`.
    ///
    /// `JiraKey.pattern` is `\b[A-Z][A-Z0-9]{1,9}-\d+\b`, so a match always
    /// has exactly one separating hyphen — but this does not assume its only
    /// caller passes a match.
    private static func prefix(of key: String) -> String? {
        guard let separator = key.lastIndex(of: "-") else { return nil }
        return String(key[key.startIndex..<separator]).uppercased()
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Format, lint, commit**

```bash
make format && make lint
git add StenoKit/Capture/RoutingDecision.swift StenoKit/Capture/ProjectRouter.swift StenoTests/Capture/ProjectRouterTests.swift
git commit -m "feat: project routing ladder for quick capture (FR-1.4)

FR-1.4 says a capture must never block on project selection, and names
two rungs: a ticket key whose prefix matches a configured project, then
the last-used project. Three more are needed to make that total — the
capturing surface's own context, FR-6's configured default, and the
first project — so the ladder is written once, pure, here.

Routing scans for ticket keys directly rather than calling M1-01's
extractor. The extractor's overlap rule suppresses keys inside links,
which is correct for refs and wrong for routing: a browse URL should
route to its project. NSDataDetector per keystroke also has a cost
cliff on a large paste that §1.1 cannot afford.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `CaptureService` — the one write path

**Files:**
- Create: `StenoKit/Capture/CaptureService.swift`
- Test: `StenoTests/Capture/CaptureServiceTests.swift`

**Interfaces:**
- Consumes: `ProjectRouter.route(...)` and `RoutingDecision` from Task 1; `ReferenceExtractor.extract(from:)` and `ExtractedRef.sourceRef(taskID:)` from M1-01; `TaskItem`, `Event`, `EventKind.created`, `SourceRef` from M0-03.
- Produces: `CaptureError.noProjectAvailable`; `CaptureService(context:now:save:)`; `capture(text:preferred:defaultProjectID:ignoringTicketKey:) throws -> TaskItem?`. Tasks 4, 5 and 8 all call `capture`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/CaptureServiceTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// `ModelContext(container)` retains its container; `container.mainContext`
/// does NOT, so a helper returning the main context leaves it dangling and the
/// next insert traps inside SwiftData. Every test in this repo uses this form.
@MainActor
private func makeContext() throws -> ModelContext {
    ModelContext(try StenoStore.inMemory())
}

/// A clock that advances a second per read.
///
/// Two captures under a frozen clock share a `createdAt`, which makes "the
/// most recently created task" undefined — and the last-used derivation is
/// exactly what these tests are asserting about.
@MainActor
private final class AdvancingClock {
    private var current: Date

    init(start: Date) { current = start }

    func next() -> Date {
        defer { current = current.addingTimeInterval(1) }
        return current
    }
}

@MainActor
@discardableResult
private func insertProject(
    _ name: String, keys: [String] = [], order: Int = 0, into context: ModelContext
) throws -> Project {
    let project = Project(
        name: name,
        colorHex: ProjectPalette.hex(forIndex: order),
        jiraProjectKeys: keys,
        sortOrder: order,
        modifiedAt: epoch
    )
    context.insert(project)
    try context.save()
    return project
}

@MainActor
@Test("a capture writes the task, its created event, and its refs")
func captureWritesEverythingOnce() throws {
    let context = try makeContext()
    let payments = try insertProject("Payments", keys: ["PAY"], into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(
        try service.capture(text: "PAY-421 fix the retry handler", preferred: nil)
    )

    #expect(task.title == "PAY-421 fix the retry handler")
    #expect(task.projectID == payments.id)
    #expect(task.createdAt == epoch)

    let events = try context.fetch(FetchDescriptor<Event>())
    #expect(events.count == 1)
    #expect(events.first?.kind == .created)
    #expect(events.first?.taskID == task.id)

    let refs = try context.fetch(FetchDescriptor<SourceRef>())
    #expect(refs.map(\.identifier) == ["PAY-421"])
}

@MainActor
@Test("every ref carries both the foreign key and the relationship (D-016)")
func refsAreWiredBothWays() throws {
    let context = try makeContext()
    try insertProject("Payments", keys: ["PAY"], into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(
        try service.capture(text: "PAY-421 see https://github.com/acme/api/pull/912", preferred: nil)
    )

    let refs = try context.fetch(FetchDescriptor<SourceRef>())
    #expect(refs.count == 2)
    for ref in refs {
        // PersistedInvariantsTests asserts these never disagree.
        // `ExtractedRef.sourceRef(taskID:)` sets only the first.
        #expect(ref.taskID == task.id)
        #expect(ref.task?.id == task.id)
    }
}

@MainActor
@Test("text that is empty after trimming writes nothing at all")
func blankTextWritesNothing() throws {
    let context = try makeContext()
    try insertProject("Payments", into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try service.capture(text: "   \n  ", preferred: nil)

    #expect(task == nil)
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
}

@MainActor
@Test("the title is stored trimmed")
func titleIsTrimmed() throws {
    let context = try makeContext()
    try insertProject("Payments", into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(try service.capture(text: "  fix the thing  ", preferred: nil))

    #expect(task.title == "fix the thing")
}

@MainActor
@Test("a failed save leaves nothing partially written")
func failedSaveRollsBack() throws {
    struct Boom: Error {}
    let context = try makeContext()
    try insertProject("Payments", keys: ["PAY"], into: context)
    let service = CaptureService(context: context, now: { epoch }, save: { _ in throw Boom() })

    #expect(throws: Boom.self) {
        try service.capture(text: "PAY-421 fix the retry handler", preferred: nil)
    }

    // Accepting a write that evaporates is worse than refusing it: the loss
    // surfaces at a stand-up weeks later (D-018, §1.1).
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<SourceRef>()).isEmpty)
}

@MainActor
@Test("the last-used project is the newest task's, across projects")
func lastUsedFollowsTheNewestTask() throws {
    let context = try makeContext()
    try insertProject("Payments", order: 0, into: context)
    let hiring = try insertProject("EM — Hiring", order: 1, into: context)
    let clock = AdvancingClock(start: epoch)
    let service = CaptureService(context: context, now: { clock.next() })

    try service.capture(text: "first", preferred: hiring.id)
    let second = try #require(try service.capture(text: "second", preferred: nil))

    // No key, no preference — so rung 3, and rung 3 is where `first` went.
    #expect(second.projectID == hiring.id)
}

@MainActor
@Test("last-used ignores a newer task belonging to an archived project")
func lastUsedSkipsArchivedProjects() throws {
    let context = try makeContext()
    try insertProject("Payments", order: 0, into: context)
    let design = try insertProject("Design System", order: 1, into: context)
    let hiring = try insertProject("EM — Hiring", order: 2, into: context)
    let clock = AdvancingClock(start: epoch)
    let service = CaptureService(context: context, now: { clock.next() })

    // Older capture into a project that stays live...
    try service.capture(text: "into design", preferred: design.id)
    // ...then a newer one into the project about to be archived.
    try service.capture(text: "into hiring", preferred: hiring.id)
    hiring.setArchived(true, at: epoch)
    try context.save()

    let next = try #require(try service.capture(text: "where does this land", preferred: nil))

    // **Three projects, not two, and that is what makes this test discriminate.**
    // D-021: `TaskItem` has no archived flag of its own, so the newest task row
    // still belongs to archived Hiring. The three candidate implementations
    // must give three answers, and only one of them is Design System:
    //
    //   correct           → Design System — newest task in a *live* project
    //   `fetchLimit = 1`  → Hiring, which `ProjectRouter` then rejects as not
    //                       live, falling through to rung 5 → Payments
    //   no derivation     → rung 5 → Payments
    //
    // With only two projects the correct answer collapses onto rung 5's answer
    // and the bug this test is named for passes it.
    #expect(next.projectID == design.id)
}

@MainActor
@Test("with every project archived, capture refuses and writes nothing")
func noLiveProjectRefuses() throws {
    let context = try makeContext()
    let payments = try insertProject("Payments", into: context)
    payments.setArchived(true, at: epoch)
    try context.save()
    let service = CaptureService(context: context, now: { epoch })

    #expect(throws: CaptureError.noProjectAvailable) {
        try service.capture(text: "nowhere to put this", preferred: nil)
    }

    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
}

@MainActor
@Test("a dismissed chip routes down the ladder instead of to the key")
func ignoringTicketKeyFallsThrough() throws {
    let context = try makeContext()
    try insertProject("Payments", keys: ["PAY"], order: 0, into: context)
    let hiring = try insertProject("EM — Hiring", order: 1, into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(
        try service.capture(
            text: "PAY-421 fix it", preferred: hiring.id, ignoringTicketKey: true)
    )

    #expect(task.projectID == hiring.id)
    // The ref is still extracted — dismissing the chip declines the routing,
    // not the reference (FR-1.5 is passive and unconditional).
    let refs = try context.fetch(FetchDescriptor<SourceRef>())
    #expect(refs.map(\.identifier) == ["PAY-421"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'CaptureService' in scope`.

- [ ] **Step 3: Write the service**

Create `StenoKit/Capture/CaptureService.swift`:

```swift
import Foundation
import SwiftData

/// Why a capture could not be written.
public enum CaptureError: Error, Equatable {
    /// Every project is archived, so there is nowhere to route.
    ///
    /// The one state in which capture refuses text — see the design doc §4.2
    /// and ARCHITECTURE §3's "capture never blocks" row, whose single
    /// documented exception this is.
    case noProjectAvailable
}

/// D15's "one code path": the whole of turning typed text into a persisted
/// task, shared verbatim by the main window (M1-02), the floating hotkey
/// window (M1-03) and the menu bar popover (M1-04).
///
/// `@MainActor` because `ModelContext` is not `Sendable`. `now` and `save` are
/// injected for the same reasons `MainWindowModel` injects them: a testable
/// clock, and a save that can be made to fail on demand — a real
/// `ModelContext` cannot.
@MainActor
public struct CaptureService {
    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.now = now
        self.save = save
    }

    /// Capture `text` as a task.
    ///
    /// Returns `nil` for text that is empty after trimming — a no-op rather
    /// than an error, because a surface committing an untouched field is not a
    /// failure worth reporting to the user.
    ///
    /// Throws `CaptureError.noProjectAvailable` when there is nowhere to
    /// route, and rethrows a save failure after rolling the context back.
    ///
    /// - Parameters:
    ///   - preferred: the surface's own context. The main window passes its
    ///     sidebar selection; the hotkey window and popover pass `nil`.
    ///   - defaultProjectID: FR-6's configured default. `nil` until M1-08.
    ///   - ignoringTicketKey: the user dismissed the chip, so skip rung 1.
    @discardableResult
    public func capture(
        text: String,
        preferred: UUID?,
        defaultProjectID: UUID? = nil,
        ignoringTicketKey: Bool = false
    ) throws -> TaskItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let projects = try liveProjects()
        let lastUsed = try lastUsedProjectID(among: projects)
        let decision = ProjectRouter.route(
            text: trimmed,
            projects: projects,
            preferred: preferred,
            lastUsed: lastUsed,
            defaultProjectID: defaultProjectID,
            ignoringTicketKey: ignoringTicketKey
        )
        guard let projectID = decision.projectID else { throw CaptureError.noProjectAvailable }

        // FR-1.5, the full M1-01 path, run once. Unlike routing's scan this
        // one wants each reference exactly once, links and keys reconciled.
        let extracted = ReferenceExtractor.extract(from: trimmed)
        let stamp = now()

        let task = TaskItem(title: trimmed, projectID: projectID, createdAt: stamp)
        context.insert(task)

        // §3.3's EventKind table: `created` is written when a task is created.
        // A task without one is a hole in the append-only log — M2-01's
        // gathering would skip it and M2.5-02's merge would reason from it.
        context.insert(
            Event(taskID: task.id, timestamp: stamp, kind: .created, body: "Task created")
        )

        for ref in extracted {
            let stored = ref.sourceRef(taskID: task.id)
            context.insert(stored)
            // `sourceRef(taskID:)` sets the foreign key only. D-016 keeps both
            // the key and the relationship, and PersistedInvariantsTests
            // asserts they never disagree.
            stored.task = task
        }

        // `SourceRef.newRefs(from:existing:)` is deliberately NOT called here.
        // For a brand-new task `existing` is empty, and `extract` has already
        // deduped by `(kind, identifier)` — which is `SourceRef.DedupKey`
        // minus a `taskID` that is constant across one pass — so it is
        // provably a no-op. M1-06's note path is its real first caller.

        do {
            try save(context)
        } catch {
            // Without this the objects sit in the context, the next reload
            // finds them, and the window shows a task that is not on disk
            // (D-018).
            context.rollback()
            throw error
        }
        return task
    }

    private func liveProjects() throws -> [Project] {
        try context.fetch(
            FetchDescriptor<Project>(
                predicate: #Predicate { !$0.isArchived },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
        )
    }

    /// FR-1.4's "last-used project", derived rather than stored.
    ///
    /// No new field, no `UserDefaults` key, no settings row: it is the project
    /// of the most recently created task. It therefore cannot drift from
    /// reality, every surface agrees by construction, and it round-trips
    /// through §10's export for free because it is not a separate fact.
    ///
    /// **Not `fetchLimit = 1`.** D-021: `TaskItem` has no archived flag of its
    /// own — "a project's tasks disappear when it archives" is an emergent
    /// property of one in-memory filter, not a stored fact. Limiting the fetch
    /// returns a task belonging to an archived project and routes the capture
    /// somewhere the user cannot see it. D18 caps the dataset under 20 live
    /// tasks, so reading them all costs nothing.
    private func lastUsedProjectID(among projects: [Project]) throws -> UUID? {
        let live = Set(projects.map(\.id))
        guard !live.isEmpty else { return nil }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let newest = try context.fetch(descriptor)
        return newest.first { live.contains($0.projectID) }?.projectID
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

If `#expect(throws: CaptureError.noProjectAvailable)` fails to compile, the value-matching overload needs `Equatable` — which `CaptureError` declares. If it still resists, use `#expect(throws: CaptureError.self)` and assert the store is empty; do not drop the test.

- [ ] **Step 5: Format, lint, commit**

```bash
make format && make lint
git add StenoKit/Capture/CaptureService.swift StenoTests/Capture/CaptureServiceTests.swift
git commit -m "feat: capture service — one write path for all three surfaces

D15 specifies three entry points and one code path. This is the path:
route, extract, insert the task with its created event and its refs,
and commit all of it in a single save. Building it before either of the
surfaces that will consume it (M1-03, M1-04) is what stops three
divergent implementations.

Two details worth the reviewer's attention. Last-used is derived from
the newest task rather than stored, and the derivation re-applies the
visible-projects filter: D-021 warns that TaskItem has no archived flag
of its own, so a fetchLimit of 1 returns a task from an archived
project and routes the capture out of sight. And the rollback lives
here rather than in MainWindowModel.perform, so M1-03 and M1-04
inherit D-018's guarantee instead of each remembering it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Seed a project on first launch

**Files:**
- Move: `StenoKit/Features/MainWindow/ProjectPalette.swift` → `StenoKit/Support/ProjectPalette.swift`
- Create: `StenoKit/Persistence/StoreBootstrap.swift`
- Modify: `Steno/App/StenoApp.swift`
- Test: `StenoTests/Persistence/StoreBootstrapTests.swift`

**Interfaces:**
- Consumes: `StenoStore`, `Project`, `ProjectPalette.hex(forIndex:)`.
- Produces: `StenoStore.defaultProjectName` (`"Inbox"`), `StenoStore.seedDefaultProjectIfEmpty(in:) throws -> Project?`.

- [ ] **Step 1: Move `ProjectPalette` out of the feature layer**

The persistence layer is about to need it, and ARCHITECTURE §2 puts persistence *below* features — a dependency the other way is backwards. `ProjectPalette` is a dependency-free constant table, so the move is mechanical and there are no imports to fix (same module).

```bash
git mv StenoKit/Features/MainWindow/ProjectPalette.swift StenoKit/Support/ProjectPalette.swift
make build
```
Expected: build succeeds with no source changes.

- [ ] **Step 2: Write the failing test**

Create `StenoTests/Persistence/StoreBootstrapTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
@Test("an empty store gets exactly one default project")
func emptyStoreIsSeeded() throws {
    let context = ModelContext(try StenoStore.inMemory())

    let seeded = try #require(try StenoStore.seedDefaultProjectIfEmpty(in: context))

    #expect(seeded.name == StenoStore.defaultProjectName)
    #expect(seeded.jiraProjectKeys.isEmpty)
    #expect(seeded.sortOrder == 0)
    #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
}

@MainActor
@Test("seeding twice does not produce a second project")
func seedingIsIdempotent() throws {
    let context = ModelContext(try StenoStore.inMemory())
    try StenoStore.seedDefaultProjectIfEmpty(in: context)

    let second = try StenoStore.seedDefaultProjectIfEmpty(in: context)

    #expect(second == nil)
    #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
}

@MainActor
@Test("a store whose only project is archived is not re-seeded")
func archivedOnlyStoreIsNotReseeded() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let seeded = try #require(try StenoStore.seedDefaultProjectIfEmpty(in: context))
    seeded.setArchived(true, at: epoch)
    try context.save()

    let second = try StenoStore.seedDefaultProjectIfEmpty(in: context)

    // Seeding happens once in a store's life. Re-seeding would resurrect a
    // project the user archived on purpose (design §4.2).
    #expect(second == nil)
    #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
}

@MainActor
@Test("a store that already has projects is left alone")
func populatedStoreIsNotSeeded() throws {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(name: "Payments", colorHex: "#3B82F6", sortOrder: 0, modifiedAt: epoch)
    )
    try context.save()

    let seeded = try StenoStore.seedDefaultProjectIfEmpty(in: context)

    #expect(seeded == nil)
    #expect(try context.fetch(FetchDescriptor<Project>()).map(\.name) == ["Payments"])
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `type 'StenoStore' has no member 'seedDefaultProjectIfEmpty'`.

- [ ] **Step 4: Write the bootstrap**

Create `StenoKit/Persistence/StoreBootstrap.swift`:

```swift
import Foundation
import SwiftData

extension StenoStore {
    /// The project a first-ever capture lands in.
    public static let defaultProjectName = "Inbox"

    /// Give a brand-new store one project, so capture always has a target.
    ///
    /// On a fresh install there are zero projects, so a task has no
    /// `projectID` to take — and M0-05 handled that by disabling New Task,
    /// which is a capture surface refusing text and so is exactly what §1.1
    /// forbids. It gets worse in M1-03, where the hotkey window would open
    /// above every other app into a field whose `Return` does nothing.
    ///
    /// The seeded project is ordinary: renameable, archivable, no Jira keys.
    ///
    /// **The emptiness check counts archived projects too.** Seeding happens
    /// once in a store's life. Were it to skip them, archiving every project
    /// would resurrect one the user deliberately put away — see the design
    /// doc §4.2, which keeps that state as capture's one documented refusal.
    ///
    /// Returns the seeded project, or `nil` when the store already had one.
    ///
    /// **Pass a context with no unrelated pending changes.** The `save()` below
    /// commits everything the context holds, not just the seed. Both current
    /// callers are clean at the call site — the app seeds before anything else
    /// touches the store, and each test builds a fresh context — but a future
    /// caller with pending edits would have them committed here as a side
    /// effect.
    @discardableResult
    public static func seedDefaultProjectIfEmpty(in context: ModelContext) throws -> Project? {
        var descriptor = FetchDescriptor<Project>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return nil }

        let project = Project(
            name: defaultProjectName,
            colorHex: ProjectPalette.hex(forIndex: 0),
            sortOrder: 0,
            modifiedAt: Date.now
        )
        context.insert(project)
        try context.save()
        return project
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Seed at launch**

In `Steno/App/StenoApp.swift`, inside `init()`, immediately after the existing `switch store { … }` block that logs the outcome, append:

```swift
        // Capture must always have somewhere to go (FR-1.4, §1.1). A failure
        // here is not fatal — the window still opens, and the empty state
        // tells the user to create a project — so it is logged, not surfaced.
        if case .success(let container) = store {
            do {
                // `container.mainContext`, deliberately — **not** a fresh
                // `ModelContext(container)`. `MainWindowView.init` builds its
                // view model over `mainContext`, so seeding into the same
                // context makes the window's first fetch a same-context read
                // that is guaranteed to see the seeded row. A sibling context
                // would leave the one guarantee this seeding exists to make
                // resting on cross-context visibility, which SwiftData does
                // not contractually document — and which no test here could
                // cover, since GUI automation is unavailable.
                //
                // This does not contradict the tests' use of
                // `ModelContext(container)`: that rule exists because
                // `mainContext` does not retain its container, and a test
                // whose container is a local would dangle. Here `store` is a
                // stored property of the `@main` App, so the container lives
                // for the whole process.
                if let seeded = try StenoStore.seedDefaultProjectIfEmpty(
                    in: container.mainContext)
                {
                    Log.app.info("seeded default project \(seeded.name, privacy: .public)")
                }
            } catch {
                Log.app.error(
                    "could not seed the default project: \(String(describing: error), privacy: .public)"
                )
            }
        }
```

- [ ] **Step 7: Verify the build and the whole suite**

Run: `make build && make test && make lint`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add StenoKit/Support/ProjectPalette.swift StenoKit/Persistence/StoreBootstrap.swift StenoTests/Persistence/StoreBootstrapTests.swift Steno/App/StenoApp.swift
git commit -m "feat: seed a default project so capture always has a target

On a fresh install there are no projects, so M0-05 disabled New Task —
a capture surface refusing text, which §1.1 forbids. It would be worse
in M1-03, where the hotkey window opens above every other app into a
field whose Return does nothing. Seeding one ordinary, renameable
Inbox project at launch makes 'capture always has a target' true
rather than nearly true.

The emptiness check counts archived projects, so seeding happens once
in a store's life. Archiving every project therefore still refuses
capture, deliberately: re-seeding would undo something the user did on
purpose and can undo themselves.

ProjectPalette moves to Support/ because the persistence layer now
needs it and ARCHITECTURE §2 puts persistence below features. It is a
dependency-free constant table, so the move is mechanical.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `CaptureFieldModel` — the shared chip

**Files:**
- Create: `StenoKit/Features/Capture/CaptureChip.swift`
- Create: `StenoKit/Features/Capture/CaptureFieldModel.swift`
- Test: `StenoTests/Features/Capture/CaptureFieldModelTests.swift`

**Interfaces:**
- Consumes: `CaptureService.capture(...)` from Task 2; `ProjectRouter.ticketKeyMatch(text:projects:)` from Task 1.
- Produces: `CaptureChip(key:projectID:projectName:colorHex:)`; `CaptureFieldModel(service:projects:preferred:onCaptured:)` with `text`, `chip`, `lastError`, `dismissChip()`, `commit()`, `reset()`. Task 6's view binds to all of these.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Features/Capture/CaptureFieldModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeField() throws -> (CaptureFieldModel, ModelContext, [Project]) {
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
        sortOrder: 0, modifiedAt: epoch)
    let hiring = Project(
        name: "EM — Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
        sortOrder: 1, modifiedAt: epoch)
    context.insert(payments)
    context.insert(hiring)
    try context.save()

    let projects = [payments, hiring]
    let field = CaptureFieldModel(
        service: CaptureService(context: context, now: { epoch }),
        projects: { projects },
        preferred: { hiring.id }
    )
    return (field, context, projects)
}

@MainActor
@Test("typing a configured key raises a chip naming its project")
func typingAKeyRaisesTheChip() throws {
    let (field, _, projects) = try makeField()

    field.text = "PAY-421 fix the retry handler"

    let chip = try #require(field.chip)
    #expect(chip.key == "PAY-421")
    #expect(chip.projectID == projects[0].id)
    #expect(chip.projectName == "Payments")
    #expect(chip.colorHex == "#3B82F6")
}

@MainActor
@Test("text with no configured key raises no chip")
func plainTextRaisesNoChip() throws {
    let (field, _, _) = try makeField()

    field.text = "write the interview loop doc"

    #expect(field.chip == nil)
}

@MainActor
@Test("dismissing clears the chip and it stays gone while the key stands")
func dismissalSticksForThatKey() throws {
    let (field, _, _) = try makeField()
    field.text = "PAY-421 fix"

    field.dismissChip()
    #expect(field.chip == nil)

    field.text = "PAY-421 fix the retry handler"

    #expect(field.chip == nil)
}

@MainActor
@Test("a different key after a dismissal raises a new chip")
func aDifferentKeyRaisesANewChip() throws {
    let (field, _, projects) = try makeField()
    field.text = "PAY-421 fix"
    field.dismissChip()

    field.text = "HIR-9 screen the candidate"

    // Dismissal drops one auto-assignment; it does not disable routing for
    // the rest of a capture still being typed (design §5.1).
    let chip = try #require(field.chip)
    #expect(chip.key == "HIR-9")
    #expect(chip.projectID == projects[1].id)
}

@MainActor
@Test("committing an undismissed chip routes to the key's project")
func commitHonoursTheChip() throws {
    let (field, context, projects) = try makeField()
    field.text = "PAY-421 fix the retry handler"

    field.commit()

    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    #expect(tasks.first?.projectID == projects[0].id)
}

@MainActor
@Test("committing a dismissed chip routes down the ladder")
func commitHonoursTheDismissal() throws {
    let (field, context, projects) = try makeField()
    field.text = "PAY-421 fix the retry handler"
    field.dismissChip()

    field.commit()

    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    // preferred == hiring, so rung 2 catches it.
    #expect(tasks.first?.projectID == projects[1].id)
}

@MainActor
@Test("a successful commit clears the field for the next capture")
func commitResetsTheField() throws {
    let (field, _, _) = try makeField()
    field.text = "PAY-421 fix"
    field.dismissChip()

    field.commit()

    #expect(field.text.isEmpty)
    #expect(field.chip == nil)
    #expect(field.lastError == nil)
}

@MainActor
@Test("a commit that cannot be saved reports it and keeps the text")
func failedCommitKeepsTheText() throws {
    struct Boom: Error {}
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", sortOrder: 0, modifiedAt: epoch)
    context.insert(payments)
    try context.save()
    let field = CaptureFieldModel(
        service: CaptureService(context: context, now: { epoch }, save: { _ in throw Boom() }),
        projects: { [payments] }
    )
    field.text = "this will not save"

    field.commit()

    // Losing the user's typing on a failed save is the capture-tool version
    // of the notebook page falling out.
    #expect(field.text == "this will not save")
    #expect(field.lastError != nil)
}

@MainActor
@Test("committing an empty field does nothing and reports nothing")
func emptyCommitIsSilent() throws {
    let (field, context, _) = try makeField()

    field.commit()

    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(field.lastError == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `cannot find 'CaptureFieldModel' in scope`.

- [ ] **Step 3: Write the chip**

Create `StenoKit/Features/Capture/CaptureChip.swift`:

```swift
import Foundation

/// FR-1.4's dismissible inline chip, as facts rather than as a view.
///
/// Carries the project's name and colour so the rendering surface needs no
/// store access of its own (D-019), and so all three surfaces show the same
/// thing without each deciding what to display.
public struct CaptureChip: Equatable, Sendable {
    /// The ticket key that caused the routing, e.g. `"PAY-421"`.
    public let key: String
    public let projectID: UUID
    public let projectName: String
    public let colorHex: String

    public init(key: String, projectID: UUID, projectName: String, colorHex: String) {
        self.key = key
        self.projectID = projectID
        self.projectName = projectName
        self.colorHex = colorHex
    }
}
```

- [ ] **Step 4: Write the field model**

Create `StenoKit/Features/Capture/CaptureFieldModel.swift`:

```swift
import Foundation
import SwiftData

/// One in-progress capture: the draft text, the chip it raises, and the
/// commit.
///
/// **In `StenoKit`, not as `@State` in a view, and that is deliberate.**
/// M1-04's acceptance criterion is "the auto-routing chip behaving identically
/// to the main window" — chip state held in a view lives in `Steno/`, where
/// D-010 puts it beyond the headless test bundle, and where M1-03 and M1-04
/// would each rebuild it by hand. Three hand-rolled chips that drift is the
/// failure D15 names and this milestone exists to prevent.
///
/// The dependencies are closures rather than values because a surface's
/// project list and its preferred project both change under it while the field
/// is open — the sidebar selection being the obvious case.
@Observable
@MainActor
public final class CaptureFieldModel {
    /// The draft. Assigning re-derives the chip.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            refreshChip()
        }
    }

    public private(set) var chip: CaptureChip?

    /// Set when a commit could not be saved. The text is kept when this is
    /// non-nil, so the user can retry rather than retype.
    public private(set) var lastError: String?

    /// The key whose chip was dismissed, if any.
    ///
    /// Keyed to the key rather than a `Bool`: dismissing drops *this*
    /// auto-assignment, it does not disable routing for the rest of a capture
    /// still being typed. Type on so a different key matches and a new chip
    /// appears (design §5.1).
    private var dismissedKey: String?

    private let service: CaptureService
    private let projects: () -> [Project]
    private let preferred: () -> UUID?
    private let onCaptured: (TaskItem) -> Void

    public init(
        service: CaptureService,
        projects: @escaping () -> [Project],
        preferred: @escaping () -> UUID? = { nil },
        onCaptured: @escaping (TaskItem) -> Void = { _ in }
    ) {
        self.service = service
        self.projects = projects
        self.preferred = preferred
        self.onCaptured = onCaptured
    }

    /// Decline the auto-assignment the chip is showing.
    ///
    /// One click, no modal, no confirmation — §1.1 treats a modal interruption
    /// during capture as a defect.
    public func dismissChip() {
        dismissedKey = chip?.key
        chip = nil
    }

    /// Write the draft as a task.
    ///
    /// Never throws: a capture surface has nowhere useful to propagate an
    /// error to, so a failure becomes `lastError` and the text is kept.
    public func commit() {
        do {
            if let task = try service.capture(
                text: text,
                preferred: preferred(),
                ignoringTicketKey: isCurrentMatchDismissed()
            ) {
                onCaptured(task)
            }
            reset()
        } catch CaptureError.noProjectAvailable {
            lastError = "Create a project before capturing a task."
        } catch {
            Log.app.error(
                "could not capture the task: \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not save the task. Your text is still here."
        }
    }

    /// Clear the field for the next capture.
    public func reset() {
        text = ""
        chip = nil
        dismissedKey = nil
        lastError = nil
    }

    /// Whether the chip the user dismissed is still the one the text raises.
    ///
    /// Recomputed at commit rather than cached, so an edit between dismissal
    /// and `Return` is honoured: the save re-runs the decision the field is
    /// currently displaying.
    private func isCurrentMatchDismissed() -> Bool {
        guard let dismissedKey else { return false }
        let match = ProjectRouter.ticketKeyMatch(text: text, projects: projects())
        return match?.key == dismissedKey
    }

    /// Per keystroke — which is why it is a regex scan with an early exit and
    /// no `NSDataDetector`. See `ProjectRouter.ticketKeyMatch`.
    private func refreshChip() {
        let live = projects()
        guard let match = ProjectRouter.ticketKeyMatch(text: text, projects: live),
            match.key != dismissedKey,
            let project = live.first(where: { $0.id == match.projectID })
        else {
            chip = nil
            return
        }
        chip = CaptureChip(
            key: match.key,
            projectID: project.id,
            projectName: project.name,
            colorHex: project.colorHex
        )
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Format, lint, commit**

```bash
make format && make lint
git add StenoKit/Features/Capture/ StenoTests/Features/Capture/
git commit -m "feat: shared capture field model with FR-1.4's dismissible chip

The chip lives in StenoKit rather than as view state because M1-04's
acceptance criterion is that it behave identically to the main
window's. Held in a view it would sit in Steno/, which D-010 puts
beyond the headless bundle, and M1-03 and M1-04 would each rebuild it.

Dismissal is keyed to the dismissed ticket key rather than a boolean,
so editing the text into a different match raises a new chip.
Dismissing declines one auto-assignment; it does not disable routing
for a capture still being typed. The commit re-derives the decision
rather than caching it, so an edit between dismissal and Return is
honoured.

A failed save keeps the user's text. Losing it is the capture-tool
equivalent of the notebook page falling out.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Wire `MainWindowModel` to the capture path

**Files:**
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift:242-268`
- Test: `StenoTests/Features/MainWindow/MainWindowModelTasksTests.swift`

**Interfaces:**
- Consumes: `CaptureService`, `CaptureError` from Task 2.
- Produces: `MainWindowModel.createTask(titled:)` now routes by the ladder. `targetProjectID()` no longer exists.

- [ ] **Step 1: Update the tests that assert the old stand-in**

In `StenoTests/Features/MainWindow/MainWindowModelTasksTests.swift`, replace the test named `allTargetsFirstProject` (currently "under All, a new task goes to the first project by sortOrder") in its entirety with these three:

```swift
@MainActor
@Test("under All with no history, a new task goes to the first project")
func allTargetsFirstProjectWhenThereIsNoHistory() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let first = try #require(model.projects.first?.id)
    model.selection = .all

    model.createTask(titled: "where does this go")

    // FR-1.4 rung 5: no key, no selection, no last-used, no configured
    // default. Same answer as M0-05's stand-in, now for a stated reason.
    #expect(model.groups[0].tasks.first?.projectID == first)
}

@MainActor
@Test("under All, a new task follows the last-used project")
func allFollowsLastUsed() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let second = try #require(model.projects.last?.id)

    model.selection = .project(second)
    model.createTask(titled: "into second")
    model.selection = .all
    model.createTask(titled: "and this one?")

    // FR-1.4 rung 3, which D-021 recorded as M1-02's to implement.
    let landed = try #require(model.groups[0].tasks.first { $0.title == "and this one?" })
    #expect(landed.projectID == second)
}

@MainActor
@Test("a matching ticket key outranks the sidebar selection")
func ticketKeyOutranksSelection() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    model.createProject(named: "EM — Hiring")
    let payments = try #require(model.projects.first)
    let hiring = try #require(model.projects.last?.id)
    payments.setJiraProjectKeys(["PAY"], at: origin)
    try context.save()

    model.selection = .project(hiring)
    model.createTask(titled: "PAY-421 fix the retry handler")

    // Assert under All: the task went to Payments while the sidebar shows
    // Hiring, and `groups` is scoped to the selection — so reading it here
    // would find an empty list and prove nothing.
    model.selection = .all

    // FR-1.4 rung 1 beats rung 2.
    let landed = try #require(model.groups.flatMap(\.tasks).first)
    #expect(landed.projectID == payments.id)
}
```

Then replace `createTaskWithoutProjectsIsNoOp` in its entirety with:

```swift
@MainActor
@Test("with no projects, creating a task stores nothing and says why")
func createTaskWithoutProjectsExplainsItself() throws {
    let (model, context) = try makeModel()

    model.createTask(titled: "orphan")

    #expect(model.groups.isEmpty)
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
    // The one state where capture refuses. Silence here would look like a
    // dropped keystroke (design §4.2).
    #expect(model.lastError != nil)
}
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `make test`
Expected: FAIL — `allFollowsLastUsed`, `ticketKeyOutranksSelection`, and `createTaskWithoutProjectsExplainsItself` all fail; the rest pass.

- [ ] **Step 3: Replace `createTask` and delete the stand-in**

In `StenoKit/Features/MainWindow/MainWindowModel.swift`, replace `createTask(titled:)` and `targetProjectID()` — everything from `public func createTask(titled title: String) {` through the closing brace of `private func targetProjectID() -> UUID? { … }` — with:

```swift
    /// FR-1's capture, through the shared path (D15) — **programmatic entry
    /// point only.**
    ///
    /// The routing, the `created` event and the ref extraction all live in
    /// `CaptureService`. What stays here is this surface's own context — the
    /// sidebar selection — and the error presentation.
    ///
    /// **The capture sheet does not call this.** `NewTaskSheet` drives
    /// `CaptureFieldModel`, which needs per-keystroke chip state this method
    /// has no way to express, and reaches the same `CaptureService`. Both
    /// wrappers therefore share the write path, which is what D15 requires,
    /// but this one has no production caller today. Whether it should be
    /// deleted or kept as a documented API is recorded for review rather than
    /// settled here — see the M1-02 plan's Task 6 findings.
    public func createTask(titled title: String) {
        // Constructed per call rather than stored: three retained references
        // is nothing against a SwiftData save, and it keeps `now` and `save`
        // from being captured at init and going stale in tests.
        let capture = CaptureService(context: context, now: now, save: save)
        do {
            try capture.capture(text: title, preferred: preferredProjectID())
            lastError = nil
        } catch CaptureError.noProjectAvailable {
            lastError = "Create a project before adding a task."
        } catch {
            Log.app.error(
                "could not create the task: \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not create the task. Your change was not saved."
        }
        reload()
    }

    /// FR-1.4 rung 2: this surface's own context.
    ///
    /// Under "All" the window has no opinion about where a task belongs, so it
    /// says so with `nil` and the ladder falls through to the last-used
    /// project — rather than asserting the first project, which is what
    /// D-021's stand-in did before this task retired it.
    private func preferredProjectID() -> UUID? {
        switch selection {
        case .project(let id): id
        case .all: nil
        }
    }
```

- [ ] **Step 4: Run the whole suite**

Run: `make build && make test && make lint`
Expected: all pass. `MainWindowModelProjectsTests`, `TaskGroupingTests` and the remaining task tests are untouched by this change and must stay green.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Features/MainWindow/MainWindowModel.swift StenoTests/Features/MainWindow/MainWindowModelTasksTests.swift
git commit -m "feat: main window captures through the shared path

createTask now delegates to CaptureService, and targetProjectID is
deleted rather than superseded in place — it was D-021's second interim
behaviour ('the first project by sortOrder'), recorded there as M1-02's
to replace.

Under 'All' the window passes nil rather than asserting the first
project, so the ladder falls through to the last-used project as FR-1.4
specifies. Under a selected project it passes that selection, which
outranks last-used: filing a task into a project other than the one on
screen is the kind of surprise that costs trust in a recall tool, and
FR-1.4's 'change it after the fact' does not land until M1-05.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `CaptureFieldView` — the field and its chip

**Files:**
- Create: `Steno/Features/Capture/CaptureFieldView.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift`

**Interfaces:**
- Consumes: `CaptureFieldModel` from Task 4; `Color(projectHex:)` from `Steno/Features/MainWindow/Color+Project.swift`.
- Produces: `CaptureFieldView(field:onDismiss:)` — the surface-shared field, embedded by M1-03 and M1-04 — and `NewTaskSheet(model:)`, the main window's owner for it.

This task is not covered by tests — views need a window server, which D-010 puts outside the bundle and which is unavailable on this machine. Verification is `make build` plus the user's own pass.

- [ ] **Step 1: Write the view**

Create `Steno/Features/Capture/CaptureFieldView.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-1's capture field: one focused line, `Return` commits, `Esc` dismisses.
///
/// **The surface-shared one.** M1-03's floating window and M1-04's popover
/// embed this view rather than rebuilding it, which is what makes D15's "one
/// code path" true of the UI as well as the write.
///
/// Everything stateful lives in `CaptureFieldModel` over in `StenoKit`, where
/// the headless bundle can reach it; this file is layout.
struct CaptureFieldView: View {
    @Bindable var field: CaptureFieldModel
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What are you working on?", text: $field.text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                // Guarded, not bare `.onSubmit(commit)`. `CaptureService`
                // treats empty-after-trim text as a silent no-op, so an
                // unguarded Return on an empty field would run the success
                // path and dismiss the sheet as though something had been
                // saved — while the Add button, one line below, refuses the
                // very same action. Esc is the way out; Return is Add.
                .onSubmit {
                    guard !isBlank else { return }
                    commit()
                }

            if let chip = field.chip {
                chipView(chip)
            }

            if let message = field.lastError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBlank)
            }
        }
        .padding(20)
        .frame(width: 420)
        // FR-1.1: focused the instant it appears, no click required.
        .onAppear { isFocused = true }
    }

    /// FR-1.4's dismissible inline chip.
    ///
    /// A plain button with an `xmark`, not a confirmation: §1.1 treats a modal
    /// interruption during capture as a defect, so declining the routing costs
    /// exactly one click and blocks nothing.
    private func chipView(_ chip: CaptureChip) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(projectHex: chip.colorHex))
                .frame(width: 8, height: 8)
            Text(chip.projectName)
                .font(.caption)
            Button {
                field.dismissChip()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Don't file under \(chip.projectName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(projectHex: chip.colorHex).opacity(0.15), in: Capsule())
    }

    /// One definition of "nothing to submit", shared by the Add button and
    /// the Return key so the two cannot disagree.
    private var isBlank: Bool {
        field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        field.commit()
        // A failed save keeps the text and reports why, so the sheet stays
        // open for the retry rather than swallowing the capture.
        if field.lastError == nil { onDismiss() }
    }
}
```

- [ ] **Step 2: Give the sheet an owner for its model**

The field model must be held in `@State`, **not** constructed inside the `.sheet(item:)` content closure. That closure re-runs on every render of the presenting view, so building the model there would hand the field a fresh, empty model mid-capture and discard whatever the user had typed. A wrapper view owns it for the life of one presentation.

Append to `Steno/Features/Capture/CaptureFieldView.swift`:

```swift
/// Owns the field model for one presentation of the capture sheet.
///
/// `@State`, not a value built in `body`: `.sheet(item:)`'s content closure
/// re-runs on every render of the presenting view, and rebuilding the model
/// there would replace it with an empty one mid-capture — losing the user's
/// typing, which is the single worst thing a capture tool can do (§1.1).
///
/// `MainWindowView.init` already establishes this pattern for
/// `MainWindowModel`, and for the same reason.
struct NewTaskSheet: View {
    private let model: MainWindowModel
    @State private var field: CaptureFieldModel

    init(model: MainWindowModel) {
        self.model = model
        _field = State(
            initialValue: CaptureFieldModel(
                service: model.captureService(),
                projects: { model.projects },
                preferred: { model.preferredProjectIDForCapture },
                onCaptured: { _ in model.reload() }
            )
        )
    }

    var body: some View {
        CaptureFieldView(field: field) { model.activeSheet = nil }
    }
}
```

- [ ] **Step 3: Render it from the main window**

In `Steno/Features/MainWindow/MainWindowView.swift`, replace the `case .newTask:` arm of the `.sheet(item:)` switch with:

```swift
            case .newTask:
                NewTaskSheet(model: model)
```

`TextEntrySheet` keeps the `.newProject` arm unchanged: the two sheets' contracts have genuinely diverged, and parameterising one view over "has a chip" would serve neither.

- [ ] **Step 4: Expose what the view needs from the model**

In `StenoKit/Features/MainWindow/MainWindowModel.swift`, add to the `// MARK: - Writing` section, directly above `createTask(titled:)`:

```swift
    /// A capture service over this window's context, for the capture sheet.
    ///
    /// The view never touches the context itself — it gets a service that
    /// already holds one, so D-019's rule (no `@Query`, no
    /// `@Environment(\.modelContext)`) is untouched.
    public func captureService() -> CaptureService {
        CaptureService(context: context, now: now, save: save)
    }

    /// FR-1.4 rung 2, exposed for the capture sheet. See `preferredProjectID`.
    public var preferredProjectIDForCapture: UUID? { preferredProjectID() }
```

- [ ] **Step 5: Build and run the suite**

Run: `make build && make test && make lint`
Expected: all pass.

- [ ] **Step 6: Verify by hand in the running app**

Run: `make run`

Check, and note the result for the PR body:
1. ⌘N opens the capture sheet with the field already focused — no click needed.
2. Typing plain text and pressing `Return` creates the task.
3. With a project configured for `PAY` (Task 7 builds the editor — do this check again after that task), typing `PAY-421` raises the chip; clicking its `xmark` clears it; `Return` then files the task under the sidebar's project instead.
4. `Esc` closes the sheet with nothing saved.

- [ ] **Step 7: Commit**

```bash
git add Steno/Features/Capture/CaptureFieldView.swift Steno/Features/MainWindow/MainWindowView.swift StenoKit/Features/MainWindow/MainWindowModel.swift
git commit -m "feat: capture field view with the inline routing chip

The surface-shared view: M1-03's floating window and M1-04's popover
embed this rather than rebuilding it, which is what makes D15's one
code path true of the UI as well as of the write. Everything stateful
stays in CaptureFieldModel over in StenoKit, where the headless bundle
can reach it; this file is layout.

Dismissing the chip is a plain button with an xmark and no
confirmation — §1.1 treats a modal interruption during capture as a
defect, so declining a routing costs one click and blocks nothing. A
failed save keeps the sheet open with the text intact.

TextEntrySheet keeps the New Project arm. The two sheets' contracts
have diverged and parameterising one view over 'has a chip' would
serve neither.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: The Jira keys editor

**Files:**
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Create: `Steno/Features/MainWindow/ProjectEditSheet.swift`
- Modify: `Steno/Features/MainWindow/SidebarView.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowActions.swift`
- Test: `StenoTests/Features/MainWindow/MainWindowModelProjectsTests.swift`

**Interfaces:**
- Produces: `ActiveSheet.editProject(UUID)`; `MainWindowModel.updateProject(id:name:jiraKeys:)`; `MainWindowModel.normalisedKeys(_:)` (internal, for tests).

**Why this task exists at all:** no task in the 36-task plan owns editing `Project.jiraProjectKeys`. Without it, `createProject(named:)` always produces `[]`, auto-routing is unreachable in the running app, and M1-04's "chip behaving identically" criterion has nothing to compare. This widens the PR past the task file's In-scope list, deliberately and declared (design §7).

- [ ] **Step 1: Write the failing test**

Append to `StenoTests/Features/MainWindow/MainWindowModelProjectsTests.swift`. If that file's `makeModel()` helper is named differently, match the local one rather than adding a second.

```swift
@MainActor
@Test("editing a project stores its name and Jira keys")
func editingAProjectStoresNameAndKeys() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)

    model.updateProject(id: id, name: "Payments Platform", jiraKeys: "PAY, BILL")

    let project = try #require(model.project(withID: id))
    #expect(project.name == "Payments Platform")
    #expect(project.jiraProjectKeys == ["PAY", "BILL"])
}

@MainActor
@Test("keys are uppercased, trimmed, de-duplicated, and emptied")
func keysAreNormalised() {
    #expect(MainWindowModel.normalisedKeys(" pay , BILL,pay,, ") == ["PAY", "BILL"])
    #expect(MainWindowModel.normalisedKeys("") == [])
    #expect(MainWindowModel.normalisedKeys("   ") == [])
}

@MainActor
@Test("a project cannot be renamed to nothing")
func blankProjectNameIsRefused() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)

    model.updateProject(id: id, name: "   ", jiraKeys: "PAY")

    let project = try #require(model.project(withID: id))
    #expect(project.name == "Payments")
    #expect(project.jiraProjectKeys.isEmpty)
}

@MainActor
@Test("editing keys makes auto-routing reachable end to end")
func editedKeysRouteACapture() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createProject(named: "EM — Hiring")
    let payments = try #require(model.projects.first?.id)
    let hiring = try #require(model.projects.last?.id)
    model.updateProject(id: payments, name: "Payments", jiraKeys: "PAY")

    model.selection = .project(hiring)

    // **Drives the live path deliberately.** This is the same
    // `CaptureFieldModel` wiring `NewTaskSheet` builds — not
    // `MainWindowModel.createTask`, which production no longer calls. An
    // end-to-end claim has to travel the route the user's keystrokes take,
    // or it is an end-to-end claim about nothing.
    let field = CaptureFieldModel(
        service: model.captureService(),
        projects: { model.projects },
        preferred: { model.preferredProjectIDForCapture },
        onCaptured: { _ in model.reload() }
    )
    field.text = "PAY-421 fix the retry handler"

    // The chip is the user-visible half of the same routing decision, and
    // it is the thing the editor exists to make reachable at all.
    #expect(field.chip?.projectID == payments)

    field.commit()

    // Under All, because the key routed the task away from the selection and
    // `groups` only ever holds the selected project's tasks.
    model.selection = .all

    // The whole point of the editor: without it every project holds [] and
    // this assertion cannot be made to pass by any user action.
    let landed = try #require(model.groups.flatMap(\.tasks).first)
    #expect(landed.projectID == payments)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — `value of type 'MainWindowModel' has no member 'updateProject'`.

- [ ] **Step 3: Add the model method**

In `StenoKit/Features/MainWindow/MainWindowModel.swift`, add after `createProject(named:)`:

```swift
    /// Edit a project's name and its Jira key prefixes (FR-3).
    ///
    /// `jiraProjectKeys` is what FR-1.4 routes on, and before this method
    /// nothing in the plan could set it — every project held `[]` from
    /// creation, so auto-routing was unreachable in the running app. See the
    /// M1-02 design doc §7 and REQUIREMENTS.md v1.11.
    ///
    /// Keys arrive as the comma-separated string the field holds; normalising
    /// here means `ProjectRouter` never depends on how they were typed.
    public func updateProject(id: UUID, name: String, jiraKeys: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let keys = Self.normalisedKeys(jiraKeys)
        let stamp = now()
        perform("save the project") {
            project.rename(to: trimmed, at: stamp)
            project.setJiraProjectKeys(keys, at: stamp)
        }
    }

    /// `" pay , BILL,pay,, "` → `["PAY", "BILL"]`.
    ///
    /// Internal rather than private so the normalisation rules can be tested
    /// without a container; `@testable import` reaches it.
    static func normalisedKeys(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for piece in raw.split(separator: ",") {
            let key = piece.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Add the sheet case**

In `StenoKit/Features/MainWindow/MainWindowActions.swift`, add a case to `ActiveSheet`:

```swift
    /// Edit the named project — FR-3's project editing (REQUIREMENTS v1.11).
    case editProject(UUID)
```

`ActiveSheet` is `Identifiable, Hashable, Sendable` with `public var id: Self { self }`, so the associated `UUID` needs no further work.

- [ ] **Step 6: Write the sheet**

Create `Steno/Features/MainWindow/ProjectEditSheet.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-3's project editing: a name, and the Jira key prefixes FR-1.4 routes on.
///
/// Two fields and nothing else. FR-6 owns Settings; project colour has no
/// picker by decision (see `ProjectPalette`); and §3.1 has no delete, only
/// archive, which the sidebar's context menu already offers.
struct ProjectEditSheet: View {
    let projectName: String
    let jiraKeys: [String]
    let onCommit: (String, String) -> Void

    @State private var name: String
    @State private var keys: String
    @Environment(\.dismiss) private var dismiss

    init(
        projectName: String,
        jiraKeys: [String],
        onCommit: @escaping (String, String) -> Void
    ) {
        self.projectName = projectName
        self.jiraKeys = jiraKeys
        self.onCommit = onCommit
        _name = State(initialValue: projectName)
        _keys = State(initialValue: jiraKeys.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Project")
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Jira keys, comma separated", text: $keys)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Text("A task mentioning PAY-421 files itself here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed, keys)
        dismiss()
    }
}
```

- [ ] **Step 7: Reach it from the sidebar**

In `Steno/Features/MainWindow/SidebarView.swift`, inside the existing `.contextMenu { … }`, add above the Archive button:

```swift
                        Button("Edit Project…") {
                            model.activeSheet = .editProject(project.id)
                        }
```

`SidebarView` holds `let model: MainWindowModel`, and `activeSheet` is a `public var`, so no signature change is needed.

- [ ] **Step 8: Render it**

In `Steno/Features/MainWindow/MainWindowView.swift`, add a third arm to the `.sheet(item:)` switch:

```swift
            case .editProject(let id):
                if let project = model.project(withID: id) {
                    ProjectEditSheet(
                        projectName: project.name,
                        jiraKeys: project.jiraProjectKeys
                    ) { name, keys in
                        model.updateProject(id: id, name: name, jiraKeys: keys)
                    }
                }
```

- [ ] **Step 9: Build, test, lint, and check by hand**

Run: `make build && make test && make lint`
Expected: all pass.

Run: `make run` and verify: right-click a project → "Edit Project…" → set keys to `PAY` → Save. Then ⌘N, type `PAY-421 fix`, and confirm the chip names that project. This is Task 6 Step 6's check 3, now actually performable.

- [ ] **Step 10: Commit**

```bash
git add StenoKit/Features/MainWindow/MainWindowModel.swift StenoKit/Features/MainWindow/MainWindowActions.swift Steno/Features/MainWindow/ProjectEditSheet.swift Steno/Features/MainWindow/SidebarView.swift Steno/Features/MainWindow/MainWindowView.swift StenoTests/Features/MainWindow/MainWindowModelProjectsTests.swift
git commit -m "feat: edit a project's name and Jira keys

Declared scope widening, flagged rather than smuggled. No task in the
36-task plan owns editing Project.jiraProjectKeys: the field and its
mutator exist from M0-03, createProject always passes [], and grepping
docs/tasks finds the field named only inside M1-02's own file. M1-08's
Settings scope is hotkey, launch at login and default project, and
per-project keys are not Settings-shaped anyway.

Without an editor this task's second acceptance criterion is provable
only in the test bundle: in the running app every project holds []
forever, the chip can never appear, and M1-04's 'chip behaving
identically to the main window' has nothing to compare.

Keys are uppercased, trimmed, de-duplicated and emptied on save, so
ProjectRouter never depends on how the user typed them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Measure the latency

**Files:**
- Modify: `StenoKit/Support/Logging.swift`
- Modify: `StenoKit/Capture/CaptureService.swift`
- Test: `StenoTests/Capture/CapturePerformanceTests.swift`

**Interfaces:**
- Produces: `Log.captureSignposter`. M1-03 uses it to measure the hotkey path including window presentation.

- [ ] **Step 1: Add the signposter**

In `StenoKit/Support/Logging.swift`, add inside `enum Log`:

```swift
    /// Intervals around the capture path.
    ///
    /// §1.1 makes capture latency a P0 functional requirement and §13 requires
    /// it measured rather than assumed. `CapturePerformanceTests` is the
    /// automated gate; this is how the same path is measured *in the running
    /// app*, where GUI automation is unavailable:
    ///
    ///     log show --last 5m --info --predicate \
    ///       'subsystem == "com.lgabrielgr.steno" AND category == "capture"'
    ///
    /// M1-03 and M1-04 must each show they did not regress it.
    public static let captureSignposter = OSSignposter(
        subsystem: subsystem, category: "capture")
```

If Swift 6 rejects the `static let` on `Sendable` grounds, make it a computed property — the way `JiraKey.pattern` handles the same problem for `Regex`:

```swift
    public static var captureSignposter: OSSignposter {
        OSSignposter(subsystem: subsystem, category: "capture")
    }
```

- [ ] **Step 2: Instrument `capture`**

In `StenoKit/Capture/CaptureService.swift`, as the first two lines of `capture(text:preferred:defaultProjectID:ignoringTicketKey:)`, above the `trimmed` line:

```swift
        let interval = Log.captureSignposter.beginInterval("capture")
        defer { Log.captureSignposter.endInterval("capture", interval) }
```

- [ ] **Step 3: Write the measurement**

Create `StenoTests/Capture/CapturePerformanceTests.swift`:

```swift
import Foundation
import SwiftData
import XCTest

@testable import StenoKit

/// §1.1 makes capture latency a P0 functional requirement: if capture exceeds
/// ~3 seconds the user reverts to paper and the product dies. §13 requires it
/// measured, not assumed. **M1-03 and M1-04 diff against this file.**
///
/// XCTest rather than Swift Testing per D-011 — the `measure` exception.
///
/// Each case asserts against the **worst** of `measure`'s ten iterations, not
/// the last, so the assertion does not look only at the warmest run.
///
/// The class is not `@MainActor` — that would make the XCTest overrides
/// main-actor-isolated and conflict with their nonisolated declarations. The
/// test methods carry the isolation instead, which is where `CaptureService`
/// needs it.
final class CapturePerformanceTests: XCTestCase {
    private static let realistic =
        "PAY-421 debugged the retry handler, PR https://github.com/acme/api/pull/912"

    /// A store on disk in a fresh temp directory.
    ///
    /// **Not `StenoStore.inMemory()`.** The in-memory store skips the fsync,
    /// which is the entire question this file asks.
    @MainActor
    private func makeService(at directory: URL, tasks: Int = 0) throws -> (
        CaptureService, ModelContext
    ) {
        let container = try StenoStore.live(at: directory.appendingPathComponent("Steno.store"))
        let context = ModelContext(container)
        let project = Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: Date())
        context.insert(project)
        for index in 0..<tasks {
            context.insert(
                TaskItem(title: "existing \(index)", projectID: project.id, createdAt: Date()))
        }
        try context.save()
        return (CaptureService(context: context), context)
    }

    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-capture-perf-\(UUID().uuidString)", isDirectory: true)
    }

    /// One realistic capture — routing, extraction, three inserts, one save —
    /// on an empty store.
    @MainActor
    func testSingleCaptureIsWellUnderBudget() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, context) = try makeService(at: directory)
        var elapsed = 0.0
        var failures = 0

        measure {
            let start = Date()
            do {
                try service.capture(text: Self.realistic, preferred: nil)
            } catch {
                failures += 1
            }
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }

        // `measure` runs the block ten times, so a swallowed error would
        // otherwise measure ten no-ops and pass.
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TaskItem>()).count, 10)
        XCTAssertLessThan(elapsed, 0.050, "a single capture exceeded 50 ms")
    }

    /// The same capture against D18's ceiling of live tasks, because the
    /// last-used derivation reads all of them (`CaptureService`'s comment
    /// explains why it cannot use `fetchLimit`).
    @MainActor
    func testCaptureAtScaleIsWellUnderBudget() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (service, _) = try makeService(at: directory, tasks: 20)
        var elapsed = 0.0
        var failures = 0

        measure {
            let start = Date()
            do {
                try service.capture(text: Self.realistic, preferred: nil)
            } catch {
                failures += 1
            }
            elapsed = max(elapsed, Date().timeIntervalSince(start))
        }

        XCTAssertEqual(failures, 0)
        XCTAssertLessThan(elapsed, 0.050, "a capture at D18 scale exceeded 50 ms")
    }
}
```

- [ ] **Step 4: Run it and read the real numbers**

Run: `make test 2>&1 | grep -i "capture.*seconds\|measured"`

`measure` prints the average for each case. Record both numbers.

- [ ] **Step 5: Tighten the ceilings to the measured values**

Replace each `0.050` with roughly **five times the worst measured value**, rounded up to a readable figure, and rewrite each doc comment to name the measured number — matching M1-01's `ExtractionPerformanceTests`, whose comments read "Measured at 180 µs, worst of ten, on this machine."

The ratio matters: too tight and a loaded machine fails the build; too loose and a real regression passes. If a measured value is already above 50 ms, do **not** simply raise the ceiling — that is the finding the task was asking for, and §8 of the design doc has the remedy (save the task and event first, extract and insert refs in a second save off the critical path). Report it before changing the design.

- [ ] **Step 6: Get the end-to-end number**

```bash
make run
```

Capture three or four tasks through ⌘N, quit, then:

```bash
log show --last 5m --info --predicate 'subsystem == "com.lgabrielgr.steno" AND category == "capture"'
```

Record the interval durations. This is the figure for the PR body — the automated gate measures the service, this measures the service inside the real app on the real store.

- [ ] **Step 7: Run everything and commit**

Run: `make build && make test && make lint`

```bash
git add StenoKit/Support/Logging.swift StenoKit/Capture/CaptureService.swift StenoTests/Capture/CapturePerformanceTests.swift
git commit -m "test: measure capture latency and gate it

§13 makes any change to this path performance-sensitive and requires
measurement rather than assumption; M1-03 and M1-04 must each prove
they did not regress it, so the measurement has to be something they
can mechanically re-run.

The gate measures against a real on-disk store in a temp directory,
not StenoStore.inMemory(), because the in-memory store skips the fsync
that is the entire question. The second case runs at D18's ceiling of
20 live tasks, since the last-used derivation reads all of them.

The signposter is how the same path gets measured in the running app,
where GUI automation is unavailable — and it stays in the source as
the instrument M1-03 uses to measure the hotkey path including window
presentation.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Records — decisions, architecture, spec amendment, task tick

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/REQUIREMENTS.md`
- Modify: `docs/tasks/README.md`

- [ ] **Step 1: Add the decisions**

In `docs/DECISIONS.md`, append to the `## Accepted` section, after D-023 and before the `---` that closes it. **D-028 records a deviation Task 1 already shipped** — read `StenoKit/Capture/ProjectRouter.swift`'s `route` signature to confirm the entry describes what is actually there before writing it:

````markdown
### D-024 — "Last-used project" is derived from the newest task, not stored
**2026-08-26** · M1-02 · **Status:** accepted

FR-1.4's "default to the last-used project" is answered by a query — the project of the most
recently created `TaskItem` — rather than by a stored `lastUsedProjectID`. No new field, no
`UserDefaults` key, no settings row.

**Why:** it cannot drift from reality; all three capture surfaces agree by construction rather
than by each remembering to write the same key; and it round-trips through §10's JSON export for
free, because it is not a separate fact at all. D18 caps the dataset under 20 live tasks, so the
read costs nothing.
**Alternatives:** a `UserDefaults` key written on each save (fastest read, but state outside the
store — it does not export, and it can point at an archived project, needing validation on read
anyway); a singleton settings row in SwiftData (portable, but a schema addition that §6's
CloudKit-compat rules and M2.5-02's merge would both then have to reason about, for one UUID).
**The trap, and it is D-021's:** the derivation must re-apply the visible-projects filter.
`TaskItem` has no archived flag of its own, so a `fetchLimit = 1` returns a task belonging to an
archived project and routes the capture into a project the user cannot see.

### D-025 — Routing scans for ticket keys directly, not through `ReferenceExtractor`
**2026-08-26** · M1-02 · **Status:** accepted

`ProjectRouter.ticketKeyMatch` runs `JiraKey.pattern` over the text with an early exit. It does
not call M1-01's extractor, and the two therefore disagree about keys inside links — deliberately.

**Why, twice over.** *Cost:* the chip re-derives on every keystroke, and `NSDataDetector` is the
expensive half of extraction — 180 µs on a capture string but ~180 ms on a 250 KB paste, which
would then be paid per keystroke. A regex scan with an early exit has no such cliff.
*Correctness:* M1-01's overlap rule suppresses keys sitting inside links so a browse URL yields
one ref rather than two. That is right for extraction and wrong for routing —
`https://acme.atlassian.net/browse/PAY-421` should route to Payments. Routing wants every key the
text mentions; extraction wants each one once.
**Alternatives:** calling `extract` for both (one scan, but pays `NSDataDetector` per keystroke
*and* silently declines to route a pasted browse URL); debouncing the live extraction (adds a
timer and a stale-chip window to the latency-critical path).
**Consequence to know about:** a URL slug like `/reports/AWS-2024/q3` routes to a project
configured with the prefix `AWS`. Narrow, and one click to dismiss.

### D-026 — A project is seeded on first launch; capture refuses only when all are archived
**2026-08-26** · M1-02 · **Status:** accepted

`StenoStore.seedDefaultProjectIfEmpty(in:)` inserts one `Inbox` project when the store holds zero
projects, called from `StenoApp` after the container opens. The emptiness check counts archived
projects, so seeding happens once in a store's life.

**Why:** on a fresh install there are no projects, so M0-05 disabled New Task — a capture surface
refusing text, which §1.1 forbids. M1-03 makes it worse: the hotkey window would open above every
other app into a field whose `Return` does nothing.
**The exception this leaves, stated because ARCHITECTURE §3 claims capture never blocks.** With
every project archived, routing has no target, `CaptureService` throws `noProjectAvailable`, and
`canCreateTask` is false. Not re-seeded: that would resurrect a project the user archived on
purpose, and unlike a fresh install it is a state they navigated into deliberately with a visible
undo. §3.1 hides archived projects and never deletes them, so choosing to hide all of them is a
legitimate thing to have done.
**Alternatives:** minting a project lazily inside the first capture (nothing exists until the user
types, but the write becomes conditional and two-part on the latency-critical path); keeping
M0-05's gate (honest about the data model, dead field on a fresh install).

### D-027 — M1-02 adds project editing, which no task owned
**2026-08-26** · M1-02 · **Status:** accepted · spec amendment

Spec amendment — carried by `REQUIREMENTS.md` FR-3 (v1.11). Nothing in the 36-task plan owned
editing `Project.jiraProjectKeys`: the field and `setJiraProjectKeys(_:at:)` exist from M0-03,
`createProject(named:)` always passes `[]`, and the field is named in `docs/tasks/` only inside
M1-02's own file. M1-08's Settings scope is hotkey, launch at login and default project, and
per-project keys are not Settings-shaped.

**Why it could not wait:** FR-1.4 routes on `jiraProjectKeys`. Without an editor every project
holds `[]` forever, so auto-routing and its chip are unreachable in the running app, M1-02's second
acceptance criterion is provable only in the test bundle, and M1-04's "chip behaving identically to
the main window" has nothing to compare.
**Scope:** a sidebar context-menu sheet with a name field and a comma-separated keys field, over
the mutators M0-03 already shipped. Deliberately outside the task file's In-scope list, and
declared in the PR body rather than smuggled.

### D-028 — `ProjectRouter.route`'s `defaultProjectID` carries a default value
**2026-08-26** · M1-02 · **Status:** accepted · extends D-013, D-023

`route(text:projects:preferred:lastUsed:defaultProjectID:ignoringTicketKey:)` takes six
parameters, which trips SwiftLint's `function_parameter_count` (warning threshold 5, promoted to
a failure by `--strict`). `defaultProjectID` is declared `UUID? = nil`; the rule's
`ignores_default_parameters` option defaults to true, so one default clears the violation.

**Why this parameter and not another:** FR-6's configured default is the one rung that genuinely
has no value until M1-08 builds the setting — the design already describes it as "a parameter
from day one, `nil` until M1-08 fills it." A default therefore misrepresents nothing. The other
five are required at every call site and defaulting any of them would hide a real argument.
**Why not the alternatives:** an inline `swiftlint:disable` is what D-023 reserves for genuine
false positives, and a function that really does take six arguments is not one. Disabling
`function_parameter_count` in `.swiftlint.yml` would drop the rule for the whole project to
settle one call — the opposite of D-023's reasoning, where a rule was removed because its
residual value was nil rather than because one site found it inconvenient.
**The cost, and where it is paid:** the design's argument for threading the parameter through
from day one is that M1-08 satisfies its acceptance criterion "by passing an argument, not by
editing this function" — which holds only while every call site passes it explicitly. A default
makes silent omission possible. `CaptureService.capture` is the only production caller and does
pass it explicitly; `capture`'s *own* `defaultProjectID: UUID? = nil` is separate and was
specified from the start. **M1-08 should verify both call sites rather than assuming.**
````

- [ ] **Step 2: Update ARCHITECTURE**

In `docs/ARCHITECTURE.md` §3's invariant table, replace the "Capture never blocks" row with:

```markdown
| Capture never blocks | No modal, picker, or validation before text entry | Capture core (M1-02). One documented exception: every project archived (D-026) | §1.1, FR-1.4 |
```

In §5's layout block, replace the `Capture/` line with:

```
  Capture/        ref extraction (M1-01); routing, capture service (M1-02)
```

and the `Features/` line with:

```
  Features/       view models, by feature — MainWindow (M0-05), Capture (M1-02)
```

and the `Support/` line with:

```
  Support/        Logging.swift, ProjectPalette.swift            (exists, M0-02/M1-02)
```

In §4's Capture data-flow block, replace the routing line with:

```
                          └─> project routing (ticket key, else surface context,
                              else last-used, else configured default)
```

- [ ] **Step 3: Amend REQUIREMENTS**

In `docs/REQUIREMENTS.md`:

Change the status line from `**Status:** Draft v1.10` to `**Status:** Draft v1.11`, and the date to `**Date:** 2026-08-26`.

Add as the first changelog entry, above the `- *v1.10*` line:

```markdown
- *v1.11* — FR-3 gains project editing. FR-1.4 routes captures on `Project.jiraProjectKeys`, but no requirement granted any way to set them: projects are created with `[]` and nothing could change it, so auto-routing and its chip would have shipped unreachable in the running app. Found while implementing M1-02, which adds the editor.
```

In FR-3, after the numbered three-column list and before the "**Keyboard-first requirement.**" paragraph, insert:

```markdown
**Project editing.** A project's name and its `jiraProjectKeys` are editable from the sidebar. This is what makes FR-1.4's auto-routing reachable: routing matches a typed ticket key's prefix against `jiraProjectKeys`, and without a way to set them every project holds an empty list forever. Colour is not editable — see D9 and §3.1; deletion does not exist — see §3.1, archiving only.
```

- [ ] **Step 4: Tick the task**

In `docs/tasks/README.md`, change the M1-02 row from `- [ ]` to `- [x]`.

Then check the rows above it for any that merged without being ticked (CLAUDE.md's "Working a task" step 4). As of `942742c` there are none outstanding — M1-01 was ticked in its own PR — but verify rather than assume.

- [ ] **Step 5: Verify the whole thing one more time**

Run: `make build && make test && make lint`
Expected: all pass. Docs-only changes cannot break these, but §9.5 step 4 wants the sequence run against the final tree.

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "docs: record M1-02's decisions and amend FR-3

Four decisions: last-used derived rather than stored (D-024), routing
scanning keys directly rather than through the extractor (D-025), the
seeded first-launch project and the one state where capture still
refuses (D-026), and project editing as a declared scope widening
(D-027).

REQUIREMENTS goes to v1.11. FR-1.4 routes on jiraProjectKeys but no
requirement granted any way to set them, so auto-routing would have
shipped unreachable — every project holds [] from creation. FR-3 now
carries project editing.

ARCHITECTURE §3's 'capture never blocks' row gains its enforcement site
and names its single documented exception, so the invariant table stays
true rather than aspirational.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Open the pull request

- [ ] **Step 1: Final verification**

Run: `make build && make test && make lint`

Do not proceed unless all three pass. §9.5 step 4 and §13 both make this the gate, and "this should compile" is explicitly not acceptable.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/quick-capture-core
```

Then open the PR with a body covering, at minimum:

1. **The measured capture latency** — both the `CapturePerformanceTests` figures and the `log show` end-to-end number (Task 8 steps 4 and 6). This is an explicit acceptance criterion.
2. **The declared scope widening** — the project keys editor, why the task could not meet its own acceptance criterion without it, and the FR-3 amendment to v1.11 (CLAUDE.md: "Say so in the PR body. Do not silently deviate.").
3. **The one state where capture still blocks** — every project archived — and why it was not papered over.
4. **What cannot be verified here** — GUI automation is unavailable, so the chip's legibility and the hittability of its dismiss target need the reviewer's own pass. The state machine behind it is covered headlessly.

- [ ] **Step 3: Stop**

Do not merge. The user reviews and merges (CLAUDE.md non-negotiable 1; `main` is protected, so a direct push fails regardless).
