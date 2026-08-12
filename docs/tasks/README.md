# Steno — Task Index

One file per task. Each is scoped to be a single branch and a single pull request per
[REQUIREMENTS.md §9.5](../REQUIREMENTS.md), and small enough that an agent with no prior
context can pick it up, spec it, plan it, and implement it in one session.

**Source of truth is [REQUIREMENTS.md](../REQUIREMENTS.md).** These files do not restate it —
they point at it. Where a task file and REQUIREMENTS.md disagree, REQUIREMENTS.md wins, and the
disagreement is a bug worth raising in the PR body (§9.5).

## How to run a task

1. Read the task file and the REQUIREMENTS.md sections it cites.
2. `git checkout main && git pull`, then `git checkout -b <branch from the task file>`.
3. Brainstorm → spec → plan → implement.
4. `make build && make test && make lint` — all three green before the PR (§9.5 step 4).
5. Open the PR. **Do not merge it.**

## Task boundaries

Tasks are ordered so that each one's dependencies are already merged. Sequential execution is
the intended mode — a task assumes everything above it exists. Where two tasks are genuinely
independent, the `Depends on` field says so.

Two rules shaped the boundaries:

- **A task is the smallest unit worth a separate review gate.** Setup, config, and docs fold
  into the task whose deliverable needs them rather than becoming their own task.
- **Layer separation from §13 is a boundary.** `SourceConnector` and `AIProvider` work never
  share a task. A task touching both is two tasks.

## Milestones

Per §11, each milestone is independently usable — you can stop at any one and still have
something better than paper. **M2 is the true MVP; M6 is the finish line.**

### M0 — Skeleton
> Exit: create projects and tasks, data survives relaunch, `make build/test` green.

| Task | Deliverable |
|---|---|
| [M0-01](M0-01-build-system.md) | XcodeGen project, Makefile, stable signing — `make build` green |
| [M0-02](M0-02-test-lint-harness.md) | Headless test target and SwiftLint — `make test`/`make lint` green |
| [M0-03](M0-03-domain-models.md) | The five SwiftData models, CloudKit-compatible |
| [M0-04](M0-04-persistence-container.md) | Local store wiring; data survives relaunch |
| [M0-05](M0-05-main-window-shell.md) | Three-column shell; create and list projects and tasks |

### M1 — Capture
> Exit: the user can abandon the paper notebook for capture.

| Task | Deliverable |
|---|---|
| [M1-01](M1-01-reference-extraction.md) | Passive ref extraction (FR-1.5) — pure, headless-tested |
| [M1-02](M1-02-quick-capture-core.md) | The one shared capture code path, with project auto-routing |
| [M1-03](M1-03-global-hotkey.md) | Global hotkey and floating window (FR-1.1) |
| [M1-04](M1-04-menu-bar.md) | Menu bar item and popover (FR-1.2) |
| [M1-05](M1-05-status-control.md) | Status transitions and `statusChanged` events |
| [M1-06](M1-06-progress-notes.md) | Notes, timeline, redact-and-reappend grace window (FR-2) |
| [M1-07](M1-07-ci-workflow.md) | GitHub Actions running build/test/lint on every PR (§9.6) |
| [M1-08](M1-08-settings-shell-and-capture-pane.md) | Settings window plus the Capture pane; later panes attach here |

### M2 — Report, no AI
> Exit: the user can run a real stand-up from the app. **This is the MVP.**

| Task | Deliverable |
|---|---|
| [M2-01](M2-01-report-window.md) | Window computation and event gathering (D8) |
| [M2-02](M2-02-raw-report-renderer.md) | Deterministic markdown for both cadences — also the §7.4 fallback |
| [M2-03](M2-03-report-ui-and-copy.md) | Editable draft, clipboard, and the three Copy side effects |
| [M2-04](M2-04-undo-standup.md) | Undo via redaction (FR-4.1) |

### M2.5 — Portability
> Exit: export from Mac A, import on Mac B, resume with nothing lost. Core, not optional (§10).

| Task | Deliverable |
|---|---|
| [M2.5-01](M2.5-01-export-encoder.md) | JSON export, secrets-free by construction |
| [M2.5-02](M2.5-02-import-merge.md) | Merge-by-UUID: idempotent, bidirectional, non-destructive |
| [M2.5-03](M2.5-03-import-preview-ui.md) | Preview, cancel, single-transaction apply, Replace mode |
| [M2.5-04](M2.5-04-cli-subcommands.md) | `steno export`/`import` and the matching make targets |
| [M2.5-05](M2.5-05-auto-export.md) | Auto-export, defaulting ON at onboarding |

### M3 — AI summarization
> Exit: polished summary; failure falls back cleanly to M2 output.

| Task | Deliverable |
|---|---|
| [M3-01](M3-01-ai-provider-protocol.md) | `AIProvider` protocol, credential enum, Keychain storage |
| [M3-02](M3-02-anthropic-provider.md) | Anthropic provider with a runtime-fetched model list |
| [M3-03](M3-03-summarization-call.md) | Both output schemas, prompt constraints, degradation path |
| [M3-04](M3-04-ai-settings-ui.md) | Provider, key, model picker, Test connection |

### M4 — Atlassian
> Exit: ticket detail appears in reports.

| Task | Deliverable |
|---|---|
| [M4-01](M4-01-source-connector-protocol.md) | `SourceConnector`, refresh policy, cache, never-block guarantee |
| [M4-02](M4-02-jira-connector.md) | Jira REST v3 read-only, with token-expiry handling |
| [M4-03](M4-03-confluence-connector.md) | Confluence read-only on the same credential |
| [M4-04](M4-04-integrations-settings-ui.md) | Credential entry, expiry warning, connection test |
| [M4-05](M4-05-background-refresh.md) | Scheduled refresh so the morning view is instant |

### M5 — MCP
> Exit: GitHub and Calendar working via off-the-shelf servers.

| Task | Deliverable |
|---|---|
| [M5-01](M5-01-mcp-stdio-client.md) | JSON-RPC over pipes to a subprocess, stdio only |
| [M5-02](M5-02-mcp-server-management.md) | Add, configure, enable, and test servers |
| [M5-03](M5-03-mcp-source-adapter.md) | MCP resources as `SourceRef`s; tools exposed to the AI layer |

### M6 — Stale detection
> Exit: forgotten tasks surface without prompting. **Finish line.**

| Task | Deliverable |
|---|---|
| [M6-01](M6-01-stale-rule.md) | The deterministic rule and its resolution order (FR-5) |
| [M6-02](M6-02-needs-attention-view.md) | Badges and the needs-attention section |

## Not tasks

Per §2.1 and §14, these are out of scope and a proposal to build one should be declined with a
pointer to this line: writing to Jira, time tracking, team features, sprint planning, OCR,
custom statuses, prioritization, auto-posting to Slack, iOS, and CloudKit sync.