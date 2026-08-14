# M0-02 Test & Lint Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make test` and `make lint` exist, are green, run with no GUI session and with outbound
networking denied at the OS level — turning §13's "verify, don't assert" from a rule agents
agree with into a gate that fails them.

**Architecture:** A macOS unit-test bundle that runs headless cannot be *hosted* (a host app
launches `NSApplication`, which needs a window server), and an unhosted bundle cannot link an
application target. So testable code moves into a new `StenoKit` framework that both the app and
the test bundle link. `make test` runs in two phases — an unsandboxed `build-for-testing`, then a
`test-without-building` confined by `sandbox-exec` with IP traffic denied.

**Tech Stack:** XcodeGen 2.46.0 (`project.yml` → generated `.xcodeproj`), `xcodebuild` +
`xcbeautify`, Swift Testing (`@Test`/`#expect`), SwiftLint 0.65.0, `xcrun swift-format`,
`sandbox-exec`, GNU Make 3.81 (Apple's).

**Spec:** [`docs/superpowers/specs/2026-08-14-m0-02-test-lint-harness-design.md`](../specs/2026-08-14-m0-02-test-lint-harness-design.md)

## Global Constraints

Copied verbatim from the spec and REQUIREMENTS.md. Every task below implicitly includes these.

- **Branch:** `chore/test-lint-harness`, already created off current `main`. **Never commit to
  `main`; never merge the PR** (§9.5).
- **Bundle identifiers:** app `com.lgabrielgr.steno`; framework `com.lgabrielgr.steno.kit`; test
  bundle `com.lgabrielgr.steno.tests`. The `os.Log` subsystem is `com.lgabrielgr.steno` and is
  fixed by §9.1 — do not change it.
- **Deployment target:** macOS 14.0. **Swift version:** 6.0. Both already set in `project.yml`;
  do not alter them.
- **Never commit** `Steno.xcodeproj` or `Local.xcconfig`. Both are gitignored. If either shows up
  in `git status`, stop.
- **The layer rule this plan creates:** logic goes in `StenoKit/`; `Steno/` holds only SwiftUI
  views and the `@main` entry point. If it cannot be tested without a window server, it does not
  belong in `Steno/`.
- **Test framework:** Swift Testing, unless the test measures performance (`measure { }` exists
  only in XCTest). An XCTest case must be justified in the PR body.
- **swift-format owns layout; SwiftLint owns semantics and naming.** Never re-enable a SwiftLint
  rule that swift-format already governs.
- **Commit messages:** Conventional Commits prefix (`feat:`/`fix:`/`chore:`/`docs:`/`test:`/
  `refactor:`), explaining *why* not just *what*, and ending with:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- **Verify, don't assert.** Every "run this" step means run it and read the output. A step whose
  expected output does not appear is a stop, not a shrug.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `project.yml` | Adds `StenoKit` and `StenoTests` targets; app depends on and embeds `StenoKit`; scheme gains a test action | 1, 2 |
| `StenoKit/Support/Logging.swift` | Moved from `Steno/App/Logging.swift`, made `public`. The `os.Log` entry point | 1 |
| `Steno/App/StenoApp.swift` | Gains `import StenoKit` | 1 |
| `StenoTests/LoggingTests.swift` | The one proving test; asserts §9.1's fixed subsystem | 2 |
| `Scripts/test-sandbox.sb` | `sandbox-exec` profile denying IP traffic during the test run | 3 |
| `Makefile` | New `test`, `lint`, `format` targets | 2, 3, 5, 6 |
| `.swiftlint.yml` | The lint contract for every later PR | 5 |
| `.swift-format` | Layout config | 6 |
| `docs/DECISIONS.md` | D-010 … D-013; closes O-1; annotates D-006 | 7 |
| `docs/ARCHITECTURE.md` | §5 rewritten for the two-target source layout | 7 |
| `CLAUDE.md`, `README.md`, `docs/tasks/README.md` | Harness docs catch up to reality | 7 |

---

### Task 1: Extract the StenoKit framework

Nothing can be tested headless until testable code lives outside the app target. This task
changes no behavior — `make run` must still print `Steno launched` afterward.

**Files:**
- Modify: `project.yml` (add `StenoKit` target; add dependency to `Steno`)
- Create: `StenoKit/Support/Logging.swift` (moved content, made public)
- Delete: `Steno/App/Logging.swift`
- Modify: `Steno/App/StenoApp.swift` (add `import StenoKit`)

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces: `public enum Log` in module `StenoKit`, with
  `public static let subsystem: String` (value `"com.lgabrielgr.steno"`) and
  `public static let app: Logger`. Task 2's test imports these.

- [ ] **Step 1: Confirm the starting state is green**

```bash
make build
```

Expected: build succeeds. If it does not, stop — this plan assumes a green `main`.

- [ ] **Step 2: Move the logging file**

```bash
mkdir -p StenoKit/Support
git mv Steno/App/Logging.swift StenoKit/Support/Logging.swift
```

- [ ] **Step 3: Make `Log` public**

Replace the whole of `StenoKit/Support/Logging.swift` with this. The doc comment is preserved
from M0-01 — it explains why `make run`'s visible output is a separate `print`, which is still
true and still non-obvious:

```swift
import OSLog

/// Logging entry point.
///
/// The subsystem is fixed by REQUIREMENTS.md §9.1 and lives here so it is
/// written once.
///
/// `Logger` writes to the unified log, never to stdio — so this output does not
/// appear in the terminal even under `make run`, whose visible launch line is a
/// separate `print`. To watch it, in another terminal:
///
///     log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
public enum Log {
    public static let subsystem = "com.lgabrielgr.steno"

    public static let app = Logger(subsystem: subsystem, category: "app")
}
```

- [ ] **Step 4: Add the framework target to `project.yml`**

Insert this block under `targets:`, immediately **above** the existing `Steno:` target:

```yaml
  # Everything testable lives here, not in the app target. A macOS unit-test
  # bundle that runs headless (§9.4) cannot be hosted by an app — the host
  # would launch NSApplication and need a window server — and an unhosted
  # bundle cannot link an application target. A framework is what both the app
  # and the tests can link. See DECISIONS.md D-010.
  StenoKit:
    type: framework
    platform: macOS
    sources:
      - path: StenoKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lgabrielgr.steno.kit
        PRODUCT_NAME: StenoKit
        GENERATE_INFOPLIST_FILE: YES
        SKIP_INSTALL: YES
```

- [ ] **Step 5: Make the app depend on and embed it**

In the existing `Steno:` target, add a `dependencies:` block between `sources:` and `settings:`:

```yaml
    dependencies:
      - target: StenoKit
        embed: true
        codeSign: true
```

- [ ] **Step 6: Import the framework in the app**

In `Steno/App/StenoApp.swift`, add `import StenoKit` to the import block. Final import block:

```swift
import Darwin  // fflush/stdout — explicit rather than transitively via SwiftUI
import StenoKit
import SwiftUI
```

- [ ] **Step 7: Regenerate and build**

```bash
make generate && make build
```

Expected: `xcodegen generate` reports 3 targets is *not* expected yet — only `StenoKit` and
`Steno` exist at this point. Build succeeds. If it fails with `no such module 'StenoKit'`, the
dependency in Step 5 is missing or misindented.

- [ ] **Step 8: Verify behavior is unchanged**

```bash
make run
```

Expected: `Steno launched` prints to the terminal, and a window appears. Quit the app (⌘Q or
Ctrl-C).

- [ ] **Step 9: Commit**

```bash
git add project.yml StenoKit Steno/App
git commit -F - <<'EOF'
refactor: extract StenoKit so tests can run without a window server

§9.4 requires `make test` to pass with the GUI session inactive. A hosted
test bundle launches the app under test, and an NSApplication needs a
window server — so the conventional setup fails exactly the condition the
requirement exists to enforce. An unhosted bundle is the fix, but it
cannot link an application target, so testable code has to live in a
framework both targets link.

Only Logging moves today; the rule it establishes is that Steno/ holds
views and @main, and everything else belongs in StenoKit/.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Unhosted test bundle and the proving test

**Files:**
- Modify: `project.yml` (add `StenoTests` target; add scheme test action)
- Create: `StenoTests/LoggingTests.swift`
- Modify: `Makefile` (add `test` target — plain for now; Task 3 sandboxes it)

**Interfaces:**
- Consumes: `StenoKit.Log.subsystem` from Task 1.
- Produces: a working `make test`; the `StenoTests` target name, which Task 3's sandboxed
  invocation reuses via the same `Steno` scheme.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/LoggingTests.swift`:

```swift
import Testing

@testable import StenoKit

@Test("os.Log subsystem matches the identifier fixed by §9.1")
func subsystemIsFixed() {
    #expect(Log.subsystem == "com.lgabrielgr.steno")
}
```

This is deliberately not `#expect(true)`. The task file asks for a test proving the harness
works; this one proves that *and* guards a value §9.1 fixes, so it keeps earning its place after
today.

- [ ] **Step 2: Run it and watch it fail for the right reason**

```bash
make test
```

Expected: **`make: *** No rule to make target 'test'`**. That is the correct first failure — the
target does not exist yet. If you get anything else, `make test` was defined early.

- [ ] **Step 3: Add the test target to `project.yml`**

Insert under `targets:`, after the existing `Steno:` target:

```yaml
  # No TEST_HOST, deliberately: an unhosted bundle runs under the xctest
  # runner with no NSApplication and no window server, which is what lets
  # `make test` pass over SSH (§9.4). Do not add a host app.
  StenoTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: StenoTests
    dependencies:
      - target: StenoKit
        embed: true
        codeSign: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lgabrielgr.steno.tests
        GENERATE_INFOPLIST_FILE: YES
        LD_RUNPATH_SEARCH_PATHS:
          - $(inherited)
          - "@loader_path/../Frameworks"
```

`embed: true` copies `StenoKit.framework` into `StenoTests.xctest/Contents/Frameworks`, which is
what `@loader_path/../Frameworks` resolves to. Self-contained, rather than depending on the
runner's `DYLD_FRAMEWORK_PATH`.

- [ ] **Step 4: Give the scheme a test action**

Replace the existing `schemes:` block at the bottom of `project.yml` with:

```yaml
# Declared explicitly, not left to Xcode's autocreate: `xcodebuild -scheme`
# needs a *shared* scheme on disk, and an autocreated one lands in xcuserdata/,
# which is gitignored — a clean checkout would fail in exactly the way this
# task exists to prevent.
schemes:
  Steno:
    build:
      targets:
        Steno: all
        StenoTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - StenoTests
```

`StenoKit` is not listed: it is a dependency of both targets and builds implicitly. Adding it
would be redundant, not wrong.

- [ ] **Step 5: Add the `test` target to the `Makefile`**

Add `test` to the `.PHONY` line:

```make
.PHONY: help bootstrap preflight clean generate build run release test
```

Add a destination variable next to the existing `XCB` definition (around line 110):

```make
DEST := -destination 'platform=macOS'
```

And add the target after `run`:

```make
test: preflight $(PBXPROJ) ## Unit tests, headless
	$(XCB) -configuration Debug $(DEST) test | xcbeautify
```

This is the plain form. Task 3 replaces it with the two-phase sandboxed version — it exists now
so the framework wiring can be verified separately from the sandbox, which is the part most
likely to need iteration.

- [ ] **Step 6: Run the test**

```bash
make generate && make test
```

Expected: `xcodegen generate` now reports 3 targets. Test run succeeds, output contains
`subsystemIsFixed` and a passing result.

If it fails with `Library not loaded: @rpath/StenoKit.framework/Versions/A/StenoKit`, the
`LD_RUNPATH_SEARCH_PATHS` or `embed: true` from Step 3 did not take effect — inspect with:

```bash
otool -l .build/Build/Products/Debug/StenoTests.xctest/Contents/MacOS/StenoTests | grep -A2 LC_RPATH
ls .build/Build/Products/Debug/StenoTests.xctest/Contents/Frameworks
```

- [ ] **Step 7: Prove the harness actually fails on a bad assertion**

A green test run proves nothing if the runner silently reports success. Temporarily break the
test — change `"com.lgabrielgr.steno"` to `"wrong"` in `StenoTests/LoggingTests.swift` — then:

```bash
make test; echo "exit status: $?"
```

Expected: the run fails, names `subsystemIsFixed`, and **exit status is non-zero**. A zero exit
status here means the gate is decorative, exactly as D-008 describes — stop and investigate the
`xcbeautify` pipe.

Then restore `"com.lgabrielgr.steno"` and re-run `make test` to confirm green.

- [ ] **Step 8: Commit**

```bash
git add project.yml StenoTests Makefile
git commit -F - <<'EOF'
test: add an unhosted test bundle and `make test`

Swift Testing is the convention from here (closes O-1): it ships with the
Xcode 16 floor §9.1 already requires, and its parameterized cases suit
the table-driven tests coming in M1-01 and M2.5-02. XCTest stays linkable
for `measure { }`, which Swift Testing has no equivalent of and which
§1.1's capture-latency budget will need.

The bundle has no TEST_HOST on purpose — that is what keeps the run free
of a window server. The proving test asserts §9.1's fixed os.Log
subsystem rather than a tautology, so it still earns its place later.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Deny the network at the OS level

The riskiest task; it is third so its risk surfaces early. Acceptance criterion #2 asks for proof
that `make test` *makes no network calls*, not merely that it survives offline. Nothing in the
repo calls the network yet, so the entire value is catching the M4 task that later adds a live
Atlassian call.

**Files:**
- Create: `Scripts/test-sandbox.sb`
- Modify: `Makefile` (replace the `test` recipe from Task 2)
- Temporary, deleted before the commit: `StenoTests/NetworkProbeTests.swift`

**Interfaces:**
- Consumes: the `test` target and `DEST` variable from Task 2.
- Produces: `make test` as the sandboxed gate. Later tasks and CI (M1-07) invoke exactly this.

- [ ] **Step 1: Write the probe that must fail under the sandbox**

Create `StenoTests/NetworkProbeTests.swift`. **This file is deleted in Step 8** — it exists only
to prove the gate works:

```swift
import Foundation
import Testing

// TEMPORARY — deleted before this task is committed. Proves the sandbox in
// Scripts/test-sandbox.sb actually blocks outbound traffic, rather than the
// suite merely happening to make no calls.
@Test("TEMPORARY probe: reaches example.com")
func probeReachesNetwork() async throws {
    let url = try #require(URL(string: "https://example.com"))
    _ = try await URLSession.shared.data(from: url)
}
```

`#require` rather than a force-unwrap: Task 5 turns on SwiftLint's `force_unwrapping` rule, and
this keeps the file lint-clean for as long as it exists.

- [ ] **Step 2: Confirm the probe passes with no sandbox**

This is the half that makes the next step meaningful — a sandbox that blocks the test for an
unrelated reason looks identical, from outside, to one that works.

```bash
make test; echo "exit status: $?"
```

Expected: **passes**, exit status 0, with an active internet connection. If it fails here, fix
that before continuing — a failing probe would make Step 5 prove nothing.

- [ ] **Step 3: Write the sandbox profile**

Create `Scripts/test-sandbox.sb`:

```scheme
;; Confines `xcodebuild test-without-building` so a stray network call fails
;; the run instead of passing quietly (REQUIREMENTS.md §9.4, acceptance
;; criterion #2 of docs/tasks/M0-02-test-lint-harness.md).
;;
;; (allow default) then selective denial, rather than deny-by-default:
;; xcodebuild spawns processes, reads DerivedData, and performs mach lookups,
;; and enumerating all of that would produce a profile that breaks on the next
;; Xcode update for reasons unrelated to networking.
;;
;; The `remote ip` filter is deliberate. A bare (deny network*) would also
;; block unix-domain sockets, which the test runner's own IPC uses — the run
;; would fail for the wrong reason and look like a working gate.
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(deny network-inbound)
(deny network-bind)
```

- [ ] **Step 4: Replace the `test` recipe with the two-phase form**

In the `Makefile`, add next to `DEST`:

```make
SANDBOX := Scripts/test-sandbox.sb
```

Replace the `test` target from Task 2 with:

```make
# Two phases on purpose. The build is not sandboxed: it needs no network
# either — D-007 declined `-allowProvisioningUpdates` precisely to avoid Apple
# ID round-trips — but confining the build system too would produce failures
# that are hard to attribute, and the build is not what §9.4 is about.
#
# This IS `make test`, not an opt-in `make test-offline`. D-008's lesson was
# that a gate agents can skip is a gate agents skip; §9.5 step 4 says
# `make test`.
test: preflight $(PBXPROJ) ## Unit tests — headless, network denied
	$(XCB) -configuration Debug $(DEST) build-for-testing | xcbeautify
	sandbox-exec -f $(SANDBOX) \
	  $(XCB) -configuration Debug $(DEST) test-without-building | xcbeautify
```

- [ ] **Step 5: Confirm the probe now fails**

```bash
make test; echo "exit status: $?"
```

Expected: `probeReachesNetwork` **fails** with a URLError (typically "A server with the specified
hostname could not be found" or "The Internet connection appears to be offline"), and exit status
is non-zero. `subsystemIsFixed` still passes.

**Capture both this output and Step 2's — they go in the PR body together.** Neither is
convincing alone.

- [ ] **Step 6: If the runner itself breaks, not just the probe**

Only if Step 5 fails with the *suite* unable to start (no test results at all, or an
`xctest` launch error) rather than the probe failing cleanly:

Add a localhost exemption below the deny lines in `Scripts/test-sandbox.sb` and re-run Step 5.
Localhost is not external, so the gate still holds — but **say so explicitly in the PR body**:

```scheme
;; The test runner's IPC needed loopback. Localhost is not external, so the
;; gate is unchanged in substance.
(allow network-outbound (remote ip "localhost:*"))
```

If that still does not produce a working suite, **stop and return to the user.** Per spec §5.4,
do not substitute a weaker mechanism — a quietly downgraded gate is worse than none, because the
PR body would still claim the criterion was met.

- [ ] **Step 7: Confirm the suite is green without the probe**

```bash
rm StenoTests/NetworkProbeTests.swift
make test; echo "exit status: $?"
```

Expected: passes, exit status 0.

- [ ] **Step 8: Commit**

```bash
git add Scripts/test-sandbox.sb Makefile
git status --short   # confirm NetworkProbeTests.swift is gone, not staged
git commit -F - <<'EOF'
test: deny outbound network during `make test`

§9.4 asks for proof that the suite makes no network calls, which running
with Wi-Fi off does not provide. Nothing here calls the network yet, so
the mechanism's whole value is catching the M4 connector task that adds a
live Atlassian call later — which means it has to be a gate that outlives
this PR, not an honor-system convention.

Only the run phase is confined; the build needs no network either (D-007)
but sandboxing it would produce failures that are hard to attribute. The
`remote ip` filter leaves unix-domain sockets alone, which the test
runner's IPC needs.

Verified both directions: a probe fetching example.com passes unsandboxed
and fails under the profile. A sandbox broken for unrelated reasons is
indistinguishable from a working one unless you show both.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 4: Prove it runs headless

**This task needs a user action and can block.** Acceptance criterion #1 is not "it worked in my
Terminal" — a logged-in Terminal has a window server connection, so it cannot distinguish a
headless-safe suite from a hosted one.

**Files:** none. This task produces evidence, not code.

- [ ] **Step 1: Ask the user to enable Remote Login**

Post this and wait — do not attempt to enable it yourself:

> Acceptance criterion #1 needs `make test` verified with the GUI session out of the picture.
> Please enable **System Settings → General → Sharing → Remote Login**, and tell me when it's on.
> I'll turn it back off afterward if you'd like.

- [ ] **Step 2: Run the suite over SSH**

```bash
ssh localhost "cd $(pwd) && make test"; echo "exit status: $?"
```

Expected: the suite passes, exit status 0. Save the full output for the PR body.

- [ ] **Step 3: Interpret a failure correctly**

If it fails with a window-server or `NSApplication` error, a `TEST_HOST` has crept into the
`StenoTests` target — re-check Task 2 Step 3. If it fails with `xcodebuild: command not found`,
the non-interactive SSH shell has a different PATH; re-run with an explicit
`/usr/bin/xcrun`-prefixed invocation and note it in the PR rather than changing the `Makefile`,
since the interactive path is the one agents use.

- [ ] **Step 4: Record the result**

No commit — this task's output is the transcript, which goes into the PR body under "how it was
verified" (§9.5). Tell the user they can turn Remote Login back off.

---

### Task 5: SwiftLint as a real gate

**Files:**
- Create: `.swiftlint.yml`
- Modify: `Makefile` (add `lint`)

**Interfaces:**
- Consumes: the three source directories established in Tasks 1–2.
- Produces: `make lint`, which every later PR must pass (§9.5 step 4).

- [ ] **Step 1: Write the config**

Create `.swiftlint.yml`:

```yaml
# The lint contract for every PR after M0-02 (REQUIREMENTS.md §9.5 step 4).
#
# Division of labor: swift-format owns layout, SwiftLint owns semantics and
# naming. Both tools have opinions about whitespace, and if both are
# authoritative the failure mode is an agent running `make format`, seeing a
# clean diff, and still failing `make lint` with no indication which tool to
# believe. See DECISIONS.md D-013.

included:
  - Steno
  - StenoKit
  - StenoTests

excluded:
  - .build

# swift-format's territory — see .swift-format
disabled_rules:
  - line_length
  - trailing_whitespace
  - vertical_whitespace

# Deliberately modest. Rules are cheap to add later against real code and
# expensive to remove once 34 tasks have been written under them.
opt_in_rules:
  - empty_count
  - explicit_init
  - first_where
  - force_unwrapping
```

- [ ] **Step 2: Add the `lint` target**

Add `lint` to `.PHONY`, then add the target after `test`:

```make
# The swiftlint check lives here rather than in `preflight`, which gates
# build/run/release — none of which should start requiring a linter.
#
# --strict promotes warnings to errors. Without it, `make lint` passes on code
# carrying accumulated warnings and §9.5 step 4 stops meaning anything. The
# cost is that a genuine false positive needs an explicit
# `// swiftlint:disable:next <rule>` — which shows up in the diff, where a
# reviewer sees it. That is intended.
lint: ## SwiftLint — warnings are errors
	@command -v swiftlint >/dev/null || { \
	  echo "error: swiftlint not found. Run: make bootstrap"; exit 1; }
	swiftlint --strict
```

- [ ] **Step 3: Run it and fix what it finds**

```bash
make lint; echo "exit status: $?"
```

Expected: either clean (exit 0), or a small number of violations in the ~40 lines of existing
code. Fix any violations in the source — do not silence them by editing `.swiftlint.yml`, which
would make the config describe the code rather than constrain it. Re-run until exit status is 0.

- [ ] **Step 4: Prove it fails on a violation (acceptance criterion #3)**

Temporarily append this to `StenoTests/LoggingTests.swift` — a `force_cast`, which is a default
SwiftLint rule, not one of the opt-ins:

```swift
@Test("TEMPORARY: lint gate proof")
func lintGateProof() {
    let anyValue: Any = "steno"
    _ = anyValue as! String
}
```

Then run:

```bash
make lint; echo "exit status: $?"
```

Expected: fails, names `force_cast`, **non-zero exit status**. Save this output for the PR body.

Then delete the whole `lintGateProof` function and re-run `make lint` — expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add .swiftlint.yml Makefile Steno StenoKit StenoTests
git commit -F - <<'EOF'
chore: add .swiftlint.yml and a strict `make lint`

--strict is the point: without it the gate passes on code carrying
warnings, and §9.5 step 4's `make lint` requirement means nothing. A real
false positive now costs an explicit disable comment, which a reviewer
sees in the diff.

Formatting rules are disabled here because swift-format owns layout. Two
authoritative tools that disagree produce a loop where `make format`
leaves a clean diff that `make lint` still rejects.

The opt-in rule set is deliberately small — rules are cheap to add later
against real code and expensive to remove once 34 tasks have been written
under them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 6: swift-format

**Files:**
- Create: `.swift-format`
- Modify: `Makefile` (add `format`)

**Interfaces:**
- Consumes: `.swiftlint.yml`'s `disabled_rules` from Task 5 — the two configs are complementary
  halves of one contract.
- Produces: `make format`, which must be idempotent (acceptance criterion #4).

- [ ] **Step 1: Write the config**

Create `.swift-format`:

```json
{
  "version": 1,
  "lineLength": 100,
  "indentation": { "spaces": 4 },
  "respectsExistingLineBreaks": true
}
```

`lineLength: 100` matches the prose wrap already used across the repo's Markdown. SwiftLint's
`line_length` is disabled, so there is nothing to disagree with.

- [ ] **Step 2: Add the `format` target**

Add `format` to `.PHONY`, then add after `lint`:

```make
# swift-format ships inside the Xcode toolchain, so this adds no dependency to
# `make bootstrap` and its version tracks the compiler §9.1 already pins.
format: ## swift-format, in place
	@xcrun --find swift-format >/dev/null 2>&1 || { \
	  echo "error: swift-format not found in the Xcode toolchain."; exit 1; }
	xcrun swift-format --in-place --recursive Steno StenoKit StenoTests
```

- [ ] **Step 3: Run it once and review the diff**

```bash
make format
git diff
```

Read the diff. If swift-format reflows the long explanatory comments in `StenoApp.swift` or
`Logging.swift` into something less readable, that is worth knowing now — those comments carry
reasoning M0-01 deliberately wrote down. If it mangles them, set
`"respectsExistingLineBreaks": true` (already set) and report the specific damage rather than
accepting it silently.

- [ ] **Step 4: Prove idempotency (acceptance criterion #4)**

```bash
make format
git diff --exit-code; echo "exit status: $?"
```

Expected: **exit status 0** — the second run produces no diff. Non-zero means swift-format is
oscillating; capture the diff and stop.

- [ ] **Step 5: Confirm the other two gates still pass**

Formatting changed source files, so re-verify rather than assume:

```bash
make build && make test && make lint; echo "exit status: $?"
```

Expected: exit status 0.

- [ ] **Step 6: Commit**

```bash
git add .swift-format Makefile Steno StenoKit StenoTests
git commit -F - <<'EOF'
chore: add .swift-format and `make format`

swift-format comes from the Xcode toolchain via xcrun rather than a
Homebrew formula, so `make bootstrap` gains no dependency and the
formatter version tracks the compiler §9.1 already constrains.

It owns layout; SwiftLint owns semantics. Verified idempotent — a second
run produces no diff, which is what stops an agent and a formatter from
trading edits forever.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 7: Documentation

The harness docs currently describe a repo with one target and no test command. Leaving them
stale is the drift CLAUDE.md's D-005 warns about — a wrong instruction is worse than a missing
one, because an agent follows it confidently.

**Files:**
- Modify: `docs/DECISIONS.md` (add D-010…D-013; annotate D-006; close O-1)
- Modify: `docs/ARCHITECTURE.md` (§5 rewritten)
- Modify: `CLAUDE.md` (the "does not exist yet" caveat)
- Modify: `README.md` (testing section)
- Modify: `docs/tasks/README.md` (tick M0-01 and M0-02)

**Interfaces:**
- Consumes: every decision made in Tasks 1–6.
- Produces: the layout rule M0-03 onward depends on.

- [ ] **Step 1: Annotate D-006 in `docs/DECISIONS.md`**

Change D-006's status line from:

```
**2026-08-13** · M0-01 · **Status:** accepted
```

to:

```
**2026-08-13** · M0-01 · **Status:** accepted — layout amended by D-010
```

D-006's *reasoning* survives intact (one XcodeGen source entry per target, so a new area is a new
folder and needs no manifest change). Only the single-root assumption changes.

- [ ] **Step 2: Append the four new entries to the Accepted section**

Insert after D-009, before the `---` that precedes "## Open":

```markdown
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
`Scripts/test-sandbox.sb`, which denies IP traffic while leaving unix-domain sockets alone.

**Why:** §9.4 asks for proof the suite makes no network calls, which running offline does not
provide. Nothing calls the network yet, so the mechanism's entire value is catching the M4
connector task that adds a live call later — it has to outlive this PR. It is `make test` itself
rather than an opt-in `make test-offline` because D-008 already showed what an unenforced gate is
worth, and §9.5 step 4 says `make test`.
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
```

- [ ] **Step 3: Close O-1 in the Open table**

Delete this row from the "Open — decided by the task that owns them" table:

```
| O-1 | Swift Testing or XCTest? Swift Testing ships with the Xcode 16 floor §9.1 already requires, and suits the table-driven tests in M1-01 and M2.5-02 | `M0-02` |
```

- [ ] **Step 4: Rewrite `docs/ARCHITECTURE.md` §5**

Replace the entire "## 5. Where code lives" section body (from "Landed by M0-01" through the
closing paragraph "…one you can edit reliably.") with:

```markdown
Three targets, and which one a file belongs to is decided by a single test: **if it cannot be
tested without a window server, it does not belong in `Steno/`** (D-010, amending D-006).

```
StenoKit/         framework — everything testable
  Support/        Logging.swift                          (exists, M0-02)
  Models/         SwiftData models, enums                (M0-03)
  Persistence/    container, store config                (M0-04)
  Capture/        capture core, ref extraction           (M1-01, M1-02)
  Report/         window computation, renderers          (M2-01, M2-02)
  Portability/    export, import, merge                  (M2.5)
  AI/             AIProvider, AnthropicProvider          (M3)
  Sources/        SourceConnector, Jira, Confluence, MCP (M4, M5)
  Features/       view models, by feature
Steno/            application — SwiftUI views and @main, nothing else
  App/            StenoApp.swift, ContentView.swift      (exists)
  Features/       views, by feature — paired with StenoKit/Features/
  Steno.entitlements                                     (exists)
StenoTests/       unhosted unit-test bundle; headless, network denied  (exists, M0-02)
Scripts/
  test-sandbox.sb sandbox profile used by `make test` (§9.4)  (exists, M0-02)
project.yml       XcodeGen manifest — the .xcodeproj is generated and gitignored (§9.1)
Makefile          the only entry point you need (§9.2)
```

`Features/` is the one place the split is visible in daily work: a feature's **view models go in
`StenoKit/Features/<Feature>/`** and its **views in `Steno/Features/<Feature>/`**. That is not
tidiness — §2's rule 2 says view models mediate between views and the store *on testability
grounds* (§9.4), and a view model in the app target is a view model no test can reach.

Split by responsibility rather than by technical layer: things that change together live
together. Prefer smaller focused files — a file you can hold in your head at once is one you can
edit reliably.
```

- [ ] **Step 5: Update `CLAUDE.md`**

Replace the block at `CLAUDE.md:80`:

```markdown
> **Until `M0-01` merges, these do not exist yet.** That task creates them, and `M0-02` adds
> `test`, `lint`, and `format`.
```

with:

```markdown
> All of these exist as of `M0-02`. `make test` runs headless with outbound networking denied by
> a `sandbox-exec` profile (§9.4, D-012) — if a change makes it need the network, that is the
> finding, not the obstacle.
```

- [ ] **Step 6: Add a testing section to `README.md`**

Insert after the `make run` code block, before the `log stream` paragraph:

````markdown
## Tests, lint, and formatting

```bash
make test      # headless, with outbound networking denied
make lint      # SwiftLint; warnings are errors
make format    # swift-format, in place
```

`make test` runs in two phases: an ordinary build, then the test run confined by
`Scripts/test-sandbox.sb`, which blocks IP traffic. That is deliberate — §9.4 requires proof the
suite makes no network calls, and running with Wi-Fi off only proves it survives without one. A
test that needs the network is a boundary in the wrong place (D-012).

The suite is unhosted: it never launches the app, so it runs over SSH with no GUI session. Code
that needs a window server belongs in the `Steno` target, which the tests do not link (D-010).
````

- [ ] **Step 7: Tick the task checkboxes**

In `docs/tasks/README.md`, change line 49 from `- [ ]` to `- [x]` (M0-01, merged as PR #5 but
never ticked) and line 50 from `- [ ]` to `- [x]` (M0-02).

Do not add a `— PR #<n>` suffix to line 50. The number does not exist until Task 8 pushes, and
chasing it means either an empty-commit amend or a second commit that says nothing. M0-01's row
already carries its number; the user can add M0-02's when merging.

- [ ] **Step 8: Commit**

```bash
git add docs CLAUDE.md README.md
git commit -F - <<'EOF'
docs: record the M0-02 decisions and the two-target layout

D-010 through D-013 cover the StenoKit extraction, the Swift Testing
choice (closing O-1), the network sandbox, and the lint/format division.
ARCHITECTURE.md §5 is rewritten because the forward-looking tree it
described assumed a single target — leaving it would have sent M0-03's
models to the target no test can reach.

Also ticks M0-01, which merged as PR #5 without its checkbox.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 8: Final gate and pull request

**Files:** none, beyond the PR body.

- [ ] **Step 1: Run all three gates from a clean slate**

A clean build catches anything that only works because of stale DerivedData:

```bash
make clean
make build && make test && make lint; echo "exit status: $?"
```

Expected: exit status 0.

- [ ] **Step 2: Confirm nothing forbidden is staged**

```bash
git status --short
git log --oneline main..HEAD
```

Expected: clean working tree; no `Steno.xcodeproj`, no `Local.xcconfig`, no
`StenoTests/NetworkProbeTests.swift`. Seven commits (the spec plus Tasks 1, 2, 3, 5, 6, 7).

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin chore/test-lint-harness
```

The PR body must cover what §9.5 requires. Include, specifically:

1. **Requirement IDs:** §9.2, §9.4; closes **O-1**; milestone M0.
2. **The framework extraction, stated as a cost.** A reviewer expecting "add a test target" will
   find a new target and a moved file — say why in the first paragraph: headless is
   incompatible with a hosted bundle, and an unhosted bundle cannot link an app target.
3. **Test framework choice** (D-011) — the task file explicitly requires this in the PR body.
4. **Acceptance-criterion evidence, all four**, as literal terminal output:
   - Task 4 Step 2's SSH transcript.
   - Task 3 Steps 2 and 5 — the probe passing unsandboxed *and* failing under the sandbox.
     Both, or neither proves anything.
   - Task 5 Step 4's non-zero lint exit on a `force_cast`.
   - Task 6 Step 4's empty second-run diff.
5. **Any localhost exemption** added in Task 3 Step 6, if one was needed.
6. **Deliberately left out:** domain-logic tests (ship with the logic, §13), UI tests (separate
   scheme, §9.4), CI (M1-07), test doubles for external calls (none exist yet — building them now
   would be speculative).

- [ ] **Step 4: Stop**

Do not merge. Do not squash-merge your own PR. The user reviews and merges (§9.5 step 7).

---

## Deferred to later tasks

Restated from the spec so a reader of this plan alone does not drift into them:

- **Tests for domain logic** — ship inside the task that writes the logic (§13).
- **UI tests** — separate scheme, excluded from default `make test` (§9.4).
- **CI** — M1-07.
- **Test doubles for external calls** — §9.4 requires them, but no external calls exist yet. The
  target layout must not make them awkward; building them now would be speculative.
