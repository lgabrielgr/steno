# M0-01 — Build System & Project Generation — Design

**Task:** [`docs/tasks/M0-01-build-system.md`](../../tasks/M0-01-build-system.md)
**Requirements:** [§9.1](../../REQUIREMENTS.md#91-project-generation),
[§9.2](../../REQUIREMENTS.md#92-required-make-targets),
[§9.3](../../REQUIREMENTS.md#93-signing-from-the-command-line),
[§6.1](../../REQUIREMENTS.md#61-apple-developer-program-not-required)
**Branch:** `chore/build-system`
**Date:** 2026-08-13

## Goal

A SwiftUI macOS app that builds, runs, and cleans from the command line, from an Xcode project
generated out of a committed YAML manifest and never itself committed.

Everything else in the repo is blocked on this. §9 exists because an agent that cannot compile
what it wrote is guessing; this task is what removes the excuse.

---

## 1. Environment as found

Verified on the build machine before designing:

| Fact | Value |
|---|---|
| Xcode | 26.6 (build 17F113) |
| Homebrew | present at `/opt/homebrew/bin/brew` |
| `xcodegen`, `xcbeautify`, `swiftlint` | none installed |
| `security find-identity -v -p codesigning` | **0 valid identities** |
| Xcode accounts / provisioning profiles | none |

The last two rows are the constraint that shapes this design: the stable Personal Team identity
§9.3 requires does not exist yet, and no `make` target can create it.

---

## 2. Signing

### 2.1 Why this is the subtle part

§9.3's chain: stable certificate → stable code signature → the TCC Accessibility grant survives
rebuilds → M1-03's global hotkey does not re-prompt on every launch. Ad-hoc (`-`) signing mints
a fresh identity per build and breaks the chain. The breakage is not observable until M1, where
it presents as a hotkey bug rather than a build-configuration bug.

### 2.2 One-time manual step

**The user, not an agent:** Xcode → Settings → Accounts → add Apple ID. This mints an
`Apple Development` certificate under a free Personal Team. No paid membership is involved or
wanted (§6.1).

### 2.3 Finding the Team ID

The parenthetical in a certificate's common name is easy to mistake for the Team ID. The
`README` and the preflight error message both use the authoritative form:

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
```

`OU=` is the Team ID.

### 2.4 Where the value lives

`Local.xcconfig.example` is committed and carries the instructions plus an empty
`DEVELOPMENT_TEAM =`. The real `Local.xcconfig` is gitignored (already covered by `.gitignore`)
and holds the Team ID. No team IDs, credentials, or tokens are committed (§9.3).

It attaches at **project level** in `project.yml`, not target level:

- M0-02's test bundle needs signing too and inherits rather than re-declaring.
- The Xcode GUI picks it up, which passing `xcodebuild -xcconfig` would not. §9 makes the GUI
  optional, not forbidden.

### 2.5 Missing-config behavior: hard fail

`make build` refuses to run when `Local.xcconfig` is absent or its `DEVELOPMENT_TEAM` is empty:

```
error: Local.xcconfig not found.

Steno needs a stable Personal Team signing identity (REQUIREMENTS.md §9.3)
so macOS Accessibility grants survive rebuilds.

  1. Xcode -> Settings -> Accounts -> add your Apple ID
  2. cp Local.xcconfig.example Local.xcconfig
  3. Put your Team ID in DEVELOPMENT_TEAM

Find your Team ID:
  security find-certificate -c "Apple Development" -p \
    | openssl x509 -noout -subject | tr ',' '\n' | grep OU=
```

**Rejected: falling back to ad-hoc signing with a warning.** A warning that is ignored produces
exactly the M1-03 failure above, months later, with no trace back to this decision.

### 2.6 Signing style

`CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = Apple Development`. A macOS app whose only
entitlement disables the sandbox needs no provisioning profile, so this should be quiet. If
xcodebuild demands one, the escape hatch is `-allowProvisioningUpdates` on the build line —
recorded in `DECISIONS.md` rather than added speculatively.

---

## 3. Entitlements

`Steno/Steno.entitlements` sets `com.apple.security.app-sandbox` to `false` **explicitly**, with
a comment citing §6.1 and §9.3. `ENABLE_HARDENED_RUNTIME = NO`.

Reasoning, recorded so a later agent does not "helpfully" turn the sandbox on:

- Steno is never distributed (§6.1) — no App Store, no notarization, no TestFlight. The sandbox
  protects users who install software they did not build; there are none.
- A sandboxed app's claim on Accessibility trust is unreliable, which is the M1-03 risk again.
- Network (M4), Keychain (M3), and file export/import (M2.5) all work without entitlement
  plumbing.

An explicit `false` beats omitting the file: absent, a reader cannot tell whether unsandboxed
was chosen or overlooked.

---

## 4. `project.yml`

```yaml
name: Steno
options:
  bundleIdPrefix: com.lgabrielgr
  deploymentTarget: { macOS: "14.0" }      # SwiftData floor (D2)
  createIntermediateGroups: true
configs: { Debug: debug, Release: release }
configFiles:                                # project level — see §2.4
  Debug: Local.xcconfig
  Release: Local.xcconfig
settings:
  base:
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: Apple Development
    ENABLE_HARDENED_RUNTIME: NO             # not notarizing (§6.1)
targets:
  Steno:
    type: application
    platform: macOS
    sources: [Steno]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lgabrielgr.steno
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_ENTITLEMENTS: Steno/Steno.entitlements
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
schemes:
  Steno:
    build: { targets: { Steno: all } }
    run: { config: Debug }
```

Fixed facts are taken verbatim from §9.1: product and scheme `Steno`, bundle ID
`com.lgabrielgr.steno`, deployment target macOS 14.0.

Three non-obvious choices:

- **The scheme is declared, not autocreated.** `xcodebuild -scheme Steno` needs a *shared*
  scheme on disk. An Xcode-autocreated scheme lives under `xcuserdata/`, which is gitignored —
  so a clean checkout would fail in precisely the way this task exists to prevent. M0-02 extends
  this block with a test action.
- **`GENERATE_INFOPLIST_FILE: YES`** — no hand-maintained `Info.plist`. M1-04's `LSUIElement`
  becomes an `INFOPLIST_KEY_*` build setting when that task needs it.
- **No `SWIFT_STRICT_CONCURRENCY` setting.** Xcode 26's Swift 6 default is already strict.
  Pinning it belongs to M0-03, which will have real models to compile against.

---

## 5. `Makefile`

### 5.1 The header is load-bearing

```make
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
```

Without `pipefail`, `xcodebuild ... | xcbeautify` reports **xcbeautify's** exit status: a failed
build exits 0, and the acceptance criterion "every target exits non-zero on failure" is silently
false. Every gate in this repo — §9.5 step 4, M1-07's CI — rests on this line.

### 5.2 Variables and targets

```make
DERIVED := .build
PROJECT := Steno.xcodeproj
PBXPROJ := $(PROJECT)/project.pbxproj
SCHEME  := Steno
APP     := $(DERIVED)/Build/Products/Debug/Steno.app
BIN     := $(APP)/Contents/MacOS/Steno
XCB     := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED)

$(PBXPROJ): project.yml | preflight
	xcodegen generate

generate: preflight ; xcodegen generate
build:   preflight $(PBXPROJ) ; $(XCB) -configuration Debug build | xcbeautify
release: preflight $(PBXPROJ) ; $(XCB) -configuration Release build | xcbeautify

run: build
	pkill -x Steno || true
	$(BIN)

clean: ; rm -rf $(DERIVED) $(PROJECT)

.PHONY: bootstrap preflight generate build run clean release help
```

Everything except `$(PBXPROJ)` is phony — these are commands, not files, and an untracked
directory named `build` would otherwise shadow the target.

`build` depends on the **file** `$(PBXPROJ)`, which depends on `project.yml`. Editing the
manifest regenerates; leaving it alone skips generation. `make generate` stays available as an
explicit phony target. This makes it structurally impossible to build a stale project
configuration after editing `project.yml` — the alternative, independent targets, fails silently
and looks like a mystery.

`run` execs the binary directly rather than using `open`, so `stdout`/`stderr` stream to the
terminal (§9.2). `pkill -x Steno || true` tolerates no running instance.

`release` is a thin Release-configuration variant; products land in
`.build/Build/Products/Release/`. No notarization (§6.1).

### 5.3 `bootstrap`

```make
bootstrap:
	command -v brew >/dev/null || { echo "error: Homebrew required — https://brew.sh"; exit 1; }
	for f in xcodegen xcbeautify swiftlint; do \
	  brew list --formula $$f >/dev/null 2>&1 || brew install $$f; \
	done
```

Idempotent by construction rather than by trusting `brew install`'s behavior on an
already-installed formula: a second run makes no network calls and exits 0.

`swiftlint` is installed here, per the task's acceptance criteria, even though `make lint`
arrives in M0-02. `swift-format` is not installed — it ships inside Xcode 16+ as
`xcrun swift-format`, which is M0-02's concern.

### 5.4 `preflight`

Phony, silent on success, a prerequisite of everything that generates or compiles. It attaches
to the `$(PBXPROJ)` file target as an **order-only** prerequisite (`| preflight`) — a phony
prerequisite always counts as newer than its target, so a normal dependency there would
regenerate the project on every build and defeat §5.2.

Three checks:

1. `xcodegen` and `xcbeautify` are on `PATH` → else "run `make bootstrap`".
2. `Local.xcconfig` exists → else the §2.5 message.
3. `DEVELOPMENT_TEAM` is present and non-empty in it → else the §2.5 message, pointed at step 3.

It gates `generate` as well as `build`: XcodeGen writes a reference to `Local.xcconfig`, so
generating without it yields a project that fails later with a worse error.

It verifies that the file *names* a team, not that the team exists. Validating against installed
certificates invites false failures across keychain configurations, and xcodebuild's own error
is adequate for a genuinely wrong ID.

### 5.5 `help`

`.DEFAULT_GOAL := help`, printing a self-documenting target list, so a bare `make` describes the
repo instead of running whichever target happens to be first.

---

## 6. App sources

```
Steno/App/StenoApp.swift        @main, WindowGroup, one launch log line
Steno/App/ContentView.swift     Text("Steno") — M0-05 replaces this wholesale
Steno/App/Logging.swift         os.Log subsystem constant + Logger categories
Steno/Steno.entitlements        app-sandbox = false (§3)
```

Layout follows [`ARCHITECTURE.md` §5](../../ARCHITECTURE.md); `App/` is the entry point
directory that document already proposes. Roughly 40 lines of Swift.

`Logging.swift` earns its place: §9.1 fixes the `os.Log` subsystem as `com.lgabrielgr.steno`,
and §9.2 advertises `log stream --predicate 'subsystem == "com.lgabrielgr.steno"'` as the way to
watch a detached run. Without a single logging line that predicate matches nothing, and the
subsystem string would otherwise be re-typed by whichever later task first needs it.

---

## 7. README

A "First-time setup" section covering, in order: `make bootstrap`; the Xcode Apple ID sign-in
(§2.2); the Team ID lookup (§2.3); `cp Local.xcconfig.example Local.xcconfig` and fill it in;
`make run`. Plus the `log stream` invocation for detached runs.

---

## 8. Verification

Each acceptance criterion maps to a command. Results are pasted into the PR body per §9.5 step 4
— "this should compile" is not acceptable (§9).

| Criterion | Command / check |
|---|---|
| `bootstrap` idempotent | Run twice; second run installs nothing, exits 0 |
| Clean checkout builds | `make clean && make generate && make build` |
| `make run` streams output | Launch; the log line appears in the terminal, not only Console.app |
| `make clean` | `.build/` and `Steno.xcodeproj` both removed |
| **Non-zero on failure** | Inject a syntax error into `ContentView.swift`; `make build; echo $?` → non-zero; revert. This is what proves `pipefail` works |
| `git status` clean | After a full build — no `.xcodeproj`, no `Local.xcconfig`, no `.build/` |

Beyond the checklist: confirm `make build` skips regeneration when `project.yml` is untouched,
and triggers it after `touch project.yml`.

---

## 9. Out of scope

Per the task file, deferred deliberately:

- `make test`, `make lint`, `make format`, and the test target → M0-02
- Any domain model or persistence → M0-03, M0-04
- CI workflow → M1-07
- `LSUIElement` / menu-bar configuration → M1-04
- Notarization, App Store, paid membership → never (§6.1)

## 10. Risks

- **The Apple ID step is a hard human dependency.** Until it is done, nothing in this repo
  builds. §2.5 makes that failure legible instead of mysterious, but it cannot remove it.
- **Automatic signing may still ask for a provisioning profile.** Mitigation in §2.6.
- **XcodeGen behavior across versions.** `bootstrap` installs the current Homebrew version
  rather than pinning; §9.1 explicitly leaves the toolchain unpinned. If generation breaks on a
  future version, pinning is the fix and belongs in a follow-up.