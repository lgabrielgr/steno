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

> **Amended by D-099 (2026-09-12).** This entry's description of `lastStandupAt`'s merge rule as
> "take the later timestamp" no longer holds — M2.5-02 derives it from the project's reports. The
> conclusion it draws is unaffected: the field still must not stamp `modifiedAt`, and a plain
> property is still how that is guaranteed rather than remembered.
**2026-08-19** · M0-03 · **Status:** accepted — closes O-4

`modifiedAt` is written only by mutations to fields whose §10.1 conflict rule is "later
`modifiedAt` wins": `Project.name`, `.colorHex`, `.jiraProjectKeys`, `.isArchived`, `.sortOrder`,
`.reportCadence`, `.staleThresholdDays`; `TaskItem.title`, `.projectID`, `.isArchived`. Fields
with their own authority never touch it — `status`, `statusChangedAt` and `completedAt` are
derived from the event log, and `lastStandupAt` has a rule of its own. `Project.lastStandupAt`
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
container means there is no route from a view to *query* the store by accident. Every behaviour
in the main window — grouping, the DONE window, project scoping, the `created` event, archive
filtering — is therefore covered by the headless bundle, which matters more than usual here
because GUI automation is unavailable on this machine.

**What this does NOT close, stated precisely because the obvious reading overclaims it.** This
closes the *read* path only. The model publishes live `@Model` objects — `projects` is `[Project]`,
and `groups` carries `[TaskItem]` — and those types expose public mutators (`rename(to:at:)`,
`setStatus(_:at:)`, `setArchived(_:at:)`). A view therefore *holds* objects it could mutate, and
because `save(context)` commits every pending change in the context, such a mutation would be
persisted by the next unrelated `perform(_:_:)` — a write nobody asked for, riding along on a
save for something else. No view does this today: the only production mutator call is
`MainWindowModel.archive`. **The danger is M1-05's:** a view calling `setStatus` directly would
change status *without* appending the `statusChanged` event, which ARCHITECTURE §1 names as a bug
that surfaces much later as an inexplicable revert after an import (§10.1). M1-05 owns the status
service and should close this by construction — reducing the domain mutators from `public` to
`internal` compiles today (the sole production caller is inside `StenoKit`, and tests use
`@testable import`), and is the cheapest option; mapping to value types is the thorough one.
Deliberately not done here: it changes M0-03's domain API, which deserves its own task and review
rather than a tail-end amendment to this one.
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

### D-022 — `SourceRef.identifier` must be unique within its kind
**2026-08-25** · M1-01 · **Status:** accepted

Spec amendment — carried in full by `REQUIREMENTS.md` §3.4 (v1.10). §3.4's "PR number" could not
serve as an identifier, because the same section makes a ref unique per
`(taskID, kind, identifier)`. GitHub identifiers are repo-qualified (`acme/api#421`).

### D-023 — `opening_brace` is disabled; swift-format owns brace placement
**2026-08-25** · M1-01 · **Status:** accepted · extends D-013

`make format && make lint` — the exact sequence §9.5 step 4 requires — failed on `main` before
this branch started, with three `opening_brace` violations in M0-05 files
(`Steno/Features/MainWindow/TaskListView.swift:66`, `StenoKit/Features/MainWindow/MainWindowModel.swift:92`
and `:143`). swift-format breaks a multi-clause `if let` and a long generic signature across
lines, and SwiftLint `--strict` then rejects its own formatter's output — latent since M0-05
merged because no task had run `make format` since. Commit `43f563d` restructured the three
sites; it also touched `StenoKit/Features/MainWindow/TaskGrouping.swift:31-32`, which was not a
violation but swift-format layout the same run rewrote, folded in so the tree stayed
format-stable. `opening_brace` is now in `.swiftlint.yml`'s `disabled_rules`, and the two
`if`-restructurings that existed only to satisfy it are reverted (the generic-signature wrap and
the `TaskGrouping` change stay — those are formatter output, not lint appeasement).

**Why:** the rule is pure layout, which D-013 already assigns to swift-format; this extends that
division rather than contradicting it. Its only observed effect here was rejecting the
formatter's own output and forcing correct code to be rewritten by hand — the loop D-013 exists
to prevent. Its residual value is nil, because `make format` normalises a hand-written misplaced
brace anyway.
**Alternatives:** per-site restructuring, as `43f563d` did (pays the cost again at every
multi-clause `if let` anyone writes, in code that was already correct); `swiftlint:disable`
comments (D-013 reserves those for genuine false positives, which this is not — the rule is
working as designed and the design is wrong for this repo).

### D-024 — "Last-used project" is derived from the newest task, not stored
**2026-08-26** · M1-02 · **Status:** accepted

FR-1.4's "default to the last-used project" is answered by a query — the project of the most
recently created `TaskItem` — rather than by a stored `lastUsedProjectID`. No new field, no
`UserDefaults` key, no settings row.

**Why:** it cannot drift from reality; all three capture surfaces agree by construction rather
than by each remembering to write the same key; and it round-trips through §10's JSON export for
free, because it is not a separate fact at all. D18 caps the dataset under 20 live tasks, so the
read costs nothing.
**Alternatives:** a `UserDefaults` key written on each save (fastest read, but state outside the
store — it does not export, and it can point at an archived project, needing validation on read
anyway); a singleton settings row in SwiftData (portable, but a schema addition that §6's
CloudKit-compat rules and M2.5-02's merge would both then have to reason about, for one UUID).
**The trap, and it is D-021's:** the derivation must re-apply the visible-projects filter.
A task row does not encode whether its **project** is archived — `TaskItem.isArchived` exists and
the fetch does use it, but it tracks the task, not the project — and no predicate on `TaskItem` can
express "belongs to a live project", because D-021 makes that an in-memory join rather than a
stored fact. So `fetchLimit = 1` returns the newest unarchived task, which may still sit in an
archived project, and routes the capture somewhere the user cannot see it. The join must happen
after the fetch.

### D-025 — Routing scans for ticket keys directly, not through `ReferenceExtractor`
**2026-08-26** · M1-02 · **Status:** accepted

`ProjectRouter.ticketKeyMatch` runs `JiraKey.pattern` over the text with an early exit. It does
not call M1-01's extractor, and the two therefore disagree about keys inside links — deliberately.

**Why, twice over.** *Cost:* the chip re-derives on every keystroke, and `NSDataDetector` is the
expensive half of extraction — 180 µs on a capture string but ~180 ms on a 250 KB paste, which
would then be paid per keystroke. A regex scan with an early exit is the cheaper of the two.

**Corrected before merge — this entry originally claimed the regex scan "has no such cliff", and
that was asserted, not measured.** It has one. A large paste containing no resolving key defeats
the early exit, and a paste dense in the false positives `JiraKey` documents (`UTF-8`, `ISO-8601`,
`COVID-19`) defeats it while also maximising the match loop. Worse, `JiraKey.pattern` must be a
computed property — `Regex` is not `Sendable` — so reading it inside the loop condition built a
fresh `Regex` per iteration: **342 ms on a 250 KB adversarial paste, per keystroke, on the main
actor.** Hoisting it to a local before the loop brings that to 21 ms (both `-O`). The scan is still
cheaper than paying `NSDataDetector` on top of it, which is what this decision is actually about —
but "no cliff" was wrong and the number is now gated by
`CapturePerformanceTests.testKeyScanOnALargePasteStaysInteractive` rather than claimed in prose.
The lesson generalises past this entry: CLAUDE.md's non-negotiable #4 says the quick-add path must
be *measured*, and a decision record is exactly where an unmeasured assertion gets read as fact by
the next agent.
*Correctness:* M1-01's overlap rule suppresses keys sitting inside links so a browse URL yields
one ref rather than two. That is right for extraction and wrong for routing —
`https://acme.atlassian.net/browse/PAY-421` should route to Payments. Routing wants every key the
text mentions; extraction wants each one once.
**Alternatives:** calling `extract` for both (one scan, but pays `NSDataDetector` per keystroke
*and* silently declines to route a pasted browse URL); debouncing the live extraction (adds a
timer and a stale-chip window to the latency-critical path).
**Consequence to know about:** a URL slug like `/reports/AWS-2024/q3` routes to a project
configured with the prefix `AWS`. Narrow, and one click to dismiss.

### D-026 — A project is seeded on first launch; capture refuses only when all are archived
**2026-08-26** · M1-02 · **Status:** accepted

`StenoStore.seedDefaultProjectIfEmpty(in:)` inserts one `Inbox` project when the store holds zero
projects, called from `StenoApp` after the container opens. The emptiness check counts archived
projects, so seeding happens once in a store's life.

**Why:** on a fresh install there are no projects, so M0-05 disabled New Task — a capture surface
refusing text, which §1.1 forbids. M1-03 makes it worse: the hotkey window would open above every
other app into a field whose `Return` does nothing.
**The exception this leaves, stated because ARCHITECTURE §3 claims capture never blocks.** With
every project archived, routing has no target, `CaptureService` throws `noProjectAvailable`, and
`canCreateTask` is false. Not re-seeded: that would resurrect a project the user archived on
purpose, and unlike a fresh install it is a state they navigated into deliberately with a visible
undo. §3.1 hides archived projects and never deletes them, so choosing to hide all of them is a
legitimate thing to have done.
**Alternatives:** minting a project lazily inside the first capture (nothing exists until the user
types, but the write becomes conditional and two-part on the latency-critical path); keeping
M0-05's gate (honest about the data model, dead field on a fresh install).
**Called on `container.mainContext`, not a sibling context.** The plan specified
`ModelContext(container)`; that was changed during implementation because `MainWindowView` reads
`mainContext`, and seeding into a sibling would have rested M1-02's core guarantee — a fresh
install has somewhere to capture to — on undocumented SwiftData cross-context visibility.

### D-027 — M1-02 adds project editing, which no task owned
**2026-08-26** · M1-02 · **Status:** accepted · spec amendment

Spec amendment — carried by `REQUIREMENTS.md` FR-3 (v1.11). Nothing in the 36-task plan owned
editing `Project.jiraProjectKeys`: the field and `setJiraProjectKeys(_:at:)` exist from M0-03,
`createProject(named:)` always passes `[]`, and the field is named in `docs/tasks/` only inside
M1-02's own file. M1-08's Settings scope is hotkey, launch at login and default project, and
per-project keys are not Settings-shaped.

**Why it could not wait:** FR-1.4 routes on `jiraProjectKeys`. Without an editor every project
holds `[]` forever, so auto-routing and its chip are unreachable in the running app, M1-02's second
acceptance criterion is provable only in the test bundle, and M1-04's "chip behaving identically to
the main window" has nothing to compare.
**Scope:** a sidebar context-menu sheet with a name field and a comma-separated keys field, over
the mutators M0-03 already shipped. Deliberately outside the task file's In-scope list, and
declared in the PR body rather than smuggled.

### D-028 — `ProjectRouter.route`'s `defaultProjectID` carries a default value
**2026-08-26** · M1-02 · **Status:** accepted · extends D-013, D-023

`route(text:projects:preferred:lastUsed:defaultProjectID:ignoringTicketKey:)` takes six
parameters, which trips SwiftLint's `function_parameter_count` (warning threshold 5, promoted to
a failure by `--strict`). `defaultProjectID` is declared `UUID? = nil`; the rule's
`ignores_default_parameters` option defaults to true, so one default clears the violation.

**Why this parameter and not another:** FR-6's configured default is the one rung that genuinely
has no value until M1-08 builds the setting — the design already describes it as "a parameter
from day one, `nil` until M1-08 fills it." A default therefore misrepresents nothing. The other
five are required at every call site and defaulting any of them would hide a real argument.
**Why not the alternatives:** an inline `swiftlint:disable` is what D-023 reserves for genuine
false positives, and a function that really does take six arguments is not one. Disabling
`function_parameter_count` in `.swiftlint.yml` would drop the rule for the whole project to
settle one call — the opposite of D-023's reasoning, where a rule was removed because its
residual value was nil rather than because one site found it inconvenient.
**The cost, and where it is paid:** the design's argument for threading the parameter through
from day one is that M1-08 satisfies its acceptance criterion "by passing an argument, not by
editing this function" — which holds only while every call site passes it explicitly. A default
makes silent omission possible. `CaptureService.capture` is the only production caller and does
pass it explicitly; `capture`'s *own* `defaultProjectID: UUID? = nil` is separate and was
specified from the start. **M1-08 should verify both call sites rather than assuming.**
Note also that `CaptureFieldModel.commit()` omits `defaultProjectID` and has no way to receive
one — M1-08 must thread a parameter through there too, so the work is three sites, not two.

### D-029 — The global hotkey needs no Accessibility permission
**2026-08-27** · M1-03 · **Status:** accepted

`CarbonHotkeyMonitor` binds the chord with Carbon's `RegisterEventHotKey`, which the WindowServer
dispatches directly to the registering process. REQUIREMENTS.md §9.3 previously derived its
stable-signing requirement from Accessibility (TCC) permission this mechanism never requests;
§9.3 is corrected in this PR (REQUIREMENTS.md v1.12).

**Why:** `M1-03-global-hotkey.md`'s fifth acceptance criterion — "Denying or revoking
Accessibility permission produces a clear explanation, not a dead hotkey" — describes a state
`RegisterEventHotKey` cannot enter. It is dropped from the task file rather than implemented:
there is no permission to deny or revoke, and a dialog built for that case would be a control
surface over nothing, working against the case §1.1 already makes for interrupting nothing on
this path.
**Alternatives:** `NSEvent.addGlobalMonitorForEvents` — TCC-gated, and fails silently rather than
throwing until the grant exists, the worse failure mode for a P0 capture path. `CGEventTap` —
also TCC-gated, and heavier: it can synthesize and swallow events system-wide, a capability this
feature never needs.
**The evidence, and what it is not.** A grep across `StenoKit/` and `Steno/` finds no
`AXIsProcessTrusted`, `NSEvent.addGlobalMonitorForEvents`, `CGEvent.tapCreate`, or
`NSAccessibility` call, and `make run` produced a clean launch with no registration fault in the
unified log. That is source-level and runtime-log evidence that the mechanism does not request
the permission — it is not proof that no dialog can appear on screen. That remains design §7's
manual check 6, run by the reviewer rather than an agent, and is not claimed as verified by the
test suite here.

### D-030 — The capture panel is non-activating
**2026-08-27** · M1-03 · **Status:** accepted

`CapturePanel` is an `NSPanel` with `.nonactivatingPanel` in its style mask, `canBecomeKey`
overridden to `true`, `canBecomeMain` to `false`, and is shown with `makeKeyAndOrderFront(nil)`
and no `NSApp.activate`. The panel becomes key and receives typing while the user's own
application never stops being frontmost at the `NSWorkspace` level, so dismissal has nothing to
restore. Focus *return* is therefore structural, not a step that can fail at runtime.

**Alternatives:** *Activate and restore* — stash `NSWorkspace.shared.frontmostApplication`, call
`NSApp.activate(ignoringOtherApps:)`, restore on dismiss. Focus is guaranteed, but Steno visibly
becomes frontmost (the menu bar swaps, the Dock icon marks active) and the restore is an
asynchronous cross-process call that can lose a race to whatever else activates — the "steals the
user's place" the task file warns against, and a round trip inside the 3-second budget. *Toggling
activation policy* — flip to `.accessory` around show and hide. Gets some of the same discretion
without `.nonactivatingPanel`, but mutates global application state on the latency-critical path
and pre-empts M1-04, which has its own view on activation policy for the menu bar item.
**What is not settled here.** Whether SwiftUI's `@FocusState` reliably takes the caret *inside*
a non-activating panel — as opposed to the panel merely becoming key — is a runtime question no
compile probe answers, and GUI automation is unavailable on this machine (design §4.1). It is
design §7's manual check 1, run by the reviewer rather than an agent, and no result had been
recorded as of this PR. If it fails, design §4.1 names the fallback as the rejected
activate-and-restore alternative above, and that outcome belongs in an update to this entry, not
a silent patch around it.

### D-031 — `.stenoDidCapture` is posted at the write, not per surface
**2026-08-27** · M1-03 · **Status:** accepted, closes D-019's gap

`CaptureService.capture` posts `Notification.Name.stenoDidCapture` synchronously on the main
actor after a successful write; `MainWindowModel` observes it and reloads. This closes the
staleness gap D-019 named for a later task: a manually-fetched view model does not refresh when
another surface writes, and D-019 left `MainWindowModel` correctness resting on whichever task
added the second writing surface actually closing the gap.

**Why one post site, not one per surface:** M1-03's floating panel and M1-04's future popover
both call the same `CaptureService.capture`, so a single post there covers every surface without
each one remembering to notify. The alternative D-019 itself suggested —
`NSApplication.didBecomeActiveNotification` — is less code but leaves two holes: a main window
visible on a second display and never re-activated stays stale, and a menu bar popover (M1-04)
never activates the application either. Posting synchronously on the main actor, rather than
deferring to the next run-loop turn, is also what makes the observing tests deterministic — a
reload can be asserted immediately after `capture()` returns rather than waited for.
**Why the observer token lives in `CaptureObservation`, not a stored property with a `deinit`:**
in Swift 6, `deinit` on a `@MainActor` class is nonisolated and cannot reference isolated stored
members, so `MainWindowModel`'s obvious `deinit { NotificationCenter.default.removeObserver(...) }`
does not compile. `CaptureObservation` holds the token in a plain, non-isolated object; ARC
releases it alongside the model, and *its* `deinit` — which touches nothing isolated — does the
removal. The same rule surfaces once more in this task, in `CarbonHotkeyMonitor`: its
`EventHotKeyRef`/`EventHandlerRef` are `nonisolated(unsafe)` for the identical reason, so its
`deinit` can call a nonisolated cleanup function and actually run — `deinit` is also the one
context where exclusive access to those references is structurally guaranteed, which is what
makes the `unsafe` honest. One rule, two independent workarounds; recorded here rather than
twice.

**Renamed by D-035 (M1-05):** the notification is now `.stenoDidWrite` and the
token holder `WriteObservation`. Everything above still applies.

### D-032 — Reserved-hotkey detection carries a static default table
**2026-08-27** · M1-03 · **Status:** accepted

`SystemHotkeys.reserved(in:)` resolves conflicts against `com.apple.symbolichotkeys`'s
`AppleSymbolicHotKeys` domain, but treats the domain as a record of *deviations from the
default*, not the full set of live shortcuts: `systemDefaults` supplies the thirteen ids a
capture hotkey could plausibly collide with, and any id the domain omits entirely is still live
at its default chord.

**The evidence.** Run against this machine's real domain — after Task 3's fixture-based tests
already passed — the three real units (`HotkeyChord`, `SystemHotkeys`, `HotkeyConflictChecker`)
resolved 19 domain entries to 13 reserved chords, and the default `⌥Space` chord came back free.
Four of those thirteen — Spotlight (`⌘Space`, id 64), Finder search (`⌥⌘Space`, 65), Mission
Control (`⌃↑`, 32), and Application windows (`⌃↓`, 33) — were recovered entirely from
`systemDefaults`, because none of the four ids appears in the domain at all. A resolver that
trusted the plist alone would have reported `⌘Space` free, which is the single likeliest conflict
any user of FR-1.1 will ever attempt.
**The fail-safe direction, decided during review.** When a domain entry exists but is malformed —
its key isn't parseable as `Int`, or its value isn't a `[String: Any]` — `reserved(in:)` does not
mark that id `seen`. It falls through to the "id absent from the domain" path and reserves it at
its `systemDefaults` chord, rather than dropping it. This is deliberate and asymmetric: falling
back to the default can only produce a false-positive conflict warning, which is advisory and
visible; dropping the id would produce a false negative — the user picks a chord macOS already
owns, Steno binds it, and the hotkey is silently dead. The fallback direction is the one that
cannot silently lose the hotkey.
**What this cannot do, documented rather than simulated:** a chord already claimed by a
*third-party* application is invisible to this mechanism — `RegisterEventHotKey` typically
returns `noErr` regardless, and the other application simply wins the dispatch.
`HotkeyConflictChecker`'s own doc comment states the limit; there is no fixture or unit test that
could demonstrate covering it, because it isn't covered.

### D-033 — `StatusService` is the only route to a status change
**2026-08-28** · M1-05 · **Status:** accepted, closes D-019's mutation hole

Status transitions go through `StatusService`, which appends the `statusChanged`
event §3.3 requires in the same call. To make that structural rather than
advisory, the domain mutators — `TaskItem.rename`/`.move`/`.setArchived`/`.setStatus`,
`Project.rename`/`.setJiraProjectKeys`/`.setArchived`/`.setColorHex`/`.setSortOrder`/
`.setCadence`/`.setStaleThresholdDays`, `Event.redact()`,
`StandupReport.markUndone()` and `SourceRef.recordFetch(summary:at:)` — drop from
`public` to `internal`. `Project.lastStandupAt` stays `public`: §10.1 gives it its own
merge rule of its own (**superseded**: D-099 derives it from the reports rather than
comparing timestamps), which a plain property gets by construction
and a mutator would get only by remembering.

**Why:** `MainWindowModel` publishes live `@Model` objects, so view code holds a
real `TaskItem`. With a `public setStatus` it could skip the event and have the
next unrelated `save(context)` commit the change — the hole M0-05 left and D-019
named. M2.5-02's merge *derives* `TaskItem.status` from the newest `statusChanged`
event, so such a transition silently reverts after an import, months later,
looking like data corruption. The reduction compiles because no file in the
`Steno` target calls a mutator or constructs a model, and every test file uses
`@testable import`.
**Alternatives:** a doc comment asking view code not to call `setStatus` — a
promise, where this branch's predecessor spent four review rounds on comments
that promised things the code did not enforce.

**The visibility widening this forced, recorded here rather than as its own
entry.** Task 5's five status methods pushed `MainWindowModel.swift` past
SwiftLint's `file_length` limit, so they live in
`StenoKit/Features/MainWindow/MainWindowModel+Status.swift` instead, needing
`StatusService` built over that file's own `context`, `now`, and `save`. Those
three widened from `private` to `internal`, and `lastError` from `public
private(set)` to `public internal(set)`. Every widening stops at `internal`, so
the app target's access is unchanged and "views get no store access" still
holds — that rule constrains the app target, not StenoKit's interior.

### D-034 — The cycle shortcut skips BLOCKED
**2026-08-28** · M1-05 · **Status:** accepted

`Status.cycle` is `[.todo, .inProgress, .done]`, and ⌘⇧S walks it. `blocked` is
reachable from the status control and from ⌘⇧B, never from the cycle. Cycling
out of `blocked` goes to `inProgress`.

**Why:** every transition appends an event, and M2-02 renders that log into a
stand-up. Cycling all four would make TODO → DONE a three-press walk appending
two events for states the user never meant to be in — individually truthful,
collectively a description of work that did not happen. `blocked` is also the one
status §3.3 pairs with a reason, which makes it a deliberate act rather than a
waypoint. FR-3 requires a cycle shortcut and does not say what it cycles through,
so this is a choice inside a silent spec, not a deviation from it.
**Alternatives:** all four in declaration order (the event noise above); four
direct shortcuts (⌃⌘1–4), rejected because FR-3 asks for a cycle specifically.

### D-035 — `.stenoDidCapture` is renamed `.stenoDidWrite`
**2026-08-28** · M1-05 · **Status:** accepted, renames D-031's notification

One notification, posted by every writing service after a successful save.
`CaptureService` and `StatusService` post it today; M1-06's notes will. D-031's
reasoning is unchanged and still applies in full — only the name moved, along
with `CaptureObservation` → `WriteObservation` and the file to `StenoKit/Support/`.

**Why:** D-031's own doc comment said the notification was meant to cover "M1-05's
and M1-06's future writes", but the name said capture, and a status change is not
a capture.
**Alternatives:** a second name alongside the first, which grows a registration
per observer per feature and makes the first forgotten one a staleness bug that
looks like SwiftData being flaky; or posting `.stenoDidCapture` from
`StatusService`, which is free and makes the name assert something false.

### D-036 — The blocked reason is offered after the transition, never before
**2026-08-28** · M1-05 · **Status:** accepted

Moving a task to BLOCKED commits the `statusChanged` event immediately; only then
does a sheet offer an optional reason. Esc or empty input appends no
`blockedReason` event, and the status has already changed either way.
`StatusService.addBlockedReason(_:to:)` is a separate method rather than a
parameter on `setStatus`.

**Why:** §3.3 marks the reason optional, and M1-05's task file warns that making
it mandatory adds friction at the moment the user is most frustrated. Committing
first means the friction is zero even if they ignore the sheet. The parameter
form was drafted and rejected: because the transition commits first, nothing
would ever pass it, and it would ship as an unused argument.
**Alternatives:** the service taking the reason inline (dead parameter); no UI at
all until M1-06 (ships a capability nothing exercises).

### D-037 — The popover lists every IN-PROGRESS task, no date filter
**2026-08-31** · M1-04 · **Status:** accepted — closes O-6; `REQUIREMENTS.md` FR-1.2 points here as of v1.13

`MenuBarModel.reload()` lists every task with `status == .inProgress`, across every non-archived
project, newest `statusChangedAt` first. There is no "today" or "this project" filter.

**Why:** a task started Monday and still running Thursday is exactly what gets reported at
stand-up, so a date filter would hide the thing the popover exists to surface. Scoping to "the
selected project" has no meaning here either — the popover has no project selection of its own,
and the point of a menu-bar-wide view is that it is not scoped to whatever the main window
happens to have open. D18 caps the whole dataset under 20 live tasks, so "every project" costs
nothing to render and stays glanceable.
**Alternatives:** filtering to tasks transitioned today (loses Monday's still-running task, the
case that matters most); scoping to the main window's currently-selected project (the popover
would then depend on main-window state it is built to work without — `MenuBarModel` explicitly
does not reach for `MainWindowModel`).

### D-038 — The menu bar activates Steno; the capture panel does not
**2026-08-31** · M1-04 · **Status:** accepted

`MenuBarController.show()` calls `NSApp.activate(ignoringOtherApps: true)` before showing the
popover. `CapturePanel` (M1-03, D-030) deliberately never does.

**Why:** the two surfaces are opposites. The hotkey panel appears *over* whatever app the user is
already in — activating would visibly steal their place, which D-030 rejects outright. The menu
bar item is reached only by the user first leaving their app to look at the menu bar, so there is
no place left to steal; activation is what then lets the popover's window become key and focuses
the field without an extra click, which §1.1's capture-latency budget would otherwise spend on
one. Knowingly contradicts `CapturePanel`'s "do not activate" posture — recorded here so a future
reader sees an argument, not an inconsistency.
**Alternatives:** never activating, matching `CapturePanel` (the popover could show without
becoming key, leaving the field unfocused and reintroducing the click §1.1 forbids).

### D-039 — Blocking from the popover commits without offering the reason
**2026-08-31** · M1-04 · **Status:** accepted

`MenuBarModel.setStatus` calls `StatusService.setStatus` directly and never opens D-036's
blocked-reason sheet, even when the transition is into `.blocked`.

**Why:** §3.3 already makes the reason optional, so skipping it loses nothing required. A sheet
would have to dismiss the `.transient` `NSPopover` that spawned it — two floating pieces of UI
fighting over the same dismissal — and the main window's detail pane still offers the reason for
anyone who wants to add one after the fact.
**Alternatives:** opening the sheet over the popover (the dismissal conflict above); dropping
BLOCKED from the popover's inline menu entirely (removes a status the user may legitimately want
to set from the surface they use most).

### D-040 — The main window becomes a `Window` scene, and the app outlives it
**2026-08-31** · M1-04 · **Status:** accepted

`StenoApp.body` declares `Window("Steno", id: MainWindowReveal.sceneID)` instead of a
`WindowGroup`, and `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`.

**Why:** M1-04's first acceptance criterion — the icon persists and is present without the main
window open — is a claim about process lifetime, so it has to be stated somewhere rather than
left to a framework default that macOS is free to change. `Window` is also what makes "Open Main
Window" able to *reopen* a closed window at all: a `WindowGroup` answers a reopen request by
minting a second instance, which is wrong for a window that is already effectively
single-instance (`MainWindowCommands` already replaces `.newItem`).
**Alternatives:** `WindowGroup` (the second-instance problem above); leaving
`applicationShouldTerminateAfterLastWindowClosed` at its default `true` (the app would quit on
⌘W, taking the menu bar icon with it — the opposite of the criterion this task owns).

### D-041 — Launch at login ships as a hook with no caller
**2026-08-31** · M1-04 · **Status:** accepted

`StenoKit/Support/LoginItem.swift` ships a `LoginItem` protocol and `SystemLoginItem`, its
`SMAppService`-backed implementation. Nothing in the running app calls `enable()`.

**Why:** FR-6 owns the launch-at-login *setting*, and places it in M1-08's Settings Capture pane.
Registering the user for launch-at-login without their asking is a product decision this task has
no standing to make unilaterally. Shipping the type now, unused, means M1-08 adds a pane over an
existing capability rather than designing the type under its own deadline — the same posture
`QuickCaptureModel.rebind` already established for a different capability.
**Alternatives:** waiting for M1-08 to add both the type and the pane together (defers no risk,
but means M1-08 designs a `SMAppService` wrapper from scratch instead of wiring a UI to one
already reviewed); calling `enable()` unconditionally at launch (the unrequested registration
this decision exists to avoid).
**What is not tested:** the real `SystemLoginItem` — `LoginItemTests.swift` exercises only a fake
double, because `SMAppService.mainApp.register()` from an unhosted headless test bundle would be
a side effect on the developer's own machine, registering the test runner's bundle for login.

### D-042 — The status picker's order is named, not inherited from the enum
**2026-08-31** · M1-04 · **Status:** accepted

`Status.menuOrder` (`StenoKit/Features/MainWindow/Status+Display.swift`) is a named
`[.todo, .inProgress, .blocked, .done]`, distinct from `TaskGrouping.order`'s
`[.inProgress, .blocked, .todo, .done]`. `StatusMenuItems` renders `menuOrder`, and both the main
window's `StatusControl` and M1-04's popover row menu render `StatusMenuItems`.

**Why:** `TaskGrouping.order` already refuses to let a list's section order fall out of `Status`'s
declaration order, on the grounds that reordering the enum for an unrelated reason must not
silently reorder the user's window. The popover becoming the *second* surface to render
`StatusMenuItems` is what makes the same argument bite for the picker: an accidental reorder would
now move items under the user's cursor in two places at once instead of one. The two orders are
deliberately different — `TaskGrouping.order` answers "what to look at first" for a list of
sections, `menuOrder` reads best in workflow order for a picker — and naming both, rather than
letting the picker borrow the list's order, is what makes that difference visible instead of
accidental.
**Alternatives:** `Status.allCases` (reintroduces the coupling `TaskGrouping.order` already
rejected); reusing `TaskGrouping.order` for the picker too (conflates "read order" with "workflow
order", which happen to be needs that differ).

### D-043 — `Esc` discards the panel's draft and keeps the popover's
**2026-09-01** · M1-04 · **Status:** accepted

The two surfaces that embed `CaptureFieldView` give `Esc` opposite meanings, deliberately.
`QuickCaptureController` passes an `onDismiss` that calls `field.reset()`
(`Steno/Features/Capture/QuickCaptureController.swift`), so `Esc` on M1-03's floating panel
discards the typed line. `MenuBarController` passes an `onDismiss` that only closes the popover
(`Steno/Features/MenuBar/MenuBarController.swift`), so `Esc` leaves the draft to be found on the
next open. FR-1.1 says only that `Esc` "dismisses without saving", which does not settle what
happens to the text.

**Why:** the popover's two dismissals — `Esc` and a stray click — cannot be made to agree on
discarding without a `willClose` hook. Its `NSPopover` is `.transient`, and AppKit's own
click-outside dismissal never runs through `onDismiss` — the only hook that covers it is
`NSPopover.willCloseNotification`, which fires on *every* close. Resetting there would throw away
a half-typed line whenever the user glanced at another window, which for a capture tool is data
loss (§1.1). Keeping the draft makes the
popover's two dismissals agree with each other, which is what a user actually compares. The panel
has no such constraint and the opposite pull: it is summoned over another app by a chord and
dismissed straight back into it, so a line cancelled on Monday reappearing at an unrelated chord
press on Tuesday would be the surprise. D15 asks for one capture *code path*, which both surfaces
still share literally — it does not ask two different windows to answer a key the same way.
**Alternatives:** discarding on both (needs the `willClose` reset above, and loses drafts to
incidental closes); keeping on both (changes M1-03's shipped, tested `Esc` behaviour from inside
M1-04, which is out of this task's scope and was not the panel's design intent).

### D-044 — Correction is redact-and-reappend, in its own service
**2026-09-02** · M1-06 · **Status:** accepted

`NoteService` (`StenoKit/Notes/NoteService.swift`) is a sibling of `StatusService`, not an
extension of it. It owns all three note writes — `addNote`, `correct`, `redact` — and is the only
route to any of them.

**Why:** `StatusService.addBlockedReason` guards on `status == .blocked`, which is right for
*writing* a reason and wrong for *correcting* one. A user who blocks a task, mistypes the reason,
unblocks, and then notices the typo must still be able to fix it inside FR-2's five minutes, and
under `StatusService`'s guard they could not. Correction is a property of the event, not of the
task's current status, so it needs an owner whose guards are about events.
**Alternatives:** extending `StatusService` (inherits the wrong guard, as above); putting the
rule on `MainWindowModel` (the guard is about the event, not about what is on screen — a window
model is the wrong owner for a rule that has nothing to do with a window, and it puts a store
write behind a surface that headless callers and tests cannot reach).

**FR-4.1's undo does *not* get to reuse `redact` here, and must not try.**
[`REQUIREMENTS.md` FR-4.1](REQUIREMENTS.md) redacts `standupReported` events, and
`NoteService.redact` guards on `event.kind.isUserAuthored`, which is `false` for that kind
(`StenoKit/Models/EventKind.swift`; D-045). So this method refuses precisely the events FR-4.1
needs redacted — and refuses by returning `false` rather than throwing, which reads at the call
site as "ineligible", not as a wiring mistake. That is correct for `NoteService`, whose whole
scope is FR-2's user-authored prose. **M2-04 needs its own redaction path**, with an eligibility
rule about the report being undone rather than about who wrote the body.

### D-045 — `EventKind.isUserAuthored` decides correction and redaction scope
**2026-09-02** · M1-06 · **Status:** accepted

`note` and `blockedReason` are correctable and redactable; `created`, `statusChanged`,
`externalUpdate`, and `standupReported` are neither (`StenoKit/Models/EventKind.swift`, consumed by
`NoteCorrection.isCorrectable`).

**Why:** those two are the kinds the user typed prose into, and prose is the only thing a typo
window is for. Redacting a `statusChanged` would corrupt what M2-01 and M2.5-02 derive status
history from; redacting `created` would leave a task with no origin row in its own timeline. The
line is "did a human write this body", and `isUserAuthored` states it once instead of letting each
call site enumerate kinds.
**Alternatives:** notes only (leaves M1-05's `blockedReason` — which the user types free-hand into
a sheet, and can therefore fat-finger — permanently uncorrectable); every kind (the corruption
above).

### D-046 — The replacement carries the original's kind, not `.note`
**2026-09-02** · M1-06 · **Status:** accepted — amends `REQUIREMENTS.md` FR-2 (v1.14)

Correcting a `blockedReason` appends a `blockedReason`, not a `note`.

**Why and full statement:** [`REQUIREMENTS.md` FR-2](REQUIREMENTS.md#fr-2-progress-notes-p0). FR-2
was written when `note` was the only correctable kind and says "append a new `note` event"; taken
literally it relabels a corrected blocked reason as a note, which changes what the row *means*
rather than what it says. The spec carries this one, per the "What goes where" rule above; this
entry is the pointer.

### D-047 — The five-minute window measures from the event's own timestamp, and does not restart
**2026-09-02** · M1-06 · **Status:** accepted

`NoteCorrection.isCorrectable` compares `now` against the event's own `timestamp`. Because a
replacement inherits the original's timestamp (FR-2), correcting a correction does not buy another
five minutes: at T+4m a correction is still editable, and at T+6m it is not, even though it was
written two minutes ago.

**Why:** it is free. FR-2 already requires the replacement to carry the original timestamp so the
timeline does not reorder mid-correction, and once it does, "age of the event" and "age of the
original" are the same number. It is also the behaviour that matches the requirement's intent — a
typo window, not a rolling edit lease that a user could hold open indefinitely by correcting a
correction every four minutes.
**Alternatives:** restarting the window on each correction (unrepresentable without a new `Event`
field to hold the write time separately from the display timestamp, and §3.3's append-only model is
not worth widening for it); measuring from the *task's* `modifiedAt` (a note does not stamp it —
see `NoteServiceTests.aNoteDoesNotStampModifiedAt` — and should not).

### D-048 — FR-2's bare `N` is scoped to the task list, with ⌘⇧A in the menu
**2026-09-02** · M1-06 · **Status:** accepted

`N` is an `.onKeyPress` on the task column (`Steno/Features/MainWindow/TaskListView.swift`), live
only while that column has focus and a task is selected. The menu carries ⌘⇧A ("Add Note") as the
globally-live equivalent (`Steno/App/MainWindowCommands.swift`).

**Why:** a plain-letter *menu* key equivalent is global to the window. SwiftUI would match `n`
before the focused text field saw it, which means typing the letter "n" into the quick-capture
field, the New Task sheet, or the note composer itself would instead open a note composer. §1.1
makes the capture field's keystroke handling a P0 concern, so a shortcut that can eat a character
out of it is not shippable. Scoping to the task list keeps FR-2's one-keystroke affordance where
FR-2 puts it — "from a selected task" — and the menu item gives the same action a discoverable,
modifier-guarded route.
**Alternatives:** a bare `N` menu command (the hijack above); no bare key at all, menu only (drops
the one-keystroke affordance FR-2 asks for).
**Not verified:** whether the bare `N` fires at all. The focused view is a `List`, which on macOS
is `NSTableView`-backed and does type-select on plain characters; if it consumes the keydown, the
ancestor's handler never runs. This is a hypothesis, not a measurement — see M1-06's manual
verification section, item 1.

### D-049 — Orphan `SourceRef` rows from a corrected or redacted note are left in place
**2026-09-02** · M1-06 · **Status:** open — deferred to M5

Neither correcting nor redacting a note withdraws the `SourceRef` rows that note's body created,
so a task can carry a ref whose only mention no longer exists.

**Correction is the primary generator**, not redaction. `NoteService.correct` calls
`insertNewRefs` for the *new* body and does nothing about the old one, so correcting
`PAY-42` → `PAY-421` — which is exactly the fat-finger FR-2's five-minute window exists for —
leaves the task permanently carrying a ref to `PAY-42`, a ticket that was never really mentioned.
Redaction produces the same orphan but needs a user who wrote a ref and then deleted the line,
which is both rarer and less misleading than a typo the user believes they already fixed.

**Why deferred:** reconciling them would add the app's first delete path for a persisted row, and
would add it immediately beside the invariant this task exists to defend — a delete helper sitting
one file away from "nothing is ever deleted" is exactly the shape a later reader misapplies. It
would also discard `cachedSummary` and `lastFetchedAt`, which §10.1 preserves across import, on a
ref that a *different* note may still mention. Nothing observes the orphan today: as of M1-06 no
surface reads `task.sourceRefs` at all — `NoteService.insertNewRefs` is the only code outside the
models that touches it — so the orphan is invisible rather than merely ambiguous. **Owner: M5**,
where fetched external state makes a dead ref visible.
**Alternatives:** deleting the ref on correction or redaction (the delete path above, plus it
drops refs other live notes still mention); reference-counting refs against live events (real
machinery, no observable payoff before M5).

### D-050 — `MainWindowModel`'s project actions move to `+Projects.swift`
**2026-09-02** · M1-06 · **Status:** accepted

`createProject`, `updateProject`, and `archive(projectID:)` move verbatim from
`MainWindowModel.swift` to `MainWindowModel+Projects.swift`. No behaviour change, no signature
change.

**Why:** `MainWindowModel.swift` stood at 396 lines against SwiftLint's 400-line ceiling under
`--strict`, and M1-06 had to add note actions to it. Splitting first keeps that addition from being
a lint failure dressed as a design decision, and it makes the notes diff readable — a reviewer can
skim the move and read the new code. Projects were chosen as the half to move because they are the
model's most self-contained group: nothing in the notes or status paths calls them.
**Alternatives:** raising the limit (the ceiling is doing its job); splitting notes out instead
(the notes code is new in this PR, so moving old code out gives the better diff).

### D-051 — After a failed save, what a held `Event` or `TaskItem` object reports is not dependable
**2026-09-02** · M1-06 · **Status:** accepted — recorded as a **hazard**, not a design choice

This is not a decision anyone made; it is a property of SwiftData that M1-06 measured and could not
predict. After `context.rollback()`, whether an in-memory object still shows the rejected change or
has reverted to the stored value is **not something this codebase can rely on**.

**Why it is recorded:** M1-06 measured the post-rollback state of a held reference twice, in two
separate fix rounds, and got contradictory answers. Each run was internally deterministic and each
was reproducible on demand — but the result tracked the *composition of the test suite*, an
isolated single-test run and a full `make test` disagreeing, rather than anything about the code
under test. No predictive rule was found, and none is claimed here.
**Consequence, already shipped:** M1-06 asserts only what the product actually guarantees — that
the store is left clean and that no `.stenoDidWrite` was posted
(`NoteServiceTests.aFailedCorrectionRollsBack`, `.redactFailedSaveRollsBack`,
`.addNoteFailedSaveRollsBack`) — and every failure path in `MainWindowModel+Notes.swift` refetches
rather than reasoning about what survived.
**Alternatives:** picking one of the two measured directions and pinning it in a test (converts an
undefined SwiftData implementation detail into an assertion any future unrelated test can break,
with a failure message pointing at correction logic that is fine); fixing the two pre-existing
sites below (widens this PR into M1-05's territory).

Two pre-existing sites carry the older, stronger claim and are **known-suspect and deliberately
left untouched**, so that the next person to trip over one finds this explanation instead of
re-deriving it:

- `StenoTests/Status/StatusServiceTests.swift:168` — `failedSaveLeavesHeldReferenceStaleUntilRefetch`.
  Currently green. If it ever fails, this is why: it pins undefined behaviour, not a requirement.
- `StenoKit/Features/MainWindow/MainWindowModel+Status.swift:41` — a comment asserting that
  "`rollback()` leaves the held task reporting the rejected status". Untested in either direction.
  The `reload()` it justifies is still correct; only the stated reason is suspect.

### D-052 — Changing the selected task discards the note draft
**2026-09-02** · M1-06 · **Status:** accepted

`MainWindowModel.selectedTaskID`'s `didSet` calls `noteComposer.cancel()`, clearing the text and
returning the composer to `.adding`.

**Why:** the composer is one instance for the whole window, but `commitNote()` resolves its subject
from the *current* selection. Without this, a note typed against task A and committed after
clicking task B is filed on B — and for a recall tool whose entire output is per-task attribution
at stand-up, misfiled prose is a data defect, not a UI annoyance. A correction carried across the
change is worse still: the first ⌘↩ cannot find the event in the new task's timeline and silently
drops to adding, so the second files task A's corrected prose onto task B as a fresh note. Found in
Task 9's review; pinned by `MainWindowModelTasksTests.switchingTasksDiscardsThePendingDraft` and
`.switchingTasksMidCorrectionFilesNothing`, both verified by mutation.
**Alternatives:** `.id(taskID)` on the composer view (does not work — it resets `@State` and
`@FocusState`, while `text` and `mode` live on the model, which is what survives); giving the
composer a per-task identity and refusing a mismatched commit (more machinery, and it strands the
user holding a draft they cannot commit anywhere).
**Cost accepted:** a user who types, switches task to look something up, and switches back loses
the draft.

---

### D-053 — CI signs ad-hoc, through an `XCFLAGS` seam rather than an xcconfig key
**2026-09-04** · M1-07 · **Status:** accepted

`make build`, `make test` and `make release` pass `$(XCFLAGS)` — empty unless set on the command
line — to `xcodebuild`. CI sets it to `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual` and writes a
stub `Local.xcconfig` carrying `DEVELOPMENT_TEAM = CI0000000`. `main`'s branch protection requires
the resulting `build-test-lint` check, with `strict: false`.

**Only the command line may set it, and `?=` was not enough.** The first cut wrote `XCFLAGS ?=`,
which honours a variable inherited from the developer's environment: origin `environment` counts
as already-defined, so `?=` leaves it in place and it lands on every local `xcodebuild`
invocation — the opposite of the intent. Caught by Copilot reviewing PR #18 and reproduced before
fixing. The guard is `ifneq ($(origin XCFLAGS),command line)` / `XCFLAGS :=`, verified on Apple's
GNU Make 3.81 across four cases: unset, environment-only (now ignored), command-line-only (works),
and both at once (command line wins).

**Why an xcconfig key does not work:** `project.yml` sets `CODE_SIGN_IDENTITY` under
`settings.base`; XcodeGen writes that into the `.pbxproj`; and a `.pbxproj` build setting outranks
the xcconfig attached to the same configuration. Putting the override in `Local.xcconfig` resolves
to `Apple Development` and is ignored — measured with `-showBuildSettings`, not assumed. The
xcodebuild command line is the only level that wins, so the seam has to be a Make variable.

**Why the stub file is needed at all:** `Local.xcconfig` is gitignored, so a fresh checkout lacks
it — and `xcodegen generate` then fails outright with `Invalid config file "Local.xcconfig"`. CI
cannot simply build without one. `preflight` is left unmodified and the stub satisfies it as
written: teaching `preflight` to stand down when `CI` is set would weaken the gate exactly where
nobody is watching.

**Why ad-hoc rather than `CODE_SIGNING_ALLOWED=NO`:** both build and test green, but ad-hoc still
runs the codesign step over the app, the embedded `StenoKit` framework and the test bundle, and
embeds the entitlements — verified with `codesign -dv --entitlements -`. So a broken
`Steno.entitlements` or a framework-embedding regression fails CI instead of reaching `main` and
surfacing on the next local build. This does not weaken §9.3: its stable-identity rule exists so
macOS TCC grants survive rebuilds, and a runner holds no TCC grants. `XCFLAGS` defaults to empty
and `project.yml` still pins `Apple Development`, so local signing is untouched.

**Why `strict: false`:** `strict: true` also requires a branch be up to date with `main` before
merging, forcing a rebase every time `main` moves. The race it protects against needs concurrent
merges to arise; with one developer merging sequentially it is friction bought for nothing.
Nothing in the protection settings enforces that serial-merge assumption, though — it holds only
because it happens to be true today. Flip `strict: true` if two task branches are ever in flight
at once.

**Unpinned bootstrap formulae:** `make bootstrap` installs `xcodegen` and `swiftlint` from
Homebrew without pinning a version, so a future SwiftLint release that adds or tightens a
default rule can turn `make lint --strict` red on a PR that changed nothing. Accepted for now
because local `make bootstrap` has always had the same property — this just makes CI inherit
it — recorded here so it is a known exposure rather than a surprise.

**Alternatives:** indirection in `project.yml` (`CODE_SIGN_IDENTITY: $(STENO_SIGN_IDENTITY)`) —
rejected because an existing `Local.xcconfig` lacking the new key resolves it to empty and
silently changes how local builds sign, which is precisely what §9.3 forbids; a `CI`-conditional
`Makefile` — rejected because the build system would then behave differently where nobody is
watching.

---

### D-054 — Settings is a `Settings` scene, reached only by ⌘,
**2026-09-06** · M1-08 · **Status:** accepted

`StenoApp` gains a SwiftUI `Settings` scene. There is no other way in — no toolbar button, and no
"Settings…" row in FR-1.2's popover.

**Why:** the `Settings` scene is what puts "Steno › Settings…" in the application menu at the
correct position with ⌘, bound, and what makes macOS treat the window as a settings window —
single-instance, non-restorable, correct in Mission Control. A `Window` scene would need all of
that rebuilt by hand and would still sit in the wrong menu.

**The apparent gap, and why it is not one.** The application menu is reachable only while Steno is
frontmost, and `AppDelegate` keeps the process alive with no windows open — so on paper there is a
state with no route to Settings. In practice there is not: `MenuBarController.show()` calls
`NSApp.activate(ignoringOtherApps:)` before showing the popover, so clicking the menu bar icon
makes Steno frontmost and the application menu available.
**Alternatives:** a "Settings…" row in the menu bar popover (edits M1-04's reviewed surface to
solve a state that does not occur); a gear in the main window's toolbar (redundant — the window
being open is exactly when ⌘, already works).

---

### D-055 — `SettingsPane` is the registry, and its switch is deliberately exhaustive
**2026-09-06** · M1-08 · **Status:** accepted

`SettingsPane` is a `CaseIterable` enum in `StenoKit` carrying each pane's title, symbol and
order. `SettingsView` in `Steno/` is a `TabView` over `allCases` with **one `switch` and no
`default` arm**. Adding M3-04's pane is one case, one arm, one new view file.

**Why the missing `default` matters:** an exhaustive switch means a new case fails to compile until
its view exists. Without that, the registry could silently acquire a tab that renders nothing —
the only failure mode a registry of this shape has, and the one a reviewer would never see.

**Why the enum is in `StenoKit` and the switch in `Steno/`:** D-010's test. Pane titles, symbols
and ordering are data a headless test can read; `TabView` construction is not.

**Cost accepted:** with one case, `TabView` draws a toolbar with a single segment, which reads
oddly until M3-04 lands. A `count == 1` special case was rejected — it becomes dead code the day
the second pane arrives, and this is the shape all five panes use.

---

### D-056 — `AppSettings` is the one `UserDefaults` facade
**2026-09-06** · M1-08 · **Status:** accepted · supersedes `QuickCaptureModel.chordKey`

Every `UserDefaults`-backed setting is declared in `StenoKit/Settings/AppSettings.swift`, one key
per setting. M1-03's `QuickCaptureModel.chordKey` moved into it, and `QuickCaptureModel` takes an
`AppSettings` rather than a raw `UserDefaults`.

**Why:** declaring the key on the model that used it was right when there was one setting. FR-6
lists five Settings areas and four arrive with later milestones; a codebase where every model
declares its own key leaves §10.3's "secrets are never exported" audit with no single place to
look, and O-9 (whether the chord is exported) with no single place to read.

**Both accessors report a bad stored value as absent without overwriting it,** the posture
`storedChord()` already took, so the pane can still show what is really on disk. `UserDefaults` is
a shared, user-editable store — `defaults write` is a supported thing for a person to do — so
`UUID(uuidString:)` has to be allowed to fail rather than trap. A force-unwrap there is a launch
crash no test of the happy path would find.
**Alternatives:** a settings row in SwiftData (a schema addition §6's CloudKit rules and M2.5-02's
merge would both have to reason about, for two values that are not domain data).

**O-9 is now closed by D-093: neither setting is exported.**

---

### D-057 — `LoginItem` reports a status, not a `Bool`
**2026-09-06** · M1-08 · **Status:** accepted · amends D-041

`LoginItem.isEnabled: Bool` becomes `status: LoginItemStatus` — `.enabled`, `.notRegistered`,
`.requiresApproval`, `.notFound` — and `SettingsModel` re-reads it after every call rather than
inferring success from the call returning.

**Why:** `SMAppService.mainApp.register()` can succeed and leave the service at
`.requiresApproval`: macOS lists Steno under Login Items with its switch off, waiting for the user
to approve it. Read through a `Bool` that state is indistinguishable from "off", with nothing
thrown — so the toggle would flip itself back and say nothing. That is the same silent failure
FR-1.1's conflict warning exists to prevent, on a different control, and §13 makes designing it
out the job.

D-041 shipped this protocol with no callers precisely so that M1-08 would wire a UI to a reviewed
type rather than design one under a deadline. That posture is what made this change cost a type
and its fake instead of a redesign.

**What is still not tested,** unchanged from D-041: the real `SystemLoginItem`. `SMAppService`
from an unhosted bundle registers the *test runner* on the developer's machine, which a headless
suite may not do (§9.4). The thrown-failure path is exercised through the fake, and a relocated
debug build run out of `.build/` is expected to hit it for real — which is why the pane reports
the thrown error verbatim rather than a generic message.

---

### D-058 — `rebind` takes a chord and nothing else, and refuses to bind before `start`
**2026-09-06** · M1-08 · **Status:** accepted · supersedes M1-03's `rebind(to:onPress:)`

`QuickCaptureModel.start(onPress:)` stores the closure; `rebind(to:)` re-registers with it.

**Why the signature changed:** the Settings pane's business is *which chord*, not what pressing it
does. Under the old signature the settings layer would have had to supply
`{ quickCaptureController.toggle() }` — which means Settings knowing how the capture panel works,
a dependency that buys nothing and that the next pane driving a controller would copy. No retain
cycle: the controller passes `{ [weak self] in self?.toggle() }`.

It is also what makes FR-1.1's "takes effect without relaunch" provable headlessly. The half that
can break silently is the action, not the chord: drop the stored closure and the chord still
changes, the monitor still reports the new binding, and pressing it does nothing.
`FakeHotkeyMonitor` now keeps the closure so a test can fire it.

**Binding before `start` registers nothing** and sets `registrationProblem`. A chord bound in
front of a `nil` action is a live system-wide shortcut that swallows the keystroke and does
nothing — strictly worse than the unbound state it replaces.

---

### D-059 — Recorded modifiers are masked to ⇧⌃⌥⌘ before a chord is built
**2026-09-06** · M1-08 · **Status:** accepted

`HotkeyChordValidator.validate(keyCode:modifiers:)` intersects the event's raw
`modifierFlags.rawValue` with `[.shift, .control, .option, .command]` before constructing a
`HotkeyChord`.

**Why, and this is the subtlest thing in M1-08.** `NSEvent.modifierFlags` also reports
`.capsLock`, `.function` and `.numericPad`, plus device-dependent left/right bits — a laptop's
arrow and function keys set `.function`, and `.capsLock` is set whenever caps lock is on.
`HotkeyChord` compares modifiers for **exact equality**: against `SystemHotkeys`' reserved table in
`HotkeyConflictChecker`, and across its own `Codable` round-trip. An unmasked recorded chord
therefore never matches a system shortcut — **FR-1.1's conflict warning would simply stop firing**,
with no error anywhere — and `carbonModifiers` would convert a mask the user did not press.

Neither the design doc nor its review caught this; writing the validator did. It is guarded by
`extraneousFlagsAreStripped`, which records the reasoning in full so a later simplification of
`validate` cannot quietly drop the mask.

**Where the rules live:** all of them in `StenoKit`, none in the recorder — in `Capture/` since
D-063, which corrects this entry's original placement under `Features/Settings/`.
`HotkeyRecorderView` is
event plumbing only, which is what keeps "a bare key is refused" a unit test rather than a manual
check. A bare key is refused because a global binding swallows that key in every application —
including whatever the user would type to reach this pane and undo it.

### D-060 — Project writes post `.stenoDidWrite` too

**2026-09-07** · M1-08 · **Status:** accepted · **amends the note on `.stenoDidWrite`**

`MainWindowModel.perform(_:_:)` posts `.stenoDidWrite` after a successful save, so all four write
kinds — capture, status, notes, projects — announce themselves at the write (D-031).

**Why this is an amendment and not an addition.** `WriteNotifications.swift` used to say project
writes deliberately did not post, "that view model is the only surface that shows projects today,
so nothing yet depends on it", and warned: *"A future cache of projects elsewhere must not assume
this notification covers them."* M1-08's default-project picker became that cache and made exactly
that assumption. The user archived a project and the Settings picker went on offering it — and
went on resolving to it, so FR-1.4 rung 4 pointed at an archived project.

The warning was the right instinct and the wrong remedy: an exception that has to be remembered is
an exception that gets forgotten, and this one was forgotten by the next task to touch it. A
per-write-kind notification would have moved the same forgettable registration one level down —
the case `WriteNotifications` already argues against.

**What it also fixed, unasked:** the menu bar popover kept listing an archived project's tasks
until the next capture happened to refresh it. Nobody had reported that; it was the same defect.

**Only on success.** A rolled-back save changed nothing, so posting would announce a write that
did not happen — the write-side twin of D-018's rule, guarded by `aFailedProjectWritePostsNothing`.

**Testing note.** The two `SettingsModelTests` cases covering this ground post the notification by
hand. They pass, and they cannot detect a missing post site. `ProjectWriteNotificationTests`
archives through the real path with no `NotificationCenter` call in the test at all; it is the one
that failed before this change.

---

### D-061 — The hotkey recorder disarms on resigning key, not on leaving its window

**2026-09-07** · M1-08 · **Status:** accepted

`HotkeyRecorderControl` disarms when its window posts `NSWindow.didResignKeyNotification`, and
independently refuses to record any press that arrives while its window is not key.

**Why the original hook was wrong.** It disarmed in `viewDidMoveToWindow` when `window == nil`,
on the assumption that closing Settings tears the view down. SwiftUI's `Settings` scene keeps its
window and content view alive across a close — ⌘, reopens the same window rather than building a
new one — so a control left armed never moves out of a window and the disarm never ran. The local
monitor survived the close, and because it is application-wide it then swallowed and bound the
next keystroke anywhere in the app. In practice that keystroke is ⌘, itself: the user presses it
to get Settings back, and instead silently rebinds capture onto it. Confirmed from the persisted
chord, which read `{"modifiers":1048576,"keyCode":43}`.

Resigning key is the signal that actually fires, and it is the *right* signal independently: a
recorder should also stop listening when the user switches to the main window or ⌘Tabs away.

**Both halves, deliberately.** The notification disarms eagerly; the `window?.isKeyWindow` check
inside the monitor makes a missed notification harmless and passes the keystroke through instead of
eating it. This is view plumbing in `Steno/`, so per D-010 it carries no unit test — the evidence
is the manual check, and the reason the check exists.

### D-062 — The stored hotkey chord is re-validated on load, not trusted

**2026-09-07** · M1-08 · **Status:** accepted

`QuickCaptureModel.start(onPress:)` runs the stored chord back through
`HotkeyChordValidator.validate` and falls back to `.default` if it fails. The stored value is left
on disk untouched.

**Why this became necessary in this task specifically.** Before M1-08, `rebind` had no caller
anywhere in `StenoKit` or `Steno` — nothing could write `AppSettings.hotkeyChord`, so the load
path had never been handed a value it did not produce itself. The Capture pane makes the chord a
real, user-writable setting, which is what turns "decodes cleanly" into a weaker property than
"is safe to register". `defaults write` reaches this key directly (the app is unsandboxed, per
`Steno.entitlements`), and a second caller of `rebind` in a later task would too.

The harm is specific and asymmetric: a chord with no modifiers registers a **bare key
system-wide** through `RegisterEventHotKey`, swallowing it in every application — the exact
failure `HotkeyChordValidator` exists to refuse at the recorder, and the one invalid state here
that damages the machine rather than the app. Refusing on the read side as well as the write side
is proportionate to that.

**It is a refusal, not a correction.** The bad value stays on disk, matching what
`undecodableStoredChordFallsBack` already guaranteed and D-056's rule that `AppSettings` reports
bad stored values as absent rather than overwriting them.

**Both halves of `validate` earn their keep here, not just the judging half.** A chord the app
wrote was masked on the way in, so the second pass is a no-op for it — but that is a property of
this app's write path, not of the file, and the values this guard exists for never came from the
recorder. One carrying `.capsLock` or `.function` is masked on load, which means the chord that
gets bound can differ from the one stored. `storedChordWithStrayBitsIsMasked` asserts that rather
than leaving it to a comment.

**`rebind` is deliberately left unvalidated**, against the reviewer's suggestion. D-058 made it a
narrow seam whose whole job is "bind this chord"; `SettingsModel.record` is its validating caller
and the only producer of chords from user input. Putting the rule inside `rebind` too would place
one policy in two places that can drift, and the two callers need different things from a
rejection — `record` must tell the user *why* in words, while a load-path refusal has nobody to
tell. The read-side guard covers what a future misuse of `rebind` could actually persist.

**Raised by GitHub Copilot's review of PR #20.** Recorded because the reasoning about *where* the
check belongs is not obvious from the code.

---

### D-063 — `HotkeyChordValidator` lives in `Capture/`, not `Features/Settings/`

**2026-09-07** · M1-08 · **Status:** accepted · **corrects D-059's placement**

Moved to `StenoKit/Capture/`, beside `HotkeyChord`, `SystemHotkeys` and `GlobalHotkeyMonitor`;
its tests moved to `StenoTests/Capture/` with it.

M1-08 put it under `Features/Settings/` because the recorder was its first caller. That was wrong
on the layer map's own terms — `Features/` holds **view models**, and this is a pure rule — and
D-062 made it visible by giving the validator a second caller in `Features/Capture/`, which would
otherwise have left capture depending on a settings-namespaced type. The dependency runs the other
way round: settings configures capture.

No behaviour changed. The rule it encodes — what is safe to register as a global chord — was always
a capture concern.

### D-064 — Both store-write performance cases assert the mean, not the worst of ten

**2026-09-07** · follow-up to M1-07/M1-08 · **Status:** accepted · **completes D-053's fix**

`testSingleCaptureIsWellUnderBudget` and `testCaptureAtScaleIsWellUnderBudget` now gate on the
mean of `measure`'s iterations. The 50 ms ceiling is unchanged. All three cases in
`CapturePerformanceTests` are now on the same statistic; the file's "one exception" note is gone.

**The evidence.** `testCaptureAtScaleIsWellUnderBudget` failed at 63 ms, failed again at 72 ms,
then passed — **all three on the identical commit `f757b07`**, which changed a doc comment and
added an unrelated test. Three outcomes from one commit is proof the code was not the variable.
The failing run reported a mean of 11 ms at an RSD of **±189%**: nine iterations near 3 ms and one
pathological one. Worst-of-ten is the statistic that selects for exactly that.

M1-07 had already reached this conclusion for `testKeyScanOnALargePasteStaysInteractive` and
recorded it in D-053, but left the two store-write cases on worst-of-ten because they had not
flaked in seven runs. They had the same weakness; one of them simply had not crossed the line yet.
`testSingleCaptureIsWellUnderBudget` still has not, and is moved anyway — it shares the cause, the
statistic and the ceiling, and the file already argues the two gates must not drift apart. That
has to cover *how* they measure, not only the figure they compare against.

**A root-cause fix was tried first and rejected on measurement.** Per-iteration values show the
first iteration is consistently 2–5x the other nine, and the existing comment attributed that to a
cold store. If true, an untimed warm-up capture before `measure` would have removed the spike and
allowed worst-of-ten to stay — the stricter gate. It was implemented and measured: the spike did
not move (9.5 ms → 9.6 ms). The overhead is in XCTest's measurement harness, not in the store, so
the warm-up was reverted rather than shipped. **A change that does nothing, carrying a comment
saying it fixed something, would have been worse than no change** — and the comment was already
written before the measurement contradicted it.

**What the mean gives up.** A regression that slowed a single capture in a run would now pass. That is
accepted for the same reason D-053 accepted it: no worst-of-ten ceiling separates that defect from
runner noise, because 72 ms has been observed on clean code. A regression worth catching — the
order-of-magnitude kind this gate exists for — moves the mean with it, verified by mutation: a
60 ms delay injected into the measured block fails both cases.

**Mutation-checked twice**, the second because D-053 records a hardcoded ceiling surviving a
changed literal in a failure *message*: changing `ceiling` to 0.5 ms produced "over the 0.5 ms
ceiling", so the message cannot drift from the value asserted.

**Numbers are ranges over four runs**, not three cherry-picked values, because two more arrived
during mutation testing under full-suite load and the low end came from there.

**Nothing in the file assumes ten iterations any more.** `XCTMeasureOptions` can change the count,
so the mean divides by the iterations actually run and the row-count assertions compare against
that same tally rather than a literal `10` and `30`. The separate `iterations > 0` assertion is
what keeps that safe: a block that never ran leaves both sides at zero, which would satisfy the
equality on its own. Mutation-checked — a measured block that throws nothing and writes nothing
still fails both counts. Raised by Copilot's review of PR #21.

**This entry claimed the file's "one exception" note was removed before it actually was.** The
class doc rewrite was collateral damage when the warm-up experiment above was reverted with `git
checkout --`, and only the per-test edits were re-applied. Caught by Copilot, not by me, on a PR
whose subject is not shipping claims the code disproves.

---

### D-065 — A gathered window is a `Sendable` value snapshot
**2026-09-07** · M2-01 · **Status:** accepted

`GatheredWindow`, `GatheredTask` and `GatheredEvent` — `ReportGatherer.gather(for:)`'s return type
— carry plain values, not the `@Model` rows they were read from. All three are `Sendable`.

**Why:** M3-03 hands a `GatheredWindow` to an `AIProvider` across an async boundary, and `TaskItem`
and `Event` are `@Model` classes — not `Sendable`, not safe to touch from another isolation domain.
Returning live rows would only defer the problem: the snapshot types would still get built, later,
in a task whose review gate is about prompt construction rather than about the shape of the report
payload. Building them here puts the question in front of the reviewer who is actually thinking
about it.

It doubles as half of FR-4's side-effect guarantee expressed as a type rather than a convention: a
caller holding a `GatheredWindow` has nothing in hand that it *could* mutate. `ReportGatherer`
itself has no `save` parameter for the same reason.

`GatheredEvent` carries no `id` — an earlier draft gave it one, justified as what M2-04 would use
to find the events it redacts. That was false: M2-04 redacts `standupReported` events, and D-066
excludes that kind from gathering entirely, so nothing reads the field. It was dropped rather than
shipped unused on a type three downstream tasks depend on.

**Alternatives:** returning live `TaskItem`/`Event` (not `Sendable`; the snapshot types get written
anyway in M3-03, under a review gate about prompts rather than about payload shape).

---

### D-066 — `standupReported` events are never gathered
**2026-09-07** · M2-01 · **Status:** accepted · a declared interpretation of FR-4 step 3

`ReportGatherer` excludes `Event`s of kind `.standupReported` from the window it returns, even
though FR-4 step 3's interval is closed and unqualified by kind.

**The collision is measured, not theorised.** Copy sets `project.lastStandupAt = now` and appends
`standupReported` events stamped with that same `now`. The next report's `windowStart` is
therefore exactly equal to those events' timestamps, and `EventQueries.inWindow` is a closed
interval — `timestamp >= start && timestamp <= end`. A runtime probe against SwiftData on this
branch confirmed the closed interval returns an event stamped at exactly `windowStart`. So every
report after a project's first one would open with "a report was generated" as reported work,
every time, not rarely.

The exclusion stands on its own merits independent of that tie: a report is not work. "Yesterday I
generated a stand-up" is not something the user says out loud at today's stand-up, so the kind
should never reach the renderer or the prompt regardless of timestamps — including the case where
two reports happen in one day and the earlier one's event sits in the middle of the next window,
where an interval change alone would not help.

**M2-04 inherits a constraint from this.** Undo must redact the `standupReported` events Copy
appended, and this path deliberately never returns that kind — so M2-04 cannot get them from a
`GatheredWindow`. `StandupReport` stores `projectID`, `windowStart` and `windowEnd` but no event
IDs, so M2-04 has to query for them itself: `standupReported` events for the project's tasks at or
after the report's `windowEnd`.

**Alternatives:** a half-open interval `(windowStart, now]` (deviates from FR-4's stated interval,
drops a legitimate note stamped at exactly `windowStart`, and leaves mid-window `standupReported`
events flowing in — narrowing the problem rather than solving it); doing both (makes the interval
change untestable — once the kind is excluded, no fixture can distinguish half-open from closed, so
it would be a line of code nothing can verify).

---

### D-067 — An inverted window is clamped, not fatal
**2026-09-07** · M2-01 · **Status:** accepted · a declared interpretation of FR-4 step 2

`ReportWindow.bounds(lastStandupAt:now:)` clamps `start` to `min(requested, now)` rather than
letting `windowStart` land after `windowEnd`.

**This is reachable through a supported path, not defensive padding.** §10.1 merges
`lastStandupAt` by "take the later timestamp" — the rule **D-099 supersedes**, though not its
reasoning. Report on a Mac whose clock runs a few minutes fast,
export, import onto a Mac whose clock does not — the second machine's stored `lastStandupAt` is
genuinely ahead of its own `now`. M2.5 is core rather than optional (§10), so this arrives by
design.

Clamping yields an empty window: a thin report, with open tasks still surfacing per D-068, rather
than a crash or a fabricated 24-hour window. It also keeps `windowStart <= windowEnd` true for
every `StandupReport` M2-03 persists, which M2-04's undo reads back — an inverted interval left
unclamped would let M2-04 restore a future `lastStandupAt` from it, turning a transient clock skew
into a permanent one. The clamp is logged (dates only, never task content) by `ReportGatherer`, not
by `ReportWindow`, so the rule itself stays a pure function of its arguments.

**Alternatives:** a 24-hour fallback (silently re-reports work already said aloud on the other Mac,
and overloads the first-run rule — 24h would then mean "reported recently elsewhere" as well as
"never reported"); throwing (§7.4's posture is that the user must never arrive at a stand-up
empty-handed; failing the app's core feature over a clock disagreement of minutes is a bad trade).

---

### D-068 — Report inclusion is active-or-open
**2026-09-07** · M2-01 · **Status:** accepted

A task is included in a `GatheredWindow` when it is not archived and either it has at least one
non-redacted event in the window, or its current status is `.inProgress` or `.blocked`. A quiet
open task appears with an empty `events` array rather than being dropped.

**This is the rule that makes FR-4's own report structure satisfiable, not a departure from it.**
FR-4 step 3 speaks about gathering *events*; two paragraphs later, FR-4's report structure requires
current **Today** ("IN-PROGRESS tasks") and **Blockers** ("BLOCKED tasks with reasons") sections —
defined by current *status*, not by window activity. Neither half of FR-4 is being deviated from
here: active-or-open reconciles the two, because an events-only reading of step 3 would leave
Today and Blockers empty in exactly the case FR-4 requires them populated. A task set to
in-progress on Friday and left quiet over the weekend is exactly what Monday's stand-up is for;
activity-only gathering drops it, and the report would omit the thing the user is actually working
on.

**Consequence for M2-02, named here so it is not rediscovered as a gap:** `GatheredTask.events` may
be empty, and the renderer must produce something honest for that case rather than a blank bullet.

**Alternatives:** activity-only (drops the task Monday's stand-up is about, and pushes M2-02 toward
opening a second, unreviewed read path into the store to recover open tasks on its own — splitting
"what is in the report" across two files); every non-archived task (pushes the reportability
judgement downstream into M3-03's prompt as noise — shipping every long-finished task to the model
as context it must learn to ignore).

---

### D-069 — `blockedReason` is sourced independent of the report window
**2026-09-07** · M2-01 · **Status:** accepted

`GatheredTask.blockedReason` carries the most recent non-redacted `blockedReason` event's body for
a task whose current status is `.blocked`, found by querying that task's full timeline rather than
the window's bucketed events — `nil` for any other status.

**D-068 includes a quiet blocked task precisely because FR-4's report structure demands it — but
gathering the reason from the window alone would have handed back the task with nothing to say.**
FR-4's structure specifies "**Blockers** — BLOCKED tasks with reasons". `blockedReason` is an
ordinary `Event`, so a task blocked before the window opened and quiet since — the common case: it
was blocked last week, is still blocked, and nothing new has happened — arrives with an empty
`events` array under D-068's own rule, and the one event that explains *why* it is blocked sits
outside `[start, end]`. The type would be withholding the very thing that justified including the
task in the first place.

**The precedent that settles it: `ticketKeys` already reads `task.sourceRefs`, not windowed
events.** Nothing about "ticket references survive outside the window but blocked reasons don't"
is defensible — the two fields disagreeing was the defect. Making `blockedReason` consistent with
`ticketKeys` is the fix, not a new exception.

**One accepted gap, stated rather than hidden:** if a task was blocked, unblocked, and re-blocked
without a fresh `blockedReason` event, the earlier reason surfaces — not the current episode's
reason, because there isn't one yet. That matches how a person recalls the task from memory, and
is better than the alternative of going silent.

**Alternatives:** let M2-02 query the store for the reason when it renders a blocked task with no
in-window event — rejected because it reopens the side-effect question inside a renderer task, the
same argument D-068 already made for putting the inclusion rule in the gatherer rather than the
renderer; widen the report window for blocked tasks specifically — rejected because the window
belongs to FR-4, and bending it per-task would make `StandupReport.windowStart` mean a different
thing on different rows of the same report.

---

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

**Amended in review, before merge: a currently-blocked task's `blockedReason` events are excluded
too, because the reason is already surfaced separately.** `StatusService.addBlockedReason` stamps
`now()`, so a task blocked since the last stand-up — the ordinary case — carries its reason both as
an event inside the window and on `GatheredTask.blockedReason` (D-069). Counting it as an authored
bullet made the daily report say the reason under *Since last stand-up* and again under *Blockers*,
and made the periodic report say it **twice inside one bullet**. The exclusion is conditioned on
`status == .blocked` rather than dropping the kind outright: D-069 leaves `blockedReason` `nil` for
anything not currently blocked, so on a task unblocked during the window the event is the only
carrier of what the user wrote, and filtering it unconditionally would delete their words instead
of de-duplicating them. **Accepted gap,** matching D-069's own: a task blocked, unblocked, and
re-blocked inside one window shows the current reason only.

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

---

### D-075 — CI fails when `make format` would change anything
**2026-09-08** · chore · **Status:** accepted

The `build-test-lint` job runs `make format` and fails if it rewrote anything under `Steno`,
`StenoKit` or `StenoTests`.

**D-013 assigns layout to swift-format and semantics to SwiftLint, but only SwiftLint's half was
enforced.** A file could therefore merge unformatted and stay that way indefinitely: nothing
checked, and the only signal was the *next* author running `make format` as §9.5 step 4 requires
and finding an unrelated file in their working tree. That is not hypothetical —
`EventQueriesTests.swift` drifted at M1-06, was rediscovered twice during M2-02, and was fixed in
its own PR (#24) precisely because it did not belong in a feature diff.

**The step runs last, and that placement is load-bearing.** `make format` writes in place, so
asking "is this formatted" necessarily mutates the checkout. No later step may observe a tree that
no commit corresponds to.

**It carries `if: '!cancelled()'`, for the reason `make lint` already does.** Formatting is
independent of compiling, so a red build must not hide it, and one run should report every problem
rather than surfacing them one push at a time.

**The diff is scoped to the three directories the target writes to**, so a failure always names
formatting rather than some other step having dirtied the tree. `Steno.xcodeproj` and
`Local.xcconfig` are gitignored, which makes the scope belt-and-braces rather than load-bearing.

**The cost, stated rather than discovered: formatting now has veto power over a build.** A correct,
passing change can be blocked on whitespace. Mitigated by the fix always being exactly
`make format`, by the error message saying so, and by the step running last so it never masks a
real failure.

**Alternatives:** a separate `format` job — rejected because branch protection matches the single
required check `build-test-lint` verbatim, so a second job would need adding to the protection rule
to mean anything, and a job that is not required is a gate that does not gate (D-008, D-014 are
this repo's history of exactly that); a pre-commit hook — rejected because §9.5's gate must hold
without an agent's or a contributor's cooperation, which is the whole argument for M1-07.

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

**One latent assumption, recorded because it is invisible at the call site.**
`MainWindowModel` hands the same `ModelContext` to all five of its services, so
the `context.rollback()` above discards *every* pending change on that context,
not only this transaction's. That is safe today only because each service saves
immediately after it mutates, leaving nothing else pending when Copy runs. A
service that batches writes would have them silently destroyed by a failed
Copy — so whoever adds one needs either its own context or a narrower recovery
than `rollback()`.

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

### D-082 — The confirmed sheet says whether the clipboard actually took it

**2026-09-09** · M2-03 · **Status:** accepted

`StandupDraftSheet`'s headline is three-way, not two: `Prepare Stand-up` while editing,
`Copied to clipboard` once copied, and `Recorded — not copied` when the report committed but
`NSPasteboard` refused the write.

Keying the headline on `phase` alone — which is what this task's own plan specified — announced
"Copied to clipboard" in bold directly above the notice explaining that the clipboard had refused
it. The screen asserted two contradictory things, and the false half was the prominent one, at the
exact moment the user is about to read their stand-up aloud from an empty clipboard.

The report being **recorded** and the text reaching the **clipboard** are two different facts, and
D-078 creates the one state where they disagree: the transaction commits, the clock advances, and
the copy fails with no way back (the compensation would be deleting an `Event`, which §3.3
forbids). A UI keyed on a single flag cannot express that state honestly.

`notice` is the discriminator rather than a second stored flag — it is non-nil exactly when the
commit succeeded and the clipboard refused, so the view needs nothing new from
`StandupDraftModel`.

Found in review, not in planning. The plan's header expression was wrong; the spec was not —
§6 asks `.copied` to show "a confirmation" and never asks it to claim a success it did not have.

---

### D-083 — Emphasis goes on the clipboard as real rich text, not as markup

**2026-09-09** · M2-03 · **Status:** accepted

`StandupClipboard` puts two flavours on the pasteboard: RTF where headings are genuinely bold and
D-074's `_None_` is genuinely italic, and the markdown unchanged as the plain-text fallback.

**Slack's composer converts `*bold*` as you type, not when you paste.** Markup arriving on the
clipboard therefore stays literal, and a heading emitted as `*Today*` reached the channel as
`*Today*`. Found by the user on the first real stand-up — it is M2-03's D6 acceptance criterion
("pasting into Slack produces correctly formatted output") and no agent can verify it, which is
exactly why it survived review.

**D-073 already had the right principle and this extends it.** It chose the literal `•` and `◦`
characters over `-` "because a literal bullet character *is* a bullet in any paste target and does
not depend on Slack's composer choosing to convert a hyphen" — then emitted headings that depended
on precisely that. Bold that is actually bold is the same idea applied to emphasis.

**One rule, whole-line only:** a line entirely wrapped in `*` becomes bold, a line entirely wrapped
in `_` becomes italic, delimiters dropped. Those are the only two constructs `SlackMarkdown` emits.
A line carrying more than one delimiter pair is left plain rather than guessed at.

**Inline emphasis inside a note body is deliberately untouched**, which is D-073's verbatim rule
holding: a body containing `*` or `_` is passed through unescaped because "appear verbatim as the
user typed them" is an acceptance criterion and correct Slack emphasis is not. Resolving an interior
delimiter here would overturn that decision in the one place the user cannot see it happen.

`StandupReport.markdownBody` still stores the markdown. M2-04's undo and §10's export read that
field and neither wants a document format — and the plain flavour means pasting into a plain-text
target is no worse than before.

**Alternatives:** uppercase headings with no emphasis at all (simplest, but loses the distinction a
spoken stand-up reads from); asking the user to enable Slack's "Format messages with markup"
preference (makes correct output depend on per-device config, which D6 assigns to the app, and
breaks silently on another machine).

### D-084 — FR-4.1's undo is its own service, not a method on `StandupService`

**2026-09-10** · M2-04 · **Status:** accepted

`StandupUndoService` owns every write undo makes. It takes `context` and an injected `save`, and
deliberately takes **no `now` and no clipboard**: it reads every timestamp it needs out of the
report being undone, and the markdown is already in the user's paste buffer.

**Why not a method on `StandupService`.** That type's `init` carries a
`copy: @MainActor (String) -> Bool` seam undo never reaches, so every undo test would have to
supply a clipboard stub for a path that cannot touch one. Its doc comment declares it "the one
place the stand-up clock advances", which undo makes false in a way no reader would expect from
the name. And D-044 already records that the two guard on different things: `StandupService` on
project identity, undo on report recency.

**Why not `NoteService`.** D-044 says it outright — `redact` guards on `EventKind.isUserAuthored`,
which is `false` for `standupReported` (D-045), so it refuses precisely the events FR-4.1 must
redact, and refuses by returning `false` rather than throwing. The misuse would be silent.

**Alternatives:** putting the logic on `MainWindowModel+Standup` (D-044's own reasoning applies
again — the guard is about reports and events, not about what is on screen, and it would put a
store write behind a surface the headless bundle cannot reach).

---

### D-085 — The `reportID` payload discriminates; the timestamp only narrows the fetch

**2026-09-10** · M2-04 · **Status:** accepted · consumes D-079, D-066

Undo finds its events in two steps, because neither half of the test is expressible in a
`#Predicate` — an `EventKind` does not compile there in either spelling, and `payload` is `Data`
with no predicate operation that could read a UUID out of it:

1. `EventQueries.notRedacted(atOrAfter:)` bounds the fetch at the report's `windowEnd`, which is
   the bound D-066 named.
2. The caller filters in memory on `kind == .standupReported` and a decoded
   `reportID == report.id`.

**The payload decides.** D-079 added it for exactly this and rejected matching on
`timestamp == report.generatedAt`, which works today only because `StandupService` stamps both
from one `now()` — a coincidence it is free to stop honouring, and whose loss would break undo
silently. Since the payload match is exact, the fetch bound costs a few extra rows rather than
correctness, which is why an over-broad bound is the safe direction.

**The redaction filter stays in `EventQueries`** rather than being restated here: §3.3's rule
already lives in one place, and a bespoke `!isRedacted` predicate in the service would be the
second copy and the first to drift.

Two tests keep this falsifiable rather than merely stated. One builds two reports whose events
straddle the later report's `windowEnd` — the boundary case D-066 calls normal, where the bound
alone cannot separate them. The other inserts a `standupReported` row carrying the right
`reportID` and a *different* timestamp, and asserts it is still redacted. Dropping the payload
clause fails the first; matching on `generatedAt` fails the second.

---

### D-086 — One query answers both of FR-4.1's eligibility rules

**2026-09-10** · M2-04 · **Status:** accepted

`undoableReport(for:)` fetches `StandupReport` where `projectID` matches, sorted by `generatedAt`
descending with `fetchLimit = 1`, and returns it only when `!isUndone`.

That single query is three requirements at once. "Undo applies only to the most recent report"
falls out of the sort and the limit. "And only while it is the most recent" falls out of it being
evaluated at call time rather than cached when the report was written. And an already-undone
report yields `nil`, so undo is not itself undoable — matching `Event.redact()`, which is one-way
by design and names this requirement as the reason there is no `unredact()`.

**A `generatedAt` tie cannot be broken and does not need to be.** `SortDescriptor` has no
secondary key available — `UUID` is not `Comparable`, the wall `EventQueries.timeline` documents
for its own tie case — but two Copies stamped at the same instant are unreachable, because
`StandupDraftModel.canCopy` is `false` once `phase` leaves `.editing`.

This is the first read path over `StandupReport`; M2-03 only inserted.

---

### D-087 — Undoing a project's *first* report restores `windowStart`, not `nil`

**2026-09-10** · M2-04 · **Status:** accepted · a declared interpretation of FR-4.1

`Project.lastStandupAt` is `Date?` and is `nil` until a project's first Copy. Undo restores
`report.windowStart` in every case — for a first report that is a frozen "24h before Prepare ran",
not the `nil` the field actually held.

**This is the better direction, not an accepted approximation.** `StandupReport` records no "was
this the first" flag, so `nil` could only be inferred; and restoring it would make the next
Prepare compute a *sliding* 24-hour window, silently losing everything between the original
cutoff and the new one. The frozen cutoff yields a window that is a superset of the one the user
would have had if they had never pressed Copy. FR-4.1's promise is that undo loses nothing — a
slightly wider window keeps it, a sliding one breaks it.

D-067's clamp is what makes this safe rather than merely defensible: `windowStart <= windowEnd`
holds for every persisted report, so undo can never install a *future* `lastStandupAt`.

**Alternatives:** storing the previous `lastStandupAt` on `StandupReport` as its own field (§3.5
already defines `windowStart` as exactly that value, so the field would be a second copy of one
fact and a new import-merge question for M2.5-02).

---

### D-088 — Undo takes its report explicitly rather than resolving it

**2026-09-10** · M2-04 · **Status:** accepted

`undo(_ report: StandupReport, for project: Project)` — not `undo(for: project)`, which would be
one fewer parameter and one fewer error case.

Resolving the report internally turns "undo is unavailable once a newer report exists" from a
refusal the caller can observe into a **silent substitution of a different report** — reversing a
window the user never asked about. The acceptance criterion would then be testable only by
inspecting which rows changed. The explicit pair also mirrors `commit(_:of:for:)`, so the two
halves of FR-4 step 7 read alike, and it keeps the project-pair guard meaningful.

The service still guards recency through the same `undoableReport(for:)` the UI gates on, so a
menu item that went stale between a reload and a click cannot undo a report that has since
stopped being the most recent.

---

### D-089 — Undo is a menu item with no key equivalent, and the sheet owns it while open

**2026-09-10** · M2-04 · **Status:** accepted

Two surfaces. The draft sheet gains an Undo button in its `.copied` phase and a third `.undone`
phase — D-080 kept the sheet open after Copy precisely so this button would have somewhere to
live. `MainWindowModel` also caches `undoableStandupReport` and exposes `canUndoStandup`, so
"Undo Last Stand-up" sits in the `Task` menu beside Prepare Stand-up and **outlives the sheet**,
which is when the misclick FR-4.1 exists for is actually noticed.

**No keyboard shortcut.** ⌘Z is the system's text-editing undo, and this window puts `TextEditor`s
inside the very sheet that produces the report — binding a store transaction to it would make the
two indistinguishable at the moment the user most wants them apart. FR-3 asks for shortcuts on the
primary actions; this is a recovery action.

**`canUndoStandup` includes `activeSheet == nil`**, so while the sheet is up it owns undo. A menu
path firing behind it would leave `phase` reading `.copied` over a report that has just been taken
back, and the sheet would still be offering to undo it. Gating rather than reconciling two paths
is what `canPrepareStandup` does for the same collision.

The cached report is refreshed in `reload()` rather than fetched on demand because
`canUndoStandup` is read from `MainWindowCommands.body` — a fetch behind it would be a store read
on SwiftUI's render path, the hazard `selectedTaskEvents` documents.

---

### D-090 — Export sets `.sortedKeys`; key order is alphabetical, not §10.2's

**2026-09-11** · M2.5-01 · **Status:** accepted · amends REQUIREMENTS.md §10.2 (v1.16)

`ExportDocument.encoder()` sets `.prettyPrinted`, `.sortedKeys` and `.withoutEscapingSlashes`. The
file's keys are therefore alphabetical, and §10.2's example ordering — `schemaVersion` first — is
illustrative rather than emitted.

**Why:** the appealing alternative was to rely on synthesized `Codable` emitting keys in property
declaration order, which would have matched §10.2 exactly. That is simply false. `Codable`
synthesis writes into a dictionary, so without the option the key order is hash order, and **it
differs between processes** — two runs of the suite produced two different top-level orders for
the same document. Two exports of an unchanged store would be byte-different files, which defeats
the diffability §10.2 asks for by name and reduces M2.5-05's auto-export history to noise. No
single test run can observe this, which is why it is written down here: the falsification is to
remove the option and run `make test` **twice**.
**Alternatives:** a hand-written serializer that controls key order (the only way to have both,
and far too much machinery for a cosmetic property); accepting nondeterminism (it is the one thing
§10.2 cannot accept).

---

### D-091 — Timestamps carry milliseconds, and encoding truncates

> **Superseded in part by D-101 (2026-09-11): encoding now rounds to the nearest millisecond.**
> Everything below about *why* the format carries milliseconds still stands, and the measurements
> of truncation were correct — they were simply of the wrong direction. `Date → string → Date` is
> what this entry measured; `string → Date → string` is what a merge needs, and truncation made
> that unstable for 496 of 1000 values. Read D-101 for the format's current contract: the error is
> 0.5 ms in either direction rather than 1 ms downward, and `.0625` still emits `.062`.

**2026-09-11** · M2.5-01 · **Status:** accepted · amends REQUIREMENTS.md §10.2 (v1.16)

Dates encode as ISO-8601 with three fractional digits, through a `Date.ISO8601FormatStyle`. The
decoder accepts the fractional form first and falls back to whole seconds, so a hand-edited file
still imports.

**Why:** §10.1 resolves three of its four mutable-field merge rules by comparing timestamps.
Whole-second precision makes two notes typed in the same second a tie no rule can break, and
their order in the append-only log is then unrecoverable.

**The precision claim is narrower than "milliseconds" suggests, and was measured.** Formatting
**truncates rather than rounds**, and at epoch 1.7e9 most decimals are not representable as a
`Double`: `.481` is stored as `.4809999…` and emitted as `.480`; `.1` emits as `.099`. So a
round-trip is *exact* only when the fractional second is an **eighth** — `0`, `.125`, `.25`,
`.375`, `.5`, `.625`, `.75`, `.875`, the only values both exactly representable in binary and
exactly expressible in three decimals — and otherwise lands within 1 ms and **never later**. Not
every dyadic value qualifies: `.0625` is dyadic and still truncates to `.062`. Every fixture date
**used in a direct `==` assertion** is whole or an eighth for this reason, which is what lets
`ExportDocument ==` be a fair assertion; the ordering and tolerance tests deliberately use values
that do not survive — `.5001`, a clock-shaped date — because that is the behaviour they pin. **M2.5-02's "the object
graph is identical" criterion means identical at this precision** — an `==` on a `Date` that came
from `Date.now` will fail there, and will look like a merge bug.
**Alternatives:** epoch seconds as a JSON number (lossless and bit-exact, and unreadable at
exactly the field a person most wants to read); whole seconds per the original example (loses
ordering within a second).

---

### D-092 — Every exported array carries a total order, ending in the record id

**2026-09-11** · M2.5-01 · **Status:** accepted

Projects sort by `(sortOrder, name, id)` and refs by §3.4's dedup key then `id`. Tasks, events
and reports sort by their timestamp **as the file carries it** — the emitted ISO-8601 string —
then by `id`.

**The date-sorted arrays key on the emitted string, not the in-memory `Date`, and that was a bug
found in review.** Two events a fraction of a millisecond apart are distinguishable in memory and
identical on the wire, so ordering on the `Date` produces a sequence the file cannot express: any
store built from that file ties on them, falls through to the id, and can reverse the pair
relative to the export it came from. An unchanged store would then export differently after a
round trip, which is exactly what M2.5-05's backup history and M2.5-02's convergence rely on not
happening. Keying on the emitted value makes the array order derivable from the file's own
contents.

The first attempt quantized arithmetically, `(seconds * 1000).rounded(.down)`, and disagreed with
the formatter at `.999` — a second implementation of truncation drifting from the first in the
third decimal place, caught by the test written to compare them. There is now one
implementation: the formatter.

**Projects carry three components, not two, and the middle one is the point.** `sortOrder` is
not unique, and `MainWindowModel.fetchProjects` breaks that tie on `name` — so sorting on
`(sortOrder, id)` would export two equally-ordered projects in a sequence the user has never
seen, under a comment claiming the file reads in sidebar order. Corrected in review of M2.5-01's
PR; `name` is not unique either, which is why `id` stays as a third component. Sorting happens in memory
rather than through `FetchDescriptor.sortBy`, so the comparators sit together and `SourceRefKind`
is not a special case — an enum inside a `#Predicate` does not compile in either spelling
(`EventQueries.swift`, D-085).

**Why:** `sorted(by:)` is not documented as stable, so two records sharing a timestamp would
otherwise have an unspecified relative order and consecutive exports of an unchanged store would
differ. The time-ordered arrays also mean a day's new rows append at the *end*, so a diff between
two daily exports reads as additions rather than as a reshuffle. This is what makes M2.5-05's
auto-export a backup history rather than churn. Falsified by dropping the id from the event
comparator, which turns the tie-break test red.
**Alternatives:** sorting by `id` alone (fully stable, and it scatters a task's timeline across
the file); relying on SwiftData's fetch order (unspecified — `ReportGatherer` already records
this).

---

### D-093 — The export carries no `AppSettings`, closing O-9

**2026-09-11** · M2.5-01 · **Status:** accepted · closes **O-9** · amends D-056

§10's export carries domain data only. The hotkey chord and FR-6's default project stay on the
machine that set them.

**Why:** three reasons, in the order they matter. FR-6's default project is a `UUID` that may name
a project the target machine does not have, so importing it installs a dangling pointer into the
capture path §1.1 requires never to block. A chord free on machine A may collide with another
app's on machine B, and import has no way to ask. And M2.5-02's merge would need a conflict rule
for something that is not a record. `AppSettings.swift`'s doc comment already asserted this
outcome; this decision is what makes the assertion true rather than aspirational, and
`ExportSecretsTests` asserts that neither key nor value reaches the file.
**Alternatives:** exporting settings so a new machine comes up configured (a sixth top-level key
that is not a record type, plus a dangling-`UUID` validation path on import, for two values the
user sets once).

---

### D-094 — Integration configuration is deferred to M4-04/M5-02, closing O-7

**2026-09-11** · M2.5-01 · **Status:** accepted · closes **O-7**

§10.3 permits integration *configuration* — Jira site URLs, MCP server definitions minus secrets —
to be exported. M2.5-01 does not export it, and that permission passes to the tasks that create
those records.

**Why:** there is nothing to serialize. `StenoKit/Sources/` does not exist, there is no
`SourceConnector` and no MCP server definition anywhere in the codebase. Designing their export
now would mean inventing the shape of records that do not exist, and fixing that shape in the one
file format that has to stay compatible. The task that creates them adds them under a bumped
`schemaVersion`, alongside the first-use credential prompt §10.3 already requires.
**Alternatives:** reserving empty keys in the envelope now (buys format stability for a shape
nobody can predict, and every reserved key is one M2.5-02 must decide how to merge).

---

### D-095 — §10.3's guarantee needs four layered guards; the JSON allowlist alone misses most of them

**2026-09-11** · M2.5-01 · **Status:** accepted

The export's field completeness is asserted four times, each guard blind to what the next
catches: over the emitted JSON keys; over each record type's declared stored properties via
`Mirror`; over each `@Model`'s stored properties, against the same set plus a named exclusion
list; and over `Schema(StenoStore.models())`, so a whole model with no DTO fails rather than
being silently absent from every export. The first three read one shared literal declaration of
the allowed keys.

**Why:** §10.3 asks for the scan because "construction-based guarantees erode silently when
someone later adds a field" — and a key allowlist read from the JSON **does not catch that case**.
Mutation testing proved it: adding `public let apiToken: String?` to a record changed nothing. The
field is `nil`, synthesized `Codable` uses `encodeIfPresent`, the key is omitted, and the bytes are
byte-for-byte identical. A field with no fixture value is never anything *but* `nil`, so it would
stay invisible forever. The `Mirror` assertion fails the moment the property is declared, valued
or not, and it caught the same mutation immediately.

**A third assertion was added in review, for the direction the first two cannot see.** Both
allowlists compare the *records* to a literal set, so a field added to `Project` and forgotten in
`ExportedProject` changes nothing — the DTO has not grown, the JSON has not changed, and the
export silently drops user data. `everyModelFieldIsAccountedFor` compares each `@Model`'s stored
properties (via `Mirror`, dropping the macro's `_` prefix and its `_$` artifacts) against the same
literal set plus a named exclusion list, so the two relationship fields §3.4 deliberately omits
are stated rather than filtered by a rule. Mutation-tested: adding a field to `Project` turns it
red.

Note what the pattern scan still cannot prove: that a credential in a format nobody anticipated
would be recognised. The allowlists cover the unanticipated *field*; the scan covers the known
markers, and its positive control — which asserts the specific pattern name, not merely that
something matched — is what proves the scanner is not vacuous.
**Alternatives:** the JSON allowlist alone (demonstrably blind to new optionals); requiring every
new field to be non-optional (a schema rule the domain models cannot follow).

---

### D-096 — `CredentialPatterns` is test infrastructure, not `StenoKit`

**2026-09-11** · M2.5-01 · **Status:** accepted

The §10.3 scanner lives in `StenoTests/Portability/`. Nothing in production reads it.

**Why:** §10.3 asks for an assertion about the output, not a runtime guard. A scanner shipped in
the framework with no caller is an invitation to wire it into the write path, where it would
become a filter on user content — and **if the user pastes a token into a note, the export
containing it is correct.** §10.3 governs credentials *the app holds*, which per §8 live in
Keychain and never reach SwiftData. Stripping content from a note because it pattern-matches would
be the export silently deleting the user's data, with no second copy anywhere. M2.5-05's tests,
which assert the same property on the unattended auto-export path, link it from the test bundle.
**Alternatives:** a production scanner called before every write (turns a test into a content
filter, and the false-positive costs the user data).

---

### D-097 — `Event.payload` exports as base64, and the cost is real today

**2026-09-11** · M2.5-01 · **Status:** accepted · corrected during review

`payload` is `Data?`, so it encodes as a base64 string — neither greppable nor diffable, against
§10.2's stated goals.

**This affects ordinary stores, not hypothetical future ones.** An earlier draft of this entry
claimed `payload` was `nil` for every event the app creates and deferred the question to M4. That
was false: `StandupService` writes a `StandupReportedPayload` on every Copy (D-085), so every
`standupReported` event in a real export already carries an opaque `eyJyZXBvcnRJRCI6…` where the
report id would otherwise be greppable. Caught in review of M2.5-01's PR.

**Why base64 anyway:** round-trip fidelity outranks readability for this field. `payload` is
`Data`, and §10's first criterion is that every field survives byte-exactly — there is no second
copy (§10, D1). Embedding the JSON as a nested object means re-serializing it on import, and that
does not reproduce the original bytes: key order and whitespace are not preserved. The field
chosen for readability would become the only field that does not survive the trip. §10.2 now
states the trade rather than implying the file is uniformly greppable, and a test asserts a real
`standupReported` payload survives the round trip.
**Alternatives:** a nested JSON object (readable, and it breaks byte-exactness — disqualifying);
a UTF-8 string when the bytes decode and base64 otherwise (readable, and a decoder facing two
shapes in one field needs a discriminator the format does not have); excluding `payload` (loses a
field §10 cannot afford, and would break M2-04's undo across a transfer).

---

### D-098 — Both mutable flags merge sticky-true, closing O-8

**2026-09-11** · M2.5-02 · **Status:** accepted · **closes O-8** · amends REQUIREMENTS.md §10.1 (v1.17)

`Event.isRedacted` and `StandupReport.isUndone` merge as `local || incoming`. Once set on either
machine, set everywhere.

**Why:** neither model carries `modifiedAt`, so §10.1's "later wins" cannot reach them, and adding
one would put a mutable timestamp on the record §3.3 says is never edited. It is not needed:
**both flags are one-way in the domain.** `Event.redact()` and `StandupReport.markUndone()` only
ever assign `true`, and nothing anywhere un-assigns. A grow-only boolean is commutative, idempotent
and order-free with no clock at all, and it fails in the safe direction — a redaction made on
either machine survives the trip, so text the user took back cannot reappear in a stand-up, which
is the specific harm §10.1 warns about.

The cost is that a future un-redact would not propagate. That is pinned rather than commented:
`StoreMergeRuleTests` asserts the sticky behaviour in both directions, and the day someone adds an
`unredact()` the premise is wrong in a place a test is looking.
**Alternatives:** `modifiedAt` on both models (a migration for two booleans, and a mutable
timestamp on an append-only record); deriving `isUndone` from whether the report's
`standupReported` events are redacted (couples two records M2-04 keeps apart, and leaves
`isRedacted` itself still open).

---

### D-099 — `lastStandupAt` is derived from the reports, not compared

**2026-09-11** · M2.5-02 · **Status:** accepted · amends REQUIREMENTS.md §10.1 (v1.17)

`Project.lastStandupAt` merges as `max` over that project's reports of
`isUndone ? windowStart : windowEnd`, and `nil` when there are none.

**Why: §10.1's "take the later timestamp" was written before M2-04, and the two do not compose.**
`StandupService.commit` sets the clock to the window's end; `StandupUndoService.undo` moves it
*backwards* to `report.windowStart`, and stamps nothing. With `isUndone` sticky (D-098), taking the
later timestamp means any older export from the other machine defeats an undo: the report comes
back marked undone, its `standupReported` events stay redacted, and the clock keeps the pre-undo
value — so the window the user reclaimed is never reported again. That is the same class of failure
§10.1's rule exists to prevent, pointing the other way.

The derivation is also the more faithful reading of §10.1's own principle — *"any mutable field
that can be recomputed from the log, should be"* — since a `StandupReport` is part of the log.

**The `isUndone ? windowStart : windowEnd` shape is load-bearing.** The simpler "newest report that
is not undone" rule returns `nil` when the only report is undone, and `nil` makes the next Prepare
compute a *sliding* 24-hour window — the loss D-067 and M2-04's step 5 went out of their way to
avoid. Reading the undone report's `windowStart` reproduces exactly what undo restores.

**The "reproduces what the services write" claim is a single-machine one, and the cross-machine
rule is different on purpose.** Raised in review of PR #29: once a merge unions two machines'
reports, a live report from A with `windowEnd` 100 can sit beside a report from B that B undid,
and the derivation returns 100 where B's undo had written B's `windowStart`. That is correct, and
it is the rule rather than an accident: A reported the work up to 100 aloud and never took it
back, so §10.1's "must not re-report work already spoken aloud" governs. `max` over the set is
also order-independent, so the merge still converges. What the derivation does *not* do is
reproduce what a single-machine undo would have written, once the history is no longer from a
single machine — `aLiveReportOutranksTheOtherMachinesUndo` pins it.

A second consequence needed fixing rather than documenting: the merge makes two reports sharing a
`generatedAt` reachable, and `StandupUndoService.undoableReport` sorted on that field alone. Two
machines could converge on an identical record set and still disagree about which report Undo
offered. Tie-broken on `uuidString`, the key D-092 already uses for every exported array.

`LastStandupClock` is its own type so `LastStandupClockTests` can drive the real `StandupService`
and `StandupUndoService` through all six single-machine sequences and assert the derivation equals
the stored value. A derivation that models two services drifts from them; a comment claiming otherwise would
be the defect. Falsified by reverting to `windowEnd` unconditionally, which turns three tests red.
**Alternatives:** §10.1 verbatim (documented, and it silently loses an undo across a transfer);
later-wins with a clamp for undone reports (two rules whose application order is load-bearing —
reads fine, converges wrong).

---

### D-100 — `TaskItem.status` is parsed out of the event body, and `displayName` is now persisted

**2026-09-11** · M2.5-02 · **Status:** accepted

The merge derives a task's status by reading `StatusTransition.eventBody` back — `"IN-PROGRESS →
BLOCKED"` — through a new `init?(eventBody:)` beside it. `Status.displayName` moved out of
`StenoKit/Features/MainWindow/` as part of this; `menuOrder` stayed.

**Why:** §10.1 requires deriving rather than copying, and the body is the only machine-readable
record of a transition that exists. `StatusService` writes it with a `nil` payload, and **every
event already in every store is written that way**, so a structured payload cannot be retrofitted
onto history. Parsing is the only option the data model offers, not the preferred one.

Moving `displayName` is the point, not housekeeping: it stopped being display text the moment a
merge read it back. A rename in a view-adjacent file would break every import on every machine, and
the only symptom would be a task's status reverting after a transfer. Both directions now live in
one type, and a test asserts all four spellings literally plus a `body → Status → body` round trip
over `allCases` squared.

Parsing returns `nil` rather than throwing, and import falls back to the record's own
`statusChangedAt` and reports the event in its plan. §10.2 chose JSON partly so a file could be
edited by hand, so a mistyped arrow is reachable in practice; refusing the whole import over one is
a poor trade and swallowing it silently is worse.

Redacted `statusChanged` events still count. §3.3 makes `isRedacted` a visibility flag and a status
cache is not a summary — excluding them would let a redaction silently revert a task, which is a
mutation of the log by the back door.
**Alternatives:** adding a structured payload to new `statusChanged` events (changes M1-05's write
path, and every historical event still needs the parser — a second format without removing the
first); resolving status by later `statusChangedAt` (no parsing, and it contradicts §10.1's stated
reason the scheme is robust).

---

### D-101 — The wire format rounds to the nearest millisecond, because it must be a fixed point

**2026-09-11** · M2.5-02 · **Status:** accepted · amends REQUIREMENTS.md §10.2 (v1.17) and D-091

`ExportDocument.wireString` is the single implementation of what the file says an instant is, and
it adds half a millisecond before formatting so that the style's truncation becomes
round-to-nearest. Both the encoder's date strategy and D-092's sort key call it.

**Why: D-091 measured the round trip in one direction and the other one was broken.** `Date →
string → Date` is lossy in a known way, as recorded. The direction M2.5-02 needs is `string → Date
→ string`, and under truncation it was not a fixed point: parsing `…20.481Z` yields a `Double` of
`.4809999…`, which truncates back out as `…20.480Z`. **Measured over every millisecond value at
four epochs from 2020 to 2033: 496 of 1000 unstable**, walking backwards up to 2 ms across at most
two hops before sticking (504 values stable immediately, 392 after one hop, 104 after two).

Two things rested on that fixed point. §10.6 asks that importing the same file twice change
nothing — with the format moving underneath it, roughly half the timestamps come back lower on the
second read and the merge writes them again. And §10.2 promises two exports of an unchanged store
are byte-identical, which is what makes M2.5-05's auto-export a history rather than churn; a round
trip through a file undid what D-090 established.

After the change: **0 of 4000 unstable** across the same four epochs, 0 of 50000 for clock-shaped
dates, worst error halved to 0.5 ms and no longer one-sided. Eighths are still exact — all eight
verified. `schemaVersion` stays 1: the grammar is unchanged and every file already written still
parses. `.5001` still collides with `.500`, so M2.5-01's ordering test keeps its premise, and
`.0625` still emits `.062`, so D-091's example survives — **both checked rather than reasoned
about, after the reasoned version of the second one was wrong.** Behaviour at an exact
half-millisecond input is deterministic but not predictable by arithmetic.

One implementation matters more now than it did: rounding makes the `.999` boundary live, since
`…20.9995` carries into the next whole second, and that is precisely where the two implementations
D-092 found had disagreed. Falsified by deleting the half-millisecond, which turns the fixed-point
test red at exactly 1984 of 4000 — the figure quoted in its comment.
**This is the last moment the change is free, and that is load-bearing.** Raised in review of PR
#29: changing the quantization while keeping `schemaVersion: 1` would break a merge against a file
written by the old encoder — a local event at `.4817263` normalizes to `.482` here while the old
file carries `.481`, and the immutable-field check refuses the whole file as an inconsistent
record. It cannot happen today because **no v1 export file can exist**: `ExportEncoder`'s only
callers are `ImportService` and the test fixture, and nothing writes bytes to disk until M2.5-03's
save panel and M2.5-04's CLI. **Once M2.5-03 ships, the timestamp semantics of `schemaVersion: 1`
are frozen** — a later change needs a version bump with the v1 normalization retained for v1 files,
which means carrying a second quantizer permanently, the hazard D-092 records.
**Alternatives:** iterating the local snapshot's round trip to a fixed point (never more than two
passes, and it leaves export → import → export producing different bytes, so §10.2's diffability
keeps the defect and the workaround lives two layers from the cause); treating timestamps within
1 ms as equal (equality stops being transitive, and "later wins" becomes ambiguous exactly where
two machines disagree).

---

### D-102 — Orphaned records are refused, with closure checked against file ∪ store

**2026-09-11** · M2.5-02 · **Status:** accepted

A record whose parent is in neither the file nor the local store makes the import fail with
`ImportError.danglingReference`, applying nothing.

**Why:** a genuine Steno export always has referential closure — it is whole-store and nothing is
ever deleted — so a file that lacks it is truncated or hand-trimmed. Importing the orphans anyway
puts rows in the store that appear under no sidebar project and in no timeline: present,
unreachable, and invisible in the preview counts, with nothing that would ever surface them.

**Checking the union rather than the file alone is what keeps §10.2's hand-editability promise.**
Trimming one project out of an export still imports cleanly on a machine that already has that
project, and only a file that would actually leave a broken store is refused. Both directions are
tested.
**Alternatives:** importing orphans (invisible data); skipping them and reporting the count (leaves
the store having accepted half a file, against the single-transaction guarantee the rest of the
task is built on).

---

### D-103 — Duplicate `SourceRef` rows are kept, not collapsed — extending O-10

**2026-09-11** · M2.5-02 · **Status:** accepted · extends **O-10**

The merge unions refs by `id` only. Two rows sharing §3.4's `(taskID, kind, identifier)` dedup key
both survive.

**Why:** two machines that each extract `PAY-421` onto a task they both already have produce
exactly that. Collapsing them converges too — keep the lowest `uuidString`, fold the cached pair
into the survivor — but it would make import **the only path in the product outside Replace mode
that deletes a row**, and "import never deletes, except duplicate refs" is the kind of documented
exception that becomes the next task's bug. Keeping both satisfies every §10.6 property, since
`merge(A,B)` and `merge(B,A)` both yield the pair.

The cost is a duplicate chip in the task detail pane. O-10 already owns §3.4 ref reconciliation in
M5 and now names this case, rather than opening a competing rule here.
**Alternatives:** collapse to the lowest id (tidier UI, and it buys a deletion path); keying refs
by the dedup key instead of `id` (no duplicates, and not commutative — each machine keeps its own
row and the two stores never converge on the same object graph).

---

### D-104 — The merge is pure over records; the local store is normalized through the exporter

**2026-09-11** · M2.5-02 · **Status:** accepted

`StoreMerge` is a `nonisolated` function over the five record arrays. `ImportService` snapshots the
local store, round-trips it through `ExportDocument.encoder()` and back, and merges the result.

**Why:** §10.6's properties are algebraic, and a commutativity test written against two live
SwiftData stores is slow, long, and least readable exactly where the reasoning matters most. Purity
makes them comparisons between values.

**The normalization is not tidiness — without it nothing converges.** The local store holds
full-precision `Date`s and the incoming file's were quantized on the way out, so for the same
record the local value is almost always the larger by a fraction of a millisecond: every §10.1 rule
that compares timestamps hands the local machine a win it did not earn, and `merge(A,B)` stops
equalling `merge(B,A)`. It does not fail loudly; it fails by half a millisecond. In practice it
fails *loudly* instead, because an event's timestamp is immutable and the two copies no longer
match — so re-importing a store's own export is refused as an inconsistent record. That is the test
that catches it, and it took three attempts to write: a target store populated **from** a file
already holds wire-rounded dates, so the obvious round-trip tests cannot see the defect at all.

Round-tripping the whole document rather than mapping each `Date` through `wireString`: the
per-field version is cheaper and exactly equivalent, and there are twenty-odd date fields across
five record types where a missed one is silent. D-095 records what happens to a rule that depends
on someone remembering a field.

`includesCachedExternalData: true` on that snapshot is mandatory and the parameter defaults to
`false`. A cache-free local snapshot presents every local `cachedSummary` as `nil`, and §10.1's
"nil loses to any value" then hands every ref's cache to the incoming file. One word, and the
user's offline summaries are gone; a test asserts it.
**Alternatives:** a planner that queries the context per record (no double materialization, and the
merge rules interleave with fetches so commutativity needs two real stores); a single-pass merger
with a dry-run flag (least machinery, and preview fidelity depends on every write site honouring
the flag).

---

### D-105 — §10.6's commutativity is stated over everything the file actually carries

**2026-09-11** · M2.5-02 · **Status:** accepted · amends REQUIREMENTS.md §10.6 (v1.18)

Merging in either direction converges on the same record set and the same value for every field
**except** `SourceRef.lastFetchedAt` and `.cachedSummary`, which converge only for exports taken
with `includesCachedExternalData` set.

**Why:** read literally, §10.6 was false in the default configuration, and that is worth stating
plainly rather than defending. §10.2 excludes the two cached fields from an export unless the
opt-in is set, so an ordinary file carries no information about them at all. §10.1's "`nil` loses
to any value" is the right rule for that — a cache-free file must never clear a cache the other
machine built — but it necessarily preserves whichever machine is the import *target*, so A→B and
B→A differ in exactly those two fields.

Nothing in the merge is wrong. The requirement was asserting convergence over data the file does
not contain, and the honest fix is to say what the property is stated over.

**It was recorded in a test comment first, and that was the actual mistake.** `StoreMergeRuleTests`
asserted the asymmetry deliberately, with a comment explaining why it was correct — which makes it
discoverable by someone reading that file and invisible to everyone reading §10.6. A property the
spec claims and the code does not have belongs in the spec's own words. Raised in review of PR #29.
**Alternatives:** making cache state deterministic in the merge (there is nothing to be
deterministic *about* — the file carries neither field); exporting cached data by default
(contradicts §10.2, which excludes it for being bulky and re-fetchable, and would grow every
export for data that re-fetches in a second).

---

## Open — decided by the task that owns them

Each of these is a real choice the spec leaves open. The owning task decides it, records it in
its PR body, and adds an entry above.

| # | Question | Owning task |
|---|---|---|
| O-5 | Where "last-used project" is stored, and its behavior on first ever launch | `M1-02` |
| O-10 | Whether a `SourceRef` orphaned by a **corrected** note (the primary case) or a redacted one is reconciled, and how — stated in full as **D-049** above, which M1-06 left open rather than deciding blind. **Extended by D-103:** a merge can also produce two rows sharing §3.4's dedup key, when two machines each extract the same reference onto a task they both hold. Same question, second source | `M5` |

## Product questions — not for agents to decide

[`REQUIREMENTS.md §12`](REQUIREMENTS.md#12-open-questions) holds four open questions that are the user's call, not
an implementer's: Jira-driven auto-transition (Q(M4)), report history retention (Q(M3)), EM task
templates (Q(M1)), and whether auto-export is sufficient in practice (Q(M2) — a "no" reopens
§14). Raise them; do not resolve them.