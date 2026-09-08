# M2-02 — Raw Report Renderer: design

**Task:** [`docs/tasks/M2-02-raw-report-renderer.md`](../../tasks/M2-02-raw-report-renderer.md)
**Branch:** `feat/raw-report-renderer`
**Requirements:** FR-4 report structure, §7.3 (the discipline, not the call), §7.4, D6, D17, D18
**Date:** 2026-09-08

Turn a `GatheredWindow` into Slack-flavored markdown, in both cadence shapes, with no AI, no
network, and no store. This is §7.4's fallback, built before the AI path because §7.4 says to
build it first — and it is the whole of M2's value: a user with no API key can run a real
stand-up from it.

The renderer is a stenographer. It selects, orders, and lays out. It does not summarize,
compress, rephrase, or normalize.

---

## 1. Three files, two pure steps

`ARCHITECTURE.md` §5 reserves `StenoKit/Report/` for "window computation (M2-01); renderers
(M2-02)". This task fills the second half.

| File | Responsibility | Depends on |
|---|---|---|
| `Report/ReportSection.swift` | The intermediate structure: sections of bullets | nothing |
| `Report/RawReportSections.swift` | `GatheredWindow` → `[ReportSection]`; cadence lives here | domain enums, `GatheredWindow` |
| `Report/SlackMarkdown.swift` | `[ReportSection]` → `String`; D6 lives here | `ReportSection` |

Both steps are pure functions on value types: no `ModelContext`, no injected clock, no
`Foundation` beyond `String`. Nothing is `@MainActor`, because nothing here touches a
`ModelContext`.

### Why two steps rather than one

§7.3 states the split as a requirement in its own right:

> The app renders markdown from whichever structure came back. Never ask the model to format
> the final Slack text — formatting is the app's job, and separating them makes output stable.

M3-03's task file says it will be "rendering markdown from the returned structure, reusing
M2-02's renderer". That sentence only has a referent if the emitter takes a structure rather
than a `GatheredWindow` — M3-03 has no `GatheredWindow` at the point it renders, it has
schema-validated AI bullets. A single `GatheredWindow -> String` function would force M3-03 to
either duplicate the emitter or fabricate a fake window, and it would do so inside a task whose
review gate is about prompt construction.

The seam also splits the tests where the defects differ: a mapping bug puts the wrong task under
the wrong heading, an emission bug uses the wrong bullet character. One suite each.

### Why not a `ReportRenderer` protocol

Rejected. `ARCHITECTURE.md` §2 rule 4 puts a protocol behind *every external call* so it has a
test double; nothing here is external and nothing needs doubling. There is no runtime swap
either — cadence selects a branch inside one function, not an implementation. The AI path is not
a second renderer; it is a second source of `[ReportSection]`. Adding the protocol when a second
conformance actually exists is cheap; carrying it now is not.

---

## 2. The API

```swift
/// One heading and its bullets, as the report is structured before it is
/// formatted (§7.3: the app renders markdown from the structure).
public struct ReportSection: Sendable, Equatable {
    public let title: String
    public let bullets: [ReportBullet]

    public init(title: String, bullets: [ReportBullet])
}

/// One task's line, plus the user's own words beneath it.
public struct ReportBullet: Sendable, Equatable {
    /// The task line: title, plus its ticket keys.
    public let text: String

    /// Verbatim user-authored lines beneath it. May be empty.
    public let details: [String]

    public init(text: String, details: [String] = [])
}

/// FR-4's report structure, from a gathered window, with no AI (§7.4).
public enum RawReportSections {
    public static func build(from window: GatheredWindow) -> [ReportSection]
}

/// D6: text formatted for copy → paste into Slack.
public enum SlackMarkdown {
    public static func render(_ sections: [ReportSection]) -> String
}
```

`details` rather than `notes`, because a blocked task's first detail is its `blockedReason`,
which §3.3 distinguishes from a note. M3-03 will construct `ReportBullet`s with `details` empty —
the AI returns one `text` per bullet — which is why `details` has a default.

M2-03 composes the two directly:

```swift
let markdown = SlackMarkdown.render(RawReportSections.build(from: window))
```

No third convenience name wraps those two calls. A `RawReport.markdown(for:)` façade would be a
name to learn and a file to open for no behaviour, and M3-03 would not use it — it calls
`SlackMarkdown.render` with its own sections.

---

## 3. The mapping

`build(from:)` switches on `window.cadence` (D17). Task order inside every section is the order
`ReportGatherer` already established — `createdAt`, then `id.uuidString`, per M2-01's
`precedes` — **preserved, never recomputed**. Ordering has exactly one owner, and it is not this
file.

### 3.1 Only user-authored events become bullets

Details come from events where `EventKind.isUserAuthored` is true: `note` and `blockedReason`.

`created` and `statusChanged` are excluded. Their bodies are `"Task created"` and
`"In Progress → Done"` (`CaptureService`, `StatusTransition.eventBody`) — machine-authored
strings that the user would then read aloud to their team. Under §3's mapping a task's status is
already expressed by *which section it is in*, so emitting the transition as well is redundant
rather than faithful. Verbatim fidelity is a constraint on the user's words; it does not oblige
the renderer to speak the app's.

The filter calls `isUserAuthored` rather than re-listing kinds, so `externalUpdate` — which
cannot occur before M4 — gets a deliberate decision from whoever adds the connector that
produces it, at the point where they can judge whether a Jira comment belongs in a spoken
stand-up.

**Consequence, stated rather than discovered:** a task moved to `done` with no notes yields a
bullet with empty `details`. That is honest — the user wrote nothing — and it is the same
empty-details case D-068 already forced on this renderer for quiet in-progress tasks.

### 3.2 Daily — three sections, membership by two different tests

FR-4's daily sections are not defined by one criterion. *Since last stand-up* is
"completed and progressed work" — window activity. *Today* is "current IN-PROGRESS tasks" and
*Blockers* is "BLOCKED tasks with reasons" — current status. A task that is in progress *and*
had notes this week satisfies both.

| Section | Members | `details` |
|---|---|---|
| `Since last stand-up` | `status == .done`, **or** ≥1 user-authored event in the window | those bodies, oldest first |
| `Today` | `status == .inProgress` | none |
| `Blockers` | `status == .blocked` | `blockedReason` if present, else empty |

The membership test for the first section is two clauses because FR-4's phrase is two words:
"completed **and** progressed work". An activity-only test loses the task a user captured,
finished, and never wrote a note on — its only window event is the `statusChanged` that D-072
excludes, so it would appear under no daily heading at all despite being the most reportable
thing that happened. `.done` is safe to test on its own here: D-068 only admits a `.done` task to
the window when it had activity inside it.

**One accepted gap, stated rather than hidden.** A task now `.todo` whose only window event is a
status change — moved back from in progress, with nothing written — appears under no daily
heading. It is not completed, not in progress, not blocked, and the user wrote nothing about it,
so a bare title under *Since last stand-up* would assert progress that did not happen. It does
appear under periodic's *In flight*, because that mapping is a partition and must place every
task somewhere. If this proves wrong in use, the fix is a fourth clause here, not a change to
D-072.

**A task may appear in two sections, and never says the same thing twice.** That is how a DSU is
spoken: "yesterday I found the race in TokenRefresher; today I'm still on it." *Since last
stand-up* carries what happened; *Today* carries only the title, because the work was already
described above. §7.3's daily schema agrees — the same `task_id` may appear in more than one of
its three arrays.

The rejected alternative was a status partition, where each task lands in exactly one section by
current status. It is the more literal reading of §7.4's "raw events grouped by status", and it
is wrong: a task worked on all week and still in progress would appear only under *Today*, with
its week of notes dropped from the report entirely.

### 3.3 Periodic — an exhaustive partition

| Section | Members | `details` |
|---|---|---|
| `Completed` | `.done` | user-authored events in window |
| `In flight` | `.inProgress`, `.todo` | user-authored events in window |
| `Blockers & risks` | `.blocked` | `blockedReason` first, then user-authored events in window |

Written as a `switch` over `Status` with no `default`, so every task lands in exactly one section
and a fifth status added later is a compile error here rather than a silent omission from every
periodic report — the same construction M2-01 used for `isReportable`.

Periodic is a genuinely different mapping, not a rename of daily's headings. D17 and FR-4 both
insist the distinction is real ("a daily DSU is a status ping, a biweekly sync is a summary"),
and the headings are not synonyms: *Completed* means finished, where *Since last stand-up* means
everything that moved. Reading a fortnight of activity under a heading that says "Completed"
would be a false claim about the work.

**`todo`-with-events goes under *In flight*.** D-068 includes such a task in the window, and the
partition must give it a home. It is not completed and it is not blocked; the work demonstrably
happened. A slightly loose heading is a smaller violation than dropping the user's words, which
is the one failure this renderer must not have.

**The blockers asymmetry is forced, not incidental.** *Blockers* carries reason-only under daily
and reason-plus-notes under periodic, because under daily a blocked task's notes already appear
under *Since last stand-up* and under periodic there is no second section for them to live in.
Anyone tempted to "make the two cadences consistent" would be choosing between duplicating the
notes (daily) or losing them (periodic).

### 3.4 Ticket keys

`GatheredTask.ticketKeys` is plural and already sorted (D-065). The bullet text is
`title` + `" (" + keys.joined(separator: ", ") + ")"`, and the parenthesis is omitted entirely
when there are none — never an empty `()`.

---

## 4. Emission: D6, in one file

Slack's `mrkdwn` has no heading syntax. `## Since last stand-up` pastes into Slack as a literal
`##`, so the heading is `*Bold*` alone on its line. Bullets are the literal characters `•` and
`◦` rather than `-`, because a literal bullet character *is* a bullet in any paste target and
does not depend on Slack's composer choosing to convert a hyphen.

```
*Since last stand-up*
• Flaky auth test on checkout (PAY-412)
    ◦ was a race in TokenRefresher, not the test
    ◦ PR merged after review
• Bump pg driver to 15.4

*Today*
• Rate limiter tuning (PAY-388)

*Blockers*
_None_
```

The exact contract:

| Element | Emission |
|---|---|
| Heading | `*` + title + `*` |
| Bullet | `• ` + text |
| Detail | four spaces + `◦ ` + first line |
| Detail continuation line | six spaces + the line, aligning under the `◦` text |
| Empty continuation line | emitted bare, so no line carries trailing whitespace |
| Empty section | `_None_` |
| Between sections | one blank line |
| End of output | no trailing newline |

### 4.1 Multi-line detail bodies

`NoteService.addNote` trims only outer whitespace, and `NoteComposerView` uses a `TextEditor`, so
an `Event.body` can carry interior newlines. Emitted naïvely, the second line of a note would
appear as an orphan line outside any bullet, silently breaking the structure of a document the
user is about to read aloud.

The body is split on newlines: the first line follows `◦ `, the remainder are indented six spaces
to hang beneath it. Every character the user typed survives; only leading indentation is added,
which is layout rather than editing.

### 4.2 No escaping, deliberately

A note containing `*` or `_` will render with unintended emphasis in Slack. The renderer does not
escape it.

Backslash-escaping would put characters on the screen the user never typed — visible in M2-03's
**editable** draft and persisted into `StandupReport.markdownBody`. "Ticket keys, service names,
function names, and error strings appear verbatim as the user typed them" is an acceptance
criterion of this task; correct Slack emphasis is not. When the two conflict, verbatim wins.

### 4.3 The empty window needs no special case

Every section is always emitted, and an empty one says `_None_`.

"No blockers" is a sentence people say at stand-ups; dropping the heading would throw away
information the user wants to speak. And because the sections are unconditional, a wholly empty
window is not a branch at all — it is three headings that each say `_None_`, which satisfies the
"honest and usable, not a crash or a blank string" criterion without a code path existing to be
got wrong.

---

## 5. Determinism

The acceptance criterion is "same window, same markdown, every time". That is established by
construction rather than by assertion, and the construction is worth naming because each item is
a way it could have been lost:

- No clock and no date formatting anywhere — the decision to omit timestamps from bullets removes
  the only locale- and timezone-dependent input the renderer could have had.
- No `Dictionary` or `Set` iteration. Grouping is done by filtering the already-ordered
  `window.tasks` array once per section.
- No sorting. Order is inherited from `ReportGatherer`, which owns it and tie-breaks it (D-065).
- No `String` case- or diacritic-folding, no localized comparison.

§7 records how this is tested, and specifically how it is *not*.

---

## 6. Test plan

`GatheredWindow`, `GatheredTask` and `GatheredEvent` all have public initialisers, so **no test
here needs a store, a `ModelContainer`, or `ReportFixture`**. Every case is literals in, string
out. Two new files:

**`StenoTests/Report/RawReportSectionsTests.swift`** — the mapping:

- Daily dual-listing: an `inProgress` task with notes appears under both *Since last stand-up*
  and *Today*, with `details` populated in the first and empty in the second.
- Daily blockers: a `blocked` task with both a reason and in-window notes has the notes under
  *Since last stand-up* and reason-only under *Blockers*.
- Periodic partition: one task of each status, each appearing in exactly one section; asserted as
  a count over all sections, so a task appearing twice fails.
- Periodic `todo`-with-events lands under *In flight*.
- Periodic blockers carry reason first, then notes.
- `created` and `statusChanged` events produce no details, in both cadences.
- A `.done` task whose only window event is its `statusChanged` still appears under *Since last
  stand-up*, with empty `details` — the case §3.2's two-clause membership test exists for.
- An empty window still yields all three sections, each with empty `bullets`.
- Ticket keys: none → no parenthesis; two → `(A-1, B-2)` in gatherer order.

**`StenoTests/Report/SlackMarkdownTests.swift`** — the emission:

- Exact literals for a heading, a bullet, a detail, and an empty section.
- A multi-line detail body indents its continuation lines and keeps every character.
- An interior blank line in a body produces a bare line, not one of six spaces.
- A body containing `*` and `_` is emitted unescaped.
- Sections are joined by exactly one blank line and the output has no trailing newline.

**Two golden tests**, one per cadence: a hand-built window covering all four statuses, notes,
ticket keys, and an empty section, asserted against the complete expected markdown as a string
literal. These are what actually catch a formatting regression; the unit tests above localize it.

**Ordering** is tested with a window whose tasks are deliberately in non-alphabetical,
non-title order, asserting the output preserves the given order. It is **not** tested by
rendering twice and comparing — a pure function passes that by construction, so such a test could
never fail and would be worse than no test at all.

**"Renders with no network and no API key"** is satisfied structurally: these files import
`Foundation` and reference nothing in `AI/`, which does not exist yet. `make test` already runs
with outbound networking denied (D-012). No test is written to pretend to prove it.

---

## 7. Verification of this design

Every code block above is to be compiled inside the real targets before the plan is written, not
type-checked as a standalone snippet — including the `#expect` macro bodies, which fail
differently inside their macro than outside it. Test function names are to be grepped against
`StenoTests/` for collisions at module scope first.

---

## 8. Documentation changes in this PR

- `docs/DECISIONS.md` — five entries:
  - **D-070** Daily sections answer different questions; a task may appear in two.
  - **D-071** Periodic is an exhaustive status partition; `todo`-with-events is *In flight*.
  - **D-072** Only user-authored events become bullets.
  - **D-073** Slack `mrkdwn` dialect: bold headings, literal bullet characters, no escaping.
  - **D-074** Every section always renders; `_None_` removes the empty-window special case.
- `docs/ARCHITECTURE.md` §5 — mark `Report/` renderers as existing (M2-02).
- `docs/tasks/README.md` — tick M2-01 (merged in #22, never ticked) and M2-02.

---

## 9. Out of scope

- **Any AI call** — M3. This renderer must never require one, and it imports nothing from `AI/`.
- **The UI and the clipboard** — M2-03. This task produces a `String` and puts it nowhere.
- **Themed grouping and compression** — a model behaviour (§7.3). This renderer enumerates, and a
  periodic window will be long. M3-03 is what makes it concise; the task file accepts the length
  here explicitly.
- **Timestamps in bullets.** Omitted, and §5 depends on their absence. A periodic window that
  proves hard to scan without dates is a finding for M3-03, not a late addition here.
- **`externalUpdate` rendering** — M4, alongside the connector that produces the events.
