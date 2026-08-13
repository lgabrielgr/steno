# DECISIONS.md — Steno

A log of decisions made **while building**, so a future reader does not have to reverse-engineer
them from the code.

## What goes where

This file and [`REQUIREMENTS.md`](REQUIREMENTS.md) must not become two sources of truth. The
split:

| Kind of decision | Lives in | Example |
|---|---|---|
| **Product** — what to build, what not to build | `REQUIREMENTS.md` §2 (locked decisions) and its changelog | "Statuses are the fixed four" (D11) |
| **Spec amendment** — implementation revealed the spec was wrong or silent | `REQUIREMENTS.md`, version bumped, changelog line — **and a one-line pointer here** | `TaskItem` naming (§3.2, v1.8) |
| **Implementation** — a real choice the spec doesn't constrain | **Here** | Which test framework; where the store file lives |
| **Process / tooling** — how the repo itself operates | **Here** | Squash-merge policy |

**The rule: nothing is described in full in two places.** If a decision changes the spec, the
spec carries it and this file carries a pointer. If you find a full duplicate, delete the copy
here and leave the pointer.

## Format

```
### D-NNN — Short title
**Date** · **Task** · **Status:** accepted | superseded by D-NNN

Decision in one or two sentences.

**Why:** the reasoning, including what it cost.
**Alternatives:** what was rejected and why.
```

---

## Accepted

### D-001 — Branch protection enforces against admins
**2026-08-11** · setup · **Status:** accepted

`main` requires a pull request, blocks force pushes and deletion, and has `enforce_admins`
enabled. Zero required approvals, so the sole reviewer can self-merge.

**Why:** §9.6 asks for protection that constrains *agents* — but agents act with the owner's
admin token, so with admins exempt the protection would not have covered the case it exists
for. The cost is that the owner also cannot push directly to `main`.
**Alternatives:** admin-exempt protection, which would have been decorative here.

### D-002 — Squash-merge is the default, carrying the PR body
**2026-08-11** · setup · **Status:** accepted

Merge commits disabled so squash is the default button; `squash_merge_commit_title: PR_TITLE`
and `squash_merge_commit_message: PR_BODY`. Head branches auto-delete on merge.

**Why:** one task, one commit on `main`, matching §9.5's one-task-per-PR rule. Carrying the PR
body into the commit is what keeps the *why* — which requirement, how verified, what was left
out — in `git log` rather than only on GitHub, as §9.5 asks of commit messages.
**Alternatives:** merge commits preserve intermediate history, but per-task PRs rarely have
intermediate history worth keeping.

### D-003 — Task model is named `TaskItem`
**2026-08-11** · pre-M0 · **Status:** accepted — **see [REQUIREMENTS.md §3.2](REQUIREMENTS.md#32-taskitem)**

Pointer only; the decision and its reasoning live in the spec (v1.8), because every implementer
reads §3.2 and would not necessarily read this file.

### D-004 — One task file per branch and PR
**2026-08-11** · pre-M0 · **Status:** accepted

REQUIREMENTS.md is decomposed into 36 task files in [`tasks/`](tasks/README.md), sequenced so
each task's dependencies are merged before it starts.

**Why:** §9.5 requires one task per PR and PRs small enough to actually read. A task is the
smallest unit that carries its own test cycle and is worth a fresh reviewer's gate; setup and
config fold into the task whose deliverable needs them.
**Alternatives:** milestone-sized PRs, which §9.5 rules out as unreviewable.

### D-005 — Harness files point at the spec rather than restating it
**2026-08-11** · pre-M0 · **Status:** accepted

`CLAUDE.md`, `AGENTS.md`, `ARCHITECTURE.md`, this file, and the task files cite REQUIREMENTS.md
sections instead of copying their content. `AGENTS.md` is a pointer to `CLAUDE.md`.

**Why:** duplicated guidance drifts, and a drifted instruction is worse than a missing one
because an agent follows it confidently.
**Alternatives:** self-contained harness files, which would need syncing on every spec change.

---

## Open — decided by the task that owns them

Each of these is a real choice the spec leaves open. The owning task decides it, records it in
its PR body, and adds an entry above.

| # | Question | Owning task |
|---|---|---|
| O-1 | Swift Testing or XCTest? Swift Testing ships with the Xcode 16 floor §9.1 already requires, and suits the table-driven tests in M1-01 and M2.5-02 | `M0-02` |
| O-2 | Final source directory layout — §5 of ARCHITECTURE.md is a proposal until this lands | `M0-01` |
| O-3 | Where the SwiftData store file lives — needed by M2.5-03's Replace mode and §8's "delete my data" | `M0-04` |
| O-4 | What updates `modifiedAt`, exactly — M2.5-02's conflict resolution inherits any ambiguity | `M0-03` |
| O-5 | Where "last-used project" is stored, and its behavior on first ever launch | `M1-02` |
| O-6 | Does the menu bar popover show in-progress tasks across all projects, or only the selected one? FR-1.2 doesn't say | `M1-04` |
| O-7 | Whether integration *configuration* (site URLs, MCP definitions minus secrets) is exported by M2.5-01 or added by M4-04/M5-02 | `M2.5-01` |

## Product questions — not for agents to decide

[`REQUIREMENTS.md §12`](REQUIREMENTS.md#12-open-questions) holds four open questions that are the user's call, not
an implementer's: Jira-driven auto-transition (Q(M4)), report history retention (Q(M3)), EM task
templates (Q(M1)), and whether auto-export is sufficient in practice (Q(M2) — a "no" reopens
§14). Raise them; do not resolve them.