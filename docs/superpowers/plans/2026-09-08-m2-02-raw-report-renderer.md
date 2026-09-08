# M2-02 Raw Report Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a `GatheredWindow` into Slack-flavored markdown, in both cadence shapes, with no AI, no network, and no store — §7.4's P0 fallback, which §7.4 requires be built *before* the AI path.

**Architecture:** Two pure steps over value types. `RawReportSections.build(from:)` maps a gathered window onto `[ReportSection]` (this is where D17's cadence lives); `SlackMarkdown.render(_:)` turns any `[ReportSection]` into a string (this is where D6 lives). The split is §7.3's own — "the app renders markdown from whichever structure came back… formatting is the app's job" — and it is what lets M3-03 feed AI-authored bullets through the same emitter. Nothing here is `@MainActor`, injected, or store-aware.

**Tech Stack:** Swift 6, swift-testing (`@Test` / `#expect`), XcodeGen, SwiftLint `--strict`, swift-format. No new dependencies.

**Spec:** [`docs/superpowers/specs/2026-09-08-m2-02-raw-report-renderer-design.md`](../specs/2026-09-08-m2-02-raw-report-renderer-design.md)

## Global Constraints

- **Branch `feat/raw-report-renderer`. Never commit to `main`, never merge the PR** (CLAUDE.md §1, REQUIREMENTS §9.5).
- **`make build && make test && make lint` must all pass before the PR.** Assertions about compilation are not acceptable (§9.5 step 4, §13).
- **The event log is append-only.** Nothing in this task writes to the store at all; if a step seems to need a write, the step is wrong (§3.3).
- **Every new file lives in `StenoKit/`**, not `Steno/`: none of this needs a window server (D-010). XcodeGen globs both directories, so no `project.yml` edit is needed — but `make generate` (run by `make build` and `make test`) must see the file before it compiles.
- **Verbatim is a hard requirement.** Ticket keys, service names, function names, and error strings must survive byte-identical. Never escape, trim, re-punctuate, or re-case a user-authored body (§7.3, and this task's own acceptance criteria).
- **No clock, no `Date` formatting, no `Dictionary`/`Set` iteration, no sorting** anywhere in these files. Each is a way determinism could be lost; the spec's §5 depends on all four.
- **SwiftLint `--strict` gotchas that have bitten this repo:** identifiers must be ≥3 characters, and the literal word `TODO` in a comment fails the build.
- **`#expect` is a macro, and code that compiles outside it may not compile inside it.** `allSatisfy` is the known case in this task — see Task 1, Step 2's note.
- **`make test` output hides parameterized test cases.** A parameterized `@Test` that never runs looks identical to one that passes. Where this plan uses one, it says how to confirm it executed.
- **`make test` regenerates `Steno.xcodeproj` every run** by design; that can disturb an open Xcode session. Never commit `Steno.xcodeproj` or `Local.xcconfig`.

---

### Task 1: The markdown emitter

Delivers D6 — the one place the Slack dialect is decided — plus the structure type both this task and M3-03 produce. Reviewable on its own: it takes hand-built sections and emits a string, with no knowledge of cadences, statuses, or windows.

**Files:**
- Create: `StenoKit/Report/ReportSection.swift`
- Create: `StenoKit/Report/SlackMarkdown.swift`
- Test: `StenoTests/Report/SlackMarkdownTests.swift`

**Interfaces:**
- Consumes: nothing. These files import no module at all — not even `Foundation`.
- Produces: `ReportSection(title: String, bullets: [ReportBullet])`, `ReportBullet(text: String, details: [String] = [])`, and `SlackMarkdown.render(_ sections: [ReportSection]) -> String`. Task 2 constructs the first two; Task 3 calls `render`. M3-03 will construct `ReportBullet`s with `details` empty, which is why `details` is defaulted.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Report/SlackMarkdownTests.swift`:

```swift
import Testing

@testable import StenoKit

@Test("D6: a heading is bold mrkdwn, because Slack has no heading syntax")
func aSectionRendersItsTitleInBold() {
    let markdown = SlackMarkdown.render([
        ReportSection(title: "Today", bullets: [ReportBullet(text: "Rate limiter (PAY-388)")])
    ])

    // Asserted as the whole string rather than with `contains`, so a stray
    // leading blank line or trailing newline fails here.
    #expect(markdown == "*Today*\n• Rate limiter (PAY-388)")
}

@Test("A detail hangs under its bullet")
func detailsRenderAsIndentedSubBullets() {
    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Since last stand-up",
            bullets: [
                ReportBullet(text: "Flaky auth test", details: ["was a race", "PR merged"])
            ])
    ])

    #expect(
        markdown == """
            *Since last stand-up*
            • Flaky auth test
                ◦ was a race
                ◦ PR merged
            """)
}

@Test("D-074: an empty section says so rather than disappearing")
func anEmptySectionRendersNone() {
    let markdown = SlackMarkdown.render([ReportSection(title: "Blockers", bullets: [])])

    // "No blockers" is a sentence people say at stand-ups; dropping the
    // heading throws away something the user wants to speak.
    #expect(markdown == "*Blockers*\n_None_")
}

@Test("An empty window is three headings, not a blank string")
func anEmptyWindowRendersHonestly() {
    // Literal sections rather than a window, so this file tests emission and
    // nothing else. That RawReportSections yields three empty sections from an
    // empty window is asserted where that mapping lives.
    let markdown = SlackMarkdown.render([
        ReportSection(title: "Since last stand-up", bullets: []),
        ReportSection(title: "Today", bullets: []),
        ReportSection(title: "Blockers", bullets: []),
    ])

    #expect(
        markdown == """
            *Since last stand-up*
            _None_

            *Today*
            _None_

            *Blockers*
            _None_
            """)
}

@Test("A multi-line note keeps every line, hanging under the first")
func aMultiLineDetailIndentsItsContinuationLines() {
    // NoteService trims only outer whitespace and NoteComposerView is a
    // TextEditor, so this body is reachable from the UI. Rendered naïvely the
    // second line would escape its bullet entirely.
    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Today",
            bullets: [ReportBullet(text: "Migration", details: ["step one\nstep two"])])
    ])

    #expect(
        markdown == """
            *Today*
            • Migration
                ◦ step one
                  step two
            """)
}

@Test("A blank line inside a note carries no trailing whitespace")
func anInteriorBlankLineIsEmittedBare() {
    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Today",
            bullets: [ReportBullet(text: "Migration", details: ["one\n\ntwo"])])
    ])

    // The middle line must be empty, not six spaces — this text is persisted
    // into StandupReport.markdownBody.
    #expect(
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
            "*Today*", "• Migration", "    ◦ one", "", "      two",
        ])
}

@Test("§7.3 verbatim: nothing in a body is escaped or rewritten")
func bodiesAreEmittedVerbatim() {
    // Every class of string §7.3 names: a ticket key, a function name, an
    // error string, and mrkdwn metacharacters the user typed on purpose.
    let body = "fixed the flaky auth test in TokenRefresher.refresh(): `EOF *before* _end_`"

    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Since last stand-up",
            bullets: [ReportBullet(text: "Auth (PAY-412)", details: [body])])
    ])

    #expect(markdown.hasSuffix("    ◦ " + body))
}

@Test("Sections are separated by exactly one blank line")
func sectionsAreJoinedByASingleBlankLine() {
    let markdown = SlackMarkdown.render([
        ReportSection(title: "One", bullets: [ReportBullet(text: "a")]),
        ReportSection(title: "Two", bullets: [ReportBullet(text: "b")]),
    ])

    #expect(markdown == "*One*\n• a\n\n*Two*\n• b")
    #expect(!markdown.hasSuffix("\n"))
}
```

> **Do not write `#expect(sections.allSatisfy(\.bullets.isEmpty))` anywhere in this task.** It compiles standalone and fails inside the `#expect` macro with "call can throw, but it is not marked with 'try'". Use a key-path `map` compared against a literal array instead.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL at compile time — `cannot find 'SlackMarkdown' in scope`, `cannot find 'ReportSection' in scope`. A compile failure is the correct red state here; there is nothing to link against yet.

- [ ] **Step 3: Write `ReportSection.swift`**

```swift
/// One heading and its bullets, as a report is structured before it is
/// formatted (§7.3, D6).
///
/// **This type is §7.3's split expressed as an interface.** "The app renders
/// markdown from whichever structure came back. Never ask the model to format
/// the final Slack text — formatting is the app's job, and separating them
/// makes output stable." `RawReportSections` produces these from a gathered
/// window with no AI involved; M3-03 produces them from schema-validated AI
/// bullets. Both hand them to the same `SlackMarkdown.render`.
///
/// A `GatheredWindow -> String` renderer would have left M3-03 with nothing to
/// reuse: at the point it renders it holds bullets, not a window, so it would
/// have had to duplicate the emitter or fabricate a window to feed it.
public struct ReportSection: Sendable, Equatable {
    /// The heading, already in its cadence's wording (FR-4, D17).
    public let title: String

    /// May be empty. `SlackMarkdown` renders an empty section rather than
    /// dropping it — "no blockers" is a sentence people say at stand-ups.
    public let bullets: [ReportBullet]

    public init(title: String, bullets: [ReportBullet]) {
        self.title = title
        self.bullets = bullets
    }
}

/// One task's line, plus the user's own words beneath it.
public struct ReportBullet: Sendable, Equatable {
    /// The task line: its title, plus any ticket keys.
    public let text: String

    /// Verbatim user-authored lines beneath `text`, oldest first.
    ///
    /// **Named `details`, not `notes`,** because a blocked task's first detail
    /// is its `blockedReason`, which §3.3 lists as a separate kind from `note`.
    ///
    /// **May be empty, and that is not a defect.** A task moved to `done` with
    /// nothing written about it has nothing to say — D-072 excludes the
    /// machine-authored `created` and `statusChanged` bodies — and D-068
    /// already admits quiet in-progress tasks for the same reason.
    ///
    /// Defaulted because M3-03 builds these from AI bullets, which carry one
    /// line of text and no children.
    public let details: [String]

    public init(text: String, details: [String] = []) {
        self.text = text
        self.details = details
    }
}
```

- [ ] **Step 4: Write `SlackMarkdown.swift`**

```swift
/// D6: "Text formatted for copy → paste into Slack." The one place that
/// decision lives.
///
/// **Slack's `mrkdwn` has no heading syntax.** `## Since last stand-up` pastes
/// into Slack as a literal `##`, so a heading is `*bold*` alone on its line.
/// Bullets are the literal characters `•` and `◦` rather than `-`, because a
/// literal bullet character *is* a bullet in any paste target and does not
/// depend on Slack's composer choosing to convert a hyphen.
///
/// Takes `[ReportSection]` rather than a `GatheredWindow` so M3-03 can render
/// AI-authored bullets through this same function (§7.3: "Never ask the model
/// to format the final Slack text — formatting is the app's job, and
/// separating them makes output stable").
public enum SlackMarkdown {
    /// Two spaces short of the `◦`, so a wrapped detail hangs under its text.
    private static let continuationIndent = "      "

    /// The rendered report: sections in order, one blank line between them, no
    /// trailing newline.
    public static func render(_ sections: [ReportSection]) -> String {
        sections.map(block).joined(separator: "\n\n")
    }

    /// One heading and its bullets.
    ///
    /// **An empty section renders `_None_` rather than being dropped** (D-074).
    /// "No blockers" is a sentence people say at stand-ups, and dropping the
    /// heading throws away information the user wants to speak. It also means
    /// an empty *window* is not a special case at all — it is three headings
    /// that each say `_None_` — so the "honest and usable, not a crash or a
    /// blank string" criterion is met with no branch existing to get wrong.
    private static func block(_ section: ReportSection) -> String {
        let body =
            section.bullets.isEmpty
            ? ["_None_"]
            : section.bullets.flatMap(lines)
        return (["*\(section.title)*"] + body).joined(separator: "\n")
    }

    /// One bullet: its task line, then a `◦` line per detail.
    private static func lines(_ bullet: ReportBullet) -> [String] {
        ["• \(bullet.text)"] + bullet.details.flatMap(detail)
    }

    /// One detail, which may be several lines on screen.
    ///
    /// **`NoteService.addNote` trims only *outer* whitespace and
    /// `NoteComposerView` is a `TextEditor`, so a body can carry interior
    /// newlines.** Emitted naïvely, a note's second line would appear as an
    /// orphan outside any bullet, silently breaking the structure of a document
    /// the user is about to read aloud.
    ///
    /// The first line follows `◦ `; the rest hang beneath it. Every character
    /// the user typed survives — only leading indentation is added, which is
    /// layout, not editing.
    ///
    /// An interior blank line is emitted bare rather than as six spaces, so
    /// nothing persisted into `StandupReport.markdownBody` carries trailing
    /// whitespace.
    ///
    /// **Nothing is escaped, deliberately.** A body containing `*` or `_` will
    /// render with unintended emphasis in Slack. Backslash-escaping it would
    /// put characters on screen the user never typed — visible in M2-03's
    /// *editable* draft and persisted verbatim into `markdownBody` — and "appear
    /// verbatim as the user typed them" is an acceptance criterion of this
    /// task, where correct Slack emphasis is not. When the two conflict,
    /// verbatim wins.
    private static func detail(_ body: String) -> [String] {
        let split = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = split.first else { return [] }
        return ["    ◦ \(first)"]
            + split.dropFirst().map { $0.isEmpty ? "" : continuationIndent + $0 }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`, with no `recorded an issue` lines.

- [ ] **Step 6: Prove the tests can fail (mutation check)**

This repo has shipped tests that compiled, passed, and detected nothing. Confirm these can fail before trusting them.

Temporarily change `continuationIndent` from `"      "` to `"    "` in `SlackMarkdown.swift`, then run `make test 2>&1 | grep "recorded an issue"`.

Expected: exactly two failures — `A multi-line note keeps every line, hanging under the first` and `A blank line inside a note carries no trailing whitespace`.

Revert the change and re-run `make test` to confirm green again. Do not commit the mutation.

- [ ] **Step 7: Lint, format, and commit**

```bash
make format && make lint && make build
```

`make format` may reformat `StenoTests/Notes/EventQueriesTests.swift`, which is pre-existing drift from M1-06 and **not part of this task** — revert it with `git checkout StenoTests/Notes/EventQueriesTests.swift` before committing.

```bash
git add StenoKit/Report/ReportSection.swift StenoKit/Report/SlackMarkdown.swift \
        StenoTests/Report/SlackMarkdownTests.swift
git commit -m "feat: Slack-flavored markdown emission for report sections (M2-02)

Slack's mrkdwn has no heading syntax, so a bold line is the heading and
the bullet characters are literal — pasted text cannot depend on the
composer choosing to convert a hyphen.

Takes [ReportSection] rather than a GatheredWindow so M3-03 renders AI
bullets through the same function, which is what §7.3 means by keeping
formatting the app's job.

Nothing is escaped: a body containing * or _ renders oddly in Slack,
but escaping would put characters the user never typed into the editable
draft and into StandupReport.markdownBody, and verbatim is the
acceptance criterion.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The cadence mapping

Delivers FR-4's report structure and D17's two section sets. Reviewable on its own: a reviewer can reject the mapping without touching Task 1's dialect.

**Files:**
- Create: `StenoKit/Report/RawReportSections.swift`
- Create: `StenoTests/Report/SectionInput.swift`
- Create: `StenoTests/Report/RawReportSectionsTests.swift`

**Interfaces:**
- Consumes: `ReportSection` / `ReportBullet` from Task 1. `GatheredWindow`, `GatheredTask`, `GatheredEvent`, `ReportCadence`, `Status`, and `EventKind.isUserAuthored` already exist from M2-01 and M0-03.
- Produces: `RawReportSections.build(from window: GatheredWindow) -> [ReportSection]`, and the test helper `SectionInput` (`task`, `event`, `window`, `section`) that Task 3 also uses.

- [ ] **Step 1: Write the test fixture**

Create `StenoTests/Report/SectionInput.swift`:

```swift
import Foundation

@testable import StenoKit

/// Literal `GatheredWindow`s for the renderer's tests.
///
/// **No store, no `ModelContainer`, no `ReportFixture`.** `GatheredWindow`,
/// `GatheredTask` and `GatheredEvent` all have public initialisers (D-065), so
/// every case here is literals in and a string out. That is the point of the
/// value-snapshot type, and it keeps this suite independent of SwiftData's
/// behaviour entirely.
///
/// An `enum` namespace rather than free functions because `task` and `window`
/// are exactly the names a future test file would also want at module scope.
enum SectionInput {
    /// Timestamps are arbitrary: no bullet carries one (D-073), so nothing in
    /// the renderer reads them. Event *order* is what matters, and that is the
    /// order of the array passed to `task`.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    static func event(_ body: String, kind: EventKind = .note) -> GatheredEvent {
        GatheredEvent(timestamp: origin, kind: kind, body: body)
    }

    static func task(
        _ title: String,
        status: Status = .todo,
        ticketKeys: [String] = [],
        blockedReason: String? = nil,
        events: [GatheredEvent] = []
    ) -> GatheredTask {
        GatheredTask(
            id: UUID(), title: title, status: status, ticketKeys: ticketKeys,
            blockedReason: blockedReason, events: events)
    }

    static func window(_ cadence: ReportCadence, _ tasks: [GatheredTask]) -> GatheredWindow {
        GatheredWindow(
            projectID: UUID(), cadence: cadence, start: origin,
            end: origin.addingTimeInterval(86_400), tasks: tasks)
    }

    /// The bullets under `title`, or `nil` if no such section was built.
    ///
    /// Looks the section up by name rather than by index so a test that expects
    /// *Blockers* fails with "no such section" if the order changes, instead of
    /// silently asserting against *Today*.
    static func section(_ title: String, of sections: [ReportSection]) -> [ReportBullet]? {
        sections.first { $0.title == title }?.bullets
    }
}
```

- [ ] **Step 2: Write the failing mapping tests**

Create `StenoTests/Report/RawReportSectionsTests.swift`:

```swift
import Testing

@testable import StenoKit

// MARK: - Daily

@Test("FR-4 daily: an in-progress task with notes appears under two headings")
func dailyListsAProgressedInProgressTaskTwice() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Flaky auth test", status: .inProgress,
                    events: [SectionInput.event("was a race in TokenRefresher")])
            ]))

    // The whole point of the two-test membership rule: it says what happened
    // under one heading and what is happening under the other, never both.
    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Flaky auth test", details: ["was a race in TokenRefresher"])])
    #expect(
        SectionInput.section("Today", of: sections) == [ReportBullet(text: "Flaky auth test")])
}

@Test("FR-4 daily: a blocked task's notes go above, its reason under Blockers")
func dailyBlockersCarryTheReasonAndNotTheNotes() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Webhook replay", status: .blocked, blockedReason: "waiting on infra",
                    events: [SectionInput.event("raised INFRA-9")])
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["raised INFRA-9"])])
    #expect(
        SectionInput.section("Blockers", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["waiting on infra"])])
}

@Test("FR-4 daily: a task finished with no notes is still reported as completed")
func dailyReportsADoneTaskThatCarriesOnlyAStatusChange() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Bump pg driver", status: .done,
                    events: [SectionInput.event("In Progress → Done", kind: .statusChanged)])
            ]))

    // The defect this exists for: with membership tested on activity alone,
    // the statusChanged filter empties the task's details and it then matches
    // no daily heading at all — the most reportable thing that happened,
    // silently absent.
    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Bump pg driver")])
}

@Test("A task moved back to todo with nothing written appears under no daily heading")
func dailyOmitsAQuietTodoTask() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Rate limiter", status: .todo,
                    events: [SectionInput.event("In Progress → To Do", kind: .statusChanged)])
            ]))

    // The accepted gap, asserted so it stays a decision rather than becoming a
    // surprise. A bare title under "Since last stand-up" would assert progress
    // that did not happen.
    #expect(sections.map(\.bullets.count) == [0, 0, 0])
}

@Test("A reason captured inside the window is said once, not twice")
func dailyDoesNotRepeatAnInWindowBlockedReason() {
    // The common case, not an exotic one: StatusService.addBlockedReason
    // stamps now(), so a task blocked since the last stand-up has its reason
    // event *inside* the window as well as on GatheredTask.blockedReason.
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Webhook replay", status: .blocked, blockedReason: "waiting on infra",
                    events: [
                        SectionInput.event("raised INFRA-9"),
                        SectionInput.event("waiting on infra", kind: .blockedReason),
                    ])
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["raised INFRA-9"])])
    #expect(
        SectionInput.section("Blockers", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["waiting on infra"])])
}

@Test("A reason from a block that has since lifted is still the user's words")
func anUnblockedTaskKeepsItsFormerBlockedReason() {
    // D-069 leaves GatheredTask.blockedReason nil for anything not currently
    // blocked, so this event is the only carrier of what the user wrote. It
    // must survive, or the report loses words the user typed.
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Webhook replay", status: .inProgress,
                    events: [
                        SectionInput.event("was waiting on infra", kind: .blockedReason),
                        SectionInput.event("creds arrived, unblocked"),
                    ])
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [
                ReportBullet(
                    text: "Webhook replay",
                    details: ["was waiting on infra", "creds arrived, unblocked"])
            ])
}

// MARK: - Periodic

@Test("D17 periodic: every task lands in exactly one section")
func periodicIsAPartition() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .periodic,
            [
                SectionInput.task("Done thing", status: .done),
                SectionInput.task("Doing thing", status: .inProgress),
                SectionInput.task("Blocked thing", status: .blocked),
                SectionInput.task(
                    "Todo thing", status: .todo, events: [SectionInput.event("started poking")]),
            ]))

    // Counted across all sections rather than per-section, so a task rendered
    // twice fails here — which is the property that separates periodic's
    // mapping from daily's.
    #expect(sections.map(\.bullets.count).reduce(0, +) == 4)
    #expect(SectionInput.section("Completed", of: sections)?.map(\.text) == ["Done thing"])
    #expect(
        SectionInput.section("In flight", of: sections)?.map(\.text)
            == ["Doing thing", "Todo thing"])
    #expect(SectionInput.section("Blockers & risks", of: sections)?.map(\.text) == ["Blocked thing"])
}

@Test("D17 periodic: a blocked task's reason comes before its notes")
func periodicBlockersCarryReasonThenNotes() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .periodic,
            [
                SectionInput.task(
                    "Webhook replay", status: .blocked, blockedReason: "waiting on infra",
                    events: [
                        SectionInput.event("raised INFRA-9"),
                        SectionInput.event("waiting on infra", kind: .blockedReason),
                    ])
            ]))

    // Periodic has no second section for the notes to live in, so losing them
    // here would lose the user's words outright — and the in-window reason
    // event must not make the bullet say "waiting on infra" twice.
    #expect(
        SectionInput.section("Blockers & risks", of: sections)
            == [
                ReportBullet(
                    text: "Webhook replay", details: ["waiting on infra", "raised INFRA-9"])
            ])
}

// MARK: - Shared rules

/// One row of the machine-authored-event table.
///
/// Private, so the `@Test` function taking it must be private too — a
/// non-private function with a private parameter type does not compile.
private struct KindCase: Sendable {
    let label: String
    let cadence: ReportCadence
    let heading: String
}

@Test(
    "D-072: machine-authored events never become bullets",
    arguments: [
        KindCase(label: "daily", cadence: .daily, heading: "Since last stand-up"),
        KindCase(label: "periodic", cadence: .periodic, heading: "Completed"),
    ])
private func structuralEventsProduceNoDetails(kind: KindCase) {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            kind.cadence,
            [
                SectionInput.task(
                    "Ship it", status: .done,
                    events: [
                        SectionInput.event("Task created", kind: .created),
                        SectionInput.event("To Do → In Progress", kind: .statusChanged),
                        SectionInput.event("found the leak", kind: .note),
                        SectionInput.event("In Progress → Done", kind: .statusChanged),
                    ])
            ]))

    #expect(
        SectionInput.section(kind.heading, of: sections)?.first?.details == ["found the leak"],
        "\(kind.label): only the user's own words belong in a spoken stand-up")
}

@Test("An empty window still renders every heading", arguments: ReportCadence.allCases)
func anEmptyWindowStillProducesThreeSections(cadence: ReportCadence) {
    let sections = RawReportSections.build(from: SectionInput.window(cadence, []))

    #expect(sections.count == 3)
    #expect(sections.map(\.bullets.count) == [0, 0, 0])
}

@Test("FR-1.5: every ticket key on a task survives into its bullet")
func ticketKeysAreAppendedAndJoined() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task("Two keys", status: .done, ticketKeys: ["PAY-388", "PAY-412"]),
                SectionInput.task("No keys", status: .done),
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)?.map(\.text)
            == ["Two keys (PAY-388, PAY-412)", "No keys"])
}

@Test("The gatherer's task order is preserved, not re-sorted")
func taskOrderIsInherited() {
    // Deliberately not alphabetical and not sorted by status, so a renderer
    // that sorted by either would produce a different order and fail. Running
    // the renderer twice would prove nothing about this.
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task("zebra", status: .done),
                SectionInput.task("apple", status: .done),
                SectionInput.task("mango", status: .done),
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)?.map(\.text)
            == ["zebra", "apple", "mango"])
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test`
Expected: FAIL at compile time — `cannot find 'RawReportSections' in scope`.

- [ ] **Step 4: Write `RawReportSections.swift`**

```swift
/// FR-4's report structure, built from a gathered window with no AI (§7.4).
///
/// §7.4 makes this a P0 path built *before* the AI path, not an error handler
/// bolted on after it: "The user must never arrive at a stand-up
/// empty-handed because of a network error." Nothing here imports `Foundation`,
/// reads a clock, formats a date, or touches a store — which is what makes
/// "renders with no network and no API key configured" true by construction
/// rather than by test.
///
/// **A stenographer, not an editor.** It selects, orders, and lays out. §7.3's
/// constraint that "fixed the flaky auth test" must not become "enhanced
/// authentication reliability" is written about the model, but the discipline
/// binds harder here: this type has no licence to rephrase at all.
public enum RawReportSections {
    /// D17's two section sets, selected by the window's own cadence.
    ///
    /// Task order inside every section is the order `ReportGatherer` already
    /// established — `createdAt`, then `id.uuidString`. Preserved, never
    /// recomputed: ordering has exactly one owner and it is not this file.
    /// Every section is built by filtering `window.tasks` in place, so no
    /// `Dictionary` or `Set` iteration order can leak into the output.
    public static func build(from window: GatheredWindow) -> [ReportSection] {
        switch window.cadence {
        case .daily:
            daily(window.tasks)
        case .periodic:
            periodic(window.tasks)
        }
    }

    /// FR-4's daily set: a DSU's three questions.
    ///
    /// **The three sections are not one partition, and that is deliberate.**
    /// FR-4 defines them by two different tests — *Since last stand-up* is
    /// "completed and progressed work" (window activity), while *Today* is
    /// "current IN-PROGRESS tasks" and *Blockers* is "BLOCKED tasks with
    /// reasons" (current status). A task that is in progress *and* was worked
    /// on satisfies both, so it appears twice — and says something different
    /// each time, which is how a stand-up is actually spoken: "yesterday I
    /// found the race; today I'm still on it." §7.3's daily schema agrees:
    /// the same `task_id` may appear in more than one of its three arrays.
    ///
    /// The rejected alternative was a status partition, the literal reading of
    /// §7.4's "raw events grouped by status". It drops a week of notes on a
    /// task that is still in progress, because that task would appear only
    /// under *Today*.
    private static func daily(_ tasks: [GatheredTask]) -> [ReportSection] {
        [
            ReportSection(
                title: "Since last stand-up",
                bullets: tasks.filter(progressed).map { bullet($0, details: authored($0)) }),
            ReportSection(
                title: "Today",
                bullets: tasks.filter { $0.status == .inProgress }.map { bullet($0) }),
            ReportSection(
                title: "Blockers",
                bullets: tasks.filter { $0.status == .blocked }
                    .map { bullet($0, details: reason($0)) }),
        ]
    }

    /// FR-4's periodic set: D17's "summary", not a status ping.
    ///
    /// **An exhaustive partition, where `daily` is deliberately not one.** Each
    /// task appears exactly once, and the `switch` has no `default`, so a fifth
    /// `Status` is a compile error here rather than a silent omission from
    /// every periodic report — the construction `ReportGatherer.isReportable`
    /// already uses for the same reason.
    ///
    /// Not a rename of `daily`'s headings: *Completed* means finished, where
    /// *Since last stand-up* means everything that moved. Reading a fortnight
    /// of in-flight work under a heading that says "Completed" would be a false
    /// claim about the work. D17 and FR-4 both insist the distinction is real.
    ///
    /// **A `.todo` task with events goes under *In flight*.** D-068 admits it
    /// to the window and a partition has to place it somewhere; it is neither
    /// completed nor blocked, and the work demonstrably happened. A slightly
    /// loose heading is a smaller violation than dropping the user's words.
    private static func periodic(_ tasks: [GatheredTask]) -> [ReportSection] {
        var completed: [ReportBullet] = []
        var inFlight: [ReportBullet] = []
        var blocked: [ReportBullet] = []

        for task in tasks {
            switch task.status {
            case .done:
                completed.append(bullet(task, details: authored(task)))
            case .inProgress, .todo:
                inFlight.append(bullet(task, details: authored(task)))
            case .blocked:
                blocked.append(bullet(task, details: reason(task) + authored(task)))
            }
        }

        return [
            ReportSection(title: "Completed", bullets: completed),
            ReportSection(title: "In flight", bullets: inFlight),
            ReportSection(title: "Blockers & risks", bullets: blocked),
        ]
    }

    /// Whether `task` belongs under *Since last stand-up*.
    ///
    /// **Two clauses, because FR-4's phrase is two words: "completed *and*
    /// progressed work".** An activity-only test loses the task a user
    /// captured, finished, and never wrote a note on — its only event in the
    /// window is the `statusChanged` that `authored` excludes, so it would
    /// appear under no daily heading at all despite being the most reportable
    /// thing that happened all day.
    ///
    /// Testing `.done` on its own is safe here: D-068 only admits a `.done`
    /// task to the window when it had activity inside it.
    ///
    /// **One accepted gap, stated rather than hidden.** A task now `.todo`
    /// whose only window event is a status change — moved back from in
    /// progress, with nothing written — appears under no daily heading. A bare
    /// title under *Since last stand-up* would assert progress that did not
    /// happen. It does appear under `periodic`'s *In flight*, which must place
    /// every task somewhere. If that proves wrong in use, the fix is a third
    /// clause here, not a change to what counts as an authored event.
    private static func progressed(_ task: GatheredTask) -> Bool {
        task.status == .done || !authored(task).isEmpty
    }

    /// The user's own words from this task's window, oldest first.
    ///
    /// **`created` and `statusChanged` are excluded** (D-072). Their bodies are
    /// `"Task created"` and `"In Progress → Done"` — machine-authored strings
    /// the user would otherwise read aloud to their team. Under both mappings a
    /// task's status is already expressed by *which section it is in*, so
    /// emitting the transition as well is redundant rather than faithful.
    /// Verbatim fidelity is a constraint on the user's words; it does not
    /// oblige this type to speak the app's.
    ///
    /// Filters on `isUserAuthored` rather than re-listing kinds, so M4's
    /// `externalUpdate` — which cannot occur before the connector that writes
    /// it exists — gets a deliberate decision from whoever adds it, at the
    /// point they can judge whether a Jira comment belongs in a spoken
    /// stand-up.
    private static func authored(_ task: GatheredTask) -> [String] {
        task.events.filter { isBullet($0, on: task) }.map(\.body)
    }

    /// Whether `event` becomes a detail line on `task`'s bullet.
    ///
    /// **A currently-blocked task's `blockedReason` events are excluded, because
    /// `reason(_:)` already says them.** `StatusService.addBlockedReason` stamps
    /// `now()`, so a task blocked since the last stand-up — the ordinary case,
    /// not an exotic one — carries its reason both as an event inside the window
    /// and on `GatheredTask.blockedReason` (D-069). Without this the daily
    /// report says the reason under *Since last stand-up* and again under
    /// *Blockers*, and the periodic report says it twice inside a single bullet.
    ///
    /// **Conditioned on status rather than dropping the kind outright**, because
    /// D-069 leaves `blockedReason` `nil` for anything not currently blocked. On
    /// a task that was blocked during the window and has since been unblocked,
    /// the event is the *only* carrier of what the user wrote; filtering the
    /// kind unconditionally would delete their words rather than de-duplicate
    /// them.
    ///
    /// **One accepted gap**, consistent with the one D-069 already takes: a task
    /// blocked, unblocked, and re-blocked inside one window shows only the
    /// current reason, and the superseded one is dropped rather than listed as
    /// a note.
    private static func isBullet(_ event: GatheredEvent, on task: GatheredTask) -> Bool {
        guard event.kind.isUserAuthored else { return false }
        return !(task.status == .blocked && event.kind == .blockedReason)
    }

    /// A blocked task's reason as zero or one detail line.
    ///
    /// Returns an array rather than `String?` so both call sites concatenate
    /// rather than branch. `ReportGatherer` guarantees this is `nil` for any
    /// task not currently `.blocked` (D-069), so the two are never combined by
    /// accident.
    private static func reason(_ task: GatheredTask) -> [String] {
        task.blockedReason.map { [$0] } ?? []
    }

    /// The task line: title, then its ticket keys.
    ///
    /// `ticketKeys` is plural and already sorted (D-065): FR-1.5's extractor
    /// creates one ref per key, so a task whose notes mention two tickets
    /// carries two, and dropping either would lose a key the user has to say
    /// out loud. The parenthesis is omitted entirely when there are none —
    /// never a bare `()`.
    private static func bullet(_ task: GatheredTask, details: [String] = []) -> ReportBullet {
        let keys = task.ticketKeys.isEmpty ? "" : " (\(task.ticketKeys.joined(separator: ", ")))"
        return ReportBullet(text: task.title + keys, details: details)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`, with no `recorded an issue` lines.

- [ ] **Step 6: Prove the parameterized test actually runs**

`make test` never prints parameterized cases, so `structuralEventsProduceNoDetails` passing and never running look identical. Force it to fail.

Temporarily change `authored` to `task.events.map(\.body)` (dropping the `isUserAuthored` filter), then run:

```bash
make test 2>&1 | grep -E "machine-authored|recorded an issue"
```

Expected: `Test "D-072: machine-authored events never become bullets" recorded an issue with 1 argument(s)` appearing **twice** — once per argument — alongside failures in `FR-4 daily: a task finished with no notes is still reported as completed` and `A task moved back to todo with nothing written appears under no daily heading`.

Revert and re-run `make test` to confirm green. Do not commit the mutation.

- [ ] **Step 7: Second mutation — the periodic partition**

Temporarily change the periodic `switch` to `case .done, .todo:` / `case .inProgress:`, then run `make test 2>&1 | grep "recorded an issue"`.

Expected: `D17 periodic: every task lands in exactly one section` fails on two separate expectations.

Revert and confirm green.

- [ ] **Step 8: Lint, format, and commit**

```bash
make format && make lint && make build
git checkout StenoTests/Notes/EventQueriesTests.swift 2>/dev/null || true
git add StenoKit/Report/RawReportSections.swift StenoTests/Report/SectionInput.swift \
        StenoTests/Report/RawReportSectionsTests.swift
git commit -m "feat: FR-4's report structure for both cadences (M2-02)

The daily sections are not a partition: FR-4 defines 'Since last
stand-up' by window activity and 'Today'/'Blockers' by current status,
so a task that is in progress and was worked on appears under two
headings and says something different under each. That is how a DSU is
spoken, and §7.3's daily schema permits the same task_id in more than
one array.

Periodic is a real remapping rather than a heading rename — Completed
means finished, where Since last stand-up means everything that moved —
and an exhaustive switch over Status, so a fifth status is a compile
error rather than a silent omission from every periodic report.

Only user-authored events become bullets. 'Task created' and
'In Progress → Done' are the app's words, and the user reads this
aloud.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: End-to-end goldens and documentation

Delivers the contract a reviewer can actually read — the complete report for a realistic window — plus the decision records. Reviewable on its own: the goldens either look like something you would say at a stand-up or they do not.

**Files:**
- Create: `StenoTests/Report/RawReportGoldenTests.swift`
- Modify: `docs/DECISIONS.md` (append D-070…D-074 before the "Open — decided by the task that owns them" heading)
- Modify: `docs/ARCHITECTURE.md` (§5's `Report/` line)
- Modify: `docs/tasks/README.md` (lines 70–71)

**Interfaces:**
- Consumes: `RawReportSections.build(from:)` and `SectionInput` from Task 2; `SlackMarkdown.render(_:)` from Task 1.
- Produces: nothing consumed by later tasks. M2-03 will call the two functions Tasks 1 and 2 already produced.

- [ ] **Step 1: Write the golden tests**

Create `StenoTests/Report/RawReportGoldenTests.swift`:

```swift
import Testing

@testable import StenoKit

/// One realistic window, rendered under both cadences.
///
/// Covers all four statuses, a task with two ticket keys' worth of structure, a
/// task with no keys, machine-authored events that must not appear, a quiet
/// blocked task whose reason lives outside the window (D-069), and a `.todo`
/// task the two cadences file differently.
private func goldenTasks() -> [GatheredTask] {
    [
        SectionInput.task(
            "Flaky auth test on checkout", status: .done, ticketKeys: ["PAY-412"],
            events: [
                SectionInput.event("Task created", kind: .created),
                SectionInput.event("was a race in TokenRefresher, not the test"),
                SectionInput.event("To Do → In Progress", kind: .statusChanged),
                SectionInput.event("PR merged after review"),
            ]),
        SectionInput.task(
            "Bump pg driver to 15.4", status: .done,
            events: [SectionInput.event("In Progress → Done", kind: .statusChanged)]),
        SectionInput.task(
            "Rate limiter tuning", status: .inProgress, ticketKeys: ["PAY-388"],
            events: [SectionInput.event("dropped the window to 30s")]),
        SectionInput.task(
            "Spike: cache warming", status: .todo,
            events: [SectionInput.event("read the redis docs, not obviously worth it")]),
        // The reason is present both as an in-window event and on
        // blockedReason, which is what StatusService.addBlockedReason actually
        // produces for a task blocked since the last stand-up. The expected
        // output below says it exactly once; that it did not change when this
        // event was added is the assertion.
        SectionInput.task(
            "Webhook replay", status: .blocked, ticketKeys: ["PAY-401"],
            blockedReason: "waiting on infra for the DLQ credentials",
            events: [
                SectionInput.event(
                    "waiting on infra for the DLQ credentials", kind: .blockedReason)
            ]),
    ]
}

private func goldenMarkdown(_ cadence: ReportCadence) -> String {
    SlackMarkdown.render(
        RawReportSections.build(from: SectionInput.window(cadence, goldenTasks())))
}

@Test("FR-4 + D6: a daily window renders its whole report")
func aDailyWindowRendersItsGoldenMarkdown() {
    // Rate limiter tuning appears twice — with its note above, and as a bare
    // title under Today. That is the daily mapping's whole claim.
    #expect(
        goldenMarkdown(.daily) == """
            *Since last stand-up*
            • Flaky auth test on checkout (PAY-412)
                ◦ was a race in TokenRefresher, not the test
                ◦ PR merged after review
            • Bump pg driver to 15.4
            • Rate limiter tuning (PAY-388)
                ◦ dropped the window to 30s
            • Spike: cache warming
                ◦ read the redis docs, not obviously worth it

            *Today*
            • Rate limiter tuning (PAY-388)

            *Blockers*
            • Webhook replay (PAY-401)
                ◦ waiting on infra for the DLQ credentials
            """)
}

@Test("D17 + D6: the same window renders differently under periodic cadence")
func aPeriodicWindowRendersItsGoldenMarkdown() {
    // Same tasks, same words, different filing: nothing appears twice, and the
    // todo spike sits under In flight rather than alongside completed work.
    #expect(
        goldenMarkdown(.periodic) == """
            *Completed*
            • Flaky auth test on checkout (PAY-412)
                ◦ was a race in TokenRefresher, not the test
                ◦ PR merged after review
            • Bump pg driver to 15.4

            *In flight*
            • Rate limiter tuning (PAY-388)
                ◦ dropped the window to 30s
            • Spike: cache warming
                ◦ read the redis docs, not obviously worth it

            *Blockers & risks*
            • Webhook replay (PAY-401)
                ◦ waiting on infra for the DLQ credentials
            """)
}

@Test("D17: the two cadences do not merely rename each other's headings")
func theTwoCadencesDisagreeOnMoreThanTitles() {
    // Stripping the headings leaves different documents, so a future
    // "simplification" that maps periodic onto daily's sections fails here
    // rather than passing both golden tests with swapped titles.
    let bulletsOnly = { (markdown: String) in
        markdown.split(separator: "\n").filter { !$0.hasPrefix("*") }
    }

    #expect(bulletsOnly(goldenMarkdown(.daily)) != bulletsOnly(goldenMarkdown(.periodic)))
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`, no `recorded an issue`.

These tests are written after their implementation rather than before it, deliberately: a golden's value is that a human reads it and agrees it sounds like a stand-up. Writing the expected string before the emitter exists would mean inventing output rather than reviewing it. The red state that matters here is Step 3's.

- [ ] **Step 3: Prove the goldens can fail**

Temporarily change `"Blockers & risks"` to `"Blockers"` in `RawReportSections.periodic`, then run `make test 2>&1 | grep "recorded an issue"`.

Expected: `D17 + D6: the same window renders differently under periodic cadence` fails. Revert and confirm green.

- [ ] **Step 4: Append the decision records**

Add these to `docs/DECISIONS.md` immediately before the `## Open — decided by the task that owns them` heading, following the existing entry format exactly:

```markdown
### D-070 — The daily sections are not a partition
**2026-09-08** · M2-02 · **Status:** accepted

Under `daily` cadence a task may appear under two headings. *Since last stand-up* takes any task
that is `.done` or has a user-authored event in the window; *Today* takes every `.inProgress`
task; *Blockers* takes every `.blocked` task. A task appearing twice never repeats itself — the
first carries its notes, the others carry a title and, for blockers, the reason.

**FR-4 defines these three sections by two different criteria, and both readings are its own.**
*Since last stand-up* is "completed and progressed work" — window activity. *Today* is "current
IN-PROGRESS tasks" and *Blockers* is "BLOCKED tasks with reasons" — current status. A task that
is in progress and was worked on satisfies both, and that is exactly how a stand-up is spoken:
"yesterday I found the race in TokenRefresher; today I'm still on it." §7.3's daily schema agrees
outright — the same `task_id` may appear in more than one of its three arrays.

**The membership test for the first section has two clauses because FR-4's phrase has two words.**
An activity-only test loses the task a user captured, finished, and never wrote a note on: D-072
excludes its `statusChanged` body, leaving it with no details and no matching heading. The most
reportable thing that happened all day would be silently absent.

**One accepted gap, stated rather than hidden:** a task now `.todo` whose only window event is a
status change appears under no daily heading. A bare title under *Since last stand-up* would
assert progress that did not happen. It does appear under `periodic`'s *In flight*, which is a
partition and must place every task somewhere.

**Alternatives:** a status partition, the literal reading of §7.4's "raw events grouped by status"
— rejected because a task worked on all week and still in progress would appear only under
*Today*, dropping the week's notes from the report entirely.

---

### D-071 — Periodic is a real remapping, not a heading rename
**2026-09-08** · M2-02 · **Status:** accepted

Under `periodic` cadence, *Completed* takes `.done`, *In flight* takes `.inProgress` and `.todo`,
and *Blockers & risks* takes `.blocked`. Written as an exhaustive `switch` over `Status` with no
`default`, so every task lands in exactly one section and a fifth status is a compile error here
rather than a silent omission from every periodic report.

**The headings are not synonyms for daily's.** *Completed* means finished, where *Since last
stand-up* means everything that moved. Emitting a fortnight of in-flight work under a heading
that says "Completed" would be a false claim about the work — and D17 and FR-4 both insist the
daily/periodic distinction is real ("a daily DSU is a status ping, a biweekly sync is a summary").

**`todo`-with-events goes under *In flight*.** D-068 admits such a task to the window, and a
partition must place it. It is neither completed nor blocked, and the work demonstrably happened;
a slightly loose heading is a smaller violation than dropping the user's words.

**The blockers asymmetry between the two cadences is forced, not incidental.** *Blockers* carries
reason-only under daily and reason-plus-notes under periodic, because under daily a blocked task's
notes already appear under *Since last stand-up* and under periodic there is no second section for
them to live in. Making the two "consistent" means choosing between duplicating the notes and
losing them.

**Alternatives:** rename daily's headings and keep its mapping — rejected as a false label on a
fortnight of work; group by theme as §7.3 requires of the model — impossible without a model, and
the task file accepts that a periodic raw window will be long (M3-03 is what makes it concise).

---

### D-072 — Only user-authored events become bullets
**2026-09-08** · M2-02 · **Status:** accepted

The renderer's detail lines come from events where `EventKind.isUserAuthored` is true — `note` and
`blockedReason`. `created` and `statusChanged` produce no bullet.

**Their bodies are the app's words, not the user's.** `CaptureService` writes `"Task created"` and
`StatusTransition.eventBody` writes `"In Progress → Done"`. This output is read aloud to a team.
Under both D-070's and D-071's mappings a task's status is already expressed by *which section it
is in*, so emitting the transition as well is redundant rather than faithful. §7.3's verbatim
constraint binds the user's words; it does not oblige the app to speak its own.

**Filtered through `isUserAuthored` rather than by re-listing kinds**, which is the seam D-045
already established for "did the user type this". M4's `externalUpdate` is therefore excluded by
default and gets a deliberate decision from whoever adds the connector that writes it, at the
point they can judge whether a Jira comment belongs in a spoken stand-up.

**Consequence:** a task moved to `done` with no notes renders as a title with no details. That is
honest — the user wrote nothing — and it is the same empty-details case D-068 already forced on
this renderer for quiet in-progress tasks. It is also why D-070's membership test needs its
`.done` clause.

**Alternatives:** render every kind verbatim — rejected because the user then reads "Task created"
to their team; render `statusChanged` only — rejected as redundant with the section heading under
daily, and it was the weaker half of the pair.

---

### D-073 — Slack `mrkdwn`, with literal bullet characters and no escaping
**2026-09-08** · M2-02 · **Status:** accepted

`SlackMarkdown` emits a heading as `*Title*` alone on its line, bullets as the literal characters
`•` and `◦`, an empty section as `_None_`, one blank line between sections, and no trailing
newline. User-authored bodies are never escaped. No bullet carries a timestamp.

**Slack's `mrkdwn` has no heading syntax** — `## Since last stand-up` pastes in as a literal `##`
— so bold is the only heading available. Literal bullet characters are used rather than `-`
because a literal bullet *is* a bullet in any paste target, with no dependence on Slack's composer
choosing to convert a hyphen on paste.

**Nothing is escaped, deliberately.** A body containing `*` or `_` renders with unintended
emphasis in Slack. Backslash-escaping it would put characters on screen the user never typed —
visible in M2-03's *editable* draft and persisted into `StandupReport.markdownBody` — and "ticket
keys, service names, function names, and error strings appear verbatim as the user typed them" is
an acceptance criterion of M2-02, where correct Slack emphasis is not.

**A multi-line body hangs rather than escaping its bullet.** `NoteService.addNote` trims only
outer whitespace and `NoteComposerView` is a `TextEditor`, so interior newlines are reachable from
the UI. The first line follows `◦ `, the rest are indented six spaces; an interior blank line is
emitted bare so nothing persisted carries trailing whitespace. Every character survives — only
leading indentation is added, which is layout, not editing.

**Omitting timestamps is what makes determinism structural.** With no date formatting anywhere,
the renderer has no locale or timezone input at all, and "same window, same markdown, every time"
follows from the code's shape rather than from a test that reruns it.

**Alternatives:** CommonMark (`##`, `-`) — rejected because D6's paste target is Slack and `##`
would appear literally; escaping metacharacters — rejected against the verbatim criterion above.

---

### D-074 — Every section always renders, so the empty window is not a special case
**2026-09-08** · M2-02 · **Status:** accepted

`SlackMarkdown` emits every section it is given, and an empty one renders `_None_` beneath its
heading rather than being dropped.

**"No blockers" is a sentence people say at stand-ups.** Omitting the heading throws away
information the user wants to speak, which is the opposite of what a recall tool is for.

**It also removes a branch rather than adding one.** M2-02's acceptance criterion — "an empty
window produces something honest and usable, not a crash or a blank string" — is satisfied with no
empty-window code path at all: a window with no tasks is three headings that each say `_None_`.
A dedicated "no activity" line would have been a branch reachable only in that one case, which is
precisely the code that rots untested.

**Alternatives:** omit empty sections — loses the spoken "no blockers" and needs a special case
for the all-empty window anyway; a dedicated replacement line when all three are empty — friendlier
by a few words, at the cost of the only branch this design otherwise does not have.
```

- [ ] **Step 5: Update ARCHITECTURE.md**

In §5's file tree, change:

```
  Report/         window computation (exists, M2-01); renderers  (M2-02)
```

to:

```
  Report/         window computation (M2-01); section mapping and Slack
                  markdown (M2-02)                              (exists)
```

- [ ] **Step 6: Update the task README checkboxes**

In `docs/tasks/README.md`, tick both rows. M2-01 merged in #22 without being ticked, and CLAUDE.md's "Working a task" step 4 makes clearing that debt part of this PR.

```markdown
- [x] [M2-01](M2-01-report-window.md) — window computation and event gathering (D8)
- [x] [M2-02](M2-02-raw-report-renderer.md) — deterministic markdown for both cadences; also the §7.4 fallback
```

- [ ] **Step 7: Full gate, then commit**

```bash
make build && make test && make lint
git checkout StenoTests/Notes/EventQueriesTests.swift 2>/dev/null || true
git add StenoTests/Report/RawReportGoldenTests.swift docs/DECISIONS.md \
        docs/ARCHITECTURE.md docs/tasks/README.md
git commit -m "test: golden reports for both cadences, and M2-02's decisions (M2-02)

The goldens are the part a human can actually review: a complete report
for a realistic window, which either sounds like something you would say
at a stand-up or does not. The third test strips the headings and
compares what is left, so a future change that maps periodic onto
daily's sections fails rather than passing both goldens with renamed
titles.

Ticks M2-01's README row as well as M2-02's — it merged in #22 without
being ticked, and §9.5 forbids the direct commit to main that would
otherwise fix it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Open the PR and stop**

Push the branch and open a PR against `main`. The body must state:

- What changed and why, per the commit messages above.
- The five new decisions (D-070…D-074), with the two that a reviewer is most likely to disagree with called out: **a task can appear under two daily headings** (D-070) and **`statusChanged` never becomes a bullet** (D-072).
- The accepted gap in D-070 — a `.todo` task with only a status change appears under no daily heading.
- That M2-01's README row is ticked here, and why it could not be ticked in its own PR.
- That no requirement was deviated from. FR-4's report structure, §7.4's fallback, and D6/D17 are all implemented as written; the two-clause daily membership rule is FR-4's own phrase "completed and progressed work" read literally, not a departure from it.

**Do not merge.** The user reviews and merges (CLAUDE.md §1).

---

## Self-Review

**Spec coverage.** §1 (three files, two steps) → Tasks 1–2. §2 (the API) → Task 1 Steps 3–4, Task 2 Step 4. §3.1 (user-authored only) → Task 2, D-072. §3.2 (daily) → Task 2, D-070. §3.3 (periodic) → Task 2, D-071. §3.4 (ticket keys) → Task 2, `bullet`. §4 (emission, multi-line, no escaping, `_None_`) → Task 1, D-073/D-074. §5 (determinism) → structural, with the ordering test in Task 2 Step 2 and the mutation checks in Tasks 1 and 2. §6 (test plan) → all three tasks. §8 (documentation) → Task 3 Steps 4–6. §9 (out of scope) → nothing in any task touches AI, UI, clipboard, or timestamps.

**Placeholders.** None. Every code step carries complete, compiled source; every command is runnable as written.

**Type consistency.** `ReportSection(title:bullets:)`, `ReportBullet(text:details:)`, `SlackMarkdown.render(_:)`, `RawReportSections.build(from:)`, and `SectionInput.{origin,event,task,window,section}` are spelled identically in every task that uses them. `details` is never called `notes`. The `_None_`, `•`, `◦`, four-space and six-space literals match between Task 1's implementation, Task 1's tests, and Task 3's goldens.

**Verification status.** Every code block in this plan was compiled in the real targets and run before the plan was written — `make build`, `make test`, and `make lint --strict` all green — and each task's mutation check was executed and observed to fail as described. The `#expect`/`allSatisfy` incompatibility called out in the Global Constraints was found that way, not predicted.
