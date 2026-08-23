# M0-05 Main Window Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build FR-3's three-column main window — sidebar, grouped task list, detail pane — able to create and list projects and tasks, which is the M0 exit criterion made visible.

**Architecture:** A single `@Observable @MainActor` view model in `StenoKit` owns the `ModelContext` and publishes ready-to-render arrays; views in `Steno` declare no `@Query` and no `@Environment(\.modelContext)`, so ARCHITECTURE §2 rule 2 holds by construction. Keyboard shortcuts are real menu-bar items in a `Commands` struct that reaches the view model through `@FocusedValue`. The two pieces of logic worth exhaustive testing — FR-3 group ordering and the DONE cutoff — are pure free functions requiring no store at all.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XcodeGen, SwiftLint, swift-format.

**Spec:** [`docs/superpowers/specs/2026-08-23-m0-05-main-window-shell-design.md`](../specs/2026-08-23-m0-05-main-window-shell-design.md)

## Global Constraints

- **Swift 6 language mode**, deployment target **macOS 14.0**. Both are set in `project.yml`; do not change them.
- **Never commit to `main`.** All work is on `feat/main-window-shell`. Open a PR; **do not merge it** (§9.5).
- **`make build && make test && make lint` must all pass before the PR** (§9.5 step 4). Not "should compile" — run them.
- **Swift Testing** (`@Test` / `#expect`) is the convention (D-011). XCTest only for `measure`; none is needed here.
- **`make lint` runs `swiftlint --strict`** — warnings are errors. `make format` (swift-format) owns layout; SwiftLint owns semantics (D-013). If they disagree, the layout tool wins.
- **Testable code goes in `StenoKit/`; only SwiftUI views and `@main` go in `Steno/`** (D-010). The test: if it cannot be tested without a window server, it does not belong in `Steno/`.
- **Never commit `Steno.xcodeproj` or `Local.xcconfig`** — both are gitignored (§9.1, §9.3). If either appears in `git status`, stop.
- **The event log is append-only** (§3.3). This plan only ever *inserts* `Event` rows. Never mutate or delete one.
- **No pagination, virtualization, search, or filter chips** (D18, FR-3). Under 20 live tasks. If you find yourself adding any of these, stop — they are excluded permanently, not deferred.
- **This task displays status; it never mutates it.** Status changes are M1-05. The detail pane's status is a label, not a control.
- **Tests must obtain their `ModelContext` via `ModelContext(container)`, never `container.mainContext`.** A `ModelContext` created from a container retains it; `mainContext` does not, so handing `mainContext` out of a helper leaves a dangling context and the next insert traps inside SwiftData. Production code is different and correct as written: `StenoApp` holds the container for the app's lifetime, so `MainWindowView` passing `container.mainContext` is safe.
- New source directories are picked up automatically: XcodeGen's `sources:` entries are directory-recursive, and `.swiftlint.yml` already includes `Steno`, `StenoKit`, `StenoTests`. No manifest edit is needed for the new `Features/` folders.

## Verification status of the code in this plan

Every Swift snippet below was type-checked against **the real `StenoKit` sources** with:

```bash
xcrun swiftc -swift-version 6 -parse-as-library \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macos14.0 -typecheck \
  StenoKit/Models/*.swift StenoKit/Support/*.swift StenoKit/Persistence/*.swift <new files>
```

Test files were additionally checked **with the Swift Testing macros expanded**, by adding:

```bash
  -F "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  -load-plugin-library "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

That second step matters: `@Test` and `#expect` are macros, and code that type-checks outside them has previously failed inside them in this repo. The `#expect(groups.map(\.status) == …)` forms below were verified in expanded form.

Beyond type-checking, the whole model was **executed** against `StenoStore.inMemory()` in a throwaway harness: 29 behavioural assertions covering grouping order, the DONE boundary at 24h, the `created` event, project scoping, archive semantics, and selection cycling all passed. The expected values in this plan's tests are measured, not guessed.

**One thing the spec did not settle, decided here:** the spec says ⌘N "resolves a target project and inserts the `TaskItem`" but never says how the user types the title. This plan uses the same sheet contract §3.3 defines for projects — a focused field, Return commits, Esc cancels — via one reusable `TextEntrySheet`. M1-02 replaces the plumbing when quick capture lands. Flag this in the PR body.

---

### Task 1: Pure logic — selection, grouping, palette

No `ModelContext`, no container, no clock. These are the pieces worth testing exhaustively, and they are testable with literal arrays.

**Files:**
- Create: `StenoKit/Features/MainWindow/ProjectSelection.swift`
- Create: `StenoKit/Features/MainWindow/TaskGrouping.swift`
- Create: `StenoKit/Features/MainWindow/ProjectPalette.swift`
- Create: `StenoKit/Features/MainWindow/Status+Display.swift`
- Test: `StenoTests/Features/MainWindow/ProjectSelectionTests.swift`
- Test: `StenoTests/Features/MainWindow/TaskGroupingTests.swift`
- Test: `StenoTests/Features/MainWindow/ProjectPaletteTests.swift`

**Interfaces:**
- Consumes: `Status`, `TaskItem` from `StenoKit/Models/` (already merged in M0-03).
- Produces:
  - `public enum ProjectSelection: Hashable, Sendable { case all; case project(UUID) }`
  - `public static func next(after: ProjectSelection, in projectIDs: [UUID]) -> ProjectSelection`
  - `public static func previous(before: ProjectSelection, in projectIDs: [UUID]) -> ProjectSelection`
  - `public struct TaskGroup: Identifiable { public let status: Status; public let tasks: [TaskItem]; public var id: Status }`
  - `public enum TaskGrouping { public static let order: [Status]; public static func groups(from: [TaskItem], doneSince: Date) -> [TaskGroup] }`
  - `public enum ProjectPalette { public static let hexes: [String]; public static func hex(forIndex: Int) -> String }`
  - `public var Status.displayName: String`

- [ ] **Step 1: Write the failing tests for grouping**

Create `StenoTests/Features/MainWindow/TaskGroupingTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

private func task(_ title: String, _ status: Status, changedAt: Date = origin) -> TaskItem {
    // `createdAt` seeds `statusChangedAt`, and `setStatus` deliberately no-ops
    // when the status is unchanged (§3.2) — so a `.todo` task only carries the
    // instant we want if it is created at that instant. Passing `changedAt`
    // here makes the helper correct for all four statuses without branching.
    let item = TaskItem(title: title, projectID: UUID(), createdAt: changedAt)
    item.setStatus(status, at: changedAt)
    return item
}

@Test("FR-3 order is IN-PROGRESS, BLOCKED, TODO, DONE — not the enum's declaration order")
func groupsUseFR3Order() {
    let tasks = [
        task("d", .done),
        task("t", .todo),
        task("b", .blocked),
        task("p", .inProgress),
    ]

    let groups = TaskGrouping.groups(from: tasks, doneSince: origin.addingTimeInterval(-3600))

    #expect(groups.map(\.status) == [.inProgress, .blocked, .todo, .done])
}

@Test("a status with no tasks produces no group")
func emptyGroupsAreOmitted() {
    let groups = TaskGrouping.groups(from: [task("t", .todo)], doneSince: origin)

    #expect(groups.count == 1)
    #expect(groups.first?.status == .todo)
}

@Test("DONE shows completions inside the cutoff and hides older ones")
func doneHonoursCutoff() {
    let cutoff = origin.addingTimeInterval(-24 * 3600)
    let recent = task("recent", .done, changedAt: origin.addingTimeInterval(-3600))
    let ancient = task("ancient", .done, changedAt: origin.addingTimeInterval(-30 * 3600))

    let groups = TaskGrouping.groups(from: [recent, ancient], doneSince: cutoff)

    #expect(groups.count == 1)
    #expect(groups[0].status == .done)
    #expect(groups[0].tasks.map(\.title) == ["recent"])
}

@Test("a task that was never completed never appears in DONE")
func neverCompletedIsNotInDone() {
    // `completedAt` is nil for anything that has not been through
    // setStatus(.done), so the DONE filter must not admit it on the strength
    // of the cutoff alone.
    let fresh = TaskItem(title: "fresh", projectID: UUID(), createdAt: origin)

    let groups = TaskGrouping.groups(from: [fresh], doneSince: origin)

    #expect(groups.map(\.status) == [.todo])
}

@Test("the four statuses render with FR-3's spelling")
func statusDisplayNames() {
    #expect(Status.inProgress.displayName == "IN-PROGRESS")
    #expect(Status.blocked.displayName == "BLOCKED")
    #expect(Status.todo.displayName == "TODO")
    #expect(Status.done.displayName == "DONE")
    // Every case is covered, so adding a fifth status breaks this test rather
    // than silently rendering an unlabelled group. D11 says there is no fifth.
    #expect(Status.allCases.count == 4)
}

@Test("within a group, most recently touched comes first")
func groupsSortByRecency() {
    let older = task("older", .todo, changedAt: origin.addingTimeInterval(-7200))
    let newer = task("newer", .todo, changedAt: origin.addingTimeInterval(-60))

    let groups = TaskGrouping.groups(from: [older, newer], doneSince: origin)

    #expect(groups[0].tasks.map(\.title) == ["newer", "older"])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test
```

Expected: FAIL — `cannot find 'TaskGrouping' in scope`.

- [ ] **Step 3: Implement the grouping**

Create `StenoKit/Features/MainWindow/TaskGrouping.swift`:

```swift
import Foundation

/// One status section of the task list (REQUIREMENTS.md FR-3).
public struct TaskGroup: Identifiable {
    public let status: Status
    public let tasks: [TaskItem]

    public var id: Status { status }
}

/// Turns a flat array of tasks into FR-3's status sections.
///
/// Pure and free-standing rather than a method on the view model: this and the
/// DONE cutoff are the two rules in the main window worth testing exhaustively,
/// and as free functions they are tested against literal arrays with no
/// container, no context, and no clock.
public enum TaskGrouping {
    /// FR-3's order, which is **not** `Status`'s declaration order.
    ///
    /// Named here, and asserted in a test, so that reordering the enum for any
    /// other reason cannot silently reorder the user's window.
    public static let order: [Status] = [.inProgress, .blocked, .todo, .done]

    /// Sections in FR-3 order, omitting any that would be empty.
    ///
    /// `doneSince` scopes the DONE section. FR-3 scopes it to the current
    /// report window; see `MainWindowModel.doneCutoff()` for why a fixed 24
    /// hours is the same answer until M2-01 lands.
    public static func groups(from tasks: [TaskItem], doneSince cutoff: Date) -> [TaskGroup] {
        order.compactMap { status in
            let matching = tasks
                .filter { task in
                    guard task.status == status else { return false }
                    guard status == .done else { return true }
                    // A DONE task with no completedAt cannot be placed in the
                    // window, so it is not shown rather than always shown.
                    guard let completedAt = task.completedAt else { return false }
                    return completedAt >= cutoff
                }
                .sorted { $0.statusChangedAt > $1.statusChangedAt }

            guard !matching.isEmpty else { return nil }
            return TaskGroup(status: status, tasks: matching)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make test
```

Expected: PASS.

- [ ] **Step 5: Write the failing tests for selection cycling and the palette**

Create `StenoTests/Features/MainWindow/ProjectSelectionTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

@Test("cycling starts at All and reaches the first project")
func nextFromAllSelectsFirstProject() {
    let ids = [UUID(), UUID()]

    #expect(ProjectSelection.next(after: .all, in: ids) == .project(ids[0]))
}

@Test("cycling forward wraps back round to All", arguments: [0, 1, 2, 5])
func forwardCycleWraps(projectCount: Int) {
    let ids = (0..<projectCount).map { _ in UUID() }
    var selection = ProjectSelection.all

    // One step per project, plus one to come back round to All.
    for _ in 0...projectCount {
        selection = .next(after: selection, in: ids)
    }

    #expect(selection == .all)
}

@Test("cycling backward from All wraps to the last project")
func previousFromAllWrapsToLast() {
    let ids = [UUID(), UUID(), UUID()]

    #expect(ProjectSelection.previous(before: .all, in: ids) == .project(ids[2]))
}

@Test("a selection that is no longer in the list falls back to All")
func staleSelectionFallsBackToAll() {
    // The project was archived between the keystroke and the lookup.
    #expect(ProjectSelection.next(after: .project(UUID()), in: [UUID()]) == .all)
}
```

Create `StenoTests/Features/MainWindow/ProjectPaletteTests.swift`:

```swift
import Testing

@testable import StenoKit

@Test("the palette cycles rather than trapping past its end")
func paletteCycles() {
    let count = ProjectPalette.hexes.count

    #expect(ProjectPalette.hex(forIndex: count) == ProjectPalette.hex(forIndex: 0))
    #expect(!ProjectPalette.hex(forIndex: 99).isEmpty)
}

@Test("consecutive projects get distinguishable colours")
func consecutiveColoursDiffer() {
    #expect(ProjectPalette.hex(forIndex: 0) != ProjectPalette.hex(forIndex: 1))
}

@Test("every palette entry is a six-digit hex colour")
func paletteEntriesAreWellFormed() {
    for hex in ProjectPalette.hexes {
        #expect(hex.count == 7)
        #expect(hex.hasPrefix("#"))
    }
}
```

- [ ] **Step 6: Run the tests to verify they fail**

```bash
make test
```

Expected: FAIL — `cannot find 'ProjectSelection' in scope`.

- [ ] **Step 7: Implement selection, palette, and the status label**

Create `StenoKit/Features/MainWindow/ProjectSelection.swift`:

```swift
import Foundation

/// What the main window is currently showing: one project, or FR-3's "All"
/// pseudo-project at the top of the sidebar.
public enum ProjectSelection: Hashable, Sendable {
    case all
    case project(UUID)

    /// The sidebar's cycle order: "All" first, then projects in `sortOrder`.
    static func ring(_ projectIDs: [UUID]) -> [ProjectSelection] {
        [.all] + projectIDs.map(ProjectSelection.project)
    }

    /// The next selection, wrapping at the end (FR-3's "switch project").
    public static func next(
        after current: ProjectSelection,
        in projectIDs: [UUID]
    ) -> ProjectSelection {
        step(from: current, in: projectIDs, by: 1)
    }

    /// The previous selection, wrapping at the start.
    public static func previous(
        before current: ProjectSelection,
        in projectIDs: [UUID]
    ) -> ProjectSelection {
        step(from: current, in: projectIDs, by: -1)
    }

    /// Falls back to `.all` when `current` is not in the list — which happens
    /// whenever the selected project has just been archived.
    private static func step(
        from current: ProjectSelection,
        in projectIDs: [UUID],
        by offset: Int
    ) -> ProjectSelection {
        let ring = ring(projectIDs)
        guard let index = ring.firstIndex(of: current) else { return .all }
        // Swift's % is remainder, not modulo, so a negative step needs the
        // extra + count before the second % to land in range.
        let wrapped = ((index + offset) % ring.count + ring.count) % ring.count
        return ring[wrapped]
    }
}
```

Create `StenoKit/Features/MainWindow/ProjectPalette.swift`:

```swift
/// The colours new projects are assigned, in order.
///
/// There is no colour picker: §3.1 describes `colorHex` as visual
/// identification in lists, and FR-6's Settings list does not include project
/// colour. FR-3 says to build the simple thing.
public enum ProjectPalette {
    public static let hexes = [
        "#3B82F6", "#F59E0B", "#10B981", "#EF4444",
        "#8B5CF6", "#EC4899", "#14B8A6", "#F97316",
    ]

    /// Cycles rather than trapping — D18 caps live projects well below this,
    /// but a crash on the ninth project would be an absurd way to find out.
    public static func hex(forIndex index: Int) -> String {
        let wrapped = ((index % hexes.count) + hexes.count) % hexes.count
        return hexes[wrapped]
    }
}
```

Create `StenoKit/Features/MainWindow/Status+Display.swift`:

```swift
extension Status {
    /// FR-3's spelling, used for group headers and the detail pane.
    ///
    /// In `StenoKit` rather than in a view so the strings are assertable, and
    /// so M1-04's popover and M1-05's status control cannot invent a second
    /// spelling of the same four statuses.
    public var displayName: String {
        switch self {
        case .todo: "TODO"
        case .inProgress: "IN-PROGRESS"
        case .blocked: "BLOCKED"
        case .done: "DONE"
        }
    }
}
```

- [ ] **Step 8: Run the full gate**

```bash
make test && make lint
```

Expected: PASS for both. If `swiftlint --strict` objects to layout, run `make format` and re-run — swift-format owns layout (D-013).

- [ ] **Step 9: Commit**

```bash
git add StenoKit/Features/MainWindow StenoTests/Features/MainWindow
git commit -m "feat: FR-3 task grouping, project selection, and colour palette

The two rules worth testing exhaustively in the main window — FR-3's
IN-PROGRESS/BLOCKED/TODO/DONE ordering and the DONE cutoff — are pure
functions over an array, so they need no container, no context, and no
clock to test.

FR-3's order is deliberately not Status's declaration order, and a test
asserts that, so reordering the enum for an unrelated reason cannot
silently reorder the user's window.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `MainWindowModel` — projects, saving, and the action surface

The view model gains the store, the project list, project creation and archiving, and the save-or-roll-back helper every later mutation uses.

**Files:**
- Create: `StenoKit/Features/MainWindow/MainWindowActions.swift`
- Create: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Test: `StenoTests/Features/MainWindow/MainWindowModelProjectsTests.swift`

**Interfaces:**
- Consumes: `ProjectSelection`, `ProjectPalette` (Task 1); `Project`, `Log` and `StenoStore.inMemory()` from the merged code.
- Produces:
  - `@MainActor public protocol MainWindowActions: AnyObject` with `newTask()`, `newProject()`, `selectNextProject()`, `selectPreviousProject()`
  - `@Observable @MainActor public final class MainWindowModel: MainWindowActions`
  - `public init(context: ModelContext, now: @escaping () -> Date = Date.init)`
  - `public private(set) var projects: [Project]`, `public private(set) var lastError: String?`
  - `public var selection: ProjectSelection`, `public var isPresentingNewProject: Bool`, `public var isPresentingNewTask: Bool`, `public var selectedTaskID: UUID?`
  - `public var canCreateTask: Bool`
  - `public func createProject(named: String)`, `public func archive(projectID: UUID)`, `public func reload()`, `public func dismissError()`, `public func project(withID: UUID) -> Project?`

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Features/MainWindow/MainWindowModelProjectsTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeModel() throws -> (MainWindowModel, ModelContext) {
    let container = try StenoStore.inMemory()
    // `ModelContext(container)` retains its container. `container.mainContext`
    // does NOT — so returning the main context from a helper leaves it
    // dangling the moment the container goes out of scope, and the next
    // insert/save traps inside SwiftData with EXC_BREAKPOINT. Every other
    // test in this repo already uses this form; match it.
    let context = ModelContext(container)
    return (MainWindowModel(context: context, now: { origin }), context)
}

@MainActor
@Test("a new model on an empty store lists nothing and cannot create a task")
func emptyStore() throws {
    let (model, _) = try makeModel()

    #expect(model.projects.isEmpty)
    #expect(!model.canCreateTask)
    #expect(model.lastError == nil)
}

@MainActor
@Test("creating a project persists it and shows it in the sidebar list")
func createProjectPersists() throws {
    let (model, context) = try makeModel()

    model.createProject(named: "Payments Platform")

    #expect(model.projects.map(\.name) == ["Payments Platform"])
    // Persisted, not merely held in memory: a fresh fetch sees it.
    let stored = try context.fetch(FetchDescriptor<Project>())
    #expect(stored.count == 1)
}

@MainActor
@Test("project names are trimmed and blank names are refused")
func createProjectTrimsAndRefusesBlanks() throws {
    let (model, _) = try makeModel()

    model.createProject(named: "  EM — Hiring  ")
    model.createProject(named: "   ")
    model.createProject(named: "")

    #expect(model.projects.map(\.name) == ["EM — Hiring"])
}

@MainActor
@Test("projects get increasing sortOrder and distinguishable colours")
func createProjectAssignsOrderAndColour() throws {
    let (model, _) = try makeModel()

    model.createProject(named: "First")
    model.createProject(named: "Second")

    #expect(model.projects.map(\.sortOrder) == [0, 1])
    #expect(model.projects[0].colorHex == ProjectPalette.hex(forIndex: 0))
    #expect(model.projects[1].colorHex == ProjectPalette.hex(forIndex: 1))
}

@MainActor
@Test("archiving hides a project from the sidebar but does not delete the row")
func archiveHidesButKeeps() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)

    model.archive(projectID: id)

    #expect(model.projects.isEmpty)
    let stored = try context.fetch(FetchDescriptor<Project>())
    #expect(stored.count == 1)
    #expect(stored.first?.isArchived == true)
}

@MainActor
@Test("archiving the selected project falls back to All")
func archivingSelectedFallsBackToAll() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    let id = try #require(model.projects.first?.id)
    model.selection = .project(id)

    model.archive(projectID: id)

    #expect(model.selection == .all)
}

@MainActor
@Test("the menu actions move the selection through the sidebar")
func actionsCycleSelection() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)

    model.selectNextProject()
    #expect(model.selection == .project(ids[0]))

    model.selectPreviousProject()
    #expect(model.selection == .all)
}

@MainActor
@Test("newProject raises the sheet rather than creating anything itself")
func newProjectOnlyPresents() throws {
    let (model, _) = try makeModel()

    model.newProject()

    #expect(model.isPresentingNewProject)
    #expect(model.projects.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test
```

Expected: FAIL — `cannot find 'MainWindowModel' in scope`.

- [ ] **Step 3: Write the actions protocol**

Create `StenoKit/Features/MainWindow/MainWindowActions.swift`:

```swift
/// The main-window actions the menu bar can invoke.
///
/// `MainWindowCommands` in the app target depends on this rather than on
/// `MainWindowModel`, so adding a shortcut in M1-05 or M1-06 is one method
/// here plus one `Button` there — and forgetting the implementation is a
/// compile error rather than a menu item that silently does nothing.
///
/// `AnyObject` because `@FocusedValue` carries a reference to the live model.
@MainActor
public protocol MainWindowActions: AnyObject {
    func newTask()
    func newProject()
    func selectNextProject()
    func selectPreviousProject()
}
```

- [ ] **Step 4: Write the model**

Create `StenoKit/Features/MainWindow/MainWindowModel.swift`:

```swift
import Foundation
import SwiftData

/// The main window's single source of truth.
///
/// **Views get no store access at all** — no `@Query`, no
/// `@Environment(\.modelContext)`. ARCHITECTURE §2 rule 2 requires view models
/// to mediate, §14 lists that separation as retained and not to be stripped,
/// and the justification is testability (§9.4): everything this type does is
/// exercised by the headless, network-denied test bundle, which a `@Query` in
/// a view never could be.
///
/// **Known limit.** A manual fetch does not refresh when another surface
/// writes. Every mutation that goes through this model reloads itself, so the
/// window is correct for everything M0-05 can do — but M1-03's floating window
/// and M1-04's popover will insert tasks this model does not notice. Closing
/// that belongs to whichever of them lands first; a `reload()` on window
/// activation is the likely minimum.
@Observable
@MainActor
public final class MainWindowModel: MainWindowActions {
    public private(set) var projects: [Project] = []
    public private(set) var groups: [TaskGroup] = []
    public private(set) var lastError: String?

    public var selection: ProjectSelection = .all {
        didSet { if selection != oldValue { reload() } }
    }

    public var selectedTaskID: UUID?
    public var isPresentingNewProject = false
    public var isPresentingNewTask = false

    /// FR-1.4: a task needs a project to belong to, and this window offers no
    /// way to create one implicitly.
    public var canCreateTask: Bool { !projects.isEmpty }

    private let context: ModelContext
    private let now: () -> Date

    /// `now` is injected so the DONE window is testable without waiting.
    public init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
        reload()
    }

    // MARK: - Reading

    public func reload() {
        projects = fetchProjects()
    }

    public func project(withID id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    private func fetchProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Writing

    public func createProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let order = (projects.map(\.sortOrder).max() ?? -1) + 1
        let stamp = now()
        perform("create the project") {
            self.context.insert(
                Project(
                    name: trimmed,
                    colorHex: ProjectPalette.hex(forIndex: order),
                    sortOrder: order,
                    modifiedAt: stamp
                )
            )
        }
    }

    /// §3.1: archived projects are hidden, never deleted. There is no delete.
    public func archive(projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }

        let stamp = now()
        let saved = perform("archive the project") { project.setArchived(true, at: stamp) }

        // Only after the save is known to have succeeded. `rollback()` can undo
        // the `isArchived` mutation, but it cannot undo a selection change — so
        // moving the selection first would leave a failed archive showing "All"
        // while the project is still in the sidebar.
        if saved, selection == .project(projectID) { selection = .all }
    }

    // MARK: - MainWindowActions

    public func newTask() {
        guard canCreateTask else { return }
        isPresentingNewTask = true
    }

    public func newProject() {
        isPresentingNewProject = true
    }

    public func selectNextProject() {
        selection = .next(after: selection, in: projects.map(\.id))
    }

    public func selectPreviousProject() {
        selection = .previous(before: selection, in: projects.map(\.id))
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Saving

    /// Apply a mutation, save it, and reload — rolling back if the save fails.
    ///
    /// **The rollback is load-bearing.** Without it a failed save leaves the
    /// object sitting in the context, the reload finds it, and the window
    /// displays a task that is not on disk. For a capture tool, silently
    /// accepting a write that evaporates is worse than refusing it, because
    /// the loss surfaces at the next stand-up (D-018, §1.1).
    ///
    /// `what` is an infinitive phrase — it is interpolated into both the log
    /// line and the user-facing message.
    ///
    /// Returns whether the save succeeded, so callers can make follow-up state
    /// changes conditional on it — `rollback()` restores the store, not the UI.
    @discardableResult
    private func perform(_ what: String, _ mutation: () -> Void) -> Bool {
        mutation()
        var saved = true
        do {
            try context.save()
            lastError = nil
        } catch {
            context.rollback()
            // One interpolated literal: OSLogMessage has no `+` operator.
            Log.app.error(
                "could not \(what, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not \(what). Your change was not saved."
            saved = false
        }
        reload()
        return saved
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
make test
```

Expected: PASS. All eight tests in `MainWindowModelProjectsTests` green.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add StenoKit/Features/MainWindow StenoTests/Features/MainWindow
git commit -m "feat: main window view model — projects, archiving, save-or-rollback

Establishes the pattern every later UI task copies: the view model owns
the ModelContext and views get none. ARCHITECTURE §2 rule 2 already
required this; the payoff is that project creation, archiving and the
save path are covered by the headless bundle rather than by clicking.

The rollback in perform() is load-bearing. Without it a failed save
leaves the object in the context, the reload finds it, and the window
asserts something persisted that did not — the failure mode D-018
rejected for the store.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `MainWindowModel` — tasks, groups, and the `created` event

**Files:**
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Test: `StenoTests/Features/MainWindow/MainWindowModelTasksTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.
- Produces:
  - `public private(set) var groups: [TaskGroup]` (declared in Task 2, populated here)
  - `public func createTask(titled: String)`
  - `public func task(withID: UUID) -> TaskItem?`
  - `public func events(forTaskID: UUID) -> [Event]`

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Features/MainWindow/MainWindowModelTasksTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeModel() throws -> (MainWindowModel, ModelContext) {
    let container = try StenoStore.inMemory()
    // `ModelContext(container)` retains its container. `container.mainContext`
    // does NOT — so returning the main context from a helper leaves it
    // dangling the moment the container goes out of scope, and the next
    // insert/save traps inside SwiftData with EXC_BREAKPOINT. Every other
    // test in this repo already uses this form; match it.
    let context = ModelContext(container)
    return (MainWindowModel(context: context, now: { origin }), context)
}

@MainActor
@Test("a new task lands in the TODO group")
func createdTaskIsTodo() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")

    model.createTask(titled: "Fix the retry handler")

    #expect(model.groups.map(\.status) == [.todo])
    #expect(model.groups[0].tasks.map(\.title) == ["Fix the retry handler"])
}

@MainActor
@Test("creating a task appends exactly one created event (§3.3)")
func createTaskAppendsCreatedEvent() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")
    model.createTask(titled: "Fix the retry handler")

    let taskID = try #require(model.groups.first?.tasks.first?.id)
    let events = model.events(forTaskID: taskID)

    #expect(events.count == 1)
    #expect(events.first?.kind == .created)
    #expect(events.first?.taskID == taskID)
}

@MainActor
@Test("with no projects, creating a task is a no-op and stores nothing")
func createTaskWithoutProjectsIsNoOp() throws {
    let (model, context) = try makeModel()

    model.createTask(titled: "orphan")

    #expect(model.groups.isEmpty)
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
}

@MainActor
@Test("blank titles are refused")
func blankTitleRefused() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "Payments")

    model.createTask(titled: "   ")

    #expect(model.groups.isEmpty)
}

@MainActor
@Test("the All pseudo-project shows tasks across every project")
func allSpansProjects() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)

    model.selection = .project(ids[0])
    model.createTask(titled: "one")
    model.selection = .project(ids[1])
    model.createTask(titled: "two")

    model.selection = .all

    #expect(model.groups[0].tasks.count == 2)
}

@MainActor
@Test("selecting a project scopes the list to that project")
func selectionScopesTheList() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)
    model.selection = .project(ids[0])
    model.createTask(titled: "one")

    model.selection = .project(ids[1])

    #expect(model.groups.isEmpty)
}

@MainActor
@Test("under All, a new task goes to the first project by sortOrder")
func allTargetsFirstProject() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let first = try #require(model.projects.first?.id)
    model.selection = .all

    model.createTask(titled: "where does this go")

    #expect(model.groups[0].tasks.first?.projectID == first)
}

@MainActor
@Test("archiving a project also hides its tasks from All")
func archivedProjectsTasksAreHidden() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    model.createProject(named: "Second")
    let ids = model.projects.map(\.id)
    model.selection = .project(ids[1])
    model.createTask(titled: "hide me")

    model.archive(projectID: ids[1])
    model.selection = .all

    #expect(model.groups.flatMap(\.tasks).isEmpty)
}

@MainActor
@Test("DONE is scoped to the last 24 hours")
func doneWindowIsTwentyFourHours() throws {
    let (model, context) = try makeModel()
    model.createProject(named: "Payments")
    let projectID = try #require(model.projects.first?.id)

    let recent = TaskItem(title: "just finished", projectID: projectID, createdAt: origin)
    recent.setStatus(.done, at: origin.addingTimeInterval(-3600))
    let ancient = TaskItem(title: "ancient", projectID: projectID, createdAt: origin)
    ancient.setStatus(.done, at: origin.addingTimeInterval(-30 * 3600))
    context.insert(recent)
    context.insert(ancient)
    try context.save()

    model.reload()

    let done = try #require(model.groups.first { $0.status == .done })
    #expect(done.tasks.map(\.title) == ["just finished"])
}

@MainActor
@Test("changing selection reloads the list")
func selectionChangeReloads() throws {
    let (model, _) = try makeModel()
    model.createProject(named: "First")
    let id = try #require(model.projects.first?.id)
    model.createTask(titled: "one")

    model.selection = .project(id)

    #expect(model.groups[0].tasks.count == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test
```

Expected: FAIL — `value of type 'MainWindowModel' has no member 'createTask'`.

- [ ] **Step 3: Extend `reload()` to populate groups**

In `StenoKit/Features/MainWindow/MainWindowModel.swift`, replace the `reload()` method written in Task 2 with:

```swift
    public func reload() {
        projects = fetchProjects()
        groups = TaskGrouping.groups(from: fetchTasks(), doneSince: doneCutoff())

        // A task that has scrolled out of the DONE window, or whose project was
        // just archived, must not leave the detail pane showing a stale row.
        if let id = selectedTaskID,
            !groups.contains(where: { group in group.tasks.contains { $0.id == id } }) {
            selectedTaskID = nil
        }
    }
```

- [ ] **Step 4: Add the reads, the cutoff, and task creation**

In the same file, add to the `// MARK: - Reading` section, after `project(withID:)`:

```swift
    public func task(withID id: UUID) -> TaskItem? {
        groups.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    /// The task's timeline, newest first, excluding redacted events (§3.3).
    ///
    /// The exclusion is a property of this query rather than of each caller,
    /// so M1-06's redaction cannot be forgotten by one of them.
    public func events(forTaskID id: UUID) -> [Event] {
        let descriptor = FetchDescriptor<Event>(
            predicate: #Predicate { $0.taskID == id && !$0.isRedacted },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// TODO(M2-01): FR-3 scopes DONE to the current report window, which is
    /// computed from `project.lastStandupAt` (D8) and does not exist until
    /// M2-01. That field stays nil until M2-03 ships the Copy action that
    /// advances it, and FR-4 step 2 makes the first-run window 24 hours — so
    /// for every state reachable today this returns the same answer.
    private func doneCutoff() -> Date {
        now().addingTimeInterval(-24 * 60 * 60)
    }

    /// Tasks for the current selection.
    ///
    /// The project filter is applied in memory rather than in the `#Predicate`
    /// because it is a set-membership test against the visible projects, and
    /// D18 caps the whole dataset under 20 live tasks — the fetch is the cost,
    /// not the filter.
    private func fetchTasks() -> [TaskItem] {
        let visible = Set(projects.map(\.id))
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isArchived })
        let all = (try? context.fetch(descriptor)) ?? []

        switch selection {
        case .all:
            // Archiving a project takes its tasks with it — otherwise
            // archiving would not actually get a finished project out of the
            // way, which is the whole point (§3.1).
            return all.filter { visible.contains($0.projectID) }
        case .project(let id):
            guard visible.contains(id) else { return [] }
            return all.filter { $0.projectID == id }
        }
    }
```

- [ ] **Step 5: Add task creation**

In the same file, add to the `// MARK: - Writing` section, after `createProject(named:)`:

```swift
    public func createTask(titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let projectID = targetProjectID() else { return }

        let stamp = now()
        perform("create the task") {
            let task = TaskItem(title: trimmed, projectID: projectID, createdAt: stamp)
            self.context.insert(task)
            // §3.3's EventKind table: `created` is written when a task is
            // created. A task without one is a hole in the append-only log —
            // M2-01's gathering would skip it and M2.5-02's merge would reason
            // from it. M1-02's capture service takes over this call site.
            self.context.insert(
                Event(taskID: task.id, timestamp: stamp, kind: .created, body: "Task created")
            )
        }
    }

    /// FR-1.4: never block on project selection.
    ///
    /// TODO(M1-02): the specified rule is "default to the last-used project",
    /// which M1-02 owns along with the first-launch behaviour. Until then the
    /// first project by `sortOrder` stands in — and the task row shows its
    /// project, so the assignment is visible rather than silent.
    private func targetProjectID() -> UUID? {
        switch selection {
        case .project(let id): id
        case .all: projects.first?.id
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
make test
```

Expected: PASS — all ten tests in `MainWindowModelTasksTests`, and Tasks 1–2 still green.

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add StenoKit/Features/MainWindow StenoTests/Features/MainWindow
git commit -m "feat: task list, status grouping, and the created event

Creating a task appends a created event in the same save. §3.3's
EventKind table requires it: a task without one is a hole in the
append-only log that M2-01's gathering would skip and M2.5-02's merge
would reason from — a bug that surfaces months later as an
inexplicable revert.

Two placeholders carry TODO markers naming the task that replaces
them: the DONE window is a fixed 24h until M2-01 (identical in
behaviour until M2-03 advances lastStandupAt), and a task created
under All goes to the first project until M1-02 implements
last-used-project resolution.

Archiving a project hides its tasks too — otherwise archiving does not
actually get a finished project out of the way.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The three-column window

Views only. Nothing here is unit-testable — that is why Tasks 1–3 carry the behaviour.

**Files:**
- Create: `Steno/Features/MainWindow/MainWindowView.swift`
- Create: `Steno/Features/MainWindow/SidebarView.swift`
- Create: `Steno/Features/MainWindow/TaskListView.swift`
- Create: `Steno/Features/MainWindow/TaskDetailView.swift`
- Create: `Steno/Features/MainWindow/TextEntrySheet.swift`
- Create: `Steno/Features/MainWindow/ProjectColor.swift`
- Modify: `Steno/App/StenoApp.swift`
- Delete: `Steno/App/ContentView.swift`

**Interfaces:**
- Consumes: `MainWindowModel`, `ProjectSelection`, `TaskGroup`, `Status.displayName`, `ProjectPalette` — all `public` in `StenoKit`, so every view file needs `import StenoKit`.
- Produces: `MainWindowView(container: ModelContainer)`, used by `StenoApp` and extended with `.commands` in Task 5.

- [ ] **Step 1: Add the colour helper and the shared sheet**

Create `Steno/Features/MainWindow/ProjectColor.swift`:

```swift
import SwiftUI

extension Color {
    /// Renders a `Project.colorHex` value. Falls back to black on malformed
    /// input rather than trapping — a bad colour is a cosmetic problem, and
    /// crashing the window over one would not be.
    init(projectHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(digits, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
```

Create `Steno/Features/MainWindow/TextEntrySheet.swift`:

```swift
import SwiftUI

/// One focused field, Return commits, Esc cancels.
///
/// Shared by the new-project and new-task sheets so both obey the same
/// contract FR-1.1 sets for the capture window — established here, before
/// there are three surfaces to keep consistent (D15).
struct TextEntrySheet: View {
    let title: String
    let placeholder: String
    let confirm: String
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}
```

- [ ] **Step 2: Build to check the new files compile**

```bash
make build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Write the sidebar**

Create `Steno/Features/MainWindow/SidebarView.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-3's first column: a flat project list with an "All" pseudo-project.
///
/// Flat by decision, not omission — D9 rules out epics and nesting, so there
/// is no hierarchy to model here.
struct SidebarView: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        List(selection: selectionBinding) {
            Label("All", systemImage: "tray.full")
                .tag(ProjectSelection.all)

            Section("Projects") {
                ForEach(model.projects) { project in
                    Label {
                        Text(project.name)
                    } icon: {
                        Circle()
                            .fill(Color(projectHex: project.colorHex))
                            .frame(width: 10, height: 10)
                    }
                    .tag(ProjectSelection.project(project.id))
                    .contextMenu {
                        // Archive, not delete: §3.1 hides projects, never
                        // removes them, and there is deliberately no delete.
                        Button("Archive Project") { model.archive(projectID: project.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.newProject()
            } label: {
                Label("New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    /// `List` wants an optional selection; the model's is total, with `.all`
    /// as the resting state.
    private var selectionBinding: Binding<ProjectSelection?> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 ?? .all }
        )
    }
}
```

- [ ] **Step 4: Write the task list**

Create `Steno/Features/MainWindow/TaskListView.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-3's second column: tasks grouped by status.
///
/// A plain `List`. FR-3 and D18 are explicit — no pagination, no
/// virtualization, no search, no filter chips. "If the task list ever needs a
/// scrollbar the user has a workflow problem, not a UI problem."
struct TaskListView: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        Group {
            if model.projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "folder.badge.plus",
                    description: Text("Create a project (⌘⇧N) to start capturing tasks.")
                )
            } else if model.groups.isEmpty {
                ContentUnavailableView(
                    "No tasks",
                    systemImage: "checklist",
                    description: Text("Press ⌘N to add one.")
                )
            } else {
                List(selection: $model.selectedTaskID) {
                    ForEach(model.groups) { group in
                        if group.status == .done {
                            // FR-3: DONE is collapsed by default.
                            DisclosureGroup(group.status.displayName) { rows(group) }
                        } else {
                            Section(group.status.displayName) { rows(group) }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        .toolbar {
            Button {
                model.newTask()
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .disabled(!model.canCreateTask)
        }
    }

    @ViewBuilder
    private func rows(_ group: TaskGroup) -> some View {
        ForEach(group.tasks) { task in
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                // Under "All" the project is not implied by the sidebar, so
                // show it — this is also what makes M0-05's stand-in project
                // routing visible rather than silent (see targetProjectID).
                if case .all = model.selection, let project = model.project(withID: task.projectID) {
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(task.id)
        }
    }
}
```

- [ ] **Step 5: Write the detail pane**

Create `Steno/Features/MainWindow/TaskDetailView.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-3's third column: title, status, and the event timeline.
///
/// **The status is a label, not a control.** Status changes are M1-05; this
/// task displays status and never mutates it.
///
/// The timeline is not empty, though the task file said it would be: §3.3
/// requires a `created` event on every task, so there is always exactly one
/// row here today. M1-06 adds note entry, the correction window, and redaction.
struct TaskDetailView: View {
    let model: MainWindowModel
    let taskID: UUID?

    var body: some View {
        if let taskID, let task = model.task(withID: taskID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(task.title)
                        .font(.title2)

                    Text(task.status.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())

                    Divider()

                    Text("Timeline")
                        .font(.headline)

                    let events = model.events(forTaskID: taskID)
                    if events.isEmpty {
                        Text("No events.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.body)
                                Text(event.timestamp, format: .dateTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            ContentUnavailableView("No task selected", systemImage: "sidebar.right")
        }
    }
}
```

- [ ] **Step 6: Write the window itself**

Create `Steno/Features/MainWindow/MainWindowView.swift`:

```swift
import StenoKit
import SwiftData
import SwiftUI

/// FR-3's three-column main window.
struct MainWindowView: View {
    @State private var model: MainWindowModel

    /// The model is built once here, from the container, rather than in `body`
    /// — which would rebuild it on every render and drop the selection.
    init(container: ModelContainer) {
        _model = State(initialValue: MainWindowModel(context: container.mainContext))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            TaskListView(model: model)
        } detail: {
            TaskDetailView(model: model, taskID: model.selectedTaskID)
        }
        .frame(minWidth: 900, minHeight: 520)
        .safeAreaInset(edge: .top) {
            // An inline row, not an alert: a modal interruption during capture
            // is the behaviour §1.1 treats as a defect.
            if let message = model.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                    Spacer()
                    Button("Dismiss") { model.dismissError() }
                }
                .padding(8)
                .background(.yellow.opacity(0.25))
            }
        }
        .sheet(isPresented: $model.isPresentingNewProject) {
            TextEntrySheet(
                title: "New Project",
                placeholder: "Project name",
                confirm: "Create"
            ) { model.createProject(named: $0) }
        }
        .sheet(isPresented: $model.isPresentingNewTask) {
            TextEntrySheet(
                title: "New Task",
                placeholder: "What are you working on?",
                confirm: "Add"
            ) { model.createTask(titled: $0) }
        }
    }
}
```

- [ ] **Step 7: Wire the app and delete the placeholder**

Delete the placeholder:

```bash
git rm Steno/App/ContentView.swift
```

In `Steno/App/StenoApp.swift`, replace the `body` property with:

```swift
    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                // No `.modelContainer(container)`: no view reaches the store
                // directly, so ARCHITECTURE §2 rule 2 holds by construction
                // rather than by discipline. Do not add it back without a view
                // that genuinely needs `@Query`.
                MainWindowView(container: container)
            case .failure(let error):
                StoreFailureView(path: storePath, error: error)
            }
        }
    }
```

Leave `StenoApp.init`, the logging, the `Result` store property, and the `StoreFailureView` branch exactly as they are.

- [ ] **Step 8: Build and run the gate**

```bash
make build && make test && make lint
```

Expected: all three green. `make test` regenerates the Xcode project unconditionally (D-014), so the new files are picked up without any manifest edit.

- [ ] **Step 9: Commit**

```bash
git add Steno/Features/MainWindow Steno/App/StenoApp.swift
# ContentView.swift's deletion was already staged by `git rm` in Step 7.
git commit -m "feat: FR-3 three-column main window

Sidebar with an All pseudo-project, task list grouped by status, and a
detail pane. A plain List throughout: FR-3 and D18 exclude pagination,
virtualization, search and filter chips permanently.

.modelContainer is dropped from StenoApp. No view uses @Query or
@Environment(\\.modelContext), so removing it makes ARCHITECTURE §2
rule 2 structural — there is no longer a route from a view to the
store to take by accident.

Deletes ContentView.swift, whose own comment scheduled it for removal
here; its sample-project button was the only way to exercise M0-04's
acceptance criterion before this window existed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Keyboard shortcuts as menu commands

**Files:**
- Create: `Steno/App/FocusedValues+MainWindow.swift`
- Create: `Steno/App/MainWindowCommands.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift`
- Modify: `Steno/App/StenoApp.swift`

**Interfaces:**
- Consumes: `MainWindowActions` (Task 2), `MainWindowView` (Task 4).
- Produces: `MainWindowCommands`, and `FocusedValues.mainWindowActions` — the extension point M1-05 and M1-06 add one `Button` to.

- [ ] **Step 1: Add the focused-value key**

Create `Steno/App/FocusedValues+MainWindow.swift`:

```swift
import StenoKit
import SwiftUI

/// Carries the live main-window model out to the menu bar.
///
/// This is the plumbing that makes menu commands act on the front window's
/// selection. M1-05 and M1-06 do not touch this file — they add a method to
/// `MainWindowActions` and a `Button` to `MainWindowCommands`.
struct MainWindowActionsKey: FocusedValueKey {
    typealias Value = any MainWindowActions
}

extension FocusedValues {
    var mainWindowActions: (any MainWindowActions)? {
        get { self[MainWindowActionsKey.self] }
        set { self[MainWindowActionsKey.self] = newValue }
    }
}
```

- [ ] **Step 2: Add the commands**

Create `Steno/App/MainWindowCommands.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-3's keyboard-first requirement, as real menu-bar items.
///
/// Menu items rather than `.keyboardShortcut` on in-view buttons: on macOS a
/// shortcut that exists is expected to be listed in a menu, shortcuts bound
/// only to buttons are enumerated nowhere, and each later surface would
/// otherwise re-declare its own — the divergence the task file warns about.
///
/// **Extending this is the whole point.** M1-05 adds "Cycle Status" and M1-06
/// adds "Add Note": one method on `MainWindowActions`, one `Button` here.
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

        // FR-3 lists "switch project" among the actions needing a shortcut,
        // and this milestone builds the switcher.
        CommandGroup(after: .sidebar) {
            Button("Next Project") { actions?.selectNextProject() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions == nil)

            Button("Previous Project") { actions?.selectPreviousProject() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
        }
    }
}
```

- [ ] **Step 3: Publish the model from the window**

In `Steno/Features/MainWindow/MainWindowView.swift`, add one modifier to `body`, immediately after `.frame(minWidth: 900, minHeight: 520)`:

```swift
        .focusedSceneValue(\.mainWindowActions, model)
```

- [ ] **Step 4: Attach the commands to the scene**

In `Steno/App/StenoApp.swift`, add `.commands` to the `WindowGroup` — after the closing brace of its content closure, still inside `body`:

```swift
            .commands { MainWindowCommands() }
```

- [ ] **Step 5: Run the gate**

```bash
make build && make test && make lint
```

Expected: all three green.

- [ ] **Step 6: Commit**

```bash
git add Steno/App Steno/Features/MainWindow/MainWindowView.swift
git commit -m "feat: keyboard shortcuts as menu-bar commands

Establishes the mechanism M1-05 and M1-06 extend rather than replace:
the window publishes its model via .focusedSceneValue, and a Commands
struct reaches it with @FocusedValue. Adding a shortcut later is one
method on MainWindowActions plus one Button here, and forgetting the
implementation is a compile error rather than a dead menu item.

Ships ⌘N, ⌘⇧N, and ⌘⌥↑/↓. The last pair is switch-project, which FR-3
names among the actions requiring a shortcut and which this milestone
builds — leaving it unbound would half-meet FR-3 in the window that
owns the switcher.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Verify below the pixels, update the docs, open the PR

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/DECISIONS.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a PR that states honestly what was and was not verified.

- [ ] **Step 1: Build the release-path binary the harness links against**

```bash
make build
```

- [ ] **Step 2: Write the durability harness**

This proves acceptance criterion 1 — "a project created in the sidebar persists across relaunch" — as far as it can be proven without a window server: through the shipping code, against the real store, across two separate processes.

Create `/tmp/steno-harness/harness.swift` (outside the repo — this is throwaway):

```swift
import Foundation
import StenoKit
import SwiftData

@main
enum Harness {
    @MainActor
    static func main() throws {
        let container = try StenoStore.live()
        let model = MainWindowModel(context: container.mainContext)

        if CommandLine.arguments.contains("--write") {
            model.createProject(named: "Harness \(Int(Date.now.timeIntervalSince1970))")
            model.createTask(titled: "Created by the M0-05 harness")
            print("wrote — projects now: \(model.projects.count)")
        } else {
            print("read  — projects: \(model.projects.count), groups: \(model.groups.count)")
            for project in model.projects { print("  · \(project.name)  \(project.colorHex)") }
            for group in model.groups {
                print("  [\(group.status.displayName)] \(group.tasks.map(\.title))")
            }
        }
    }
}
```

- [ ] **Step 3: Compile and run it as two separate processes**

```bash
cd /tmp/steno-harness
PRODUCTS="$(cd /Users/lgutierrez/Projects/leo/steno/.build/Build/Products/Debug && pwd)"
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos14.0 \
  -F "$PRODUCTS" -framework StenoKit \
  -Xlinker -rpath -Xlinker "$PRODUCTS" \
  -o harness harness.swift

./harness --write     # process 1: create
./harness             # process 2: read back
```

Expected: process 2 prints the project and the task that process 1 created, including the `[TODO]` group. That is cross-process durability at the real store path, through `MainWindowModel` rather than around it.

**Record the actual output** — it goes in the PR body.

- [ ] **Step 4: Confirm the app itself opens the store**

```bash
make run     # leave it running
```

In another terminal:

```bash
/usr/bin/log show --predicate 'subsystem == "com.lgabrielgr.steno"' --last 5m --info
```

Expected: `Steno launched` and `store opened at …`. **`--info` is required** — `Logger.info` lines are omitted without it, and the log looks empty. Use `/usr/bin/log`, not `log`, which may hit a shell alias.

- [ ] **Step 5: Update ARCHITECTURE.md**

In §5's layout block, change the two `Features/` lines to record what now exists:

```
  Features/       view models, by feature — MainWindow (M0-05)
```

and

```
  Features/       views, by feature — MainWindow (M0-05)
```

- [ ] **Step 6: Add the two decisions**

Append to `docs/DECISIONS.md`, after D-018:

```markdown
### D-019 — View models own the `ModelContext`; views get no store access
**2026-08-23** · M0-05 · **Status:** accepted

An `@Observable @MainActor` view model in `StenoKit/Features/` holds the context, fetches, and
publishes ready-to-render arrays. Views declare no `@Query` and no
`@Environment(\.modelContext)`, and `.modelContainer(_:)` is **not** attached to the scene.

**Why:** ARCHITECTURE §2 rule 2 and §14 already require the separation on testability grounds
(§9.4); this is where it becomes structural rather than advisory. Dropping the environment
container means there is no route from a view to the store to take by accident. Every behaviour
in the main window — grouping, the DONE window, project scoping, the `created` event, archive
filtering — is therefore covered by the headless bundle, which matters more than usual here
because GUI automation is unavailable on this machine.
**Alternatives:** `@Query` in views with view models for derived logic only — idiomatic SwiftUI
and self-refreshing, but it puts the fetch in the view, which is the thing rule 2 forbids.
**The cost, and who pays it:** a manual fetch does not refresh when another surface writes.
Mutations through the model reload themselves, so M0-05 is correct; M1-03's floating window and
M1-04's popover must add a refresh (window activation is the likely minimum) or the main window
will silently miss tasks captured elsewhere.

### D-020 — Keyboard shortcuts are menu-bar commands reached via `@FocusedValue`
**2026-08-23** · M0-05 · **Status:** accepted

`MainWindowView` publishes its model with `.focusedSceneValue(\.mainWindowActions, model)`; a
`Commands` struct reads it with `@FocusedValue` and declares real menu items. Actions are declared
on the `MainWindowActions` protocol.

**Why:** FR-3 requires a shortcut for every primary action, and M1-05/M1-06 are instructed to
extend one mechanism rather than invent a second. Adding a shortcut is now one protocol method and
one `Button`, and omitting the implementation is a compile error rather than a menu item that
silently does nothing. On macOS a shortcut that exists is expected to appear in a menu, which
in-view `.keyboardShortcut` bindings never do.
**Alternatives:** `.keyboardShortcut` on toolbar/context-menu buttons (undiscoverable, enumerated
nowhere, re-declared per surface); a pure key-router in `StenoKit` with a unit-tested chord table
(most testable, and collisions become test failures — but it still needs separate menu
declarations for discoverability, so both would have to be maintained).
**Not settled here:** bare-letter shortcuts such as FR-2's suggested `N` for notes. A no-modifier
menu shortcut risks swallowing keystrokes meant for a text field; M1-06 should decide it against
real UI.
```

- [ ] **Step 7: Run the full gate one final time**

```bash
make build && make test && make lint
```

Expected: all three green. Confirm `git status` shows **no** `Steno.xcodeproj` and **no** `Local.xcconfig`.

- [ ] **Step 8: Commit the docs**

```bash
git add docs/ARCHITECTURE.md docs/DECISIONS.md
git commit -m "docs: record the view-model and command patterns as D-019/D-020

Both are choices later UI tasks would otherwise relitigate, and D-019
carries an obligation M1-03/M1-04 inherit: the manual-fetch model does
not refresh when another capture surface writes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 9: Push and open the PR**

```bash
git push -u origin feat/main-window-shell
```

The PR body must contain, per §9.5 and the spec:

1. **The two spec disagreements**, both from spec §8 and the note at the top of this plan:
   - the task file's "empty event timeline" contradicts §3.3, which mandates a `created` event on every task — the timeline renders the real log instead;
   - the spec did not say how a task title is entered for ⌘N; this PR uses the same sheet contract §3.3 defines for projects.
2. **⌘⌥↑/↓ for switch-project**, which FR-3 requires and which is scope beyond the task file's explicit list.
3. **The verification split, stated plainly:**
   - *Verified:* `make build`, `make test`, `make lint` all green; the harness output from Step 3 showing cross-process durability at the real store path.
   - *Not verified, and not verifiable on this machine:* that the sidebar button is wired, that ⌘N / ⌘⇧N / ⌘⌥↑↓ are actually bound, that Return/Esc behave in the sheet, and that the three columns render as intended. `osascript` returns `-1719` (no Accessibility permission) and `screencapture` cannot read the display (no Screen Recording permission). **Do not imply a click-through happened.**
4. **The M1-03/M1-04 obligation** from D-019.

- [ ] **Step 10: Stop**

Do not merge. The user reviews and merges (§9.5). `main` is protected, so a direct push would fail anyway.

---

## Notes for the executor

- **`make test` regenerates the Xcode project every run** (D-014). That is by design, and it means new source files need no manifest edit — but it can disturb an open Xcode session.
- **If a `#expect` fails to compile** where the equivalent plain expression works, prefer an explicit closure over a key path — `allSatisfy { $0.flag }` rather than `allSatisfy(\.flag)`. Key paths passed to `rethrows` methods lose their non-throwing proof inside the macro expansion. The `map(\.status)` forms in this plan were verified in expanded form and are fine.
- **`Logger` interpolations cannot be concatenated** with `+` — `OSLogMessage` has no such operator. One interpolated literal per line.
- **If a step's code does not compile as written**, fix it minimally and say so explicitly in the PR body rather than quietly reshaping the surrounding design.
