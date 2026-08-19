# Steno — the single entry point for building, running, and cleaning.
# REQUIREMENTS.md §9.2. Xcode's GUI is optional, never required.

# pipefail is load-bearing: `xcodebuild | xcbeautify` otherwise reports
# xcbeautify's exit status, so a failed build would exit 0 and every gate
# that depends on it (§9.5 step 4, M1-07's CI) would silently stop working.
#
# Apple ships GNU Make 3.81, which predates .SHELLFLAGS (GNU Make 4.0) and
# silently ignores it — so flags set that way never take effect and a failed
# build piped through xcbeautify exits 0. Setting them on SHELL itself is
# honoured by 3.81 and by 4.x. Do not move them back to .SHELLFLAGS.
SHELL := /bin/bash -o pipefail -e -u

DERIVED  := .build
PROJECT  := Steno.xcodeproj
PBXPROJ  := $(PROJECT)/project.pbxproj
SCHEME   := Steno
XCCONFIG := Local.xcconfig
TOOLS    := xcodegen xcbeautify swiftlint

.DEFAULT_GOAL := help
.PHONY: help bootstrap preflight clean generate build run release test lint format

help: ## Show this help
	@echo "Steno — make targets:"
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}' \
	  || true
	@# `|| true` guards against pipefail: if a future edit ever leaves zero
	@# targets carrying a `## ` marker, grep exits 1 and would otherwise take
	@# down `help` — which is .DEFAULT_GOAL, so a bare `make` would break.

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
	@! (false | cat) || { echo "error: pipefail is not in effect — check SHELL in this Makefile"; exit 1; }
	@for t in xcodegen xcbeautify; do \
	  command -v $$t >/dev/null || { \
	    echo "error: $$t not found. Run: make bootstrap"; exit 1; }; \
	done
	@# A file test, not `xcodebuild -version`, so this stays instant on the path
	@# that gates every build. Command Line Tools ship an xcodebuild shim that is
	@# on PATH but cannot build an .app bundle, so `command -v` would pass and the
	@# real failure would surface later as an opaque xcode-select error.
	@test -x "$$(xcode-select -p 2>/dev/null)/usr/bin/xcodebuild" || { \
	  echo "error: no full Xcode toolchain found."; \
	  echo "  xcode-select points at: $$(xcode-select -p 2>/dev/null || echo '(nothing)')"; \
	  echo "  Xcode 16+ is required (REQUIREMENTS.md §9.1); Command Line Tools alone"; \
	  echo "  cannot build an .app bundle, and 'make bootstrap' cannot install Xcode."; \
	  echo "  With Xcode installed, point the tools at it:"; \
	  echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"; \
	  exit 1; }
	@test -f $(XCCONFIG) || { printf '%s\n' "$$MSG_NO_XCCONFIG"; exit 1; }
	@grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[^[:space:]/]' $(XCCONFIG) \
	  || { printf '%s\n' "$$MSG_NO_TEAM"; exit 1; }

# XcodeGen enumerates the source directories at generation time and writes every
# file into the .pbxproj, so a newly added .swift file is invisible to xcodebuild
# until the project is regenerated. Depending only on project.yml meant `make test`
# passed green while never compiling a new test file — the same class of
# decorative-gate failure as D-008, by a different mechanism (see D-014).
#
# This mtime rule serves `build` and `release` only. `test` regenerates
# unconditionally instead (see that target) — Make compares whole seconds, so a
# file created in the same second as the last generation slips through this rule,
# and for the gate a slip is a silent green.
#
# Known limits of this rule, accepted for `build`: a *deleted* source file does
# not trigger regeneration, but the stale .pbxproj reference then fails the build
# loudly, which is the safe direction; a source path containing a space would
# split this prerequisite list; non-Swift sources (resources, asset catalogs) are
# not covered — add them here when the project grows any.
SOURCES := $(shell find Steno StenoKit StenoTests -name '*.swift' 2>/dev/null)

# `build` depends on this FILE, which depends on the manifest and the sources:
# change either and the project regenerates; leave them alone and generation is
# skipped. This is what makes building a stale configuration structurally
# impossible.
# preflight is order-only (|) — a phony prerequisite always counts as newer,
# which would regenerate on every single build and defeat the point.
$(PBXPROJ): project.yml $(SOURCES) | preflight
	xcodegen generate

generate: preflight ## Regenerate Steno.xcodeproj from project.yml
	xcodegen generate

APP := $(DERIVED)/Build/Products/Debug/Steno.app
BIN := $(APP)/Contents/MacOS/Steno
XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED)
DEST := -destination 'platform=macOS'
SANDBOX := Scripts/test-sandbox.sb

build: preflight $(PBXPROJ) ## Debug build into .build/
	$(XCB) -configuration Debug build | xcbeautify

release: preflight $(PBXPROJ) ## Release build of the .app bundle
	$(XCB) -configuration Release build | xcbeautify

# exec the binary directly rather than via `open`, so stdout/stderr stream to
# this terminal (§9.2).
run: build ## Kill any running instance, build, and launch
	pkill -x Steno || true
	$(BIN)

# Two phases on purpose. The build is not sandboxed: it needs no network
# either — D-007 declined `-allowProvisioningUpdates` precisely to avoid Apple
# ID round-trips — but confining the build system too would produce failures
# that are hard to attribute, and the build is not what §9.4 is about.
#
# This IS `make test`, not an opt-in `make test-offline`. D-008's lesson was
# that a gate agents can skip is a gate agents skip; §9.5 step 4 says
# `make test`.
#
# Depends on the phony `generate`, not on $(PBXPROJ), so the gate can never run
# against a stale project: build and test carry asymmetric risk. A source file
# missing from a *build* fails loudly at compile time; a test file missing from a
# *test run* passes green having never run — the failure class this milestone
# exists to eliminate. The price is one xcodegen pass, measured at ~0.06s on a
# ~2.2s `make test`. Rationale and the rejected alternatives: D-014.
test: preflight generate ## Unit tests — headless, network denied
	$(XCB) -configuration Debug $(DEST) build-for-testing | xcbeautify
	sandbox-exec -f $(SANDBOX) \
	  $(XCB) -configuration Debug $(DEST) test-without-building | xcbeautify

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

# swift-format ships inside the Xcode toolchain, so this adds no dependency to
# `make bootstrap` and its version tracks the compiler §9.1 already pins.
format: ## swift-format, in place
	@xcrun --find swift-format >/dev/null 2>&1 || { \
	  echo "error: swift-format not found in the Xcode toolchain."; exit 1; }
	xcrun swift-format --in-place --recursive Steno StenoKit StenoTests
