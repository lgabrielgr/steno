# M1-07 — CI Workflow — Design

**Task:** [`docs/tasks/M1-07-ci-workflow.md`](../../tasks/M1-07-ci-workflow.md)
**Requirements:** [§9.1](../../REQUIREMENTS.md#91-project-generation),
[§9.2](../../REQUIREMENTS.md#92-required-make-targets),
[§9.3](../../REQUIREMENTS.md#93-signing-from-the-command-line),
[§9.4](../../REQUIREMENTS.md#94-test-constraints),
[§9.5](../../REQUIREMENTS.md#95-version-control-workflow),
[§9.6](../../REQUIREMENTS.md#96-enforce-this-mechanically)
**Branch:** `chore/ci-workflow`
**Date:** 2026-09-04

## Goal

`make build && make test && make lint` runs on every pull request to `main`, and a red run
blocks the merge button.

§9.5 step 4 has been a rule agents assent to since M0-02. This task makes it a gate that holds
without an agent's cooperation. M0-02 removed the excuse for not testing; this removes the
excuse for not having run the tests.

---

## 1. Environment as found

Measured on the build machine before designing, not assumed:

| Fact | Value |
|---|---|
| Local Xcode | 26.6 |
| `main` protection today | `enforce_admins: true`, 0 required approvals, force-push and deletion blocked |
| `required_status_checks` today | **`null`** — the field is absent, not empty |
| `.github/` contents | `pull_request_template.md` only; no workflows |
| Source files | 115 `.swift` across `Steno`, `StenoKit`, `StenoTests` |
| `@available` / `#available` in sources | **none** |
| Deployment target | macOS 14.0 |
| Runner label for macOS 26 | `macos-26`, GA, arm64 |

Two of these shape the design more than the rest.

**`required_status_checks` is `null`, not an empty object.** The sub-resource endpoint
`PATCH /branches/main/protection/required_status_checks` returns 404 when the field is absent,
so enabling the check needs a full `PUT /branches/main/protection` that re-states every setting
already in place. A partial `PUT` silently drops whatever it omits — including
`enforce_admins`. §4 lists the payload in full for that reason.

**No `@available` anywhere, floor at macOS 14.0.** Every source file compiles against the macOS
14 SDK, which any Xcode 16+ ships. SDK availability is therefore a non-risk, and the only
remaining toolchain concern is compiler-version divergence in Swift 6 strict-concurrency
diagnostics — addressed in §3.2.

---

## 2. The constraint that shapes everything: the runner cannot sign

§9.3 requires a stable Personal Team identity and forbids ad-hoc signing. A GitHub runner has
no such identity and cannot acquire one without an Apple ID round-trip that D-007 already
declined. The task file anticipated this ("signing will be the friction point") and pre-approved
the escape: build unsigned or ad-hoc in CI, and *do not weaken local signing to make CI
simpler*.

What the task file did not anticipate is how far the problem reaches. Three findings, each
measured:

### 2.1 `xcodegen` refuses to run without `Local.xcconfig`

`Local.xcconfig` is gitignored (§9.3), so a fresh checkout does not have it. With the file
absent:

```
$ xcodegen generate
2 Spec validations errors:
	- Invalid config file "Local.xcconfig" for config "Debug"
	- Invalid config file "Local.xcconfig" for config "Release"
```

and, if a stale project is present anyway:

```
error: Unable to open base configuration reference file '…/Local.xcconfig'.
** TEST BUILD FAILED **
```

So CI cannot simply build without the file. It must **write** one. This is the finding that
rules out the otherwise-obvious "just don't have a config on CI" approach.

### 2.2 An xcconfig cannot override `CODE_SIGN_IDENTITY`

The natural next move is to put the signing overrides *in* that CI-written xcconfig. It does not
work. `project.yml` sets `CODE_SIGN_IDENTITY` and `CODE_SIGN_STYLE` under `settings.base`, which
XcodeGen writes into the project's build configuration in the `.pbxproj` — and a `.pbxproj`
build setting outranks the xcconfig assigned to that same configuration.

Written to `Local.xcconfig`:

```
DEVELOPMENT_TEAM = CI0000000
CODE_SIGN_IDENTITY = -
CODE_SIGN_STYLE = Manual
```

Resolved by `xcodebuild -showBuildSettings`:

```
CODE_SIGN_IDENTITY = Apple Development     <- xcconfig ignored
CODE_SIGN_STYLE    = Automatic             <- xcconfig ignored
DEVELOPMENT_TEAM   = CI0000000             <- honoured
```

`DEVELOPMENT_TEAM` flows through only because `project.yml` does not set it. The command line is
the one level that outranks the `.pbxproj`:

```
$ xcodebuild … CODE_SIGNING_ALLOWED=NO -showBuildSettings
CODE_SIGNING_ALLOWED = NO                  <- honoured
```

**This is why the seam is a Makefile variable and not an xcconfig key.** It is not a style
preference; the xcconfig route does not reach the setting.

### 2.3 Ad-hoc signing works, and embeds entitlements

Both escapes build and test green under the CI stub. The difference is what they exercise:

| Mode | Overrides | Full `make test` path | codesign step |
|---|---|---|---|
| `CODE_SIGNING_ALLOWED=NO` | 1 | `TEST EXECUTE SUCCEEDED` | skipped entirely |
| `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual` | 2 | `TEST EXECUTE SUCCEEDED` | runs |

Both were run through the real two-stage `make test` path — `build-for-testing`, then
`test-without-building` under `Scripts/test-sandbox.sb` — on a clean derived-data path, each
exiting 0. Ad-hoc was verified through the sandboxed stage too, not just the build: an unsigned
or oddly-signed test bundle failing to load under `sandbox-exec` is exactly the failure this
choice could have introduced.

Under ad-hoc, `codesign -dv --entitlements -` on the built app reports:

```
Identifier=com.lgabrielgr.steno
CodeDirectory v=20400 … flags=0x2(adhoc)
Signature=adhoc
TeamIdentifier=not set
	[Key] com.apple.security.app-sandbox
```

The entitlements file is applied. **Ad-hoc is chosen** because the codesign step then actually
runs against the app, the embedded `StenoKit` framework, and the test bundle — so a broken
`Steno.entitlements` or a framework-embedding regression fails CI. Under
`CODE_SIGNING_ALLOWED=NO` those defects reach `main` and surface only on the next local build.

The dummy `DEVELOPMENT_TEAM` in the stub stays inert: `CODE_SIGN_STYLE=Manual` performs no
profile resolution, so no Apple ID round-trip occurs and the fake team is never looked up.
Leaving the team populated (rather than blanking it on the command line) keeps the stub and the
overrides from contradicting each other, and is what `preflight` greps for.

This weakens nothing locally. §9.3's stable identity exists so macOS TCC grants survive
rebuilds; a runner holds no TCC grants and has no stake in it.

---

## 3. The units

### 3.1 The Makefile seam

`XCB` is defined once and consumed by `build`, `release`, and `test`, so one variable threads
the override through every path that compiles:

```make
# Extra build settings for every xcodebuild invocation. Empty locally.
# CI sets it to ad-hoc signing: a runner has no Personal Team identity, and
# §9.3's stable-identity rule exists for local TCC persistence, which a runner
# has no stake in (M1-07, D-053). The command line is the ONLY level that
# outranks project.yml's settings.base — an xcconfig cannot reach
# CODE_SIGN_IDENTITY, so this cannot be a Local.xcconfig key.
XCFLAGS ?=
XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) $(XCFLAGS)
```

`?=` rather than `=` so a caller's `make build XCFLAGS=…` wins while the default stays empty.

**`preflight` is not modified.** The CI stub satisfies both of its `Local.xcconfig` checks as
they are written today. Deliberately so: `preflight` is the gate that makes a misconfigured
local checkout fail loudly, and teaching it to stand down when `CI` is set would mean the gate
is weakest exactly where nobody is watching. The Makefile stays unaware that CI exists — it
gains a general-purpose override seam, not a CI branch.

### 3.2 The workflow

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
    branches: [main]

# Block style, not flow style. `${{ … }}` is built from `{`, `}` and spaces,
# which are indicators inside a YAML flow mapping: the one-line form
# `concurrency: { group: ci-${{ github.ref }} }` is a hard parse error —
# "did not find expected ',' or '}' while parsing a flow mapping".
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  build-test-lint:
    runs-on: macos-26
    env:
      SIGN: CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
    steps:
      - uses: actions/checkout@v7
      - run: xcodebuild -version
      - name: Write CI signing stub
        run: printf '// Generated by CI. Not a real team.\nDEVELOPMENT_TEAM = CI0000000\n' > Local.xcconfig
      - run: make bootstrap
      - run: make build XCFLAGS="$SIGN"
      - run: make test  XCFLAGS="$SIGN"
      - run: make lint
```

Four choices in there are load-bearing:

**No `paths:` filter.** A `paths`-filtered workflow does not run on a PR that touches nothing
matching, and a required check that never reports leaves the PR blocked on "Expected — waiting
for status to be reported" forever. With `enforce_admins: true` the user cannot self-override
that without disabling protection. The filter would save runner minutes on doc-only PRs and cost
the ability to merge them.

**`macos-26`.** Chosen to match the local Xcode 26.6 rather than for novelty. §9.1 declines to
pin a toolchain, and SDK availability is a non-risk (§1), but Swift 6 strict-concurrency
diagnostics do shift between compiler versions — code clean under one can error under another,
in either direction. Matching the local major version keeps CI from failing for a reason the
developer cannot reproduce. `macos-latest` is rejected: it is a moving target under a *required*
check, so an image bump could redden `main` with no commit to blame.

**`xcodebuild -version` as a step.** One line, and it puts the toolchain in every log. When CI
and local disagree, that is the first thing anyone needs and the most annoying thing to obtain
after the fact.

**`concurrency` with `cancel-in-progress`.** A force-push during review otherwise leaves an
orphaned macOS runner finishing a run nobody will read.

`SIGN` is a job-level `env` rather than repeated on two lines, so the two invocations cannot
drift apart.

### 3.3 The check name

The check-run name is the job's `name:` if present, else the job id. The job carries no `name:`,
so the check is **`build-test-lint`** — chosen to be a plain identifier, because it has to be
typed verbatim into branch protection and a decorative name with separators or spaces is a
transcription hazard there.

The name is confirmed by observation before it is used (§5), never assumed.

---

## 4. Branch protection

Applied by full `PUT`, re-stating the current settings verbatim because a `PUT` drops what it
omits:

```jsonc
PUT /repos/lgabrielgr/steno/branches/main/protection
{
  "required_status_checks": { "strict": false, "contexts": ["build-test-lint"] },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
```

`strict: false` — `strict: true` additionally requires a branch be up to date with `main` before
merging, forcing a rebase every time `main` moves. With one developer merging their own PRs
sequentially that is friction bought for nothing; the case it protects against (two PRs that
pass alone and fail together) needs concurrent merges to arise.

The `restrictions: null` and the reviews block are not new policy — they are what the API
already reports, restated so the `PUT` preserves them.

---

## 5. Rollout order

The order matters, because a wrong context string is not self-correcting once
`enforce_admins` is on.

1. Push `chore/ci-workflow`, open the PR. The workflow runs — it is on the branch, and
   `pull_request` evaluates the merge ref.
2. Read the check name off the actual run (`gh api …/check-runs`). Do not type it from memory.
3. `PUT` the protection payload with the observed name.
4. Confirm the PR now shows the check as required, and green.
5. Verify the failure direction on a throwaway branch (§6).
6. Stop. The user reviews and merges.

Applying protection while the PR is open is deliberate: the PR then gates itself, so the
mechanism is proven on a real PR before it governs every future one.

---

## 6. Verification

The acceptance criterion is that the workflow "fails the PR when **any** of the three commands
fails". Breaking only a test would prove one third of it, so each command is broken in turn on a
throwaway branch and its PR observed:

| Push | Breaks | Expected |
|---|---|---|
| invalid Swift syntax | `make build` | red |
| an inverted `#expect` | `make test` | red |
| a `--strict` lint violation | `make lint` | red |
| revert all three | — | green |

Then the branch and its PR are closed and deleted.

Two properties are verified by inspection rather than by run, because there is nothing to
observe:

- **No secrets.** The workflow references no `secrets.*`; `permissions: contents: read` is the
  whole token grant. Nothing in build, test, or lint takes a credential — §9.4 already requires
  the suite to pass with networking denied, and D-012 enforces that with `sandbox-exec`.
- **`sandbox-exec` on the runner.** `make test` shells out to it. It is present on macOS 26.
  Its behaviour under CI is confirmed by the run itself, not asserted here.

**Runtime is unmeasured until the first run and will be reported, not estimated.** `make
bootstrap` shells out to Homebrew; the actual bootstrap log from the green run shows
`xcbeautify` already installed, but both `xcodegen` and `swiftlint` were downloaded and poured
fresh — so `xcbeautify` ships on the runner image while `xcodegen` and `swiftlint` are installed
by Homebrew on every run. `make test` also pays one extra `xcodegen` pass on top
of `make build`'s, by design (D-014), measured locally at ~0.06s. If the total discourages small
PRs — the fourth acceptance criterion — caching is a follow-up task, not a widening of this one.

---

## 7. Deviations from REQUIREMENTS.md

**None that contradict it.** One that reads like one:

§9.3 says "use a stable Personal Team signing identity, not ad-hoc" and this task ships a
workflow that signs ad-hoc. The section's stated rationale is that ad-hoc mints a new identity
per build, which breaks TCC grants and signature-keyed per-app state across rebuilds. A runner
holds no TCC grants and keeps no state between jobs, so the rationale does not reach it. The
task file pre-authorised exactly this ("that is fine *for CI only*"). Local signing is
untouched: `XCFLAGS` defaults to empty, and `project.yml` still pins `Apple Development`.

No spec amendment or version bump is needed.

---

## 8. Out of scope

- **Release automation, notarization, artifact uploads.** Not distributing (§6.1).
- **UI tests.** §9.4 excludes them from default `make test`.
- **Dependency caching.** Not until §6 produces a runtime number that justifies it.
- **Running on `push` to `main`.** The gate is the PR. A post-merge run on a protected branch
  that already passed as a PR only reports failures nobody can act on without another PR.
- **Teaching `preflight` about CI.** §3.1.
