# ARCHITECTURE.md — Steno

**Status:** target architecture. Most of it does not exist yet — it is built across M0–M6 (see
[`tasks/README.md`](tasks/README.md)). Update this file as structure lands, in the PR that
lands it.

This document describes **shape and rules**: what the layers are, which may depend on which,
and where each invariant is enforced. It does not restate requirements —
[`REQUIREMENTS.md`](REQUIREMENTS.md) is the source of truth, and sections are cited throughout.

---

## 1. The spine: an append-only event log

Everything that happens to a task is an immutable event appended to a stream. Task state is
derived; history is never mutated (§3, D10).

```
Project (1) ──< TaskItem (1) ──< Event
                        (1) ──< SourceRef
Project (1) ──< StandupReport
```

This one decision is why the rest of the system is simple:

- **The stand-up report is trivially correct.** A report is a query over a time window, not a
  reconstruction — "what happened between `windowStart` and now" has exactly one answer (§3,
  FR-4).
- **The AI prompt is reliable.** The model summarizes a factual record rather than inferring
  history, which is what makes its output trustworthy enough to say out loud (§7.3).
- **Import merge is nearly free.** An event either exists on the target machine or it does not;
  there is no such thing as a changed event to reconcile (§10.1).

`TaskItem.status` is a **cache**, not the truth. The truth is the newest `statusChanged` event
— which is why M2.5-02's merge derives status from the log rather than copying the field, and
why a status transition that skips its event is a real bug that will surface much later as an
inexplicable revert after an import (§10.1).

> The Swift type is `TaskItem`, not `Task`, because `Task` shadows `_Concurrency.Task` (§3.2).
> Domain vocabulary is unaffected: prose, UI, the export key `"tasks"`, and the `taskID` field
> all still say "task".

---

## 2. Layers and dependency rules

```
        ┌──────────────────────────────────────────┐
        │  UI  (SwiftUI views)                     │
        ├──────────────────────────────────────────┤
        │  View models / services                  │
        ├───────────────┬──────────────┬───────────┤
        │  AI layer     │  Source layer│  Report   │
        │  AIProvider   │ SourceConn.  │  engine   │
        ├───────────────┴──────────────┴───────────┤
        │  Persistence  (SwiftData, local store)   │
        ├──────────────────────────────────────────┤
        │  Domain models                           │
        └──────────────────────────────────────────┘
```

**The rules, in priority order:**

1. **`AIProvider` and `SourceConnector` never reference each other.** Swapping AI providers
   must not affect integrations, and vice versa (§5.1, §7.1). A task touching both is probably
   two tasks (§13). The single sanctioned point of contact is §5.4's exposure of MCP tools to
   the AI layer during enrichment — narrow and specified.
2. **Views do not touch the store directly.** View models mediate. §14 lists this separation as
   deliberately retained and not to be stripped; it is justified on testability grounds alone
   (§9.4), independent of any sync ambition.
3. **The report engine depends on the domain and the store, not on the AI layer.** M2-02's
   deterministic renderer must work with no provider configured — that is what makes §7.4's
   fallback a first-class path rather than an error handler.
4. **Every external call sits behind a protocol with a test double** (§9.4). `make test` passes
   with networking disabled; if it can't, the boundary is in the wrong place.

**Why the protocols exist,** since sync and iOS are cancelled (§14) and someone will eventually
propose deleting them: they are justified on macOS-only, single-user grounds — testability
(§9.4) and provider swappability (§7.1). Keeping them costs nothing; reinstating them later is
a broad refactor.

---

## 3. Invariants and where they live

| Invariant | Rule | Enforced in | Spec |
|---|---|---|---|
| Append-only | No write to an existing `Event` except `isRedacted` | Domain models expose no mutating API (M0-03); notes redact-and-reappend (M1-06) | §3.3, §13 |
| Status has an event | Every transition appends `statusChanged` | Single status service (M1-05) | §3.2, §10.1 |
| Capture never blocks | No modal, picker, or validation before text entry | Capture core (M1-02) | §1.1, FR-1.4 |
| Preview is side-effect free | Only Copy advances `lastStandupAt` | Report engine (M2-01), report UI (M2-03) | FR-4 |
| CloudKit-compatible schema | Defaults or optionals everywhere; no `@Attribute(.unique)` | Domain models (M0-03), asserted in tests | §6 |
| Secrets never persisted | Keychain only; never SwiftData, `UserDefaults`, plists, logs | Credential layer (M3-01), asserted in export tests (M2.5-01) | §8, §10.3 |
| Reads only, permanently | No mutating request to Jira or Confluence | Connectors (M4-02, M4-03) | D5 |
| Integrations never block | A failed fetch degrades to cache, never stops a report | Connector registry (M4-01) | §5.5, §7.4 |

Where a row says "asserted in tests", that is deliberate: these are the invariants whose
violation is invisible in review and expensive in production.

---

## 4. Data flow: the two paths that matter

**Capture** (latency-critical — §1.1)

```
hotkey / menu bar / main window
        └─> capture core ──> ref extraction (pure) ──> store
                          └─> project routing (ticket-key prefix, else last-used)
```

Three surfaces, one code path (D15). Extraction is passive and silent — no `@project`, no
`#tag`; the user explicitly declined a command grammar (FR-1.5).

**Report** (correctness-critical — §7.3, §7.4)

```
project ──> window computation (pure, no side effects)
        ──> event gathering  ──> ref refresh (best-effort, non-blocking)
        ──> AI summarize ──┐
            or fallback ───┴──> markdown render ──> editable draft ──> Copy
                                                                       └─> advance clock,
                                                                           append events,
                                                                           persist report
```

The fallback is not an error handler. It is built first (M2-02, before M3) and selected when
the AI path is unavailable — because §7.4 makes producing *some* report a P0 guarantee.

---

## 5. Where code lives

Landed by M0-01 (D-006, closing O-2). `App/` exists; the rest are
forward-looking, listed with the task that adds them:

```
Steno/
  App/            StenoApp.swift, ContentView.swift, Logging.swift
  Steno.entitlements
  Models/         SwiftData models, enums          (M0-03)
  Persistence/    container, store config           (M0-04)
  Capture/        capture core, ref extraction      (M1-01, M1-02)
  Report/         window computation, renderers     (M2-01, M2-02)
  Portability/    export, import, merge             (M2.5)
  AI/             AIProvider, AnthropicProvider     (M3)
  Sources/        SourceConnector, Jira, Confluence, MCP  (M4, M5)
  Features/       views + view models, by feature
Tests/            mirrors the above; headless, no network
project.yml       XcodeGen manifest — the .xcodeproj is generated and gitignored (§9.1)
Makefile          the only entry point you need (§9.2)
```

Split by responsibility rather than by technical layer: things that change together live
together. Prefer smaller focused files — a file you can hold in your head at once is one you
can edit reliably.

---

## 6. What this architecture deliberately excludes

Not oversights. Each is a locked decision, and a proposal to add one should be declined with a
pointer to the cited section.

- **No backend, no server, no account system** (D3). Zero infrastructure.
- **No sync.** Multi-machine transfer is export/import only (§10, §14). CloudKit-compatible
  schemas are nonetheless retained — see §6's standing instruction not to strip them.
- **No iOS target**, no share extension, no touch layout (D1, §14).
- **No HTTP/SSE MCP transport.** stdio only; macOS-only is what buys this simplification
  (§5.1, §5.4).
- **No write path to Jira or Confluence**, ever (D5).
- **No pagination, virtualization, search, or filter chips.** Under 20 live tasks (D18); "if
  the task list ever needs a scrollbar the user has a workflow problem, not a UI problem"
  (FR-3).
- **No prioritization, ranking, or focus suggestions** (D12, §2.1).