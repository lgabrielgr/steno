# M0-01 Build System & Project Generation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftUI macOS app that builds, runs, and cleans entirely from the command line, from an Xcode project generated out of a committed YAML manifest and never itself committed.

**Architecture:** `project.yml` is the source of truth; XcodeGen produces a gitignored `Steno.xcodeproj`. A root `Makefile` is the only entry point — every compiling target passes through a `preflight` gate that refuses to run without the toolchain and a stable Personal Team signing identity. `make build` depends on the `.pbxproj` **file**, which depends on `project.yml`, so a stale project cannot be built.

**Tech Stack:** XcodeGen (YAML manifest), xcodebuild + xcbeautify, GNU make with bash + `pipefail`, SwiftUI, OSLog. Xcode 26.6 on the build machine; macOS 14.0 deployment floor.

**Spec:** [`docs/superpowers/specs/2026-08-13-m0-01-build-system-design.md`](../specs/2026-08-13-m0-01-build-system-design.md)
**Task file:** [`docs/tasks/M0-01-build-system.md`](../../tasks/M0-01-build-system.md)
**Branch:** `chore/build-system` — already created off current `main` (`43c9740`).

## Global Constraints

Copied verbatim from REQUIREMENTS.md §9.1/§9.2/§9.3/§6.1 and the spec. Every task's requirements implicitly include this section.

- Product name and scheme: **`Steno`**
- Bundle identifier: **`com.lgabrielgr.steno`**
- `os.Log` subsystem: **`com.lgabrielgr.steno`**
- Minimum deployment target: **macOS 14.0** (SwiftData floor, D2)
- Signing: **stable Personal Team**, never ad-hoc (`-`). `DEVELOPMENT_TEAM` lives only in a gitignored `Local.xcconfig`
- Sandbox: **off**, explicitly (`com.apple.security.app-sandbox = false`). Hardened runtime: **off**
- **Every make target exits non-zero on failure.** This requires `SHELL := /bin/bash` and `.SHELLFLAGS := -eu -o pipefail -c` — without `pipefail`, `xcodebuild | xcbeautify` reports xcbeautify's status and a failed build exits 0
  - **Superseded during implementation.** `.SHELLFLAGS` is inert on macOS's GNU Make 3.81 — the shipped Makefile sets these flags on `SHELL` itself. See `docs/DECISIONS.md` D-008.
- **Never commit** `Steno.xcodeproj` or `Local.xcconfig`. `git status` must be clean after a full build
- **Never commit to `main`.** This branch gets one PR, which the agent does not merge (§9.5)
- Out of scope, do not add: `make test`, `make lint`, `make format`, test targets (→ M0-02); domain models, persistence (→ M0-03, M0-04); CI (→ M1-07); `LSUIElement` (→ M1-04); notarization or anything needing paid membership (→ never, §6.1)

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Makefile` | The only entry point. Toolchain, preflight gate, generate/build/run/release/clean | 1, 2, 3 |
| `Local.xcconfig.example` | Committed template for the gitignored `Local.xcconfig`; carries the Team ID instructions | 1 |
| `project.yml` | XcodeGen manifest — targets, settings, shared scheme | 2 |
| `Steno/App/StenoApp.swift` | `@main` entry point and window scene | 2 |
| `Steno/App/ContentView.swift` | Placeholder view; M0-05 replaces it wholesale | 2 |
| `Steno/App/Logging.swift` | Single home for the `os.Log` subsystem constant and Logger categories | 2 |
| `Steno/Steno.entitlements` | Explicit sandbox-off declaration with its rationale | 2 |
| `README.md` | First-time setup: bootstrap, Apple ID, Team ID, run | 4 |
| `docs/DECISIONS.md` | D-006 (source layout, closes O-2), D-007 (provisioning escape hatch) | 4 |
| `docs/ARCHITECTURE.md` | §5 stops being a proposal once the layout is real | 4 |

**Task boundaries:** Task 1 is testable with no Xcode project at all (the gate must fail correctly before anything can build). Task 2 makes `make generate` produce a project. Task 3 makes it compile, run, and — critically — fail loudly. Task 4 is documentation plus the full acceptance sweep. A reviewer could reject any one while approving its neighbors.

**No unit tests exist yet** — the test target is M0-02. The verification cycle here is the honest analog: run the command, confirm it fails for the *right reason*, implement, confirm it passes. Do not skip the "confirm it fails" steps; on a build system they are the only thing separating a working gate from a decorative one.

---

### Task 1: Makefile foundation — toolchain and the signing gate

**Files:**
- Create: `Makefile`
- Create: `Local.xcconfig.example`

**Interfaces:**
- Consumes: nothing.
- Produces: make variables `DERIVED := .build`, `PROJECT := Steno.xcodeproj`, `PBXPROJ := $(PROJECT)/project.pbxproj`, `SCHEME := Steno`, `XCCONFIG := Local.xcconfig`, and the phony target `preflight`. Tasks 2 and 3 add targets that depend on `preflight` and use these variables.

- [ ] **Step 1: Write `Local.xcconfig.example`**

```
// Local.xcconfig.example — copy to Local.xcconfig and fill in:
//
//   cp Local.xcconfig.example Local.xcconfig
//
// Local.xcconfig is gitignored (REQUIREMENTS.md §9.3). No team IDs,
// credentials, or tokens are ever committed.
//
// DEVELOPMENT_TEAM is your free Personal Team ID — no paid Apple Developer
// membership is needed or wanted (§6.1). Add your Apple ID in
// Xcode -> Settings -> Accounts first, then read the Team ID out of the
// certificate's OU field:
//
//   security find-certificate -c "Apple Development" -p \
//     | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
//
// A stable identity is what makes the macOS Accessibility grant survive
// rebuilds. Ad-hoc signing mints a new identity per build, so M1-03's global
// hotkey would re-prompt for permission on every launch (§9.3).

DEVELOPMENT_TEAM =
```

- [ ] **Step 2: Write the `Makefile` header and variables**

```make
# Steno — the single entry point for building, running, and cleaning.
# REQUIREMENTS.md §9.2. Xcode's GUI is optional, never required.

# pipefail is load-bearing: `xcodebuild | xcbeautify` otherwise reports
# xcbeautify's exit status, so a failed build would exit 0 and every gate
# that depends on it (§9.5 step 4, M1-07's CI) would silently stop working.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
# Superseded during implementation: .SHELLFLAGS is inert on macOS's GNU Make
# 3.81 — the shipped Makefile sets these flags on SHELL itself instead. See
# docs/DECISIONS.md D-008.

DERIVED  := .build
PROJECT  := Steno.xcodeproj
PBXPROJ  := $(PROJECT)/project.pbxproj
SCHEME   := Steno
XCCONFIG := Local.xcconfig
TOOLS    := xcodegen xcbeautify swiftlint

.DEFAULT_GOAL := help
.PHONY: help bootstrap preflight clean
```

- [ ] **Step 3: Add `help`, `bootstrap`, and `clean`**

`help` is grep-driven so it cannot drift from the real target list. Note `##` is an ordinary make comment, so it is safe after a prerequisite list.

```make
help: ## Show this help
	@echo "Steno — make targets:"
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

bootstrap: ## Install toolchain deps via Homebrew (idempotent)
	@command -v brew >/dev/null || { \
	  echo "error: Homebrew is required — https://brew.sh"; exit 1; }
	@for f in $(TOOLS); do \
	  if brew list --formula $$f >/dev/null 2>&1; then \
	    echo "  $$f already installed"; \
	  else \
	    brew install $$f; \
	  fi; \
	done

clean: ## Remove .build/ and the generated project
	rm -rf $(DERIVED) $(PROJECT)
```

Idempotency comes from the `brew list` guard rather than from trusting `brew install`'s behavior on an already-installed formula: a second run makes no network calls and exits 0.

`swiftlint` is installed here per the task's acceptance criteria even though `make lint` arrives in M0-02. `swift-format` is deliberately absent — it ships inside Xcode 16+ as `xcrun swift-format`, which is M0-02's problem.

- [ ] **Step 4: Add the `preflight` gate**

The two multi-line messages are `define` blocks, `export`ed so the recipe shell can print them. `printf '%s\n' "$$VAR"` does not interpret escapes in the *argument*, so the literal `\n` inside the `tr` command survives intact.

```make
define MSG_NO_XCCONFIG
error: Local.xcconfig not found.

Steno needs a stable Personal Team signing identity (REQUIREMENTS.md §9.3)
so macOS Accessibility grants survive rebuilds.

  1. Xcode -> Settings -> Accounts -> add your Apple ID
  2. cp Local.xcconfig.example Local.xcconfig
  3. Put your Team ID in DEVELOPMENT_TEAM

Find your Team ID:
  security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
endef
export MSG_NO_XCCONFIG

define MSG_NO_TEAM
error: DEVELOPMENT_TEAM is empty in Local.xcconfig.

A stable Personal Team identity is required (REQUIREMENTS.md §9.3); ad-hoc
signing would re-prompt for Accessibility permission on every rebuild.

Find your Team ID:
  security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
endef
export MSG_NO_TEAM

# Gates everything that generates or compiles. Silent on success.
preflight:
	@for t in xcodegen xcbeautify; do \
	  command -v $$t >/dev/null || { \
	    echo "error: $$t not found. Run: make bootstrap"; exit 1; }; \
	done
	@test -f $(XCCONFIG) || { printf '%s\n' "$$MSG_NO_XCCONFIG"; exit 1; }
	@grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[^[:space:]/]' $(XCCONFIG) \
	  || { printf '%s\n' "$$MSG_NO_TEAM"; exit 1; }
```

The `grep` requires a first value character that is neither whitespace nor `/`, so `DEVELOPMENT_TEAM =` and `DEVELOPMENT_TEAM = // TODO` both fail. It checks that the file *names* a team, not that the team exists — validating against installed certificates invites false failures across keychain configurations, and xcodebuild's own error is adequate for a genuinely wrong ID.

- [ ] **Step 5: Verify the gate fails for the right reason**

`Local.xcconfig` does not exist yet on this machine, so this is a real test, not a simulated one.

```bash
make preflight; echo "exit=$?"
```

Expected: the `MSG_NO_XCCONFIG` block, `exit=2` (GNU Make wraps a recipe's `exit 1` in its own recipe-error code). If you get `exit=0`, the gate is decorative — stop and fix it.

- [ ] **Step 6: Verify the empty-team branch**

```bash
cp Local.xcconfig.example Local.xcconfig
make preflight; echo "exit=$?"
```

Expected: the `MSG_NO_TEAM` block, `exit=2` (GNU Make wraps a recipe's `exit 1` in its own recipe-error code) — the example ships with `DEVELOPMENT_TEAM =` empty.

- [ ] **Step 7: Install the toolchain and verify idempotency**

```bash
make bootstrap
make bootstrap
```

Expected: the first run installs `xcodegen`, `xcbeautify`, `swiftlint`; the second prints three "already installed" lines, makes no network calls, and exits 0.

- [ ] **Step 8: Fill in the real Team ID and verify the gate opens**

This needs the Apple ID signed into Xcode (Settings → Accounts). If `security find-identity -v -p codesigning` still reports 0 valid identities, **stop and ask the user** — no code change can substitute for this step.

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
# put the OU value in Local.xcconfig, then:
make preflight; echo "exit=$?"
```

Expected: no output, `exit=0`.

- [ ] **Step 9: Verify `help` and `clean`**

```bash
make
make clean
git status --short
```

Expected: `make` prints the target list (`.DEFAULT_GOAL` protects against a bare `make` running something destructive); `make clean` succeeds with nothing to remove; `git status --short` shows only `Makefile` and `Local.xcconfig.example` as untracked — **not** `Local.xcconfig`. If `Local.xcconfig` appears, `.gitignore` is broken and nothing else should proceed.

- [ ] **Step 10: Commit**

```bash
git add Makefile Local.xcconfig.example
git commit -m "chore: add the make entry point and the signing preflight gate

The gate refuses to build without a Personal Team identity rather than
falling back to ad-hoc signing. An ad-hoc fallback builds fine today and
resurfaces in M1-03 as a hotkey that re-prompts for Accessibility on every
launch, with nothing pointing back here (§9.3).

pipefail is set for the same class of reason: without it a failed build
piped through xcbeautify exits 0, and every gate in §9.5 stops working."
```

---

### Task 2: `project.yml`, app sources, and `make generate`

**Files:**
- Create: `project.yml`
- Create: `Steno/App/StenoApp.swift`
- Create: `Steno/App/ContentView.swift`
- Create: `Steno/App/Logging.swift`
- Create: `Steno/Steno.entitlements`
- Modify: `Makefile` (add `generate` and the `$(PBXPROJ)` file rule)

**Interfaces:**
- Consumes: `preflight`, `$(PBXPROJ)`, `$(PROJECT)` from Task 1.
- Produces: a generated `Steno.xcodeproj` with a **shared** scheme named `Steno`; the type `Log` with `Log.subsystem: String` and `Log.app: Logger`; the view `ContentView`. Task 3 builds this scheme; M0-02 extends the scheme with a test action.

- [ ] **Step 1: Write `project.yml`**

```yaml
# XcodeGen manifest — the source of truth for the Xcode project.
# The .xcodeproj is generated by `make generate` and is gitignored (§9.1).
# Fixed facts below are taken verbatim from REQUIREMENTS.md §9.1.
name: Steno

options:
  bundleIdPrefix: com.lgabrielgr
  deploymentTarget:
    macOS: "14.0"          # SwiftData floor (D2)
  createIntermediateGroups: true

configs:
  Debug: debug
  Release: release

# Project level, not target level: M0-02's test bundle needs signing too and
# inherits from here, and the Xcode GUI picks this up where `xcodebuild
# -xcconfig` would not (§9.3).
configFiles:
  Debug: Local.xcconfig
  Release: Local.xcconfig

settings:
  base:
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: Apple Development   # never ad-hoc "-" (§9.3)
    ENABLE_HARDENED_RUNTIME: NO             # not notarizing (§6.1)
    SWIFT_VERSION: "6.0"

targets:
  Steno:
    type: application
    platform: macOS
    sources:
      - path: Steno
        # Entitlements are referenced by build setting; without this exclude
        # XcodeGen would also copy the file into the bundle as a resource.
        excludes:
          - "**/*.entitlements"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lgabrielgr.steno
        PRODUCT_NAME: Steno
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_NSPrincipalClass: NSApplication
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.productivity
        CODE_SIGN_ENTITLEMENTS: Steno/Steno.entitlements
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"

# Declared explicitly, not left to Xcode's autocreate: `xcodebuild -scheme`
# needs a *shared* scheme on disk, and an autocreated one lands in xcuserdata/,
# which is gitignored — a clean checkout would fail in exactly the way this
# task exists to prevent.
schemes:
  Steno:
    build:
      targets:
        Steno: all
    run:
      config: Debug
```

`SWIFT_VERSION: "6.0"` makes explicit what the spec assumed implicitly (Xcode 26 defaults to strict concurrency). The app is ~40 lines with no concurrency, so it compiles cleanly. If a later task finds Swift 6 language mode obstructive, that is M0-03's call to revisit with real models in hand.

`INFOPLIST_KEY_NSPrincipalClass` is set defensively: without `NSApplication` as the principal class a generated Info.plist can produce an app that launches with no window and no menu bar, which is a confusing failure to debug at this stage.

- [ ] **Step 2: Write `Steno/Steno.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Deliberately unsandboxed, and explicitly so rather than by omission.
	     Steno is never distributed (REQUIREMENTS.md §6.1) — no App Store, no
	     notarization — so the sandbox protects nobody here, and a sandboxed
	     app's claim on Accessibility trust is unreliable, which M1-03's global
	     hotkey depends on (§9.3). Do not flip this to true. -->
	<key>com.apple.security.app-sandbox</key>
	<false/>
</dict>
</plist>
```

- [ ] **Step 3: Write `Steno/App/Logging.swift`**

```swift
import OSLog

/// Logging entry point.
///
/// The subsystem is fixed by REQUIREMENTS.md §9.1 and lives here so it is
/// written once. To watch a detached run (§9.2):
///
///     log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
enum Log {
    static let subsystem = "com.lgabrielgr.steno"

    static let app = Logger(subsystem: subsystem, category: "app")
}
```

- [ ] **Step 4: Write `Steno/App/ContentView.swift`**

```swift
import SwiftUI

/// Placeholder window contents. M0-05 replaces this with the three-column shell.
struct ContentView: View {
    var body: some View {
        Text("Steno")
            .frame(minWidth: 480, minHeight: 320)
    }
}
```

- [ ] **Step 5: Write `Steno/App/StenoApp.swift`**

```swift
import SwiftUI

@main
struct StenoApp: App {
    init() {
        Log.app.info("Steno launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

The launch log line exists so that the `log stream` predicate `make run` advertises actually matches something on day one.

- [ ] **Step 6: Add `generate` and the file rule to the `Makefile`**

Add `generate` to the `.PHONY` list, then:

```make
# `build` depends on this FILE, which depends on project.yml: edit the manifest
# and the project regenerates; leave it alone and generation is skipped. This is
# what makes building a stale configuration structurally impossible.
# preflight is order-only (|) — a phony prerequisite always counts as newer,
# which would regenerate on every single build and defeat the point.
$(PBXPROJ): project.yml | preflight
	xcodegen generate

generate: preflight ## Regenerate Steno.xcodeproj from project.yml
	xcodegen generate
```

- [ ] **Step 7: Verify generation**

```bash
make generate
ls Steno.xcodeproj/xcshareddata/xcschemes/
```

Expected: XcodeGen reports success; `Steno.xcscheme` is listed. **If the scheme is missing or lives under `xcuserdata/` instead, stop** — Task 3 will fail on a clean checkout and the cause will be much harder to see from there.

- [ ] **Step 8: Verify nothing generated is tracked**

```bash
git status --short
```

Expected: only `project.yml`, `Steno/` sources, and the modified `Makefile`. **Neither `Steno.xcodeproj` nor `Local.xcconfig` may appear.**

- [ ] **Step 9: Commit**

```bash
git add project.yml Steno Makefile
git commit -m "chore: generate the Xcode project from a committed YAML manifest

A project.pbxproj is an opaque merge-conflict blob only editable through the
GUI; a YAML manifest is diffable and editable by an agent in a text editor
(§9.1). The scheme is declared rather than autocreated because xcodebuild
needs a shared scheme on disk, and an autocreated one lands in gitignored
xcuserdata — a clean checkout would fail exactly where this task promises
it won't.

The sandbox is disabled explicitly rather than by omission so a later reader
can tell it was chosen (§6.1, §9.3)."
```

---

### Task 3: `build`, `run`, `release` — and proving they fail

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: `preflight`, `$(PBXPROJ)`, `$(DERIVED)`, `$(PROJECT)`, `$(SCHEME)` from Tasks 1–2.
- Produces: `make build`, `make run`, `make release`. M0-02 adds `test`, `lint`, and `format` alongside these using the same `XCB` variable.

- [ ] **Step 1: Add the build variables and targets**

Add `build run release` to `.PHONY`, then:

```make
APP := $(DERIVED)/Build/Products/Debug/Steno.app
BIN := $(APP)/Contents/MacOS/Steno
XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED)

build: preflight $(PBXPROJ) ## Debug build into .build/
	$(XCB) -configuration Debug build | xcbeautify

release: preflight $(PBXPROJ) ## Release build of the .app bundle
	$(XCB) -configuration Release build | xcbeautify

# exec the binary directly rather than via `open`, so stdout/stderr stream to
# this terminal (§9.2).
run: build ## Kill any running instance, build, and launch
	pkill -x Steno || true
	$(BIN)
```

- [ ] **Step 2: Verify a clean build**

```bash
make clean && make build; echo "exit=$?"
```

Expected: xcodegen regenerates (the project was just removed), xcbeautify shows a successful build, `exit=0`.

If xcodebuild demands a provisioning profile, the escape hatch is adding `-allowProvisioningUpdates` to `XCB`. Take it only if needed, and record it in `DECISIONS.md` in Task 4.

- [ ] **Step 3: Prove the failure path — the load-bearing check**

```bash
printf '\nthis is not swift\n' >> Steno/App/ContentView.swift
make build; echo "exit=$?"
git checkout Steno/App/ContentView.swift
```

Expected: a compile error and a **non-zero exit**. GNU Make wraps a recipe's `exit 1` in its own recipe-error code, so the actual value is `exit=2`, not `exit=1`.

**If `exit=0`, `pipefail` is not in effect.** Every gate in this repo depends on this one result: §9.5 step 4, M0-02's `make test`, M1-07's CI. Do not continue until it exits non-zero — `exit=2` is the expected pass, not a discrepancy to chase.

- [ ] **Step 4: Verify the incremental-generation contract**

```bash
make build          # expect: no xcodegen line, project.yml untouched
touch project.yml
make build          # expect: xcodegen runs first
```

- [ ] **Step 5: Verify `make run` streams output**

```bash
make run
```

Expected: the app window appears showing "Steno", and `Steno launched` appears **in this terminal** — not only in Console.app. Quit the app to return the prompt. Run it a second time with the app still open to confirm `pkill` replaces the running instance rather than launching a duplicate.

- [ ] **Step 6: Verify `make release`**

```bash
make release; echo "exit=$?"
ls -d $(pwd)/.build/Build/Products/Release/Steno.app
```

Expected: `exit=0` and the Release bundle exists. No notarization is involved (§6.1).

- [ ] **Step 7: Verify the signature is a real identity, not ad-hoc**

```bash
codesign -dvv .build/Build/Products/Debug/Steno.app 2>&1 | grep -E 'Authority|TeamIdentifier'
```

Expected: `Authority=Apple Development: ...` and a `TeamIdentifier` matching your `Local.xcconfig`. **`Signature=adhoc` means §9.3 is unmet** and M1-03 will re-prompt for Accessibility on every launch — fix it here, not there.

- [ ] **Step 8: Commit**

```bash
git add Makefile
git commit -m "chore: add build, run, and release targets

run execs the binary directly instead of using open, so stdout/stderr stream
to the terminal where an agent can actually read them (§9.2).

Verified the failure path deliberately: a syntax error in ContentView makes
make build exit 1. That is the check that proves pipefail works, and every
gate in §9.5 and M1-07 rests on it."
```

---

### Task 4: Documentation, decisions, and the acceptance sweep

**Files:**
- Modify: `README.md`
- Modify: `docs/DECISIONS.md`
- Modify: `docs/ARCHITECTURE.md:~130-150` (the §5 "Where code lives" block)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: nothing code-level. Closes open question **O-2** (source directory layout), which `DECISIONS.md` assigns to this task.

- [ ] **Step 1: Add the README first-time setup section**

Append to `README.md`, keeping the existing two-line description:

````markdown
## First-time setup

Steno builds entirely from the command line; Xcode's GUI is optional
(REQUIREMENTS.md §9).

```bash
make bootstrap                              # xcodegen, xcbeautify, swiftlint
```

Then, once per machine, give the build a stable signing identity. This is what
makes macOS remember the Accessibility permission the global hotkey needs — no
paid Apple Developer membership is involved (§6.1, §9.3):

1. Xcode → Settings → Accounts → add your Apple ID. This creates a free
   "Personal Team".
2. Read your Team ID out of the certificate:

   ```bash
   security find-certificate -c "Apple Development" -p \
     | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
   ```

3. Copy the template and paste the ID in:

   ```bash
   cp Local.xcconfig.example Local.xcconfig
   ```

`Local.xcconfig` is gitignored and never committed.

```bash
make run                                    # build and launch
make                                        # list every target
```

To watch logs from a detached run:

```bash
log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
```
````

- [ ] **Step 2: Record the decisions**

Add to the `## Accepted` section of `docs/DECISIONS.md`, following the existing `D-NNN` format:

```markdown
### D-006 — Source layout is `Steno/<Area>/`, closing O-2
**2026-08-13** · M0-01 · **Status:** accepted

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
```

If Task 3 Step 2 actually needed `-allowProvisioningUpdates`, invert D-007: record that it *is* passed, and why.

- [ ] **Step 3: Update `ARCHITECTURE.md` §5**

The section opens "Proposed layout, to be confirmed by M0-01 and amended here if it changes". Replace that sentence with a statement that the layout is now real, and correct the tree to what exists (`Steno/App/` holding `StenoApp.swift`, `ContentView.swift`, `Logging.swift`; `Steno/Steno.entitlements`). Leave the unbuilt directories listed as forward-looking, with their task IDs intact. Also drop `Makefile`'s "the only entry point you need" line only if it is now inaccurate — it is not; leave it.

- [ ] **Step 4: Run the full acceptance sweep**

Every criterion in the task file, in one pass, capturing output for the PR body:

```bash
make bootstrap && make bootstrap          # idempotent, second run installs nothing
make clean
make generate && make build; echo "exit=$?"   # clean checkout path
make clean && ls .build Steno.xcodeproj 2>&1  # both gone
git status --short                            # must be empty of generated files
```

Expected: every command exits 0 except the deliberate `ls` of removed paths; `git status --short` shows only the intended source changes — no `Steno.xcodeproj`, no `Local.xcconfig`, no `.build/`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/DECISIONS.md docs/ARCHITECTURE.md
git commit -m "docs: document first-time setup and close O-2

The Apple ID and Team ID steps are a hard human dependency the build cannot
automate, so the README states them in the order they must happen — a reader
who does them out of order gets the preflight error, not a mystery.

D-006 settles the source layout question DECISIONS.md assigned to this task,
which turns ARCHITECTURE.md §5 from a proposal into a description."
```

- [ ] **Step 6: Push and open the PR — then stop**

```bash
git push -u origin chore/build-system
gh pr create --title "Add the XcodeGen project, Makefile, and stable signing" --body "..."
```

The body follows `.github/pull_request_template.md`. It must contain:

- **Requirement IDs:** §9.1, §9.2, §9.3, §6.1 · Task: M0-01 · Milestone: M0 — Skeleton
- **How it was verified:** pasted output from Step 4, plus the Task 3 Step 3 failure result (`exit=2` on a broken source file — GNU Make wraps the recipe's `exit 1`) and the Task 3 Step 7 `codesign` output proving a non-ad-hoc signature. `make test` and `make lint` do not exist yet — say so rather than leaving the template checkboxes ambiguous.
- **Findings:** that `make bootstrap` cannot create the signing identity, so the Apple ID step is a documented manual prerequisite; that O-2 is closed by D-006.
- **Deliberately left out:** the M0-02 targets, models, persistence, CI, `LSUIElement`.

**Do not merge.** The user reviews and merges (§9.5 step 7).

---

## Self-Review

**Spec coverage.** §2 signing → Task 1 (gate, example file) and Task 3 Step 7 (proof). §3 entitlements → Task 2 Step 2. §4 `project.yml` → Task 2 Step 1. §5 Makefile → Tasks 1 and 3. §6 app sources → Task 2 Steps 3–5. §7 README → Task 4 Step 1. §8 verification → distributed across the verify steps and consolidated in Task 4 Step 4. §9 out of scope → Global Constraints. §10 risks → the Apple ID stop-and-ask in Task 1 Step 8, the provisioning escape hatch in Task 3 Step 2 and D-007.

**Two additions beyond the spec,** both flagged where they occur: `SWIFT_VERSION: "6.0"` (the spec asserted Xcode 26 is strict by default but left the setting unstated; leaving it unset risks an xcodebuild error) and `INFOPLIST_KEY_NSPrincipalClass` (defensive against a windowless launch). Neither changes a spec decision.

**One gap the spec missed:** `DECISIONS.md` assigns open question **O-2** — the final source directory layout — to M0-01. The spec did not mention it. Task 4 Step 2 closes it as D-006 and Step 3 updates `ARCHITECTURE.md` accordingly.

**Type consistency.** `Log.subsystem` and `Log.app` are defined in Task 2 Step 3 and used in Step 5 under those exact names. `ContentView` is defined in Step 4 and instantiated in Step 5. Make variables `DERIVED`/`PROJECT`/`PBXPROJ`/`SCHEME`/`XCCONFIG` are defined in Task 1 Step 2 and used unchanged in Tasks 2 and 3; `APP`/`BIN`/`XCB` are introduced in Task 3 Step 1 before first use.