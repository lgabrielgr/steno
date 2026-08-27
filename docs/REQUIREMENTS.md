# REQUIREMENTS.md — Steno

**Status:** Draft v1.11
**Date:** 2026-08-26
**Audience:** Engineering agents in future sessions. This document is the source of truth for task generation and implementation.

> **Steno** — a stenographer records what was said, verbatim, without editorializing. That is the product in one word: an accurate record of what you did, lightly organized, never embellished.

**Changelog**
- *v1.11* — FR-3 gains project editing. FR-1.4 routes captures on `Project.jiraProjectKeys`, but no requirement granted any way to set them: projects are created with `[]` and nothing could change it, so auto-routing and its chip would have shipped unreachable in the running app. Found while implementing M1-02, which adds the editor.
- *v1.10* — Corrected §3.4's `identifier` column. "PR number" was not a viable identifier: §3.4 makes a ref unique per `(taskID, kind, identifier)`, so two pull requests numbered 421 in different repositories collapse into one row and the second reference is silently dropped. The identifier is now required to be unique within its kind, and GitHub's is repo-qualified (`acme/api#421`). Found while designing M1-01.
- *v1.9* — Corrected §10.1's claim that events are immutable. They are append-only, but `Event.isRedacted` and `StandupReport.isUndone` are mutable flags, so a record present on both machines can still differ and union-by-UUID alone would drop a redaction. §10.1 now names the gap and routes the actual merge rule to `DECISIONS.md` O-8 (owner: M2.5-02); the mutable-field table's row count is corrected from "three" to four. Found while implementing M0-03.
- *v1.8* — The task model's Swift type is named **`TaskItem`**, not `Task`, to avoid shadowing `_Concurrency.Task` (§3.2). Domain vocabulary is unchanged: prose, UI copy, and the export key `"tasks"` all still say "task". Updated §3, §3.2, and §10.1.
- *v1.7* — Resolved nine internal contradictions and gaps found on first full read. First-run `windowStart` is now unambiguously 24h (§3.5 corrected to match FR-4). Undo (FR-4.1) and the note grace window (FR-2) are both defined as *redaction*, so the append-only invariant holds with no exceptions. `modifiedAt` added to `Project` and `Task` (§3.1, §3.2) as §10.1 already required. `SourceRef` promoted to a first-class model with `id` and an export array (§3.4, §10.1, §10.2). §7.3 gains a second output schema for `periodic` cadence. Stale threshold clarified as global default + per-project override (FR-6). Project facts fixed in §9.1 (bundle ID `com.lgabrielgr.steno`, macOS 14.0 floor). Vestigial CloudKit purge clause removed from §8.
- *v1.6* — Added §9.5 Version Control Workflow (branch-per-task, PR required, never commit to `main`) and §9.6 mechanical enforcement via branch protection. Added the rule to §13 and to M0.
- *v1.5* — Cancelled M7 (iOS + CloudKit sync). D1 now macOS-only. MCP simplified to stdio-only. Added §14 recording what was cancelled, what was retained, and the revisit trigger. Auto-export now defaults ON.
- *v1.4* — Resolved Q1/Q3/Q4 → D16–D19. Confirmed no schema change for multi-DSU. Added per-project `reportCadence` and cadence-aware staleness. Added Atlassian token-expiry handling to §5.2.
- *v1.3* — Added §10 Portability & Data Interchange: JSON export/import with merge-by-UUID semantics, auto-export as a zero-cost sync substitute. Added milestone M2.5. Partially resolves Q8.
- *v1.2* — Added §9 Build & Developer Workflow: CLI-first build/run/test, XcodeGen-managed project, Makefile entry points, stable signing for TCC persistence. Added a verification rule to §13.
- *v1.1* — Named the project. Revised D2: persistence is local-only by default, with CloudKit sync as an optional capability (see §6.1). Adjusted M0 and M7 accordingly.

---

## 1. Problem Statement

The user is a software engineer who also performs Engineering Manager duties. They currently track all work in a paper notebook, striking through completed lines. The system works for *capture* but fails for *recall*: during the next day's daily stand-up (DSU), they cannot reconstruct what they actually did, because tasks from multiple projects and activities are interleaved on the same pages. The fallback is naming JIRA keys with no detail.

The product is a **recall tool, not a project management tool.** It must answer one question extremely well:

> "What did I do since my last stand-up, for this specific project, in enough detail to say it out loud?"

### 1.1 Primary Risk

The paper notebook wins on capture latency. A pen has zero startup cost and no schema. If logging a task takes more than ~3 seconds, or forces a modal project selection before text entry, the user will revert to paper and the product dies.

**Capture speed is a P0 functional requirement, not polish.** Any design decision that trades capture speed for data cleanliness is wrong.

### 1.2 Success Criteria

The product succeeds if, after four weeks:
- The user has stopped using the paper notebook for work tasks.
- Stand-up preparation takes under 60 seconds.
- The reported summary contains specific detail (what changed, why blocked), not just ticket keys.

---

## 2. Decisions Made (Locked)

These were settled during requirements interview. Do not relitigate without user input.

| # | Decision | Value | Rationale |
|---|---|---|---|
| D1 | Platform | Native macOS (SwiftUI), **macOS only** | Personal use, not distributed. iOS explicitly out of scope — see §14 |
| D2 | Persistence | SwiftData, local-only by default; CloudKit sync behind an optional capability | No backend to host or secure. CloudKit requires paid Apple Developer membership — see §6.1 |
| D3 | Backend | **None** | Zero infrastructure cost, zero operational burden |
| D4 | AI data policy | Sending Jira/Confluence content to AI is permitted | No redaction layer required in v1 |
| D5 | Jira/Confluence access | **Read-only, permanently** | Least privilege; app must never mutate team tickets |
| D6 | Stand-up output | Text formatted for copy → paste into Slack | Clipboard is the primary export |
| D7 | Ticket coverage | Nearly all tasks reference a ticket | Ticket key is a first-class indexed field |
| D8 | Report window | Since the user's last stand-up **for that project** | Handles Mondays, vacation, sick days with no special-casing |
| D9 | Project structure | Flat list of projects/activities | No epics, no nesting, no hierarchy |
| D10 | Progress capture | Append-only timestamped notes | Immutable event log; never overwrite history |
| D11 | Statuses | Fixed four: TODO, IN-PROGRESS, BLOCKED, DONE | No custom statuses, no workflow engine |
| D12 | AI scope | Summarize event log; detect stale tasks | **No** focus suggestions, **no** prioritization |
| D13 | AI tone | Light polish — organize and clean, never rewrite | Preserve the user's technical vocabulary |
| D14 | AI credential | Anthropic API key, entered in Settings | See §7.2 for the subscription-auth caveat |
| D15 | Capture surfaces | Global hotkey, menu bar item, main window | Three entry points, one code path |
| D16 | Meeting → project mapping | Each meeting covers exactly one project | Confirms `StandupReport.projectID` and per-project `lastStandupAt`; **no schema change needed** |
| D17 | Report cadence | Per-project: daily or periodic | User has 2 daily DSUs + 1 biweekly EM sync. Cadence affects window size, report style, and staleness |
| D18 | Scale | Under 20 live tasks | No pagination, virtualization, or search in v1. Whole dataset fits one AI call |
| D19 | Atlassian deployment | Cloud (`*.atlassian.net`) | REST API v3; API-token auth. Locks §5.2 |

### 2.1 Non-Goals (Explicitly Out of Scope)

Do not build these. Reject tasks that propose them.

- Writing to Jira (comments, transitions, field updates) — see D5
- Time tracking, estimates, burndown, velocity
- Team/multi-user features, sharing, assignment to others
- Sprint planning, backlog grooming, roadmapping
- Handwriting OCR / notebook import
- Custom statuses, custom fields, custom workflows
- Task prioritization or "what should I work on" recommendations — see D12
- Auto-posting to Slack (user copies manually — see D6)

---

## 3. Core Domain Model

The central architectural idea: **everything that happens to a task is an immutable event appended to a stream.** Task state is derived; history is never mutated. This is what makes the stand-up report trivially correct and the AI prompt reliable.

```
Project (1) ──< TaskItem (1) ──< Event
                        (1) ──< SourceRef
Project (1) ──< StandupReport
```

### 3.1 Project

Represents a project *or* a non-project activity (e.g. "Hiring", "1:1s", "Performance Reviews").

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `name` | String | e.g. "Payments Platform", "EM — Hiring" |
| `colorHex` | String | Visual identification in lists |
| `jiraProjectKeys` | [String] | e.g. `["PAY", "BILL"]`; used to auto-route tasks by ticket prefix |
| `isArchived` | Bool | Archived projects hidden but never deleted |
| `sortOrder` | Int | Manual ordering |
| `lastStandupAt` | Date? | **Critical** — defines the report window per D8 |
| `reportCadence` | enum | `daily` or `periodic`. Drives report style and default staleness (D17) |
| `staleThresholdDays` | Int? | Per-project override. `nil` = derive from cadence, then global default (FR-6) |
| `modifiedAt` | Date | Last mutation of a mutable field (`name`, `colorHex`, …). Drives import conflict resolution (§10.1) |

> **Note on `lastStandupAt`:** The user attends *multiple different DSUs*. Each project therefore tracks its own last-reported timestamp independently. A report for Project A must not advance the clock for Project B.

### 3.2 TaskItem

> **The Swift type is `TaskItem`, not `Task`.** In Swift, a type named `Task` shadows
> `_Concurrency.Task`, so in any file that can see the model, `Task { … }` resolves to the
> SwiftData class instead of the concurrency primitive. This app runs async integration fetches
> from M4 onward, so the collision is guaranteed rather than theoretical, and the workaround —
> writing `_Concurrency.Task { }` at every async call site, forever — is worse than a rename.
>
> **Only the Swift identifier changes.** The domain vocabulary is untouched: this document, the
> UI, and the export key `"tasks"` (§10.2) all still say "task". Field names referring to it
> stay as specified — `taskID`, not `taskItemID`.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `title` | String | Single line. This is the whole task description. |
| `projectID` | UUID | |
| `status` | Status enum | `todo`, `inProgress`, `blocked`, `done` |
| `createdAt` | Date | |
| `statusChangedAt` | Date | Drives stale detection |
| `completedAt` | Date? | Set when status → `done` |
| `sourceRefs` | [SourceRef] | Extracted ticket keys / URLs. Relationship, not an embedded value — see §3.4 |
| `isArchived` | Bool | |
| `modifiedAt` | Date | Last mutation of a mutable field (`title`, `projectID`, …). Drives import conflict resolution (§10.1) |

**Status transitions:** Any status may move to any other status. No enforced workflow. Moving to `done` sets `completedAt`; moving out of `done` clears it.

### 3.3 Event (Append-Only)

The heart of the system. Events are **never edited or deleted** (soft-delete only, via `isRedacted`, for typo correction).

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `taskID` | UUID | |
| `timestamp` | Date | |
| `kind` | EventKind enum | See below |
| `body` | String | Human-readable content |
| `payload` | Data? | JSON blob for structured external data |
| `isRedacted` | Bool | Hidden from summaries; row retained |

**EventKind:**

| Kind | Created when | Example body |
|---|---|---|
| `created` | Task is created | "Task created" |
| `note` | User adds progress | "Repro'd the race condition, it's in the retry handler" |
| `statusChanged` | Status transition | "IN-PROGRESS → BLOCKED" |
| `blockedReason` | Optional note on blocking | "Waiting on infra to provision the staging DB" |
| `externalUpdate` | Integration fetch finds a change | "PAY-421 moved to In Review; 2 new comments" |
| `standupReported` | A report is generated & copied | "Reported to standup" |

### 3.4 SourceRef

A reference from a task to an external system, extracted automatically from task title and note bodies.

**This is a first-class SwiftData model, not an embedded value type.** It carries its own `id` so it participates in merge-by-UUID import (§10.1) like every other record, and so `lastFetchedAt` / `cachedSummary` survive a round-trip rather than being silently regenerated.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `taskID` | UUID | |
| `kind` | enum | `jiraIssue`, `confluencePage`, `githubPR`, `url`, `mcpResource` |
| `identifier` | String | Must *uniquely identify the external resource* within its `kind` — it is half the dedup key below, so an identifier two different resources could share would merge them. (Two tasks may of course reference the same resource; that is a different row each time.) Jira: the key, `PAY-421`. Confluence: the numeric page ID. GitHub: **repo-qualified**, `acme/api#421` — a bare PR number collides across repositories |
| `url` | String? | Canonical link |
| `lastFetchedAt` | Date? | |
| `cachedSummary` | String? | Last known state, for offline use |

**Deduplication.** Extraction (FR-1.5) runs on every save and every note, so the same ticket key will be seen repeatedly. A ref is unique per `(taskID, kind, identifier)`; re-extracting an existing ref is a no-op, not a new row. This is a uniqueness *rule enforced in code*, not an `@Attribute(.unique)` — §6 forbids those.

### 3.5 StandupReport

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `projectID` | UUID | |
| `generatedAt` | Date | |
| `windowStart` | Date | = previous `lastStandupAt`; on first run for a project, 24h before now (matches FR-4 step 2) |
| `windowEnd` | Date | |
| `markdownBody` | String | Final text as copied |
| `wasAIGenerated` | Bool | False when fallback used |
| `modelUsed` | String? | For debugging quality regressions |
| `isUndone` | Bool | Set by FR-4.1. Row is retained, excluded from history |

---

## 4. Functional Requirements

### FR-1: Quick Capture (P0)

The single most important feature. Three entry points, one shared code path.

**FR-1.1 — Global hotkey.** A system-wide hotkey (default `⌥Space`, user-configurable, must detect and warn on conflicts) opens a small floating window above all apps. Text field is focused on open. `Return` saves and dismisses. `Esc` dismisses without saving.

**FR-1.2 — Menu bar item.** A persistent menu bar icon. Clicking opens a popover with: the quick-add field, today's in-progress tasks with inline status toggles, and a "Open Main Window" action.

**FR-1.3 — Main window.** Full task management UI (see FR-3).

**FR-1.4 — Project assignment without friction.** The quick-add field must **never** block on project selection.
- Default the project to the last-used project.
- If the typed text contains a ticket key whose prefix matches a `Project.jiraProjectKeys` entry, auto-assign to that project and show it as a dismissible inline chip.
- Project may be changed after the fact, from the task row, with no penalty.

**FR-1.5 — Passive reference extraction.** On save, scan the text for:
- Jira ticket keys via regex `\b[A-Z][A-Z0-9]{1,9}-\d+\b`
- Confluence page URLs
- GitHub PR URLs
- Bare URLs

Create `SourceRef` records automatically. **No special syntax is required from the user** — the user explicitly declined a natural-language command grammar (no `@project`, no `#tag`). Extraction is passive and silent.

**Acceptance:** From any application, hotkey → type → `Return` completes in under 3 seconds with no mouse use and no modal interruption.

### FR-2: Progress Notes (P0)

- Adding a note appends a `note` event with the current timestamp.
- Notes are visible as a reverse-chronological timeline on the task.
- Notes are **not editable** after a grace period of 5 minutes (typo window). After that, only redaction is available.
- **The grace-period "edit" is not a mutation.** It is implemented as redact-and-reappend: set `isRedacted` on the original event and append a new `note` event carrying the corrected body. The append-only invariant (§3.3, §13) therefore has **no exceptions** anywhere in the system — no code path ever writes to an existing `Event` row except to flip `isRedacted`. The UI may present this as ordinary editing; the storage layer must not implement it as such.
- The reappended event should carry the *original* timestamp, not the correction's, so the timeline doesn't reorder under the user mid-correction.
- Note entry must be reachable in one keystroke from a selected task (suggested: `N`).

### FR-3: Main Window (P0)

Three-column layout:

1. **Sidebar** — flat list of projects with unread/stale badge counts. An "All" pseudo-project at top.
2. **Task list** — tasks for the selected project, grouped by status in the order IN-PROGRESS, BLOCKED, TODO, DONE. `DONE` collapsed by default, showing only items completed within the current report window.
3. **Detail pane** — task title, status control, source-ref cards with fetched external state, and the full event timeline.

**Project editing.** A project's name and its `jiraProjectKeys` are editable from the sidebar. This is what makes FR-1.4's auto-routing reachable: routing matches a typed ticket key's prefix against `jiraProjectKeys`, and without a way to set them every project holds an empty list forever. Colour is not editable — see D9 and §3.1; deletion does not exist — see §3.1, archiving only.

**Keyboard-first requirement.** Every primary action needs a shortcut: new task, cycle status, add note, generate report, switch project.

**Scale (D18).** Under 20 live tasks. Build the simple thing: a plain `List`, no pagination, no virtualization, no search, no filter chips in v1. If the task list ever needs a scrollbar the user has a workflow problem, not a UI problem.

### FR-4: Stand-up Report Generation (P0)

**The core value delivery.** Reached via a prominent, always-visible button on the project view.

**Flow:**
1. User selects a project and triggers "Prepare Stand-up".
2. App computes `windowStart` = `project.lastStandupAt` (or, on first run, 24h before now).
3. App gathers all events in `[windowStart, now]` for tasks in that project.
4. App refreshes stale `SourceRef` data (§5) — with a visible but non-blocking progress indicator.
5. App builds the AI request (§7.3) and renders the result.
6. User reviews the draft in an **editable** text view.
7. User clicks "Copy". This:
   - Places Slack-flavored markdown on the clipboard,
   - Sets `project.lastStandupAt = now`,
   - Appends a `standupReported` event to each included task,
   - Persists the `StandupReport`.

> The clock only advances on **Copy**, never on generate. Generating a preview must be free of side effects, so the user can peek without corrupting their window.

**Report structure.** Determined by `project.reportCadence` (D17):

*Daily cadence* — fixed three sections, matching DSU convention:
- **Since last stand-up** — completed and progressed work
- **Today** — current IN-PROGRESS tasks
- **Blockers** — BLOCKED tasks with reasons

*Periodic cadence* (e.g. the biweekly EM sync) — a two-week window produces far more events than a day, and reading 40 bullets aloud is useless. Instead:
- **Completed** — grouped by theme, not one line per task
- **In flight** — current work with a one-line state
- **Blockers & risks**

The distinction is real: a daily DSU is a status ping, a biweekly sync is a summary. Same event log, different compression ratio. See §7.3 for the corresponding prompt change.

**FR-4.1 — Undo.** An "Undo last stand-up" action must restore the previous `lastStandupAt`. Users will misclick, and an unrecoverable window advance destroys a day of recall.

Undo must therefore reverse all three side effects of Copy:

| Side effect | Undo |
|---|---|
| `project.lastStandupAt` advanced | Restore the previous value — read it from the `StandupReport.windowStart` being undone |
| `standupReported` events appended | **Redact them** (`isRedacted = true`). Never delete — see §3.3 |
| `StandupReport` persisted | Mark it undone; retain the row |

Undo applies only to the most recent report for that project, and only while it is the most recent. Once a newer report exists, the older window is history.

### FR-5: Stale Task Detection (P1)

**Implemented as a deterministic rule, not an AI call.** Free, instant, offline-capable, and cannot be wrong.

A task is stale when:
- `status ∈ {inProgress, blocked}`, AND
- no event of kind `note` or `statusChanged` in the last **N** days.

**N is per-project, derived from `reportCadence` (D17):**

| Cadence | Default N |
|---|---|
| `daily` | 3 days |
| `periodic` | 10 days |

A fixed global threshold is wrong here. A 3-day rule applied to a biweekly EM project would badge nearly every task as stale on a normal week, and a warning that always fires is a warning the user learns to ignore. `staleThresholdDays` allows a manual override per project.

**Resolution order for N — first non-`nil` wins:**

1. `project.staleThresholdDays` (per-project override, set in the project editor)
2. The cadence default from the table above (3 / 10)
3. The global default in Settings (FR-6), which seeds new projects and backstops an unrecognized cadence

The Settings value is a *default*, not a ceiling. It must never silently override a project that has set its own.

Stale tasks are badged in the UI and listed in a "Needs attention" section. The AI's only role is optional phrasing when the user asks about them.

### FR-6: Settings (P0)

- **AI provider**: provider picker, API key field (Keychain-backed), model picker (populated at runtime — see §7.1), "Test connection" button.
- **Integrations**: Atlassian site URL, email, API token; MCP server management; per-integration enable toggle and connection test.
- **Capture**: hotkey binding, launch at login, default project.
- **Stale threshold**: global default N in days. Seeds new projects and backstops the cadence defaults; a project's own `staleThresholdDays` always wins (see FR-5 for the resolution order).
- **Data**: export all data as JSON, purge cached external data.

---

## 5. Integrations (Source Layer)

### 5.1 Architecture

All external data flows through a single protocol. The AI layer and the source layer are **fully decoupled** — swapping AI providers must not affect integrations, and vice versa.

```swift
protocol SourceConnector {
    var id: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }

    func canHandle(_ ref: SourceRef) -> Bool
    func fetch(_ ref: SourceRef, since: Date?) async throws -> SourceUpdate
    func testConnection() async throws
}

struct SourceUpdate {
    let summary: String          // Human-readable current state
    let changes: [String]        // Discrete changes since `since`
    let url: URL?
    let fetchedAt: Date
}
```

**Transport: stdio is fine.** Since iOS is out of scope (D1), local MCP servers running as stdio subprocesses are acceptable for every connector. Do **not** build an HTTP/SSE transport unless a specific server requires it.

This is the one real simplification the macOS-only decision buys: M5 drops from "two transports plus a platform-capability matrix" to "spawn a subprocess and speak JSON-RPC over pipes." Take it.

> *Historical note:* earlier drafts required all connectors to work over HTTPS so an iOS client wouldn't degrade to a read-only shell. That constraint is retired. If iOS is ever revived (§14), MCP-backed sources would need remote transports — but paying that cost now, for a phone app that isn't planned, is speculative work.

### 5.2 Jira Connector (v1, P0)

**Deployment: Atlassian Cloud (D19).** REST API v3. Do not write Data Center compatibility code.

- **Auth:** Atlassian API token (email + token, HTTP Basic). Read-only scopes.
- **Token expiry is mandatory to handle.** Atlassian Cloud API tokens created since December 2024 expire — with a maximum lifetime of one year, set at creation. This is not a rare edge case; it is a scheduled, guaranteed failure. Requirements:
  - Store the user-entered expiry date alongside the token.
  - Warn in-app 14 days before expiry.
  - On `401`, show a clear "your Atlassian token expired — create a new one" message with a direct link, **never** a generic network error. A silent 401 during stand-up prep is the worst possible time to debug auth.
- **Org policy caveat:** enforcing SAML SSO does *not* break API tokens — Atlassian explicitly supports tokens under enforced SSO. However, org admins can separately block API token creation via authentication policy. If token creation is blocked, M4 requires an admin conversation; nothing in the app can work around it.
- **Endpoints:** issue detail, issue changelog, issue comments (REST v3).
- **Fetch on `since`:** status transitions, new comments, assignee changes, linked PR references.
- **Cache:** persist `cachedSummary` so a report can be generated offline with last-known state, clearly labeled as stale.

### 5.3 Confluence Connector (v1, P0)

- Same Atlassian credential — one config, two APIs. (Jira and Confluence are distinct REST APIs; do not conflate them.)
- Fetch page title, last-modified timestamp, last editor, and version delta since `since`.

### 5.4 MCP Support (v1, P1)

Generic MCP client, **stdio transport only** in v1. Users add servers via config. Tools exposed by MCP servers become available to the AI layer during enrichment. Add HTTP/SSE only if a required server offers no local option.

**This is the delivery mechanism for GitHub and Google Calendar.** The user requested both; rather than hand-building two OAuth clients and their token-refresh logic, they are satisfied by off-the-shelf MCP servers. Same outcome, materially less code, and it generalizes to any future source at zero marginal engineering cost.

If MCP proves awkward in practice for these two specific sources, native connectors move to v1.1 — but MCP is attempted first.

### 5.5 Refresh Policy

- On app launch, refresh refs on all non-done tasks older than 30 minutes.
- On "Prepare Stand-up", refresh all refs in the report window.
- Scheduled background refresh at a user-set time (default 08:00) so the morning view is instant rather than waiting on network.
- All fetches are best-effort. **A failed integration must never block report generation** — degrade to cached data with a visible staleness indicator.

---

## 6. Data & Sync

- **SwiftData**, backed by a local store. **There is no sync.** Multi-machine transfer is handled by §10 export/import.
- Models must nonetheless keep **CloudKit-compatible schemas**: optional fields or defaults on every property, no unique constraints beyond `id`, no `@Attribute(.unique)`.

> **Agents: do not strip this constraint just because sync was cancelled.** It costs nothing to honour, it is already required by the export/import merge in §10.1 (every record needs a stable `id` and tolerant decoding), and it is the difference between enabling sync someday as a config change versus a data migration. Keeping the door open is free; reopening it is not.
- **Secrets never sync via CloudKit.** API keys and tokens live in Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Optionally Keychain-synced via iCloud Keychain, user-controlled.
- Conflict resolution: last-writer-wins is acceptable given single-user, multi-device usage. The append-only event design makes true conflicts rare by construction.
- Full offline capability. Every feature except external enrichment works with no network.

---

### 6.1 Apple Developer Program: Not Required

**Steno as scoped requires no paid Apple Developer membership, ever.** This is a deliberate constraint (D1), not a temporary limitation. Xcode is free; a macOS app signed with a free Apple ID ("Personal Team") builds and runs on the developer's own Mac indefinitely. The widely-cited 7-day certificate expiry applies to *iOS devices*, not macOS.

**What the $99/year program would unlock, and why none of it is needed:**

| Capability | Would enable | Status |
|---|---|---|
| CloudKit / iCloud entitlement | Real-time multi-device sync | Not needed — §10 export/import covers it |
| iOS device install beyond 7 days | An iPhone app | Out of scope (§14) |
| TestFlight / App Store | Distribution to other people | Not distributing |
| Notarization | Others running a DMG without Gatekeeper warnings | Not distributing |

**The one friction point to be aware of:** a Personal Team–signed build runs on *the Mac that built it*. Moving the `.app` to another machine triggers Gatekeeper. The supported answer is to build from source on that machine (§9 makes this a single `make build`) and move the *data* via export/import (§10). This is a real workflow, not a workaround.

**Do not** attempt to route around signing limits with third-party signing services or unofficial sideloading tooling. They violate Apple's terms and get revoked.

**Revisit trigger:** enroll only if the user finds themselves wanting to capture tasks away from the Mac. That single need — not sync, not distribution — is what would justify the fee. Nothing else in the backlog does.

---

## 7. AI Layer

### 7.1 Provider Abstraction

The user requires that another AI provider can be plugged in easily.

```swift
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }

    func availableModels() async throws -> [AIModel]
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft
    func testConnection() async throws
}
```

Ship with `AnthropicProvider`. The protocol must contain no Anthropic-specific types in its signatures — no leaking of message-block shapes or vendor error enums into calling code.

**Model list must be fetched at runtime** via the Anthropic `/v1/models` endpoint, not hardcoded. Model IDs change; the settings picker should populate dynamically so the app doesn't need a release to expose a new model. Default selection: a mid-tier model is sufficient for summarization — this is not a reasoning-heavy workload, and cost per stand-up should stay negligible.

### 7.2 Credentials — Known Constraint

The user asked for a choice between an API key and Claude subscription sign-in.

**Ship the API key path.** There is no publicly documented OAuth flow permitting a third-party application to consume a Claude.ai consumer subscription. Implementing "subscription sign-in" is not currently possible through supported means.

Design the credential layer as an enum (`.apiKey(String)` / `.oauth(TokenSet)`) so a subscription flow can be added later without refactoring, and surface API key as the only enabled option in Settings v1. Do not attempt to reverse-engineer unofficial auth flows.

### 7.3 The Summarization Call

**Input:** the event log — the AI is summarizing a factual record, not inventing history. This is what makes output trustworthy.

```
For each task in window:
  - title, status, ticket key
  - all events in [windowStart, now] with timestamps
  - external updates fetched from integrations
```

**Use structured outputs.** The Anthropic API supports schema-constrained responses; request validated JSON rather than parsing prose.

**There are two schemas, selected by `project.reportCadence` (D17).** They are not cosmetic variants of each other — the sections differ, and so does the cardinality of the task reference.

*`daily`* — one bullet per task, three DSU sections:

```json
{
  "since_last_standup": [{ "task_id": "...", "text": "..." }],
  "today":              [{ "task_id": "...", "text": "..." }],
  "blockers":           [{ "task_id": "...", "text": "..." }]
}
```

*`periodic`* — themed bullets that may each span several tasks, hence `task_ids` (plural):

```json
{
  "completed":           [{ "task_ids": ["...", "..."], "text": "..." }],
  "in_flight":           [{ "task_ids": ["..."],        "text": "..." }],
  "blockers_and_risks":  [{ "task_ids": ["..."],        "text": "..." }]
}
```

`task_ids` is what licenses the grouping mandated in the prompt constraints below: the model may merge several tasks into one themed bullet, and the app can still link that bullet back to every task it covers. A `daily` bullet that tried to do this would be a bug.

Both schemas must reject a `task_id` the app didn't send — a hallucinated ID is the clearest possible signal the model invented a fact, and it should fail loudly into the §7.4 fallback rather than render.

The app renders markdown from whichever structure came back. Never ask the model to format the final Slack text — formatting is the app's job, and separating them makes output stable.

**Prompt constraints (hard requirements):**
- Never introduce a fact not present in the event log. No inference about what the user "probably" did.
- Preserve verbatim: ticket keys, service names, function names, error strings, acronyms.
- Light polish only — organize fragments into clean sentences. Do **not** elevate register. "fixed the flaky auth test" must not become "enhanced authentication reliability." The user has to say these words out loud to their team; inflated language is actively harmful.
- One line per task. DSU updates are spoken, not read.
- **Long windows must condense, not enumerate.** For `periodic` cadence (D17), a two-week window may cover dozens of tasks. Group related work into themed bullets rather than emitting one line per task. Target roughly 8–12 bullets regardless of window length. This is the one place the model may combine tasks — it still may not invent facts.
- If a task's events are too thin to summarize, output the raw note rather than padding.

### 7.4 Graceful Degradation

If the AI call fails, is not configured, or the device is offline, the app **still produces a report** — raw events grouped by status under the same three headings. Slightly rougher, entirely usable. The user must never arrive at a stand-up empty-handed because of a network error.

This is a P0 requirement and should be built *before* the AI path, not after.

---

## 8. Security & Privacy

- Tokens and API keys in Keychain only. Never in SwiftData, `UserDefaults`, plists, or logs.
- Atlassian credentials must be read-scoped. Document this in onboarding.
- No analytics, no telemetry, no crash reporting that includes task content.
- Redact secrets from all log output. Log AI request *metadata* (token counts, latency, model) but never full payloads by default.
- "Export my data" produces complete JSON per §10, containing no secrets. "Delete my data" purges the local store. (There is no remote copy to purge — sync is cancelled per D1/§14. If sync is ever reinstated, this line grows a second clause.)
- Onboarding must state plainly which content is transmitted to the AI provider, so the user can re-evaluate if their employer's policy changes.

---

## 9. Build & Developer Workflow

**Requirement: the app must be fully buildable, runnable, and testable from the command line. Xcode's GUI is optional, never required.**

This is not a convenience preference. Two things depend on it: the user's own edit-run loop, and — more importantly — the ability of implementing agents in future sessions to verify their work. An agent that cannot compile and test what it wrote is guessing.

### 9.1 Project Generation

**Fixed project facts.** These are settled; use them verbatim in `project.yml` rather than inventing placeholders.

| Fact | Value |
|---|---|
| Product name / scheme | `Steno` |
| Bundle identifier | `com.lgabrielgr.steno` |
| `os.Log` subsystem | `com.lgabrielgr.steno` |
| Minimum deployment target | macOS 14.0 — the SwiftData floor (D2) |
| Toolchain | Xcode 16 or later; whatever Swift ships with it. Not pinned — `make bootstrap` installs tools, not Xcode |

Do **not** commit a hand-maintained `.xcodeproj`. Use **XcodeGen** with a `project.yml` manifest; the `.xcodeproj` is generated and gitignored.

Rationale: a `project.pbxproj` is an opaque, merge-conflict-prone blob that can realistically only be edited through the Xcode GUI. A YAML manifest is diffable, reviewable, and editable by an agent in a text editor. Targets, entitlements, build settings, and schemes all live in version control as readable text.

(Tuist is an acceptable alternative if the project outgrows XcodeGen. Plain SwiftPM is **not** sufficient — it cannot produce a signed `.app` bundle with the entitlements the menu bar and hotkey require.)

### 9.2 Required Make Targets

A `Makefile` at the repo root is the single entry point. Every target must exit non-zero on failure so agents and CI can gate on it.

| Target | Behavior |
|---|---|
| `make bootstrap` | Install toolchain deps (xcodegen, xcbeautify, swiftlint) via Homebrew; idempotent |
| `make generate` | Regenerate `.xcodeproj` from `project.yml` |
| `make build` | Debug build into a local `.build/` derived data path |
| `make run` | Kill any running instance, build, and launch |
| `make test` | Unit tests, headless |
| `make lint` / `make format` | SwiftLint / swift-format |
| `make clean` | Remove `.build/` and generated project |
| `make release` | Release build of the `.app` bundle |

Reference invocations:

```bash
xcodebuild -project Steno.xcodeproj -scheme Steno \
  -configuration Debug -derivedDataPath .build build | xcbeautify

xcodebuild test -project Steno.xcodeproj -scheme Steno \
  -destination 'platform=macOS' -derivedDataPath .build | xcbeautify
```

`make run` should exec the binary directly rather than using `open`, so `stdout`/`stderr` stream to the terminal:

```bash
pkill -x Steno || true
./.build/Build/Products/Debug/Steno.app/Contents/MacOS/Steno
```

For `os.Log` output when launched detached: `log stream --predicate 'subsystem == "com.lgabrielgr.steno"'`.

### 9.3 Signing From the Command Line

**Use a stable Personal Team signing identity, not ad-hoc (`-`) signing.** This matters more than it appears.

FR-1's global hotkey requires macOS Accessibility permission, which is granted by TCC against the app's **code signature**. Ad-hoc signing produces a new identity on every build, so macOS treats each rebuild as a different app and re-prompts for permission — turning the core feature into a permissions dialog on every run. A stable identity makes the grant persist across rebuilds.

- `DEVELOPMENT_TEAM` and any local overrides go in a gitignored `Local.xcconfig`.
- No credentials, team IDs, or tokens committed to the repo.

### 9.4 Test Constraints

- Unit tests covering the model layer, report-window computation, reference extraction, and AI response parsing must run **headless** — no window server, no GUI session, no network.
- All external calls (Atlassian, AI provider, MCP) must sit behind protocols with test doubles. `make test` must pass with networking disabled.
- UI tests, if added, live in a separate scheme and are excluded from default `make test`.

### 9.5 Version Control Workflow

**Hard rule: agents never commit directly to `main`. Every task is a branch and a pull request.**

The default branch is named **`main`** throughout this document. (If the repo was initialized with `master`, rename it once, at M0, and update this line.)

**Per-task procedure — no exceptions:**

1. `git checkout main && git pull` — always branch from current `main`, never from another task branch.
2. `git checkout -b <type>/<short-description>`
3. Implement the task.
4. Run `make build && make test && make lint`. **All three must pass before a PR is opened** (§13).
5. Commit with a message explaining *why*, not just *what*.
6. Push and open a PR with the template below.
7. **Stop.** Do not merge. Do not squash-merge your own PR. The user reviews and merges.

**Branch naming:**

| Prefix | Use |
|---|---|
| `feat/` | New functionality (`feat/global-hotkey-capture`) |
| `fix/` | Bug fixes (`fix/standup-window-off-by-one`) |
| `refactor/` | Behaviour-preserving changes |
| `test/` | Test-only additions |
| `docs/` | Documentation, including edits to this file |
| `chore/` | Tooling, dependencies, build config |

**PR requirements:**

- **One task per PR.** If a task turns out to contain two changes, open two PRs. A PR that touches the capture path *and* the Atlassian connector is two PRs.
- Title: imperative and specific — "Add global hotkey capture window", not "hotkey stuff".
- Body must state: which requirement ID (`FR-1.1`, `D17`, `M2.5`) it implements; what was done; how it was verified; anything deliberately left out.
- Link the milestone from §11.
- If implementation revealed that a requirement in this document is wrong or ambiguous, **say so in the PR body**. Do not silently deviate. A PR that quietly contradicts REQUIREMENTS.md is worse than one that pauses to ask.
- Keep PRs small enough to actually read. A 2,000-line PR is not reviewable and defeats the purpose.

**Never, under any circumstances:**
- Commit or push to `main`
- Force-push to a shared branch
- Merge your own PR
- Include secrets, tokens, `Local.xcconfig`, or `.xcodeproj` (generated per §9.1) in a commit
- Rewrite history on a branch the user has already reviewed

### 9.6 Enforce This Mechanically

Convention alone is insufficient — an agent can misread an instruction, and a single `git push` to `main` costs more to untangle than the protection costs to set up. Configure GitHub **branch protection on `main`** at M0:

- Require a pull request before merging
- Block force pushes and branch deletion
- Require status checks to pass (once CI exists — see below)

The user is the sole reviewer and can self-approve; the point is not gatekeeping, it is **a review checkpoint before agent-written code lands.** With multiple agent sessions building this app, the PR diff is the user's only practical window into what actually changed and why.

A minimal GitHub Actions workflow running `make build && make test && make lint` on every PR is worth adding at M1, once there is enough code for it to mean something.

---

## 10. Portability & Data Interchange

**Requirement: full task history must be exportable to a single file and importable on another machine, restoring the user to exactly where they left off.**

This is a first-class feature and, since sync is cancelled (D1, §6.1), **the only way Steno moves between machines — permanently.** Its priority rises accordingly: treat M2.5 as core, not optional.

### 10.1 Merge, Not Replace

The critical design decision, and the append-only model (§3.3) makes it nearly free.

**Import defaults to a merge: union by UUID.** Every record already carries a stable `id`, so a record either exists on the target machine or it doesn't, and the append-only log (§3.3) means an event's *content* is never rewritten — there is no such thing as an edited event body to reconcile.

**But append-only is not immutable.** `Event.isRedacted` and `StandupReport.isUndone` are mutable flags on otherwise append-only records — flipped by FR-4.1's undo and by note correction (FR-2). A record present on **both** machines can therefore still differ. A merge implemented literally as "union by UUID, skip whatever is already present" would silently discard a redaction made on the other machine, and the redacted text would reappear in a stand-up summary. Neither model carries `modifiedAt`, so the "later `modifiedAt` wins" rule below does not reach them either. **How these two flags merge is an open question — see `DECISIONS.md` O-8, owned by M2.5-02.** Do not assume the union default covers them.

Consequences that must hold:

- **Idempotent.** Importing the same file twice changes nothing. Importing an older export after a newer one loses nothing.
- **Bidirectional.** Work done on A and B independently can be merged in either direction, in any order, converging to the same state. The user does not have to remember which machine is authoritative.
- **Non-destructive by default.** A merge never deletes a task the import file lacks.

A separate, explicitly-labeled **Replace** mode wipes the local store first. It must require typed confirmation and must auto-export a backup beforehand. It exists for restoring a known-good snapshot, not for routine transfer.

**Mutable-field conflict rules.** These four groups of fields aren't append-only and need deterministic resolution (the two boolean flags above are a fifth case, still open under O-8):

| Field | Rule | Why |
|---|---|---|
| `TaskItem.status` | Derive from the newest `statusChanged` event across both sets | The event log is the truth; the field is a cache |
| `Project.lastStandupAt` | Take the **later** timestamp | Reporting is a historical fact. Taking the earlier one would re-report work already spoken aloud |
| `TaskItem.title`, `Project.name` | Later `modifiedAt` wins | `modifiedAt` exists on both models for this purpose (§3.1, §3.2) |
| `SourceRef.lastFetchedAt`, `.cachedSummary` | Later `lastFetchedAt` wins | Both describe the same external truth at different moments; the newer observation is simply better. `nil` loses to any value |

> Deriving `status` from events rather than merging the field is what makes the whole scheme robust. Any mutable field that can be recomputed from the log, should be.

### 10.2 Format

A single JSON file, `steno-export-YYYY-MM-DD.json`. Human-readable, greppable, diffable, and trivially inspected before import.

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-08-10T14:22:05Z",
  "exportedBy": "steno/1.0 (macOS)",
  "includesCachedExternalData": false,
  "projects":   [ ... ],
  "tasks":      [ ... ],
  "events":     [ ... ],
  "sourceRefs": [ ... ],
  "reports":    [ ... ]
}
```

- `schemaVersion` is mandatory. Import must refuse a version it doesn't understand with a clear message rather than partially applying it.
- `sourceRefs` is its own top-level array, keyed by `taskID` — refs are records with identities (§3.4), not fields of a task. Exporting them means a ref the user manually attached, or one whose source text was later redacted, survives transfer; re-deriving refs by re-running extraction on import would silently lose both.
- Cached external data (`SourceRef.cachedSummary`, `lastFetchedAt`) is **excluded by default** — it's bulky and re-fetchable. The `sourceRefs` array itself is always present; only those two fields are omitted. Opt-in toggle (`includesCachedExternalData`) for offline transfer.
- Gzip if size warrants; keep plain JSON the canonical format.

### 10.3 Secrets Are Never Exported

**No API keys, Atlassian tokens, or MCP server credentials in the export file, under any option.** Per §8 these live in Keychain and never enter SwiftData; the export serializes SwiftData only, so this holds by construction — but it must be asserted in a test, because the failure mode is a work token sitting in a file the user AirDrops or drops in a shared folder.

Integration *configuration* (site URLs, MCP server definitions minus secrets) may be exported, with the target machine prompting for credentials on first use.

### 10.4 Import Preview

Import must show a summary before committing, and must be cancellable:

```
Import steno-export-2026-08-10.json?
  + 12 new tasks, 3 new projects, 148 new events
  ~ 4 tasks updated (status changed on the other machine)
  = 61 records already present, skipped
```

Import runs in a single transaction. A malformed file leaves the store untouched.

### 10.5 Surfaces

- **GUI:** File → Export… / Import…, with the standard save/open panels.
- **CLI:** `make export FILE=...` and `make import FILE=...`, plus `steno export` / `steno import` subcommands on the app binary. Consistent with §9's CLI-first stance and makes the round-trip scriptable and testable.
- **Auto-export (recommended).** An optional setting: on quit, or daily, write an export to a user-chosen folder. Point that folder at Dropbox, Google Drive, or iCloud Drive and the user gets most of the value of sync for zero cost and no Apple enrollment. What it does not give you is real-time convergence — a machine must export before the other imports. Given single-user, one-machine-at-a-time usage, that gap is largely theoretical.

> With sync cancelled, **auto-export should default to ON** during onboarding rather than being an opt-in setting. It is the backup story as well as the transfer story.

Manual export's failure mode is human: forgetting to run it. Auto-export removes that, and should be surfaced during onboarding rather than buried in settings.

### 10.6 Test Requirements

Round-trip correctness is verified headlessly in `make test`:

- Export → import into an empty store → resulting object graph is identical.
- Import the same file twice → second import is a no-op (idempotency).
- Merge divergent stores in both orders → identical final state (commutativity).
- Export contains no string matching known credential patterns.
- Malformed and truncated files → clean rejection, store unchanged.

---

## 11. Delivery Plan

Each milestone must be independently usable. The user should be able to stop at any milestone and still have something better than paper.

| Milestone | Contents | Exit criterion |
|---|---|---|
| **M0 — Skeleton** | Repo init with `main` + branch protection (§9.6), XcodeGen project, Makefile, SwiftData local store, CloudKit-compatible schema, domain models, main window shell | Create projects and tasks; data survives relaunch; `make build/test` green; PR workflow enforced |
| **M1 — Capture** | Global hotkey, menu bar, quick-add, passive ref extraction, status control, notes | User can abandon the notebook for capture |
| **M2 — Report (no AI)** | Window computation, event gathering, raw grouped report, clipboard, `lastStandupAt` + undo | User can run a real DSU from the app |
| **M2.5 — Portability** | JSON export/import, merge-by-UUID, import preview, CLI subcommands, auto-export setting | Export from Mac A, import on Mac B, resume with nothing lost |
| **M3 — AI summarization** | Provider protocol, Anthropic provider, structured output, settings, degradation path | Polished summary; failure falls back cleanly to M2 output |
| **M4 — Atlassian** | Jira + Confluence connectors, caching, refresh policy, background refresh | Ticket detail appears in reports |
| **M5 — MCP** | MCP client (stdio only), server management UI | GitHub and Calendar working via off-the-shelf servers |
| **M6 — Stale detection** | Deterministic rule, badges, needs-attention view | Forgotten tasks surface without prompting |

**M6 is now the finish line, and M2 is still the true MVP.** It delivers the core value — accurate recall of what was done since the last stand-up — with no AI and no integrations. Everything after M2 is enhancement. Build in this order.

---

## 12. Open Questions

Resolve with the user before the milestone that depends on each.

**Resolved (v1.4):** Atlassian deployment → D19 Cloud. Task volume → D18 under 20. DSU-to-project mapping → D16, no schema change required.

**Resolved (v1.8):** task model's Swift type name → `TaskItem` (§3.2).

**Resolved (v1.7):** first-run `windowStart` → 24h (§3.5). Undo semantics → redaction (FR-4.1). Note grace window → redact-and-reappend (FR-2). `modifiedAt` → on both mutable models (§3.1, §3.2). `SourceRef` → first-class model with `id`, own export array (§3.4, §10.2). Periodic output schema → §7.3. Stale threshold precedence → FR-5. Bundle ID / deployment target → §9.1.

**Still open:**

1. **Q(M4):** Should a task auto-transition to `done` when its linked Jira ticket closes, or is the app's status independent of Jira's? (Recommend: independent, with a suggestion badge. Auto-transition would make the app's state depend on a system the user doesn't fully control.)
2. **Q(M3):** Should the app retain a history of past reports for browsing (e.g. for writing self-reviews or promo packets)? Cheap to add now, awkward to retrofit.
3. **Q(M1):** Should EM recurring activities (weekly 1:1s, review cycles) support task templates or recurrence? Deferred from v1; confirm this is acceptable.
4. **Q(M2) — partially resolved by §10.** Single-device is acceptable through M6 provided export/import lands at M2.5 as specified. Remaining question: is auto-export into a cloud-drive folder sufficient in daily practice, or does the user need true concurrent multi-machine editing sooner? If the answer is genuinely "not sufficient," that reopens §14.

---

## 13. Guidance for Implementing Agents

- **Branch, then PR — never commit to `main`.** Every task starts with a fresh branch off current `main` and ends with a pull request you do not merge. Full procedure in §9.5. This is the single most important process rule in this document.
- **Verify, don't assert.** Every change must be confirmed with `make build && make test` before being reported as complete. "This should compile" is not acceptable; §9 exists so there is no excuse.
- **Preserve the append-only invariant.** Do not add code paths that mutate or delete `Event` rows. Every feature that seems to need mutation actually needs a new event.
- **Never break capture latency.** Any change to the quick-add path is a performance-sensitive change. Measure it.
- **Keep layers separate.** `SourceConnector` and `AIProvider` are independent. A task that touches both is probably two tasks.
- **Degradation before enhancement.** Every network-dependent feature ships with its offline fallback in the same task, not a follow-up.
- **Respect the non-goals in §2.1.** This product's value comes from what it refuses to do. It is a recall tool. Proposals to add planning, tracking, or team features should be declined with reference to this document.

---

## 14. Explicitly Cancelled: iOS & Cloud Sync

Recorded so this is not silently reintroduced, and so the reasoning survives.

**Cancelled:** the iPhone app, CloudKit sync, TestFlight/App Store distribution, notarization, and Apple Developer Program enrollment.

**Why:** Steno is a personal tool for one developer on one Mac. The paid membership bought exactly two things — sync and an iOS client — and §10 export/import covers the first well enough for single-user usage. The second is a genuine loss, but a deferrable one.

**What this cancellation removes from the build:**
- Dual MCP transports (§5.4 is now stdio-only)
- Compact/touch layout work, share extension
- CloudKit entitlements, container config, sync conflict handling
- Any `SyncMode` branching outside the persistence layer

**What is deliberately retained despite the cancellation, and must not be stripped:**

| Retained | Cost to keep | Cost to reinstate later |
|---|---|---|
| CloudKit-compatible schemas (§6) | Zero — also required by export/import | A data migration on a live store |
| `AIProvider` / `SourceConnector` protocols (§5.1, §7.1) | Zero — justified independently by testability (§9.4) | Broad refactor |
| Model / AI / view-model separation from UI | Zero — good architecture regardless | Broad refactor |

These are not iOS scaffolding. Each earns its place on macOS-only grounds; keeping the door open is a side benefit.

**Revisit trigger.** One signal, and only one: the user repeatedly wants to capture a task while away from the Mac. FR-1 exists because capture latency decides whether this product survives — and a three-second capture the user cannot reach is a zero-second capture that never happens. If that starts occurring weekly, the $99 is trivially justified and this section becomes the implementation plan. Until then, it is out of scope and agents should decline work proposing it.
