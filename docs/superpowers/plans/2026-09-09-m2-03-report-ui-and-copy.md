# M2-03 — Report UI & Copy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Prepare Stand-up" → editable draft → Copy, with all four of Copy's side effects applied atomically and none of them applied on generate. This is M2's exit criterion: the user can run a real DSU from the app.

**Architecture:** One new `StandupService` in StenoKit owns every write in FR-4's flow — report, events, clock — through a single `ModelContext` and a single `save`, so all-or-none is a transaction boundary rather than defensive ordering. `ReportGatherer` (M2-01) keeps owning the read side and has no `save` at all, which is what makes "generate has zero side effects" true by construction. A `StandupDraftModel` holds the editable draft and a two-phase state machine; a sheet in the app target renders it. The clipboard sits behind an injected `(String) -> Bool` so the headless bundle never touches the real pasteboard.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, AppKit (`NSPasteboard`, one file only). macOS 14.0 floor. Built with `make build && make test && make lint`.

**Spec:** [`docs/superpowers/specs/2026-09-09-m2-03-report-ui-and-copy-design.md`](../specs/2026-09-09-m2-03-report-ui-and-copy-design.md)

## Global Constraints

- **Never commit to `main`.** Branch `feat/report-ui-and-copy`, one PR, do not merge (CLAUDE.md §9.5).
- **The event log is append-only.** Never mutate or delete an `Event`; the only permitted write to an existing event is flipping `isRedacted` (§3.3, §13).
- **`make build && make test && make lint` must all pass before the PR.** Verify, do not assert (§9.5 step 4, §13).
- **CI fails when `make format` would change anything** (D-075). Run `make format` before committing; a dirty tree afterwards is your change — commit it.
- **Views get no store access** — no `@Query`, no `@Environment(\.modelContext)`. View models mediate (ARCH §2 rule 2, D-019).
- **SwiftLint runs `--strict`.** Identifiers under 3 characters fail; a literal `TODO` fails.
- **SwiftData:** an `EventKind` inside a `#Predicate` does not compile in either spelling — filter kinds in memory. In tests use `ModelContext(container)`, never `container.mainContext` (it does not retain its container and dangles). Any refetch meant to prove something about the *store* needs a **second** `ModelContext`.
- **Test bundle is headless with networking denied.** Nothing may reach the real pasteboard or the network.
- Every new decision is recorded in `docs/DECISIONS.md` and cited in the PR body.

---

## Task 1: The clipboard seam and the report-id payload

Two leaf types with no dependencies, needed by Task 2. Folded together because neither carries its own review gate.

**Files:**
- Create: `StenoKit/Support/SystemClipboard.swift`
- Create: `StenoKit/Report/StandupReportedPayload.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SystemClipboard.write(_ text: String) -> Bool`; `StandupReportedPayload(reportID: UUID)` with `encoded() -> Data?` and `static decoded(from: Data?) -> StandupReportedPayload?`. Both used by `StandupService` in Task 2.

- [ ] **Step 1: Create the clipboard wrapper**

```swift
import AppKit

/// D6's clipboard, and the only place in StenoKit that imports AppKit.
///
/// **Wrapped rather than called inline so `StandupService` can be tested.**
/// §9.4 runs the suite headless; a test that reached `NSPasteboard.general`
/// would mutate the developer's own clipboard and would be order-dependent on
/// anything else in the process that copies. The service takes a
/// `copy: (String) -> Bool` defaulting to `write`, so the real pasteboard is
/// reachable only from the app.
public enum SystemClipboard {
    /// Replace the clipboard's contents with `text`.
    ///
    /// Returns whether the write landed. `NSPasteboard.setString` returns
    /// `false` when another process holds the pasteboard, and
    /// `StandupService` reports that case rather than swallowing it — by the
    /// time it happens the report is already committed, so a silent failure
    /// would leave the user with an advanced clock and an empty clipboard and
    /// no idea why.
    ///
    /// `clearContents()` first: it is what declares the new owner and bumps the
    /// change count. Without it `setString` writes into a declaration that was
    /// never made and returns `false`.
    @discardableResult
    public static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Create the payload type**

```swift
import Foundation

/// The link from a `standupReported` event back to the report that appended it
/// (§3.3's `payload`, "JSON blob for structured external data").
///
/// **This exists for M2-04.** FR-4.1 must redact the `standupReported` events
/// appended by *one particular* report, and nothing else on the row identifies
/// which. `taskID` says where the event landed and `kind` says what it is;
/// neither says which Copy produced it, and a project reported on twice in a
/// day has two sets of them.
///
/// The rejected alternative was matching on `timestamp == report.generatedAt`.
/// It works today — `StandupService` stamps both from one `now()` — but it
/// couples undo to a coincidence rather than to a statement, and a later change
/// that stamped events independently would break undo silently, with nothing in
/// either file recording why the two values had to agree.
struct StandupReportedPayload: Codable, Equatable {
    let reportID: UUID

    /// `nil` rather than `throws`: a failure here must not abort a Copy whose
    /// four real effects are all fine. The cost of a missing payload is that
    /// M2-04 cannot undo *this* report, which is worse than a lost stand-up but
    /// far better than refusing to produce one. `JSONEncoder` on a single
    /// `UUID` has no reachable failure, so this is a total function in practice.
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decode a payload written by `encoded()`. `nil` for a row that carries
    /// none — every `standupReported` event written before this type existed,
    /// and every event of every other kind.
    static func decoded(from data: Data?) -> Self? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
```

- [ ] **Step 3: Verify both compile**

Run: `make build`
Expected: `Build Succeeded`. If SourceKit reports "cannot find type in scope" afterwards, that is the stale index after `make generate` rewrote the project — the compiler's result is what counts.

- [ ] **Step 4: Commit**

```bash
git add StenoKit/Support/SystemClipboard.swift StenoKit/Report/StandupReportedPayload.swift
git commit -m "feat: clipboard seam and the standupReported payload (M2-03)"
```

---

## Task 2: `StandupService` — the four effects, or none of them

The heart of the task. Everything FR-4 step 7 writes lives here.

**Files:**
- Create: `StenoKit/Report/StandupService.swift`
- Modify: `StenoTests/Report/ReportFixture.swift` (add three helpers)
- Test: `StenoTests/Report/StandupServiceTests.swift`

**Interfaces:**
- Consumes: `SystemClipboard.write`, `StandupReportedPayload` (Task 1); `GatheredWindow`, `ReportGatherer` (M2-01); `StandupReport`, `Event`, `Project` (M0-03).
- Produces: `StandupService(context:now:save:copy:)` with `commit(_ body: String, of window: GatheredWindow, for project: Project) throws -> StandupCommit`; `StandupCommit { report: StandupReport, didReachClipboard: Bool }`; `StandupError.windowBelongsToAnotherProject`. Used by `StandupDraftModel` in Task 3.

- [ ] **Step 1: Add the fixture helpers the tests need**

Append inside the existing `ReportFixture` struct in `StenoTests/Report/ReportFixture.swift`, after `reloadThroughASecondContext`:

```swift
    /// The service under test, with its clock pinned to `origin + offset`.
    ///
    /// `copy` defaults to a closure that accepts and discards rather than to
    /// `SystemClipboard.write`: §9.4's headless bundle has no business mutating
    /// the developer's clipboard, and a test that did would be order-dependent
    /// on anything else in the process that copies.
    func standupService(
        nowOffset: TimeInterval,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        copy: @escaping (String) -> Bool = { _ in true }
    ) -> StandupService {
        StandupService(
            context: context,
            now: { Self.origin.addingTimeInterval(nowOffset) },
            save: save,
            copy: copy)
    }

    /// Every persisted report, read through a context that has never seen them.
    ///
    /// The independent context is the whole point: a fetch on `context` returns
    /// the objects it already holds, so it would report a rolled-back insert as
    /// present and the all-or-none assertions would pass against a broken
    /// transaction.
    func reportsInStore() throws -> [StandupReport] {
        try ModelContext(container).fetch(FetchDescriptor<StandupReport>())
    }

    /// Every persisted event of `kind`, read through an independent context.
    ///
    /// The kind is filtered in memory: an `EventKind` inside a `#Predicate`
    /// does not compile in either spelling, which `EventQueries` and
    /// `ReportGatherer` both already record.
    func eventsInStore(kind: EventKind) throws -> [Event] {
        try ModelContext(container).fetch(FetchDescriptor<Event>())
            .filter { $0.kind == kind }
    }
```

- [ ] **Step 2: Write the failing tests**

Create `StenoTests/Report/StandupServiceTests.swift`. Note `editedDraft` — a string the renderer would never produce, so the "edited text wins" assertion cannot pass against an implementation that re-renders.

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 step 7: Copy's four effects, all of them or none of them.

/// A string the renderer would never produce, so an assertion that
/// `markdownBody` equals it cannot pass against an implementation that
/// re-renders the window instead of storing the user's text.
private let editedDraft = "the user rewrote every word of this by hand"

@MainActor
private func windowWithOneTask(_ fixture: ReportFixture) throws -> GatheredWindow {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    return try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
}

@MainActor
@Test("Copy persists the report carrying the edited text, not the generated text")
func copyPersistsTheEditedText() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    let reports = try fixture.reportsInStore()
    #expect(reports.count == 1)
    #expect(reports.first?.markdownBody == editedDraft)
    #expect(reports.first?.wasAIGenerated == false)
    #expect(reports.first?.isUndone == false)
    #expect(reports.first?.projectID == fixture.alpha.id)
}

@MainActor
@Test("Copy appends one standupReported event per task in the window")
func copyAppendsAnEventPerTask() throws {
    let fixture = try ReportFixture()
    let first = try fixture.task("one", in: fixture.alpha, status: .inProgress)
    let second = try fixture.task("two", in: fixture.alpha, status: .blocked)
    try fixture.event("a note", on: first, at: 60)
    try fixture.event("another", on: second, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
    #expect(window.tasks.count == 2, "precondition: both tasks are in the window")

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    let reported = try fixture.eventsInStore(kind: .standupReported)
    #expect(Set(reported.map(\.taskID)) == Set([first.id, second.id]))
    #expect(reported.allSatisfy { $0.body == "Reported to standup" })
}

@MainActor
@Test("the clock advances to the window's end, not to the moment of the Copy")
func copyAdvancesTheClockToTheWindowEnd() throws {
    let fixture = try ReportFixture()
    // Gathered at origin+300; copied ten minutes later, at origin+900.
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // D-076. `lastStandupAt` must be the generate instant, so anything captured
    // between generating and copying falls into the next window rather than
    // into a gap no report will ever cover.
    let stored = try fixture.reloadThroughASecondContext(fixture.alpha)
    #expect(stored?.lastStandupAt == ReportFixture.origin.addingTimeInterval(300))
    #expect(stored?.lastStandupAt == window.end)
}

@MainActor
@Test("the report's window bounds match the window that was copied")
func reportRecordsTheWindowItCopied() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // M2-04 recovers the previous `lastStandupAt` from `windowStart`, so these
    // two are the undo mechanism, not decoration.
    let report = try #require(try fixture.reportsInStore().first)
    #expect(report.windowStart == window.start)
    #expect(report.windowEnd == window.end)
    #expect(report.generatedAt == ReportFixture.origin.addingTimeInterval(900))
}

@MainActor
@Test("a failed save leaves the store exactly as it was")
func failedSaveWritesNothing() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    let counter = WriteCounter()

    #expect(throws: Boom.self) {
        _ = try fixture.standupService(nowOffset: 900, save: { _ in throw Boom() })
            .commit(editedDraft, of: window, for: fixture.alpha)
    }

    // Read through independent contexts: the context that attempted the write
    // still holds the inserted objects, so asserting against it would pass even
    // if the rollback had done nothing.
    #expect(try fixture.reportsInStore().isEmpty)
    #expect(try fixture.eventsInStore(kind: .standupReported).isEmpty)
    #expect(
        try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt
            == ReportFixture.origin)
    #expect(counter.posts == 0, "a write that did not happen must not be announced")
}

@MainActor
@Test("a failed Copy does not ride along on the next successful save")
func failedCopyDoesNotLeakIntoALaterSave() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    #expect(throws: Boom.self) {
        _ = try fixture.standupService(nowOffset: 900, save: { _ in throw Boom() })
            .commit(editedDraft, of: window, for: fixture.alpha)
    }

    // This is what `context.rollback()` is actually for, and the only assertion
    // that can tell whether it ran. With an injected throwing `save` nothing
    // reaches the store either way, so asserting on the store immediately after
    // the failure passes whether or not the abandoned rows were discarded.
    // They are still sitting in the context; the *next* commit is what would
    // flush them to disk.
    try fixture.context.save()

    #expect(try fixture.reportsInStore().isEmpty)
    #expect(try fixture.eventsInStore(kind: .standupReported).isEmpty)
    #expect(
        try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt
            == ReportFixture.origin)
}

@MainActor
@Test("a refused clipboard leaves the store committed and says so")
func refusedClipboardStillCommits() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    let result = try fixture.standupService(nowOffset: 900, copy: { _ in false })
        .commit(editedDraft, of: window, for: fixture.alpha)

    // Not reversible: the compensation for an appended Event is a delete, which
    // §3.3 forbids. So it is reported, and M2-04's undo is the recovery.
    #expect(result.didReachClipboard == false)
    #expect(try fixture.reportsInStore().count == 1)
    #expect(try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt == window.end)
}

@MainActor
@Test("the copied text is what reaches the clipboard")
func theEditedTextReachesTheClipboard() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    nonisolated(unsafe) var copied: String?

    let result = try fixture.standupService(nowOffset: 900, copy: { copied = $0; return true })
        .commit(editedDraft, of: window, for: fixture.alpha)

    #expect(copied == editedDraft)
    #expect(result.didReachClipboard)
}

@MainActor
@Test("D16 — copying for one project does not touch another")
func copyingOneProjectLeavesTheOtherAlone() throws {
    let fixture = try ReportFixture()
    let outsider = try fixture.task("beta's work", in: fixture.beta, status: .inProgress)
    try fixture.event("beta note", on: outsider, at: 60)
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    #expect(try fixture.reloadThroughASecondContext(fixture.beta)?.lastStandupAt == nil)
    let reported = try fixture.eventsInStore(kind: .standupReported)
    #expect(!reported.contains { $0.taskID == outsider.id })
}

@MainActor
@Test("a window belonging to another project is refused before anything is written")
func mismatchedWindowIsRefused() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    let counter = WriteCounter()

    #expect(throws: StandupError.windowBelongsToAnotherProject) {
        // Alpha's window, Beta's project: without the guard this advances one
        // project's clock against the other's window.
        _ = try fixture.standupService(nowOffset: 900)
            .commit(editedDraft, of: window, for: fixture.beta)
    }

    #expect(try fixture.reportsInStore().isEmpty)
    #expect(try fixture.reloadThroughASecondContext(fixture.beta)?.lastStandupAt == nil)
    #expect(counter.posts == 0)
}

@MainActor
@Test("each standupReported event names the report that appended it")
func eventsCarryTheirReportID() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    let result = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // M2-04 redacts exactly the events belonging to the report being undone.
    let reported = try fixture.eventsInStore(kind: .standupReported)
    #expect(reported.count == 1)
    let payload = StandupReportedPayload.decoded(from: reported.first?.payload)
    #expect(payload?.reportID == result.report.id)
}

@MainActor
@Test("a successful Copy announces itself once")
func successfulCopyPostsOnce() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)
    let counter = WriteCounter()

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    #expect(counter.posts == 1)
}

@MainActor
@Test("an empty window still copies, advancing the clock with no events")
func emptyWindowCopiesCleanly() throws {
    let fixture = try ReportFixture()
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)
    #expect(window.tasks.isEmpty, "precondition: nothing happened in this window")

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha)

    // "Nothing to report since yesterday" is a thing people say at stand-ups,
    // and D-074 renders it as three `_None_` sections rather than a blank
    // string. Copying it is legitimate and must still advance the clock.
    #expect(try fixture.reportsInStore().count == 1)
    #expect(try fixture.eventsInStore(kind: .standupReported).isEmpty)
    #expect(try fixture.reloadThroughASecondContext(fixture.alpha)?.lastStandupAt == window.end)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — the build errors with "cannot find 'StandupService' in scope".

- [ ] **Step 4: Write the service**

Create `StenoKit/Report/StandupService.swift`:

```swift
import Foundation
import OSLog
import SwiftData

/// What one Copy did (FR-4 step 7).
///
/// **Two channels, because the two failures need different responses.** A
/// thrown error means the transaction rolled back: nothing happened, and
/// retrying is safe. `didReachClipboard == false` means everything happened
/// except the clipboard, and retrying would report the window a second time.
/// Collapsing them into one `Bool` would leave the UI unable to tell the user
/// which of those they are looking at.
public struct StandupCommit {
    /// The persisted row. M2-04 undoes *this* report.
    public let report: StandupReport

    /// Whether the markdown actually reached the pasteboard.
    public let didReachClipboard: Bool
}

/// FR-4 step 7's Copy: the one place the stand-up clock advances.
///
/// A sibling of `NoteService` and `StatusService` and shaped like them —
/// `@MainActor` because `ModelContext` is not `Sendable`, `now` injected so
/// timestamps are assertable, `save` injected because a real `ModelContext`
/// cannot be made to fail on demand and the rollback is the path that most
/// needs a test — plus one seam they do not have, the clipboard.
///
/// **Deliberately not part of `ReportGatherer`.** That type has no `save` and
/// no `commit()`, and D-065 records that absence as the design: FR-4 requires
/// generating a preview to be free of side effects "so the user can peek
/// without corrupting their window". Every write in FR-4's flow lives here, so
/// the two halves of that guarantee are two types rather than two code paths in
/// one.
@MainActor
public struct StandupService {
    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void
    private let copy: (String) -> Bool

    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        copy: @escaping (String) -> Bool = SystemClipboard.write
    ) {
        self.context = context
        self.now = now
        self.save = save
        self.copy = copy
    }

    /// Commit `body` as `project`'s stand-up for `window`, then copy it.
    ///
    /// All four of FR-4 step 7's effects, or none of them. Steps 2–5 below are
    /// inserts and one field write into a single `ModelContext`, committed by a
    /// single `save` — so "a failure partway must not leave `lastStandupAt`
    /// advanced with no report persisted" is a property of the transaction
    /// boundary rather than of careful ordering. The rejected alternative was
    /// four saves with compensating writes, which cannot satisfy it at all: the
    /// compensation for an appended `Event` is a delete, and §3.3 forbids that
    /// outright.
    ///
    /// `throws` covers the save, and nothing else. A refused clipboard is
    /// reported through `StandupCommit`, not thrown — see below.
    ///
    /// **`body` is the caller's text, not a re-render of `window`.** FR-4 step 6
    /// makes the draft editable and §7.3's whole philosophy is that the user's
    /// phrasing wins, so the edited string is what reaches both the clipboard
    /// and `markdownBody`.
    public func commit(
        _ body: String, of window: GatheredWindow, for project: Project
    ) throws -> StandupCommit {
        // 1. The pair must describe the same project. `NoteService.correct`
        //    guards its own pair for this reason: a mismatch would advance one
        //    project's clock against another project's window, which is exactly
        //    what D16 forbids. Unreachable through the only caller, which draws
        //    both from the same selection; this makes it unreachable through
        //    any caller.
        guard window.projectID == project.id else {
            throw StandupError.windowBelongsToAnotherProject
        }

        // 2. One stamp, used for the report and every event it appends. Two
        //    `now()` calls would let a report and its own events disagree about
        //    when the stand-up happened.
        let stamp = now()

        let report = StandupReport(
            projectID: project.id,
            generatedAt: stamp,
            windowStart: window.start,
            windowEnd: window.end,
            markdownBody: body,
            wasAIGenerated: false
        )
        context.insert(report)

        // 3. One event per task the window reported on — **not** per task named
        //    in `body`. The user may have edited a bullet out of the draft, and
        //    recovering task identity from Slack `mrkdwn` is not merely hard but
        //    ill-defined: D6's output carries no identifiers. The window is the
        //    machine-readable record of what was reported on; the text is the
        //    user's phrasing of it.
        let payload = StandupReportedPayload(reportID: report.id).encoded()
        for task in window.tasks {
            context.insert(
                Event(
                    taskID: task.id,
                    timestamp: stamp,
                    // §3.3's own example body for this kind. Not invented here,
                    // and not the report text: D-066 keeps `standupReported`
                    // out of every future window, so this string is read in the
                    // timeline and nowhere else.
                    kind: .standupReported,
                    body: "Reported to standup",
                    payload: payload
                ))
        }

        // 4. The clock advances to the window's **end**, not to `now` (D-076).
        //    FR-4 step 7 says "now", but the window was computed at generate
        //    time: a note captured between generating and copying would fall
        //    into no report at all — neither this draft nor the next window.
        //    REQUIREMENTS v1.15 amends step 7 to match this line.
        project.lastStandupAt = window.end

        // 5. One save for all of it. On failure the context returns to where it
        //    started and the caller is told nothing happened.
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }

        // 6. After the save, never before: an observer that reloads must not
        //    read a context whose write has not landed (D-019).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

        // 7. The clipboard last. If the save had failed the user would have
        //    nothing on the clipboard and a draft still on screen — they retry,
        //    and nothing was lost. Copying first would hand them text to read
        //    aloud at a stand-up the app has no record of, with no signal that
        //    the record is missing.
        //
        //    This failing after a successful save cannot be rolled back: the
        //    compensation is deleting an `Event`, which §3.3 forbids. So it is
        //    reported rather than reversed, and M2-04's undo is the recovery.
        let didReachClipboard = copy(body)
        if !didReachClipboard {
            Log.app.error("the stand-up was recorded but the clipboard refused the write")
        }

        return StandupCommit(report: report, didReachClipboard: didReachClipboard)
    }
}

/// Why a Copy was refused before it wrote anything.
public enum StandupError: Error, Equatable {
    /// The window and the project disagree — see `commit`'s first guard.
    case windowBelongsToAnotherProject
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, all 13 new cases.

> `xcbeautify` does not print parameterized table cases — absence from the output is not failure. Check the exit code.

- [ ] **Step 6: Verify the tests can actually fail**

Four of these could pass while proving nothing. Apply each mutation, confirm the named test fails, then revert it. **Do not skip this** — the "all-or-none" test in particular passes against a missing `rollback()` and needed a second test written specifically to catch it.

| Mutation | Test that must fail |
|---|---|
| `project.lastStandupAt = stamp` | "the clock advances to the window's end" (+2 others) |
| `markdownBody: SlackMarkdown.render(RawReportSections.build(from: window))` | "Copy persists the report carrying the edited text" |
| Delete the `context.rollback()` line | "a failed Copy does not ride along on the next successful save" — and note the plain all-or-none test does **not** catch this |
| Delete the `guard window.projectID == project.id` block | "a window belonging to another project is refused" |

- [ ] **Step 7: Commit**

```bash
make format
git add StenoKit/Report/StandupService.swift StenoTests/Report/StandupServiceTests.swift StenoTests/Report/ReportFixture.swift
git commit -m "feat: StandupService — FR-4 step 7's four effects, atomically (M2-03)"
```

---

## Task 3: `StandupDraftModel` — the sheet's state machine

**Files:**
- Create: `StenoKit/Features/MainWindow/StandupDraftModel.swift`
- Test: `StenoTests/Features/MainWindow/StandupDraftModelTests.swift`

**Interfaces:**
- Consumes: `StandupService`, `StandupCommit` (Task 2); `GatheredWindow`, `Project`.
- Produces: `StandupDraftPhase { editing, copied }`; `StandupDraftModel(service:)` with `var text: String`, `phase`, `window`, `lastError`, `notice`, `canCopy`, `begin(window:text:)`, `dismiss()`, `commit(to: Project) -> Bool`. Used by Task 4 and the sheet in Task 5.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Features/MainWindow/StandupDraftModelTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 steps 6–7 as the sheet sees them.

/// A string the renderer would never produce, so "the edited text wins" cannot
/// pass against an implementation that re-renders the window.
private let editedDraft = "the user rewrote every word of this by hand"

@MainActor
private func draftReadyToCopy(
    _ fixture: ReportFixture,
    save: @escaping (ModelContext) throws -> Void = { try $0.save() },
    copy: @escaping (String) -> Bool = { _ in true }
) throws -> (model: StandupDraftModel, window: GatheredWindow) {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900, save: save, copy: copy))
    model.begin(window: window, text: "generated text")
    return (model, window)
}

@MainActor
@Test("beginning a draft shows the generated text and writes nothing")
func beginShowsTheDraft() throws {
    let fixture = try ReportFixture()
    let counter = WriteCounter()
    let (model, window) = try draftReadyToCopy(fixture)

    #expect(model.text == "generated text")
    #expect(model.phase == .editing)
    #expect(model.window == window)
    #expect(model.canCopy)
    #expect(counter.posts == 0)
    #expect(try fixture.reportsInStore().isEmpty)
}

@MainActor
@Test("the user's edit is what gets persisted, not the generated text")
func theEditedTextIsWhatCommits() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)

    // FR-4 step 6 and §7.3: the user's own last-second correction is the final
    // word. This is that requirement as an assertion.
    model.text = editedDraft
    #expect(model.commit(to: fixture.alpha))

    #expect(model.phase == .copied)
    #expect(model.lastError == nil)
    #expect(model.notice == nil)
    #expect(try fixture.reportsInStore().first?.markdownBody == editedDraft)
}

@MainActor
@Test("a failed Copy keeps the draft editable and the user's text intact")
func failedCopyKeepsTheText() throws {
    struct Boom: Error {}
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture, save: { _ in throw Boom() })
    model.text = editedDraft

    #expect(model.commit(to: fixture.alpha), "a failure still asks the window to refetch")

    // `CaptureFieldModel`'s contract: the user retries, never retypes. Staying
    // in `.editing` is what makes pressing Copy again the obvious next move,
    // and the store rolled back so it is also the safe one.
    #expect(model.phase == .editing)
    #expect(model.text == editedDraft)
    #expect(model.lastError != nil)
    #expect(model.canCopy)
}

@MainActor
@Test("a refused clipboard reports itself without claiming the save failed")
func refusedClipboardIsANoticeNotAnError() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture, copy: { _ in false })

    #expect(model.commit(to: fixture.alpha))

    // Two channels, because retrying is safe after a failed save and would
    // double-report after a refused clipboard. `lastError` must stay nil: the
    // write succeeded.
    #expect(model.phase == .copied)
    #expect(model.lastError == nil)
    #expect(model.notice != nil)
    #expect(try fixture.reportsInStore().count == 1)
}

@MainActor
@Test("Copy is refused a second time")
func copyIsNotRepeatable() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    #expect(model.commit(to: fixture.alpha))

    // Without this the confirmed sheet's Copy would report the same window
    // twice, advancing nothing but appending a second report and a second set
    // of events — which M2-04 could then only half undo.
    #expect(model.canCopy == false)
    #expect(model.commit(to: fixture.alpha) == false)
    #expect(try fixture.reportsInStore().count == 1)
}

@MainActor
@Test("dismissing discards the draft so it cannot be filed against the next project")
func dismissDiscardsTheDraft() throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftReadyToCopy(fixture)
    model.text = editedDraft

    model.dismiss()

    #expect(model.text.isEmpty)
    #expect(model.window == nil)
    #expect(model.canCopy == false)
    #expect(model.phase == .editing)
}

@MainActor
@Test("committing with no window does nothing")
func commitWithoutAWindowIsANoOp() throws {
    let fixture = try ReportFixture()
    let model = StandupDraftModel(service: fixture.standupService(nowOffset: 900))

    #expect(model.commit(to: fixture.alpha) == false)
    #expect(try fixture.reportsInStore().isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL — "cannot find 'StandupDraftModel' in scope".

- [ ] **Step 3: Write the model**

Create `StenoKit/Features/MainWindow/StandupDraftModel.swift`:

```swift
import Foundation

/// Which half of FR-4's flow the draft sheet is showing.
public enum StandupDraftPhase: Equatable, Sendable {
    /// Step 6: the editable draft, nothing written yet.
    case editing
    /// Step 7 has run. The store is committed; the sheet stays up.
    case copied
}

/// FR-4 steps 6–7: the draft, what the user did to it, and what Copy did.
///
/// **In `StenoKit`, not as `@State` in the sheet**, for `NoteComposerModel`'s
/// reason: D-010 puts view state beyond the headless bundle, and this task's
/// acceptance criteria — the draft is editable and the *edited* text is what
/// reaches the clipboard and `markdownBody`, Copy applies all its effects or
/// none — are all statements about this logic.
///
/// **It holds no reference back to `MainWindowModel`.** Its inputs — the
/// window, the project — arrive as parameters, so there is no closure web to
/// initialise and no retain cycle to weaken. `MainWindowModel+Standup` is the
/// thin wrapper that supplies them and reloads when this type says to.
@Observable
@MainActor
public final class StandupDraftModel {
    /// The draft. Bound directly by the sheet's `TextEditor`, so every
    /// keystroke lands here and `commit` reads it back verbatim.
    public var text: String = ""

    public private(set) var phase: StandupDraftPhase = .editing

    /// The window the draft was built from, frozen at generate time.
    ///
    /// **Frozen, not recomputed at Copy.** A user who previews at 09:00 and
    /// copies at 09:30 copies the 09:00 window — re-gathering would either
    /// discard their edits or contradict them, and FR-4 step 6's editable draft
    /// would become a lie. D-076 makes that safe rather than merely
    /// defensible: the clock advances to this window's end, so anything
    /// captured in between lands in the next report rather than in a gap.
    public private(set) var window: GatheredWindow?

    /// Set when the write could not be saved. The text is kept while this is
    /// non-nil so the user retries rather than retypes — `CaptureFieldModel`'s
    /// contract, for the same reason.
    public private(set) var lastError: String?

    /// Set when nothing failed to save but the user still needs telling — the
    /// report was recorded and the clipboard refused it.
    ///
    /// Its own property rather than a reading of `lastError`, for
    /// `NoteComposerModel`'s reason: one means the write failed and retrying is
    /// safe, the other means the write succeeded and retrying would report the
    /// window twice. A single field cannot say which.
    public private(set) var notice: String?

    private let service: StandupService

    public init(service: StandupService) {
        self.service = service
    }

    /// Copy is live only with a window to commit, and only once.
    public var canCopy: Bool { window != nil && phase == .editing }

    /// FR-4 steps 5–6: show `text` as the draft for `window`.
    ///
    /// Writes nothing. Every caller reaches this through
    /// `MainWindowModel.prepareStandup()`, which gathers and renders and does
    /// nothing else — which is what makes "generating a preview has zero side
    /// effects" true by construction rather than by care.
    public func begin(window: GatheredWindow, text: String) {
        self.window = window
        self.text = text
        phase = .editing
        lastError = nil
        notice = nil
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    ///
    /// Discards the draft in every case. The draft belongs to the moment it was
    /// generated and regenerating is free of side effects, so there is nothing
    /// worth preserving — and a draft surviving into the next Copy would let
    /// one project's edited prose be filed against another project's window.
    public func dismiss() {
        window = nil
        text = ""
        phase = .editing
        lastError = nil
        notice = nil
    }

    /// FR-4 step 7. Never throws — a sheet has nowhere to propagate to.
    ///
    /// Returns whether the window must refetch. `false` only when nothing was
    /// attempted; **`true` after a failure**, because a rollback keeps the
    /// refused write off disk but what it leaves in the objects this window
    /// still holds is not dependable (D-051). Refetching is the only state
    /// worth trusting.
    @discardableResult
    public func commit(to project: Project) -> Bool {
        guard let window, phase == .editing else { return false }
        // Read once, so what is asserted about `markdownBody` is the same
        // string that reached the clipboard even if a keystroke lands mid-call.
        let draft = text

        do {
            let result = try service.commit(draft, of: window, for: project)
            phase = .copied
            lastError = nil
            notice =
                result.didReachClipboard
                ? nil
                : "Your stand-up was recorded, but the clipboard refused it. "
                    + "Select the text above and copy it manually."
        } catch {
            Log.app.error(
                "could not copy the stand-up: \(String(describing: error), privacy: .public)")
            // Stays `.editing` with `text` untouched: the store rolled back, so
            // pressing Copy again is safe and is the obvious next move.
            lastError = "Could not copy your stand-up. Nothing was saved — try again."
        }
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, all 7 new cases.

- [ ] **Step 5: Commit**

```bash
make format
git add StenoKit/Features/MainWindow/StandupDraftModel.swift StenoTests/Features/MainWindow/StandupDraftModelTests.swift
git commit -m "feat: the stand-up draft state machine (M2-03)"
```

---

## Task 4: Wire it into the main window, and fix FR-3's DONE cutoff

Two changes in one task because they are the same reviewer's question: what does advancing `lastStandupAt` change about this window? The cutoff fix is only *necessary* because this task makes the clock advance.

**Files:**
- Create: `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowActions.swift`
- Modify: `StenoKit/Features/MainWindow/TaskGrouping.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Modify: `StenoTests/Features/MainWindow/TaskGroupingTests.swift` (5 call sites + 1 new case)
- Test: `StenoTests/Features/MainWindow/MainWindowModelStandupTests.swift`

**Interfaces:**
- Consumes: `StandupDraftModel` (Task 3), `StandupService` (Task 2), `ReportGatherer`/`RawReportSections`/`SlackMarkdown` (M2-01/M2-02).
- Produces: `ActiveSheet.standupDraft`; `MainWindowActions.canPrepareStandup` and `prepareStandup()`; `MainWindowModel.standupDraft`, `copyStandup()`, `dismissStandupDraft()`, `selectedProject`; `MainWindowModel.init(context:now:save:copy:settings:)`; `TaskGrouping.groups(from:doneSince:)` now taking `(TaskItem) -> Date`. Used by the views in Task 5.

- [ ] **Step 1: Extend the actions protocol and the sheet enum**

In `StenoKit/Features/MainWindow/MainWindowActions.swift`, add the case to `ActiveSheet` after `blockedReason`:

```swift
    /// FR-4 steps 6–7's editable draft (M2-03).
    ///
    /// Carries no project id, unlike its neighbours: the draft's subject is
    /// `StandupDraftModel.window`, frozen at generate time, and a second copy
    /// of that identity here would be one the two could disagree about.
    case standupDraft
```

Add to the `MainWindowActions` protocol, after `canAddNote`:

```swift
    /// FR-4 reports on exactly one project (D16), so the menu gates on this
    /// rather than offering "Prepare Stand-up" under the "All" pseudo-project,
    /// where there is no single window to compute or clock to advance.
    var canPrepareStandup: Bool { get }
```

and after `addNoteToSelection()`:

```swift
    /// FR-4 steps 1–6: gather the window and show the draft. **Writes
    /// nothing** — only Copy advances the clock.
    func prepareStandup()
```

- [ ] **Step 2: Make the DONE cutoff a function of the task**

In `StenoKit/Features/MainWindow/TaskGrouping.swift`, replace the `groups` signature and its doc comment. The body changes in exactly one place: `cutoff` becomes `cutoff(task)`.

```swift
    /// `doneSince` scopes the DONE section to FR-3's "current report window".
    ///
    /// **A function of the task, not one date for the whole list** (D-077).
    /// Under the "All" pseudo-project the visible tasks span projects with
    /// different `lastStandupAt` values and different cadences, and a single
    /// cutoff has to pick one of them. The only safe pick — the earliest across
    /// visible projects — leaks a `periodic` project's fortnight-wide window
    /// into a `daily` project's DONE section, showing two weeks of finished
    /// work under a heading FR-3 scopes to one day.
    ///
    /// This stays free of `Project` and of the store: the caller resolves each
    /// task's window, so this remains testable against literal arrays with no
    /// container, no context, and no clock.
    public static func groups(
        from tasks: [TaskItem], doneSince cutoff: (TaskItem) -> Date
    ) -> [TaskGroup] {
        order.compactMap { status in
            let matching =
                tasks
                .filter { task in
                    guard task.status == status else { return false }
                    guard status == .done else { return true }
                    // A DONE task with no completedAt cannot be placed in the
                    // window, so it is not shown rather than always shown.
                    guard let completedAt = task.completedAt else { return false }
                    return completedAt >= cutoff(task)
                }
                .sorted { $0.statusChangedAt > $1.statusChangedAt }

            guard !matching.isEmpty else { return nil }
            return TaskGroup(status: status, tasks: matching)
        }
    }
```

- [ ] **Step 3: Update the five existing call sites in `TaskGroupingTests`**

Each becomes a closure ignoring its argument. In `StenoTests/Features/MainWindow/TaskGroupingTests.swift`:

- `doneSince: origin.addingTimeInterval(-3600))` → `doneSince: { _ in origin.addingTimeInterval(-3600) })`
- `doneSince: cutoff)` → `doneSince: { _ in cutoff })`
- `doneSince: origin)` → `doneSince: { _ in origin })` (three occurrences)

- [ ] **Step 4: Add the test that a flat cutoff cannot pass**

Append to `StenoTests/Features/MainWindow/TaskGroupingTests.swift`:

```swift
@Test("the DONE cutoff is resolved per task, not once for the whole list")
func doneCutoffIsPerTask() {
    // The case that makes this necessary: under FR-3's "All" pseudo-project the
    // visible tasks span projects with different `lastStandupAt` values. Both
    // tasks completed at the same instant; only their windows differ. A single
    // cutoff — of any value — either shows both or hides both.
    let daily = task("daily", .done, changedAt: origin.addingTimeInterval(-3600))
    let fortnightly = task("fortnightly", .done, changedAt: origin.addingTimeInterval(-3600))

    let groups = TaskGrouping.groups(from: [daily, fortnightly]) { task in
        task.id == daily.id
            ? origin.addingTimeInterval(-60)  // 1 minute: excludes `daily`
            : origin.addingTimeInterval(-14 * 24 * 3600)  // 2 weeks: includes it
    }

    #expect(groups.count == 1)
    #expect(groups[0].tasks.map(\.title) == ["fortnightly"])
}
```

- [ ] **Step 5: Update `MainWindowModel`**

Four edits in `StenoKit/Features/MainWindow/MainWindowModel.swift`.

Add the stored property after `noteComposer`:

```swift
    /// FR-4's draft sheet. A `let` built in `init` for `noteComposer`'s reason:
    /// it holds no reference back to this model, so it needs nothing that only
    /// becomes available after `self` does.
    public let standupDraft: StandupDraftModel
```

Extend `init`'s signature — add `copy` between `save` and `settings`, and extend the doc comment:

```swift
    /// `now` is injected so the DONE window is testable without waiting.
    /// `save` is injected so the rollback path in `perform(_:_:)` is testable
    /// — a real `ModelContext` cannot be made to fail its save on demand.
    /// `copy` is injected so the headless bundle never reaches the real
    /// pasteboard: a test that did would mutate the developer's clipboard and
    /// would be order-dependent on anything else in the process that copies
    /// (§9.4).
    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        copy: @escaping (String) -> Bool = SystemClipboard.write,
        settings: AppSettings = AppSettings()
    ) {
```

Build the draft model in `init`, immediately after the `noteComposer` assignment and **before** `reload()`:

```swift
        self.standupDraft = StandupDraftModel(
            service: StandupService(context: context, now: now, save: save, copy: copy))
```

Replace `doneCutoff()` with the per-task version:

```swift
    /// FR-3's "current report window", for one task.
    ///
    /// **This used to be a flat `now() - 24h`**, correct only because
    /// `lastStandupAt` stayed nil until M2-03 shipped the Copy action that
    /// advances it. M2-03 shipped it, so the constant became a live FR-3
    /// violation the first time the user copied a stand-up — the shape of
    /// documented exception that is really a bug filed against whichever task
    /// makes it reachable.
    ///
    /// Delegates to `ReportWindow.bounds` rather than restating the rule, which
    /// also keeps the first-run case right for free: a project never reported
    /// on still gets 24 hours, from the one place that decision lives (D-077).
    ///
    /// A task whose project is not visible — archived between the fetch and
    /// this call — resolves through the same `nil` path as a never-reported
    /// project. It is about to be filtered out of the list anyway.
    private func doneCutoff(for task: TaskItem) -> Date {
        ReportWindow.bounds(
            lastStandupAt: project(withID: task.projectID)?.lastStandupAt,
            now: now()
        ).start
    }
```

And update the call in `reload()`:

```swift
        // `projects` first: `doneCutoff(for:)` resolves each task's project
        // through it, so the order of these two lines is load-bearing.
        projects = fetchProjects()
        groups = TaskGrouping.groups(from: fetchTasks(), doneSince: doneCutoff(for:))
```

- [ ] **Step 6: Write the extension**

Create `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift`:

```swift
import Foundation

/// FR-4's stand-up actions: the thin layer between the draft sheet and the
/// store.
///
/// `StandupDraftModel` holds the draft and decides what a Copy means; this
/// supplies the one thing it deliberately does not hold — the selected project
/// — and reloads when it says to. The same split `MainWindowModel+Notes` makes
/// for FR-2, for the same reason.
extension MainWindowModel {
    /// FR-4 needs exactly one project to report on.
    ///
    /// D16 — "each meeting covers exactly one project" — and `lastStandupAt` is
    /// per-project, so the "All" pseudo-project has no coherent answer: there
    /// is no single window to compute and no single clock to advance. The
    /// footer button and the ⌘R menu item both read this, so they cannot
    /// disagree about when the action is live.
    public var canPrepareStandup: Bool { selectedProject != nil }

    /// The project the stand-up acts on, or `nil` under "All".
    ///
    /// Resolved through `projects` rather than from `selection` alone, so a
    /// project archived from another surface stops being reportable the moment
    /// this model reloads.
    var selectedProject: Project? {
        guard case .project(let id) = selection else { return nil }
        return project(withID: id)
    }

    /// FR-4 steps 1–6: gather, render, and show the draft.
    ///
    /// **Writes nothing, and there is no write path here to fail on.**
    /// `ReportGatherer` has no `save` parameter and no `commit()` — D-065
    /// records that absence as the design — and rendering is two pure
    /// functions. That is what makes "the user can generate repeatedly, close
    /// the sheet, and their window is untouched" true by construction.
    ///
    /// A failed gather does **not** open the sheet: the error goes to the
    /// window's existing inline banner instead. A modal whose only content is
    /// an error asks the user to dismiss something they did not summon.
    public func prepareStandup() {
        guard let project = selectedProject else { return }

        let window: GatheredWindow
        do {
            window = try ReportGatherer(context: context, now: now).gather(for: project)
        } catch {
            Log.app.error(
                "could not prepare the stand-up: \(String(describing: error), privacy: .public)")
            lastError = "Could not prepare your stand-up. Nothing was changed."
            return
        }

        standupDraft.begin(
            window: window,
            text: SlackMarkdown.render(RawReportSections.build(from: window)))
        activeSheet = .standupDraft
    }

    /// FR-4 step 7, from the sheet's Copy button.
    ///
    /// Reloads on every outcome the draft model reports, including failures —
    /// see `StandupDraftModel.commit(to:)` for why a rollback is not something
    /// to reason about from the objects still in hand.
    ///
    /// A successful Copy reloads twice: `StandupService` posts `.stenoDidWrite`
    /// synchronously, which this window's own observer turns into a `reload()`,
    /// and then this line reloads again. Known and harmless — `reload()` is
    /// idempotent — and the same shape `MainWindowModel+Notes` documents.
    /// The reload is load-bearing here beyond the timeline: advancing
    /// `lastStandupAt` moves FR-3's DONE cutoff for this project, so the task
    /// list is stale until it runs.
    public func copyStandup() {
        guard let project = selectedProject else { return }
        if standupDraft.commit(to: project) { reload() }
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    public func dismissStandupDraft() {
        standupDraft.dismiss()
        activeSheet = nil
    }
}
```

- [ ] **Step 7: Write the main-window tests**

Create `StenoTests/Features/MainWindow/MainWindowModelStandupTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// FR-4 steps 1–6 through the main window, and the DONE window it moves.

private let origin = Date(timeIntervalSince1970: 1_000_000)

/// A model over a store holding one project with one in-progress, noted task.
///
/// `copy` is injected all the way down so the headless bundle never reaches the
/// real pasteboard — a test that did would mutate the developer's clipboard and
/// be order-dependent on anything else in the process that copies (§9.4).
@MainActor
private func modelWithReportableWork(
    now: @escaping () -> Date = { origin },
    copy: @escaping (String) -> Bool = { _ in true }
) throws -> (MainWindowModel, Project) {
    let container = try StenoStore.inMemory()
    // `ModelContext(container)` retains its container; `container.mainContext`
    // does not, and dangles the moment the container goes out of scope.
    let context = ModelContext(container)
    let project = Project(name: "Alpha", colorHex: "#112233", modifiedAt: origin)
    context.insert(project)
    let task = TaskItem(
        title: "ship the thing", projectID: project.id,
        createdAt: origin.addingTimeInterval(-3600))
    context.insert(task)
    task.setStatus(.inProgress, at: origin.addingTimeInterval(-3600))
    context.insert(
        Event(
            taskID: task.id, timestamp: origin.addingTimeInterval(-1800),
            kind: .note, body: "found the race in setUp"))
    try context.save()

    let model = MainWindowModel(context: context, now: now, copy: copy)
    model.selection = .project(project.id)
    return (model, project)
}

@MainActor
@Test("FR-4: generating a preview repeatedly writes nothing at all")
func generatingIsFreeOfSideEffects() throws {
    let (model, project) = try modelWithReportableWork()
    let counter = WriteCounter()

    // "The user can generate repeatedly, close the sheet, and their window is
    // untouched." Three times, because a side effect that only fires on the
    // first call would pass a single-call test.
    for _ in 0..<3 {
        model.prepareStandup()
        model.dismissStandupDraft()
    }

    #expect(counter.posts == 0)
    #expect(project.lastStandupAt == nil, "the clock only advances on Copy, never on generate")
    #expect(model.lastError == nil)
}

@MainActor
@Test("preparing a stand-up opens the sheet with the rendered draft")
func prepareOpensTheSheetWithADraft() throws {
    let (model, _) = try modelWithReportableWork()

    model.prepareStandup()

    #expect(model.activeSheet == .standupDraft)
    #expect(model.standupDraft.window != nil)
    // The §7.4 renderer's output, not a placeholder: D-073's headings are
    // `*bold*` because Slack `mrkdwn` has no heading syntax.
    #expect(model.standupDraft.text.contains("*Since last stand-up*"))
    #expect(model.standupDraft.text.contains("found the race in setUp"))
}

@MainActor
@Test("D16: the stand-up action is unavailable under the All pseudo-project")
func allPseudoProjectCannotPrepare() throws {
    let (model, _) = try modelWithReportableWork()

    model.selection = .all

    #expect(model.canPrepareStandup == false)
    model.prepareStandup()
    #expect(model.activeSheet == nil, "there is no single window to compute or clock to advance")
}

@MainActor
@Test("Copy advances the clock and appends the event, through the window")
func copyThroughTheWindowCommits() throws {
    let (model, project) = try modelWithReportableWork()
    model.prepareStandup()
    let generatedWindowEnd = model.standupDraft.window?.end

    model.copyStandup()

    #expect(model.standupDraft.phase == .copied)
    #expect(project.lastStandupAt == generatedWindowEnd)
    #expect(model.activeSheet == .standupDraft, "the sheet stays up so M2-04's undo has a home")
}

@MainActor
@Test("FR-3: copying moves the DONE window, so older completions drop out")
func copyMovesTheDoneWindow() throws {
    // A task finished 12 hours ago: inside the 24h first-run window, and
    // outside the window that Copy leaves behind.
    let (model, project) = try modelWithReportableWork()
    let finished = TaskItem(
        title: "finished earlier", projectID: project.id,
        createdAt: origin.addingTimeInterval(-13 * 3600))
    model.context.insert(finished)
    finished.setStatus(.done, at: origin.addingTimeInterval(-12 * 3600))
    try model.context.save()
    model.reload()

    #expect(
        model.groups.contains { $0.status == .done },
        "precondition: the first-run 24h window includes it")

    model.prepareStandup()
    model.copyStandup()

    // `lastStandupAt` is now `origin`, so FR-3's "current report window" is
    // `[origin, origin]` — and a task completed 12 hours ago is no longer in
    // it. Before D-077 this section was pinned to a hardcoded 24 hours and
    // would still have shown it.
    #expect(!model.groups.contains { $0.status == .done })
}
```

- [ ] **Step 8: Run the tests**

Run: `make test`
Expected: **FAIL to build**, with exactly one error:

```
Steno/Features/MainWindow/MainWindowView.swift:50:13: switch must be exhaustive
```

This is verified, not predicted: `make test` runs `build-for-testing` against a scheme whose build targets include `Steno: all`, so it compiles the app target too. Adding `ActiveSheet.standupDraft` in Step 1 makes `MainWindowView`'s `switch sheet` non-exhaustive, and nothing closes it until Task 5.

**Task 4 therefore cannot be green on its own.** Review it on the diff, then complete Task 5 and verify the two together. If you want to run the tests before then, add the `case .standupDraft:` block from Task 5 Step 2 now and commit it with Task 5.

- [ ] **Step 9: Verify the DONE-cutoff test can fail**

Replace the body of `doneCutoff(for:)` with `now().addingTimeInterval(-24 * 60 * 60)` and confirm "FR-3: copying moves the DONE window" fails. Revert.

- [ ] **Step 10: Commit**

```bash
make format
git add StenoKit/Features/MainWindow/ StenoTests/Features/MainWindow/
git commit -m "feat: wire the stand-up into the main window; DONE cutoff per task (M2-03)"
```

---

## Task 5: The sheet, the pinned button, and ⌘R

The app target. No tests — views need a window server, which the headless bundle does not have (D-010). Everything testable was already pushed into Tasks 3 and 4.

**Files:**
- Create: `Steno/Features/MainWindow/StandupDraftSheet.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift`
- Modify: `Steno/Features/MainWindow/TaskListView.swift`
- Modify: `Steno/App/MainWindowCommands.swift`

**Interfaces:**
- Consumes: `StandupDraftModel`, `MainWindowModel.copyStandup()`/`dismissStandupDraft()`/`prepareStandup()`/`canPrepareStandup`, `ActiveSheet.standupDraft` (Tasks 3–4).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Create the sheet**

Create `Steno/Features/MainWindow/StandupDraftSheet.swift`. Note `summary(of:)` — interpolating into `Text` yields a `LocalizedStringKey`, which has no `+`, so the string is built first.

```swift
import StenoKit
import SwiftUI

/// FR-4 steps 6–7: the editable draft, and Copy.
///
/// Everything stateful is in `StandupDraftModel` over in `StenoKit`, where the
/// headless bundle can reach it (D-010); this file is layout.
///
/// **It does not dismiss on Copy.** M2-04's undo has to be "easy to find right
/// after a Copy and not require hunting through settings" (FR-4.1), and this
/// confirmed state is that place. Dismissing here would leave M2-04 to invent a
/// home for Undo after the affordance it belongs beside had already gone.
struct StandupDraftSheet: View {
    @Bindable var draft: StandupDraftModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Editable, per FR-4 step 6: the user's own last-second correction
            // is the final word, and §7.3's philosophy is that their phrasing
            // wins. The binding is what makes `markdownBody` the edited text
            // rather than the generated text.
            TextEditor(text: $draft.text)
                .font(.body.monospaced())
                .frame(minWidth: 520, minHeight: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                }

            if let notice = draft.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = draft.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            buttons
        }
        .padding(20)
        .frame(maxWidth: 720)
    }

    /// What is about to be reported on, so Copy is never a blind commit.
    @ViewBuilder
    private var header: some View {
        if let window = draft.window {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.phase == .copied ? "Copied to clipboard" : "Prepare Stand-up")
                    .font(.headline)
                // Built as a `String` first: interpolating into `Text` yields a
                // `LocalizedStringKey`, which has no `+`.
                Text(summary(of: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The window's bounds and how many tasks fall inside it.
    private func summary(of window: GatheredWindow) -> String {
        let span = window.start.formatted(.dateTime) + " – " + window.end.formatted(.dateTime)
        let count = window.tasks.count
        return span + " · \(count) task" + (count == 1 ? "" : "s")
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch draft.phase {
            case .editing:
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Copy", action: onCopy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCopy)
            case .copied:
                // Esc and Return both close: once the store is committed there
                // is no second action to protect, and M2-04 adds Undo here.
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
```

- [ ] **Step 2: Add the sheet case**

In `Steno/Features/MainWindow/MainWindowView.swift`, inside `.sheet(item:)`'s `switch sheet`, add before `case .editProject(let id):`:

```swift
            case .standupDraft:
                StandupDraftSheet(
                    draft: model.standupDraft,
                    onCopy: { model.copyStandup() },
                    onClose: { model.dismissStandupDraft() })
```

- [ ] **Step 3: Pin the button to the task list**

In `Steno/Features/MainWindow/TaskListView.swift`, insert immediately before `.navigationSplitViewColumnWidth(min: 260, ideal: 320)`:

```swift
        // FR-4's "prominent, always-visible button on the project view", and
        // the reason it is here rather than in the toolbar: the toolbar renders
        // New Task as a bare `+`, which is the opposite of prominent, and this
        // column is already scoped to one project — so "which project am I
        // reporting on" is answered by what sits directly above the button.
        //
        // `safeAreaInset` rather than a row in the `List`: pinned, so no amount
        // of scrolling can hide the core value delivery.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    model.prepareStandup()
                } label: {
                    Label("Prepare Stand-up", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                // D16: exactly one project per meeting, so "All" has no window
                // to compute and no clock to advance.
                .disabled(!model.canPrepareStandup)
                .help(
                    model.canPrepareStandup
                        ? "Generate a stand-up draft for this project (⌘R)"
                        : "Select a single project to prepare its stand-up"
                )
                .padding(10)
            }
            .background(.bar)
        }
```

- [ ] **Step 4: Add ⌘R to the Task menu**

In `Steno/App/MainWindowCommands.swift`, append inside `CommandMenu("Task")` after the "Add Note" button:

```swift
            Divider()

            // FR-3 lists "generate report" among the actions needing a
            // shortcut, and FR-4 is the reason the app exists. ⌘R is free here
            // — Steno has no Reload — and it is the conventional macOS chord
            // for "produce this again", which is exactly what it does.
            //
            // Generating writes nothing (FR-4), so an accidental ⌘R costs a
            // sheet the user presses Esc on, never a corrupted window.
            Button("Prepare Stand-up") { actions?.prepareStandup() }
                .keyboardShortcut("r")
                .disabled(actions?.canPrepareStandup != true)
```

- [ ] **Step 5: Verify everything**

```bash
make format
make build && make test && make lint
```

Expected: `Build Succeeded`; all tests pass; `0 violations` across 151 files. `git status` must be clean after `make format` — CI fails otherwise (D-075).

- [ ] **Step 6: Commit**

```bash
git add Steno/
git commit -m "feat: the stand-up draft sheet, pinned button, and ⌘R (M2-03)"
```

---

## Task 6: Documentation, the spec amendment, and the PR

**Files:**
- Modify: `docs/REQUIREMENTS.md` (→ v1.15)
- Modify: `docs/DECISIONS.md` (D-076 … D-081)
- Modify: `docs/tasks/README.md` (verify no tick debt)

- [ ] **Step 1: Amend REQUIREMENTS.md to v1.15**

Three edits. Change `**Status:** Draft v1.14` to `**Status:** Draft v1.15`, then add the changelog entry directly above the `- *v1.14*` line:

```markdown
- *v1.15* — FR-4 step 7 no longer sets `lastStandupAt = now`. It sets it to the **end of the window the draft was generated from**, and §3.5's `windowEnd` records the same instant. Read literally, the old wording opened a hole: the window is computed at generate time, so anything captured between generating and copying fell into neither the draft nor the next window and no report would ever contain it. FR-4's own note reasons carefully about the *start* of that interval — "a user who previews at 09:00 and reports at 09:30 must get the full window" — and not at all about its end. For a tool whose promise is that nothing captured is lost, that is the worst available failure mode. The side effects, their atomicity, and the "clock only advances on Copy" rule are all unchanged. Found while implementing M2-03; the implementation choice is `DECISIONS.md` D-076, which points here.
```

In FR-4 step 7's bullet list, replace `   - Sets \`project.lastStandupAt = now\`,` with:

```markdown
   - Sets `project.lastStandupAt` to the **end of the generated window** (see v1.15; *not* the instant of the click, which would skip anything captured while the draft was open),
```

In §3.5's table, replace `| \`windowEnd\` | Date | |` with:

```markdown
| `windowEnd` | Date | The instant the window was generated. Copy writes this same value to `lastStandupAt` (v1.15) |
```

- [ ] **Step 2: Add D-076 … D-081 to DECISIONS.md**

Insert these six entries verbatim, immediately before the `## Open — decided by the task that owns them` heading:

````markdown
### D-076 — Copy advances the clock to the window's end, not to `now`

**2026-09-09** · M2-03 · **Status:** accepted

`StandupService.commit` sets `project.lastStandupAt = window.end` — the instant the draft was
generated — and writes the same value to `StandupReport.windowEnd`.

FR-4 step 7 said `lastStandupAt = now`. The window is computed at *generate* time, so the two are
different instants and the difference is a hole: preview at 09:00, capture a note at 09:15, Copy at
09:30, and the 09:15 note is in neither today's draft nor tomorrow's window. No report would ever
contain it.

FR-4's own note shows the requirement was written without noticing: "a user who previews at 09:00,
gets pulled into a meeting, and reports at 09:30 must get the full window" reasons about the start
of that interval and not at all about its end.

Three properties follow. Nothing is unreportable, with no special case. `windowStart`/`windowEnd`
describe exactly the interval the stored `markdownBody` covers, which is what M2-04 reads back and
what M2.5 exports. And a draft left open for hours becomes *safe* rather than merely stale — the
cost is a thinner report today, never a lost note.

**Alternatives:** literal compliance (ships the gap); re-gathering at Copy so the window really does
end at `now` (discards the user's edits or contradicts them, making FR-4 step 6's editable draft a
lie, and breaking §7.3's "the user's phrasing wins" to satisfy a sentence about a timestamp).

**Spec:** REQUIREMENTS.md amended to v1.15 in the same PR — FR-4 step 7 and §3.5's `windowEnd` row.

### D-077 — FR-3's DONE cutoff is resolved per task, not once per view

**2026-09-09** · M2-03 · **Status:** accepted

`TaskGrouping.groups(from:doneSince:)` takes `(TaskItem) -> Date` rather than a flat `Date`, and
`MainWindowModel.doneCutoff(for:)` resolves each task's window through `ReportWindow.bounds`.

`doneCutoff()` was `now() - 24h`, and its comment said so honestly: correct "for every state
reachable today" **because `lastStandupAt` stays nil until M2-03 ships the Copy action that advances
it". M2-03 shipped it. The constant became a live FR-3 violation — "DONE shows only items completed
within the current report window" — the first time the user copied a stand-up. A documented
exception of that shape is a bug filed against whichever task makes it reachable.

Per-task rather than per-view because of the "All" pseudo-project: its tasks span projects with
different `lastStandupAt` values and different cadences (D17). A single cutoff has to pick one, and
the only safe pick — the earliest across visible projects — leaks a `periodic` project's
fortnight-wide window into a `daily` project's DONE section.

Delegating to `ReportWindow.bounds` rather than restating the rule keeps the first-run case correct
for free: a project never reported on still gets 24 hours, from the one place that decision lives.

`TaskGrouping` stays free of `Project` and of the store — the caller resolves the window — so it
remains testable against literal arrays with no container, context, or clock.

### D-078 — The clipboard is written after the save, and a refusal is reported rather than reversed

**2026-09-09** · M2-03 · **Status:** accepted

`StandupService.commit` commits the transaction, posts `.stenoDidWrite`, and only then calls `copy`.
It returns `StandupCommit { report, didReachClipboard }`.

Save-first because the alternative hands the user text to read aloud at a stand-up the app has no
record of, with no signal that the record is missing. A failed save costs them nothing: the draft is
still on screen and retrying is safe.

The residual case is real and is **not** rolled back. If the save succeeds and
`NSPasteboard.setString` returns `false`, the compensation would be deleting an `Event`, which §3.3
forbids outright. So it is reported: `didReachClipboard = false`, the sheet says the report was
recorded but not copied, and M2-04's undo is the recovery.

`throws` and the flag are two channels because the two failures need different responses — after a
throw, retrying is safe; after a refused clipboard, retrying double-reports the window.

### D-079 — `standupReported` events carry their report's id in `payload`

**2026-09-09** · M2-03 · **Status:** accepted

Each event Copy appends carries `payload` = JSON `{"reportID": <uuid>}` (`StandupReportedPayload`).

FR-4.1 must redact the events appended by *one particular* report, and nothing else on the row
identifies which: `taskID` says where it landed, `kind` says what it is, and a project reported on
twice in a day has two sets. §3.3 specifies `payload` as a "JSON blob for structured external data";
this is its first use.

**Alternative:** matching on `timestamp == report.generatedAt`. It works — `commit` stamps both from
one `now()` — but it couples undo to a coincidence rather than a statement, and a later change that
stamped events independently would break undo silently, with nothing in either file recording why
the two values had to agree.

Encoding failure yields `nil` rather than throwing: the cost of a missing payload is that M2-04
cannot undo *that* report, which is far better than refusing to produce a stand-up over it.

### D-080 — The draft sheet stays open after Copy

**2026-09-09** · M2-03 · **Status:** accepted

`StandupDraftModel` moves to `.copied` and the sheet remains presented, showing a confirmation, the
still-selectable text, and Close.

FR-4.1 requires undo to be "easy to find right after a Copy" and not to require hunting through
settings. This confirmed state is that place, and M2-04 adds the button here. Dismissing on Copy
would leave M2-04 to invent a home for Undo — a menu item, a transient banner — after the affordance
it belongs beside had already disappeared.

It is also where a refused clipboard is recoverable by hand (D-078): the text is still on screen.

`canCopy` is false in `.copied`, so the button cannot report the same window twice — which would
append a second report and a second set of events that M2-04 could then only half undo.

### D-081 — Copy marks every task in the window, not every task named in the text

**2026-09-09** · M2-03 · **Status:** accepted

`commit` appends one `standupReported` event per `window.tasks`, regardless of what the user did to
the draft. Delete a bullet and that task still gets its event.

The alternative is parsing edited markdown back to task ids. It is not merely hard but ill-defined:
D6's Slack `mrkdwn` carries no identifiers, and making the append-only log depend on a reverse-parse
of user-edited prose would be the least reliable thing in the system.

The frozen window is the machine-readable record of what was reported on; the text is the user's
phrasing of it. Those are different facts, and only one of them is recoverable.
````

- [ ] **Step 3: Check for tick debt**

Per CLAUDE.md's "Working a task" step 4, check `docs/tasks/README.md` for rows that merged without being ticked.

Run: `grep -n "M2-0" docs/tasks/README.md`
Expected: M2-01 and M2-02 are both already `[x]`. **No debt to clear.** M2-03's own row is ticked in M2-04's PR, per the README's convention.

- [ ] **Step 4: Final verification**

```bash
make format
make build && make test && make lint
git status --short   # must be empty of unstaged changes
```

- [ ] **Step 5: Commit and open the PR**

```bash
git add docs/
git commit -m "docs: REQUIREMENTS v1.15 and D-076..D-081 for M2-03"
git push -u origin feat/report-ui-and-copy
gh pr create --title "Report UI, the Copy transaction, and a clock correction (M2-03)" --body "..."
```

The PR body must state (§9.5, §13):
- **Requirement IDs:** FR-4 (full flow), FR-3 (keyboard-first, DONE window), D6, D16, §3.3, §3.5.
- **The spec amendment**, prominently: REQUIREMENTS.md → v1.15, why FR-4 step 7 was wrong, and that D-076 records the choice. A PR that quietly contradicts REQUIREMENTS.md is worse than one that pauses to ask.
- **What was verified and how**, including which mutations were run to prove the tests can fail — and specifically that the obvious all-or-none test does *not* detect a missing `rollback()`, which is why `failedCopyDoesNotLeakIntoALaterSave` exists.
- **Outstanding manual check:** pasting into Slack (D6) cannot be verified by an agent. State it as unverified rather than claiming it.
- **Raised, not decided:** report history browsing is Q(M3) in §12, a product question.
- **Deliberately left out:** undo (M2-04), AI generation (M3-03), ref refreshing (M4-01).

- [ ] **Step 6: Stop. Do not merge.**

The user reviews and merges (CLAUDE.md non-negotiable #1). Then run the Copilot review loop — fix, reply, resolve — before reporting the PR as done, and check the review *body* for suppressed comments, not just the inline list.

---

## Notes for whoever executes this

**This plan was written from a tree that was actually built.** Every code block above compiled, and the whole suite (361 tests) passed with `make lint` reporting 0 violations across 151 files. Three defects were found and fixed during that build rather than shipped in the plan:

1. `Text("...\(x)..." + "...")` does not compile — interpolation yields `LocalizedStringKey`, which has no `+`. Hence `summary(of:)` in Task 5.
2. The `ActiveSheet.standupDraft` case was initially written as a doc comment with no `case` beneath it. It compiled as documentation attached to the *next* case.
3. The obvious all-or-none test cannot detect a missing `context.rollback()`. With an injected throwing `save`, nothing reaches the store either way. `failedCopyDoesNotLeakIntoALaterSave` in Task 2 is the test that actually catches it, and it was written only because the mutation run proved the first one couldn't.

**Order matters between Tasks 4 and 5.** Adding `ActiveSheet.standupDraft` in Task 4 makes `MainWindowView`'s `switch` non-exhaustive, so the app target does not build until Task 5 lands. StenoKit and the test bundle build and pass throughout.
