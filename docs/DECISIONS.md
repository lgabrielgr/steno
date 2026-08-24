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

### D-006 — Source layout is `Steno/<Area>/`, closing O-2
**2026-08-13** · M0-01 · **Status:** accepted — layout amended by D-010

Sources live under `Steno/`, split by responsibility as
[`ARCHITECTURE.md` §5](ARCHITECTURE.md) proposes, starting with `Steno/App/`.
XcodeGen takes the whole directory as one source group, so a new area is a new
folder and needs no manifest change.

**Why:** things that change together live together, and `sources: [Steno]` means
M0-03 through M6 add directories without touching `project.yml` — one less
merge-conflict surface across 35 remaining task branches.
**Alternatives:** one XcodeGen source entry per area, which would make every
later task edit the manifest for no benefit.

### D-007 — Automatic signing without `-allowProvisioningUpdates`
**2026-08-13** · M0-01 · **Status:** accepted

`CODE_SIGN_STYLE = Automatic` with `CODE_SIGN_IDENTITY = Apple Development`
and no `-allowProvisioningUpdates` flag on the xcodebuild invocations.

**Why:** a macOS app whose only entitlement disables the sandbox needs no
provisioning profile, so the flag was unnecessary. It is the documented escape
hatch if a later task adds an entitlement that does require a profile.
**Alternatives:** passing the flag pre-emptively, which can trigger Apple ID
network round-trips during an otherwise offline build.

### D-008 — `pipefail` lives on `SHELL`, not `.SHELLFLAGS`, plus a regression guard
**2026-08-13** · M0-01 · **Status:** accepted

Shell flags are set on `SHELL` itself (`SHELL := /bin/bash -o pipefail -e -u`)
rather than via `.SHELLFLAGS`, plus a regression guard as the first recipe
line of `preflight`.

**Why:** macOS ships GNU Make 3.81, which predates `.SHELLFLAGS` (GNU Make
4.0) and **silently ignores it**. The plan originally specified
`.SHELLFLAGS`, so `pipefail`, `-e`, and `-u` were all inert — a failed
`xcodebuild | xcbeautify` exited 0 and the gate every §9.5 and CI check
depends on was decorative. Caught only by the deliberate-failure test. The
guard exists so it cannot silently regress.
**Alternatives:** inline `set -euo pipefail;` per recipe (a later task adding
a piped recipe would forget it); requiring Homebrew GNU Make 4 and `gmake`
(every doc and CI invocation says `make`, and plain `make` would still run
silently unguarded).

### D-009 — Swift 6 language mode is set explicitly in `project.yml`
**2026-08-13** · M0-01 · **Status:** accepted

`SWIFT_VERSION: "6.0"` is set explicitly in `project.yml` rather than left unset.

**Why:** REQUIREMENTS.md §9.1 deliberately does not pin the toolchain, but Xcode 26's default is
already Swift 6, so leaving the setting unset would make the effective language mode — and its
strict-concurrency-by-default behavior — depend on whichever Xcode happens to be installed. A
build that behaves differently on a different machine is exactly what §9's "verify, don't assert"
exists to prevent. The ~40-line app compiles cleanly under it today. M0-03 owns revisiting this if
SwiftData `@Model` plus actor isolation proves to be real friction, since that is the known place
strict concurrency and SwiftData collide.
**Alternatives:** leaving it unset (implicit and toolchain-dependent — the risk above); pinning to
Swift 5 (defers strict-concurrency work to M0-03 but starts the project on a language mode Apple
is already deprecating).

### D-010 — Testable code lives in a `StenoKit` framework
**2026-08-14** · M0-02 · **Status:** accepted — amends the layout in D-006

Three targets: `StenoKit` (framework, all logic), `Steno` (application, SwiftUI views and
`@main` only), `StenoTests` (unhosted unit-test bundle linking `StenoKit`). The rule for later
tasks: **if it cannot be tested without a window server, it does not belong in `Steno/`.**

**Why:** §9.4 requires `make test` to pass with the GUI session inactive. A hosted test bundle
launches the app under test, and `NSApplication` needs a window server — so the conventional
setup fails exactly the condition the requirement exists to enforce. An unhosted bundle avoids
that but cannot link an application target, which leaves a framework as the only place both the
app and the tests can link. The cost is real: a framework extraction at M0-02, before any domain
code exists to justify it.
**Alternatives:** a hosted bundle (would need a §9.4 amendment, and M1-07's CI runner is headless
too); compiling the app's sources a second time into the test bundle (headless, but the test
binary then diverges from the shipping one — tests pass against code the app does not run).
Deferring to M0-03 was rejected because it means moving SwiftData `@Model` types across a target
boundary under more pressure.

### D-011 — Swift Testing, with XCTest kept for `measure`
**2026-08-14** · M0-02 · **Status:** accepted — closes O-1

Swift Testing (`@Test`/`#expect`) is the convention. XCTest stays linkable for performance
assertions only; a PR introducing an XCTest case says why in its body.

**Why:** Swift Testing ships with the Xcode 16 floor §9.1 already requires, and its
parameterized cases suit the table-driven tests in M1-01 and M2.5-02 — a failing row names
itself instead of collapsing into one aggregate assertion failure. The exception exists because
Swift Testing has no equivalent of `measure { }`, and §1.1's capture-latency budget is a
non-negotiable that must be measured rather than assumed. Both frameworks run in one `xcodebuild
test` invocation, so the exception costs nothing structurally.
**Alternatives:** XCTest throughout (verbose table-driven tests); Swift Testing with no exception
(hand-rolled `ContinuousClock` timing, decided later under time pressure by a task that is not
about testing).

### D-012 — `make test` denies outbound network via `sandbox-exec`
**2026-08-14** · M0-02 · **Status:** accepted

`make test` runs `build-for-testing` unsandboxed, then `test-without-building` under
`Scripts/test-sandbox.sb`. Only the outbound rule is filtered — to `remote ip "*:*"`, so the
runner's own unix-domain IPC keeps working; inbound and bind are denied outright.

**Why:** §9.4 asks for proof the suite makes no network calls, which running offline does not
provide. Nothing calls the network yet, so the mechanism's entire value is catching the M4
connector task that adds a live call later — it has to outlive this PR. It is `make test` itself
rather than an opt-in `make test-offline` because D-008 already showed what an unenforced gate is
worth, and §9.5 step 4 says `make test`.

**The limit, found while proving it works:** the deny is genuine at the OS level — under
`sandbox-exec`, `curl` cannot connect — but it stops connections, not reads of an answer already
held locally. The verification probe first *passed* under the sandbox, in 0.007s, because the
xctest runner's `URLCache` (`~/Library/Caches/com.apple.dt.xctest.tool`) had been warmed by the
earlier unsandboxed run; clearing that cache and re-running, with no change to the profile or the
Makefile, produced the expected clean failure. So a cacheable GET served from a warm cache will
not trip this gate. The profile's reach is bounded the same way in a second respect: it binds
this process tree, so work handed to a system daemon outside it — a background-configuration
`URLSession`, brokered by `nsurlsessiond` — is not something `(deny network-outbound …)` is in a
position to stop. That is a statement about what the mechanism covers by construction, not an
observed leak; no probe has been run against it. Net: the gate catches the connection an M4
connector opens, which is the case it exists for, but do not read a green `make test` as proof
that no code path *wanted* the network.

**Alternatives:** a `URLProtocol` tripwire inside the bundle (misses sessions with custom
`protocolClasses`, and raw sockets — it enforces a convention, not a boundary); architectural
enforcement plus one manual check (the criterion becomes a claim in a PR body rather than a gate
that keeps working).

### D-013 — swift-format owns layout, SwiftLint owns semantics
**2026-08-14** · M0-02 · **Status:** accepted

`make lint` runs `swiftlint --strict`. `.swiftlint.yml` disables the rules swift-format governs.
`make format` uses `xcrun swift-format` from the Xcode toolchain, not a Homebrew formula.

**Why:** both tools have layout opinions, and two authoritative tools produce a loop where `make
format` leaves a clean diff that `make lint` still rejects, with no indication which to believe.
`--strict` is what makes §9.5 step 4 real — without it the gate passes on code carrying
warnings; the cost is that a false positive needs an explicit disable comment, which a reviewer
sees in the diff. Sourcing the formatter from `xcrun` adds no `make bootstrap` dependency and
tracks the compiler §9.1 already constrains.
**Alternatives:** SwiftLint authoritative with format advisory (reintroduces the loop);
non-strict linting (acceptance criterion #3 would hold only for error-level rules, and the
promised later tightening is exactly the task that never gets scheduled).

### D-014 — `make test` regenerates the project unconditionally; `build` does not
**2026-08-14** · M0-02 · **Status:** accepted

`test` depends on the phony `generate` target, so every `make test` runs `xcodegen` first.
`build` and `release` keep the cheaper mtime rule, where the `.pbxproj` is remade only when
`project.yml` or a `.swift` source is newer than it.

**Why:** XcodeGen writes every source file into the `.pbxproj` at generation time, so a newly
added `.swift` file is invisible to `xcodebuild` until the project is regenerated. The original
rule (`$(PBXPROJ): project.yml`) regenerated only when the manifest changed, which let `make
test` pass green while never compiling a newly added test file — demonstrated by adding a test
that asserts false and watching `make test` exit 0. The defect originated in M0-01, not M0-02.
The fix came in two parts: source files became prerequisites of the `.pbxproj` rule, and then
`test` was moved onto the phony `generate` target, because GNU Make 3.81 compares whole seconds,
so a source file created in the same second as the last generation counts as up to date. That
was not theoretical — it produced a false green on the first post-fix run. The asymmetry with
`build` is the point rather than an inconsistency. A source file missing from a *build* fails at
compile time — but only once something references it, so a new file nothing calls yet would build
green there too; what closes that gap is the triad rather than `build` alone, because the
generated scheme marks the app `buildForTesting` and `make test` therefore rebuilds all three
targets. A test file missing from a *test run* has no equivalent backstop: it passes green having
never run. The measured price is ~0.06s on a ~2.2s `make test` (~3%). The named side effect is that
`make test` rewrites `Steno.xcodeproj` on every run, which can disturb an open Xcode GUI session
— accepted because §9.2 makes the GUI optional, never required. A side benefit: deleting a test
file no longer needs a manual `make generate` first.
**Alternatives:** leaving `test` on the mtime rule (cheaper, but its whole-second granularity is
the failure mode above, and for a gate a slip is a silent green); regenerating unconditionally
for `build` and `release` too (pays the same cost and rewrites the project on every build to
prevent a failure that would have been loud anyway).

### D-015 — `modifiedAt` is stamped only by the fields it arbitrates
**2026-08-19** · M0-03 · **Status:** accepted — closes O-4

`modifiedAt` is written only by mutations to fields whose §10.1 conflict rule is "later
`modifiedAt` wins": `Project.name`, `.colorHex`, `.jiraProjectKeys`, `.isArchived`, `.sortOrder`,
`.reportCadence`, `.staleThresholdDays`; `TaskItem.title`, `.projectID`, `.isArchived`. Fields
with their own authority never touch it — `status`, `statusChangedAt` and `completedAt` are
derived from the event log, and `lastStandupAt` takes the later timestamp. `Project.lastStandupAt`
is a plain `var` rather than a `private(set)` with a mutator, so this holds by construction.

**Why:** `modifiedAt` is per *record*, not per field. Under a broad rule — every mutation stamps
it — a machine that changes only a task's status still advances the record's timestamp, and at
merge time that later stamp wins the *title* too, silently reverting a retitle made on the other
machine. The append-only log makes that recoverable only by hand. The narrow rule keeps the
timestamp attached to exactly the fields it arbitrates, and matches how §3.1 and §3.2 already word
it: "last mutation of a mutable field (`name`, `colorHex`, …)".
**Alternatives:** stamping on every mutation (the lost update above); per-field timestamps (exact
at merge, but it contradicts §3.1/§3.2's field tables, grows the schema, and hands M2.5-02 more
cases rather than fewer).

### D-016 — `TaskItem`↔`SourceRef` carries both a relationship and the foreign key
**2026-08-19** · M0-03 · **Status:** accepted

`TaskItem.sourceRefs: [SourceRef]?` with `@Relationship(inverse: \SourceRef.task)`, alongside
`SourceRef.taskID`. **`taskID` is authoritative**: export, import, and M2.5-02's merge read it,
and a test asserts `ref.taskID == ref.task?.id` holds across a save and a reload through a
separate `ModelContext`, so the assertion can only pass if the data actually reached the store —
not merely that the issuing context still has the objects registered in memory. Every other link
in the domain — `Event.taskID`, `TaskItem.projectID`, `StandupReport.projectID` — is a UUID
foreign key with no relationship.

**Why:** §3.2's field table lists `sourceRefs` as a relationship while §3.4 gives `SourceRef` its
own `taskID`, and the M0-03 task file requires UUID foreign keys because merge-by-UUID depends on
them. Both were kept, at the user's direction, for call-site ergonomics. The cost is that one fact
has three representations — `taskID`, the relationship, and its CloudKit-required inverse — which
is why the coherence test exists rather than a convention.
**Alternatives:** `taskID` alone with no stored array (one source of truth, nothing for merge to
reconcile, but it needs a §3.2 amendment and every reader of a task's refs pays for it).

### D-017 — The store is `~/Library/Application Support/Steno/`, closing O-3
**2026-08-21** · M0-04 · **Status:** accepted

`StenoStore.defaultURL` is `~/Library/Application Support/Steno/Steno.store`, set through an
explicit `ModelConfiguration(url:)`. `StenoStore.storeDirectory` — the *directory* — is public and
is the unit M2.5-03's Replace mode and §8's "delete my data" remove. `live(at:)` creates that
directory itself before opening the store.

**Why:** an implicit default is a path both M2.5-03 and §8 would have to re-derive, and one Apple
is free to change between releases. The directory rather than the file, because a SwiftData store
is three files — `Steno.store`, `Steno.store-shm`, `Steno.store-wal` — and deleting the first
alone strands the write-ahead log. The `createDirectory` call looks redundant and is not: Core
Data *does* recover from a missing parent, but only after logging roughly 200 lines to stderr,
including `Sandbox access to file-write-create denied` and `NSCocoaErrorDomain (512)`, which is
what first launch would look like under `make run` (§9.2). No test can catch its removal — the
container opens either way — so this entry is the guard.
**Alternatives:** SwiftData's default location (less code; leaves two later features re-deriving
an implicit path).

### D-018 — A store that will not open shows a failure scene, not a crash or a fallback
**2026-08-21** · M0-04 · **Status:** accepted

`StenoApp` builds the container into a `Result` and switches the root scene: success gets
`MainWindowView`, failure gets `StoreFailureView`, which names the store path and the underlying
error and offers Quit.

**Why:** Apple's `.modelContainer(for:)` traps, which reads as a crash to anyone not watching
stderr — and a store that cannot open is the situation where the reason matters most. Falling back
to an in-memory container was rejected outright: for a capture tool, accepting writes that
evaporate at quit is worse than refusing to launch (§1.1), because the loss surfaces at the next
stand-up. §13's "degradation ships with the feature" is scoped to network-dependent features
(§7.4); it does not ask for a store that pretends to persist.
**Alternatives:** `fatalError` with a logged reason (cheapest; invisible unless stderr is being
watched). M0-05 inherits a root scene conditional on container construction, which is deliberate.

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

### D-021 — M0-05's interim behaviours, and who supersedes them
**2026-08-24** · M0-05 · **Status:** accepted

Three rules in `MainWindowModel` are deliberately provisional, standing in for specs that need
data this milestone doesn't have yet:

- **DONE's cutoff is a fixed 24 hours** (`doneCutoff()`), not FR-3's actual report window.
  Superseded by M2-01, which computes the window from `project.lastStandupAt` (D8) — a field that
  stays nil, and so answers identically to the fixed cutoff, until M2-03 ships the Copy action that
  advances it.
- **Under "All", a new task's target project is the first by `sortOrder`** (`targetProjectID()`),
  not FR-1.4's specified "last-used project". Superseded by M1-02, which owns that rule along with
  first-launch behaviour.
- **Archiving hides a project's tasks by an in-memory join, not a stored flag.** `archive()` sets
  only `Project.isArchived`; `TaskItem` has no archived bit of its own. `MainWindowModel.fetchTasks()`
  fetches every non-deleted task and filters it to the set of currently-visible project IDs after
  the fact — "a project's tasks disappear when it archives" is an emergent property of that one
  filter, not a fact stored anywhere.

**Why:** each rule ships a real, spec-compliant behaviour for every state M0-05 can reach, while
naming the milestone that owns the general case, so the stand-in is never mistaken for the spec.
**Alternatives:** blocking M0-05 on the real rules landing first — rejected, since none of the
three specs (report window, last-used project, an archived-task flag) has an owner yet and the
main window is otherwise ready to ship.
**The archived-task rule is the one with teeth.** It lives only in `fetchTasks()`. Any future query
that wants "live tasks" and does not re-apply the visible-projects filter will silently include
tasks belonging to an archived project. The two places this is likeliest to bite: M6-01's
stale-task detection, and M2-01's event-gathering for the report window — both need "tasks
belonging to a live project," and neither gets it for free from the store.

---

## Open — decided by the task that owns them

Each of these is a real choice the spec leaves open. The owning task decides it, records it in
its PR body, and adds an entry above.

| # | Question | Owning task |
|---|---|---|
| O-5 | Where "last-used project" is stored, and its behavior on first ever launch | `M1-02` |
| O-6 | Does the menu bar popover show in-progress tasks across all projects, or only the selected one? FR-1.2 doesn't say | `M1-04` |
| O-7 | Whether integration *configuration* (site URLs, MCP definitions minus secrets) is exported by M2.5-01 or added by M4-04/M5-02 | `M2.5-01` |
| O-8 | How import merges the two mutable boolean flags, `Event.isRedacted` and `StandupReport.isUndone` — §10.1's union-by-UUID default has no rule for them and neither model carries `modifiedAt` | `M2.5-02` |

## Product questions — not for agents to decide

[`REQUIREMENTS.md §12`](REQUIREMENTS.md#12-open-questions) holds four open questions that are the user's call, not
an implementer's: Jira-driven auto-transition (Q(M4)), report history retention (Q(M3)), EM task
templates (Q(M1)), and whether auto-export is sufficient in practice (Q(M2) — a "no" reopens
§14). Raise them; do not resolve them.