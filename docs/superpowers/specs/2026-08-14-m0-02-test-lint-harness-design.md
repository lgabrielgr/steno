# M0-02 — Test & Lint Harness — Design

**Task:** [`docs/tasks/M0-02-test-lint-harness.md`](../../tasks/M0-02-test-lint-harness.md)
**Requirements:** [§9.2](../../REQUIREMENTS.md#92-required-make-targets),
[§9.4](../../REQUIREMENTS.md#94-test-constraints),
[§9.5](../../REQUIREMENTS.md#95-version-control-workflow),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents)
**Branch:** `chore/test-lint-harness`
**Date:** 2026-08-14

## Goal

`make test` and `make lint` exist, are green, and run headless with networking denied — so
§13's "verify, don't assert" rule becomes a gate that holds rather than a sentence agents
assent to.

M0-01 removed the excuse for not compiling. This task removes the excuse for not testing.

---

## 1. Environment as found

Verified on the build machine before designing:

| Fact | Value |
|---|---|
| Xcode | 26.6 (build 17F113) |
| SwiftLint | 0.65.0, `/opt/homebrew/bin/swiftlint` (installed by `make bootstrap`) |
| XcodeGen | 2.46.0 |
| `swift-format` | present in the Xcode toolchain: `xcrun swift-format` |
| Targets today | one — the `Steno` application |
| App sources today | `Steno/App/{StenoApp,ContentView,Logging}.swift`, ~40 lines |

`swift-format` shipping inside the toolchain is load-bearing for §4: it means `make format`
adds no dependency to `make bootstrap`, and its version tracks the compiler that §9.1 already
constrains.

---

## 2. The constraint that shapes everything: headless

### 2.1 Why the obvious setup fails

A conventional macOS unit-test bundle is *hosted*: `TEST_HOST` points at `Steno.app`,
`xcodebuild` launches the app, and the test bundle is injected into the running process.
`@testable import Steno` works and no architectural change is needed.

That launch instantiates `NSApplication`, which requires a window server connection. Over SSH
or with the GUI session inactive it fails — which is precisely the condition acceptance
criterion #1 requires `make test` to survive, and precisely the condition M1-07's CI runner
will present.

So the hosted configuration is not a shortcut this task is declining out of taste. It is
ruled out by the criterion the task exists to enforce.

### 2.2 The consequence

An unhosted test bundle cannot `@testable import` an *application* target — there is no
executable for it to link against. The testable code therefore has to live somewhere both the
app and the test bundle can link: a framework.

This is the real cost of this task, and it is worth stating plainly. Extracting a framework at
M0-02, before any domain code exists to justify it, is more structural change than "add a test
target" suggests. It is accepted here rather than deferred because the alternative is moving
SwiftData `@Model` types across a target boundary at M0-03, which is a worse version of the
same change made under more pressure.

---

## 3. Target topology

### 3.1 Three targets

```
StenoKit    framework          sources: StenoKit/     domain, protocols, logic
Steno       application        sources: Steno/        SwiftUI shell; depends on + embeds StenoKit
StenoTests  bundle.unit-test   sources: StenoTests/   depends on StenoKit; no TEST_HOST
```

`StenoKit` takes bundle identifier `com.lgabrielgr.steno.kit` and inherits signing from the
project-level `configFiles` in `project.yml` — which M0-01 already set up at project rather
than target level, with a comment naming this task as the reason.

The existing `Steno` scheme gains a `test:` block naming `StenoTests`, so
`xcodebuild test -scheme Steno` covers it. No second scheme is introduced; §9.4 reserves that
for UI tests, which are out of scope here.

### 3.2 The rule this creates

**Logic goes in `StenoKit`. `Steno/` holds only SwiftUI views and the `@main` entry point.**

Restated as the test an agent can apply without reading this document: *if it cannot be tested
without a window server, it does not belong in `Steno/`.*

This supersedes the part of **D-006** that put all sources under `Steno/<Area>/`. D-006's
actual reasoning — one XcodeGen source entry per target, so a new area is a new folder and
needs no manifest change — is preserved, now applied to `StenoKit/<Area>/` as well.

### 3.3 What moves in this PR

`Steno/App/Logging.swift` → `StenoKit/Support/Logging.swift`, with `Log` and `Log.app` made
`public`. `StenoApp.swift` and `ContentView.swift` stay in `Steno/App/`.

Nothing else moves. The ~40-line app is otherwise view code, which is where it belongs.

### 3.4 Risks to verify, not assume

- **Runtime framework lookup.** An unhosted bundle may need an explicit
  `LD_RUNPATH_SEARCH_PATHS` entry (`@loader_path/../Frameworks`) to find the embedded
  `StenoKit`. XcodeGen may already supply a workable default; this gets checked by running the
  test, not by reading documentation.
- **Test bundle signing.** The bundle inherits the project `configFiles`, but whether an
  unhosted bundle needs its own `CODE_SIGN_IDENTITY` treatment is unverified.

Neither is a design fork. Both are things that either work or produce an explicit error on
first run.

---

## 4. Test framework — closing O-1

**Swift Testing is the default. XCTest stays available for exactly one thing.**

Swift Testing (`@Test` / `#expect`) ships with the Xcode 16 floor §9.1 already requires, and
its parameterized cases suit the table-driven tests coming in M1-01 (reference extraction) and
M2.5-02 (merge commutativity), where a failing row names itself instead of collapsing into one
aggregate assertion failure.

The exception: Swift Testing has no equivalent of XCTest's `measure { }`. Non-negotiable #4 —
capture latency is measured, never assumed (§1.1) — means M1-02 and M1-03 will want it. Both
frameworks run in a single `xcodebuild test` invocation, so keeping XCTest linkable costs
nothing structurally.

**The recorded rule:** Swift Testing unless the test measures performance; a PR introducing an
XCTest case says why in its body.

### 4.1 The proving test

The task asks for "one trivial passing test proving the harness works." A test asserting
`true == true` proves the harness works and nothing else. This one proves the harness works
*and* guards a fact §9.1 fixes:

```swift
import Testing
@testable import StenoKit

@Test("os.Log subsystem matches the identifier fixed by §9.1")
func subsystemIsFixed() {
    #expect(Log.subsystem == "com.lgabrielgr.steno")
}
```

---

## 5. `make test` and the network gate

### 5.1 What the criterion actually demands

Acceptance criterion #2: `make test` must pass with networking disabled, and it must be
confirmed that it *does not merely succeed offline but genuinely makes no network calls*.

Running with Wi-Fi off does not satisfy this. Nothing in the repo makes a network call today,
so any check passes trivially right now — the entire value of the mechanism is catching the
M4 task that quietly adds a live Atlassian call two months from now. That rules out
honor-system approaches: the gate has to survive this PR to be worth building.

### 5.2 Two phases

```make
test: preflight $(PBXPROJ) ## Unit tests, headless, with network denied
	$(XCB) -configuration Debug -destination 'platform=macOS' \
	  build-for-testing | xcbeautify
	sandbox-exec -f Scripts/test-sandbox.sb \
	  $(XCB) -configuration Debug -destination 'platform=macOS' \
	  test-without-building | xcbeautify
```

The build phase runs unsandboxed. It needs no network either — D-007 established that when it
declined `-allowProvisioningUpdates` specifically to avoid Apple ID round-trips during a
build — but confining the build system as well as the tests would produce failures that are
hard to attribute, and the build is not what the criterion is about.

Only the run phase is confined.

### 5.3 The profile

`Scripts/test-sandbox.sb`, committed:

```scheme
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(deny network-inbound)
(deny network-bind)
```

`(allow default)` then selective denial, rather than a deny-by-default profile: `xcodebuild
test-without-building` spawns processes, reads DerivedData, and performs mach lookups, and
enumerating all of that would produce a profile that breaks on the next Xcode update for
reasons unrelated to networking.

The IP filter on `network-outbound` is deliberate. A bare `(deny network*)` would also block
unix-domain sockets, which the test runner's own IPC uses. Filtering on `remote ip` leaves
unix sockets alone while blocking every route off the machine.

### 5.4 Fallback, stated in advance

If the runner turns out to need localhost TCP, an explicit
`(allow network-outbound (remote ip "localhost:*"))` is added and called out in the PR body —
localhost is not external, so the gate still holds.

If `sandbox-exec` cannot be made to work reliably at all, implementation **stops and returns
to the user** rather than silently downgrading to a weaker mechanism. A gate that was quietly
replaced with a lesser one is worse than no gate, because the PR body would still claim the
criterion was met.

### 5.5 `make test` is the sandboxed target

The sandbox is not an opt-in `make test-offline` alongside a plain `make test`. D-008 is the
precedent: a `pipefail` setting that silently did nothing made every gate depending on it
decorative for an entire PR. A gate agents can skip is a gate agents will skip, and §9.5 step
4 says `make test` — not `make test-offline`.

---

## 6. Lint and format

### 6.1 Division of labor

SwiftLint and swift-format both have opinions about layout. If both are authoritative they
disagree, and the failure mode is an agent running `make format`, seeing a clean diff, and
still failing `make lint` — with no indication which tool to believe.

**swift-format owns layout. SwiftLint owns semantics and naming.**

```make
lint: ## SwiftLint, warnings are errors
	swiftlint --strict

format: ## swift-format, in place
	xcrun swift-format --in-place --recursive Steno StenoKit StenoTests
```

`--strict` promotes warnings to errors. Without it, acceptance criterion #3 holds only for
rules configured at error level, and §9.5 step 4's `make lint` gate passes on code with
accumulated warnings. The cost is that a genuine false positive requires an explicit
`// swiftlint:disable:next <rule>` — which appears in the diff, where a reviewer sees it. That
is the intended behavior, not a side effect.

### 6.2 Config files

**`.swiftlint.yml`** — committed, and the lint contract for every later PR:

- `included:` `Steno`, `StenoKit`, `StenoTests`
- `excluded:` `.build`
- `disabled_rules:` `line_length`, `trailing_whitespace`, `vertical_whitespace` — swift-format's
  territory
- `opt_in_rules:` `force_unwrapping`, `empty_count`, `explicit_init`, `first_where`

The opt-in set is deliberately modest. Rules are cheap to add later against real code and
expensive to remove once 34 tasks have been written under them.

**`.swift-format`** — committed JSON config, `lineLength: 100`, matching the prose wrap already
used across the docs.

### 6.3 Tool availability

The `swiftlint` presence check goes in the `lint` target, not in `preflight`. `preflight`
gates `build`, `run`, and `release`, none of which should start requiring a linter to be
installed.

---

## 7. Verification

Each acceptance criterion, and the evidence that closes it. All four outputs go in the PR body.

| # | Criterion | Method |
|---|---|---|
| 1 | Headless | `ssh localhost 'cd <repo> && make test'`. **Requires Remote Login enabled** in System Settings → General → Sharing — a user action, not an agent one |
| 2 | No network calls | Temporarily add a test fetching `https://example.com`. Confirm it **fails under the sandbox and passes without it**, then delete it |
| 3 | Lint fails on violation | Introduce a `force_cast`, show non-zero exit, remove it, show zero |
| 4 | Format idempotent | Run `make format` twice; `git diff --exit-code` after the second |

Criterion 2 is run **both ways** on purpose. A sandbox that blocks the test for an unrelated
reason looks identical, from the outside, to one that works — the passing-without-sandbox half
is what distinguishes them.

---

## 8. Documentation in this PR

| File | Change |
|---|---|
| `DECISIONS.md` | Four new entries: StenoKit + unhosted bundle; Swift Testing (**closes O-1**, which leaves the Open table); the network sandbox; the lint/format split. Plus a "superseded in part by" note on **D-006** |
| `ARCHITECTURE.md` | Target topology added to the layer map, with §3.2's rule |
| `CLAUDE.md` | The "until M0-01 merges, these do not exist yet" caveat updated — `test`, `lint`, `format` now exist |
| `README.md` | Short testing section: what `make test` does and why it is sandboxed |
| `docs/tasks/README.md` | Tick M0-02, and M0-01, still unticked at line 49 |

## 9. Out of scope

Per the task file, and repeated here because each is a plausible thing to drift into:

- **Tests for domain logic** — those ship inside the task that writes the logic (§13).
- **UI tests** — separate scheme, excluded from default `make test` (§9.4).
- **CI** — M1-07.
- **Test doubles for external calls** — §9.4 requires them, but no external calls exist yet.
  The target layout must not make them awkward; building them now would be speculative.
