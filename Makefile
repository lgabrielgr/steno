# Steno — the single entry point for building, running, and cleaning.
# REQUIREMENTS.md §9.2. Xcode's GUI is optional, never required.

# pipefail is load-bearing: `xcodebuild | xcbeautify` otherwise reports
# xcbeautify's exit status, so a failed build would exit 0 and every gate
# that depends on it (§9.5 step 4, M1-07's CI) would silently stop working.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

DERIVED  := .build
PROJECT  := Steno.xcodeproj
PBXPROJ  := $(PROJECT)/project.pbxproj
SCHEME   := Steno
XCCONFIG := Local.xcconfig
TOOLS    := xcodegen xcbeautify swiftlint

.DEFAULT_GOAL := help
.PHONY: help bootstrap preflight clean generate

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

# `build` depends on this FILE, which depends on project.yml: edit the manifest
# and the project regenerates; leave it alone and generation is skipped. This is
# what makes building a stale configuration structurally impossible.
# preflight is order-only (|) — a phony prerequisite always counts as newer,
# which would regenerate on every single build and defeat the point.
$(PBXPROJ): project.yml | preflight
	xcodegen generate

generate: preflight ## Regenerate Steno.xcodeproj from project.yml
	xcodegen generate
