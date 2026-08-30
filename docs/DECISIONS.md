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
merge rule (later timestamp wins), which a plain property gets by construction
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
| O-9 | Whether the hotkey chord in `UserDefaults` is carried by §10's export | `M2.5-01` |

## Product questions — not for agents to decide

[`REQUIREMENTS.md §12`](REQUIREMENTS.md#12-open-questions) holds four open questions that are the user's call, not
an implementer's: Jira-driven auto-transition (Q(M4)), report history retention (Q(M3)), EM task
templates (Q(M1)), and whether auto-export is sufficient in practice (Q(M2) — a "no" reopens
§14). Raise them; do not resolve them.