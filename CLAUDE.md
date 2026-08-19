# CLAUDE.md

Entry point for any agent working in this repository. Read this first, then the task file you
were given.

**Steno** is a personal macOS/SwiftUI recall tool: it answers "what did I do since my last
stand-up, for this project, in enough detail to say it out loud?" It is a **recall tool, not a
project management tool** — its value comes as much from what it refuses to do as from what it
does.

## Document map

| Document | What it is | When you need it |
|---|---|---|
| [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) | **The source of truth.** Product decisions, domain model, functional requirements, process rules | Always. Every task cites its sections |
| [`docs/tasks/`](docs/tasks/README.md) | 36 sequenced task files, one per branch/PR | To find what you're building and what's out of scope |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Layer map, dependency rules, invariants and where they're enforced | Before writing code that spans layers |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Implementation decisions made during the build | When something in the code looks arbitrary |
| [`docs/superpowers/specs/`](docs/superpowers/specs/), [`docs/superpowers/plans/`](docs/superpowers/plans/) | Per-task design and implementation records | Historical only — superseded by `DECISIONS.md` where the two disagree |

**These files point at REQUIREMENTS.md rather than restating it.** If you find a harness file
duplicating a requirement, that duplicate is a drift risk — fix it by replacing the copy with a
pointer, not by syncing the two.

## The non-negotiables

Each is stated fully in REQUIREMENTS.md; these are the pointers.

1. **Never commit to `main`. Branch, then PR, then stop.** Every task is one branch and one
   pull request that *you do not merge* — the user reviews and merges. Full procedure in §9.5.
   `main` is protected, so a direct push will fail regardless.
2. **Verify, don't assert.** `make build && make test && make lint` must all pass before you
   open a PR (§9.5 step 4, §13). "This should compile" is not acceptable — §9 exists so there
   is no excuse.
3. **The event log is append-only, with no exceptions.** Never mutate or delete an `Event` row;
   the only permitted write to an existing event is flipping `isRedacted`. Every feature that
   seems to need mutation actually needs a new event or a redaction (§3.3, §13).
4. **Never break capture latency.** Any change to the quick-add path is performance-sensitive
   and must be measured, not assumed. If capture exceeds ~3 seconds or blocks on project
   selection, the user reverts to paper and the product dies (§1.1, §13).
5. **Keep layers separate.** `SourceConnector` and `AIProvider` are independent. A task that
   touches both is probably two tasks (§5.1, §7.1, §13). See `docs/ARCHITECTURE.md`.
6. **Degradation ships with the feature, not after it.** Every network-dependent feature lands
   with its offline fallback in the same PR (§13). The user must never arrive at a stand-up
   empty-handed because of a network error (§7.4).
7. **Respect the non-goals.** §2.1 and §14 list what this product deliberately will not do.
   Decline proposals to add them, with a pointer to the section.

## Working a task

1. `git checkout main && git pull` — always branch from current `main`, never from another
   task branch.
2. `git checkout -b <branch named in the task file>` (see §9.5 for the prefix table).
3. Read the task file and the REQUIREMENTS.md sections it cites.
4. Implement. Follow the task's **Out of scope** list — it exists to keep the PR reviewable and
   to protect the next task's boundary.
5. `make build && make test && make lint`.
6. Commit with a message explaining *why*, not just *what*, prefixed with a Conventional
   Commits type (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`).
7. Push and open a PR. The template will prompt for what §9.5 requires.
8. **Stop.** Do not merge.

## Commands

All entry points are `make` targets defined in the repo root `Makefile` (§9.2). Xcode's GUI is
optional, never required.

```
make bootstrap   # install toolchain deps (xcodegen, xcbeautify, swiftlint); idempotent
make generate    # regenerate Steno.xcodeproj from project.yml
make build       # debug build into .build/
make run         # kill running instance, build, launch with stdout/stderr streaming
make test        # unit tests, headless, no network
make lint        # SwiftLint
make format      # swift-format
make clean       # remove .build/ and the generated project
make release     # release build of the .app bundle
```

> All of these exist as of `M0-02`. `make test` runs headless with outbound networking denied by
> a `sandbox-exec` profile (§9.4, D-012) — if a change makes it need the network, that is the
> finding, not the obstacle.

Never commit `Steno.xcodeproj` (generated per §9.1) or `Local.xcconfig` (§9.3). Both are
gitignored; if either appears in `git status`, something is wrong.

## When the spec is wrong

REQUIREMENTS.md is authoritative but not infallible — three rounds of review have already found
contradictions in it. If implementation reveals a requirement that is wrong, ambiguous, or
impossible:

**Say so in the PR body. Do not silently deviate.** A PR that quietly contradicts
REQUIREMENTS.md is worse than one that pauses to ask (§9.5). If the fix is a spec amendment,
amend REQUIREMENTS.md in the same PR, bump its version, and add a changelog line.