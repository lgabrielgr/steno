# M4-04 Integrations Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FR-6's Integrations pane — Atlassian credential entry, a per-integration enable toggle
and connection test, §5.2's 14-day expiry warning, §8's read-only statement, and "purge cached
external data" — plus the three source-layer changes its error vocabulary and its toggle require.

**Architecture:** Every rule lives on `IntegrationsSettingsModel` in `StenoKit`, because the
unhosted test bundle cannot reach the app target (D-010) and a rule only a view knows is a rule no
test can hold. The pane arranges controls and owns nothing. Three changes land outside it:
`SourceDispatch` gains a `.disabled` case so a switched-off integration is silent rather than
reported as unconfigured; `SourceError` gains `.siteNotFound` so a wrong site stops reading as a
network failure; `AppSettings` gains one key holding the disabled set. A `SourceCachePurge` clears
two columns on every `SourceRef` and nothing else.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, swift-testing, XcodeGen, SwiftLint, swift-format.

**Spec:** [`docs/superpowers/specs/2026-10-01-m4-04-integrations-settings-ui-design.md`](../specs/2026-10-01-m4-04-integrations-settings-ui-design.md)
— read it alongside this plan; the arguments for each decision are there, and D-217's section
carries a superseding note this plan's Task 3 and Task 9 both depend on.

## Global Constraints

- **Never commit to `main`.** One branch, one PR, which you do not merge (CLAUDE.md, §9.5). Branch
  is `feat/integrations-settings-ui`.
- **`make build && make test && make lint` must all pass before the PR.** Verify, do not assert
  (§9.5 step 4, §13).
- **The event log is append-only** (§3.3). Nothing in this task writes, deletes or mutates an
  `Event`. The purge touches two columns on `SourceRef` and is not a precedent for a second
  deletion path.
- **Tokens and API keys in Keychain only** — never SwiftData, `UserDefaults`, plists or logs (§8).
- **`SourceConnector` and `AIProvider` stay independent** (§5.1, §7.1, §13). Nothing in this task
  may reference the AI layer.
- **Degradation ships with the feature** (§13). The pane must work with no store, and say why the
  purge does not.
- **macOS 14.0 floor**, bundle id `com.lgabrielgr.steno`, `os.Log` subsystem `com.lgabrielgr.steno`
  (§9.1).
- **SwiftLint limits that this task hits repeatedly:** 400 lines per file, 50 lines per function
  body excluding comments, identifiers at least 3 characters. All three were violated during
  implementation; each task below says where.
- **`make test` does not compile the test bundle's new files unless the project is regenerated.**
  `make build` and `make test` both depend on `generate`; a bare `xcodebuild` does not. See
  "Verifying" below — a harness that skipped this reported GREEN having compiled nothing.

## Acceptance criteria, and what covers each

The task file's six, each traced to the task that owns it and the test that holds it. A criterion
with no named test is a criterion nothing is checking.

| | Criterion (task file) | Owned by | Held by |
|---|---|---|---|
| 1 | Credentials reach the connectors and are stored in Keychain only (§8) | Tasks 5, 6 | `§13: with no store the purge is unavailable and the credential half still works` writes through the store; `AISecretsTests` asserts no settings key is credential-shaped; Task 9's live run proves the connectors read what the pane wrote |
| 2 | The token is never displayed in full after entry, and never appears in logs | Tasks 5, 7 | `§8: the stored token reaches no property of the model` (a `Mirror` walk, not an allowlist); `§8: the token never appears in the output, on any path` |
| 3 | "Test connection" distinguishes bad credentials, an expired token, a wrong site URL and a network failure — a single generic message is not acceptable (§5.2) | Tasks 3, 5, 9 | `a connection test reports the connector's own error, not a generic failure`; `D-217: the two site-shaped failures do not collapse into one another`; `D-217 revised: a 404 from the verify endpoint is a wrong site, not a missing reference` |
| 4 | Disabling an integration stops its fetches without deleting its credential | Tasks 2, 5 | `D-216: a disabled connector is skipped even though it has a credential`; `the fourth acceptance criterion: disabling does not delete the credential` |
| 5 | The expiry warning appears at 14 days and does not nag before that | Task 5 | `D-194: the expiry warning appears at 14 days and not at 15` |
| 6 | In-app documentation states that credentials must be read-scoped (§8) | Task 6 | **No test, and it cannot have one** — the sentence lives in the app target, which the test bundle does not link (D-010). Its clauses are verified by reading `ReadOnlyTransport.isAllowed`, both endpoint builders' `method: .get`, and `AtlassianCredential.baseURL`. A reviewer comparing the paragraph to those four is the check |

Criterion 6's gap is the honest one to carry into the PR body: it is the only criterion whose
evidence is a reading rather than a run.

## Review Focus

Five things the spec implies that no task's tests exercised when this list was written. The first
two were fixed; the rest are stated so they are decisions rather than oversights.

1. **A pasted site URL is echoed verbatim.** `cloudHost(in:)` accepts
   `https://acme.atlassian.net/jira/software/projects/PAY/boards/1` on purpose, so a verdict read
   "Reached https://…/boards/1" — PR #44's `ConfluenceSelftest` defect, repeated. **Fixed in Task 5**
   (`siteHost`), with a mutation-verified test.
2. **"Test" verifies the stored credential, not the typed one.** Correcting the site and pressing
   Test without saving reports on the credential being replaced, beside the corrected fields.
   **Fixed in Task 5** (`hasUnsavedChanges`), surfaced by the pane in Task 6.
3. **A purge is not serialized against a refresh pass.** `SourceRefreshGate` (D-183) serializes
   passes against each other; a purge goes around it. Worst case is a ref whose `lastFetchedAt` is
   rewritten by a pass that was already in flight, so the purge looks partial. No event is
   affected and no row corrupts, so this is accepted rather than fixed — gating would make
   `purgeCache()` async for a cosmetic race. **Stated in Task 4's notes; raise it in the PR body.**
4. **The pane's expiry warning still fires when every integration is switched off.** The credential
   is still stored and still expiring, so this is deliberate — but it is the one place where
   "disabled means silent" (D-216) does not apply, because D-216 is about *fetch* reporting.
   **Asserted in Task 5** only to the extent that the warning reads the stored expiry.
5. **A valid Atlassian host that is not the credential's own site** answers 401/403 rather than
   404, so it reports as a rejected credential rather than a wrong site. That is the honest reading
   — the site exists and serves the API, the credential just is not for it — and `AtlassianErrors`
   covers it. **No new test; the existing 401/403 cases own it.**

---

## Verifying (read before Task 1)

Three facts about this repo's toolchain, each of which cost a false result during implementation:

- **`xcbeautify` exits 0 even when tests fail**, and `make test` pipes through it with no
  `pipefail`. `make test`'s exit code is therefore not a red/green signal, and grepping its output
  for `✘` found nothing while a test was failing.
- **A bare `xcodebuild` does not regenerate the project**, so a newly created test file is not in
  the target and is silently not compiled. One run reported GREEN having never seen the file under
  test.
- **`make build` does not compile the test bundle** — only `build-for-testing` does. Four test-only
  compile errors were invisible to `make build`.

Use this harness for every red/green and every mutation. Write it to your scratchpad, not the repo:

```bash
#!/bin/zsh
cd /path/to/steno
make generate > /tmp/mt-gen.log 2>&1 || { echo "VERDICT: GENERATE FAILED"; tail -5 /tmp/mt-gen.log; exit 3; }
xcodebuild -project Steno.xcodeproj -scheme Steno -derivedDataPath .build \
  -configuration Debug -destination 'platform=macOS' build-for-testing > /tmp/mt-build.log 2>&1 \
  || { echo "VERDICT: BUILD FAILED"; grep -E "error:" /tmp/mt-build.log | head -5; exit 2; }
sandbox-exec -f Scripts/test-sandbox.sb \
  xcodebuild -project Steno.xcodeproj -scheme Steno -derivedDataPath .build \
  -configuration Debug -destination 'platform=macOS' test-without-building > /tmp/mt-test.log 2>&1
[[ $? -eq 0 ]] && echo "VERDICT: GREEN" || echo "VERDICT: RED"
grep -E "✘" /tmp/mt-test.log | head -10
```

And when gating on lint, redirect rather than pipe: `make lint > /tmp/lint.log 2>&1; echo $?`.
Piping to `grep`/`tail` returns the filter's status and masks the failure — it let two commits
through with violations during implementation.

---

## Task 1: One settings key for the disabled integrations

**Files:**
- Modify: `StenoKit/Settings/AppSettings.swift`
- Test: `StenoTests/Settings/AppSettingsTests.swift`, `StenoTests/AI/AISecretsTests.swift:47`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings.integrationsDisabledKey: String`,
  `AppSettings.disabledIntegrationIDs: Set<String> { get nonmutating set }`,
  `AppSettings.isIntegrationEnabled(_ id: String) -> Bool`,
  `AppSettings.setIntegration(_ id: String, enabled: Bool)`.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Settings/AppSettingsTests.swift`. The file already has a `scratch()` helper
returning `(AppSettings, UserDefaults)` over a per-test suite; use it.

```swift
@Test("an unset store has every integration enabled")
@MainActor
func anUnsetStoreEnablesEveryIntegration() throws {
    let (settings, _) = try scratch()

    #expect(settings.disabledIntegrationIDs.isEmpty)
    #expect(settings.isIntegrationEnabled("jira"))
    // An id nothing has ever registered is enabled too — M5-02 adds ids this
    // build has never heard of.
    #expect(settings.isIntegrationEnabled("mcp-github"))
}

@Test("re-enabling removes the key rather than storing an empty array")
@MainActor
func reEnablingRemovesTheKey() throws {
    let (settings, defaults) = try scratch()

    settings.setIntegration("jira", enabled: false)
    #expect(defaults.object(forKey: AppSettings.integrationsDisabledKey) != nil)

    settings.setIntegration("jira", enabled: true)

    #expect(defaults.object(forKey: AppSettings.integrationsDisabledKey) == nil)
}

@Test("the stored value is sorted, so a rewrite that changes nothing is stable")
@MainActor
func theStoredValueIsSorted() throws {
    let (settings, defaults) = try scratch()

    settings.disabledIntegrationIDs = ["jira", "confluence", "mcp-github"]

    #expect(
        defaults.stringArray(forKey: AppSettings.integrationsDisabledKey)
            == ["confluence", "jira", "mcp-github"])
}

@Test("a stored value of the wrong type reads as nothing disabled")
@MainActor
func aWrongTypedValueReadsAsEmpty() throws {
    let (settings, defaults) = try scratch()

    defaults.set(42, forKey: AppSettings.integrationsDisabledKey)

    #expect(settings.disabledIntegrationIDs.isEmpty)
    #expect(settings.isIntegrationEnabled("jira"))
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run the harness. Expected: BUILD FAILED, `cannot find 'integrationsDisabledKey' in scope`.

- [ ] **Step 3: Add the key and its accessors**

In `AppSettings.swift`, add `integrationsDisabledKey` to the `allKeys` array, then add this
section immediately before `// MARK: - §10.5, auto-export`:

```swift
    // MARK: - FR-6, per-integration enablement

    /// Which integrations the user has switched off (D-215).
    ///
    /// **One key holding the *disabled* set, not a flag per connector.** The
    /// obvious shape is `integrations.jira.enabled` and
    /// `integrations.confluence.enabled`, and it does not survive M5-02: MCP
    /// servers have ids the user chooses, so there is no static list of keys to
    /// declare — and `allKeys` above is the static list §8's audit reads. A key
    /// that cannot be listed is a key the audit cannot see.
    ///
    /// **Disabled rather than enabled, so absence is the permissive answer.** This
    /// is `flag(_:)`'s posture one section down: `UserDefaults` holds nothing for a
    /// key never written, and the only correct reading of "nothing" here is "the
    /// user has switched nothing off". The inverse spelling would make a fresh
    /// install's integrations inert in the one direction nobody notices, because an
    /// integration that never fetches looks exactly like one with nothing to
    /// report.
    public static let integrationsDisabledKey = "com.lgabrielgr.steno.integrations.disabled"

    /// The ids in `integrationsDisabledKey`, or an empty set.
    ///
    /// Stored as `[String]` because `UserDefaults` has no set; read back through a
    /// `Set` because membership is the only question anyone asks. A stored value of
    /// the wrong type reads as empty rather than trapping — the posture
    /// `hotkeyChord` takes for an undecodable chord, and for the same reason: a
    /// `defaults write` by hand must not be able to break the app.
    public var disabledIntegrationIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.integrationsDisabledKey) ?? []) }
        nonmutating set {
            guard !newValue.isEmpty else {
                // Removed rather than stored as `[]`, so "the user has switched
                // nothing off" has one representation instead of two.
                defaults.removeObject(forKey: Self.integrationsDisabledKey)
                return
            }
            // Sorted, so the stored value is stable across writes that change
            // nothing — a `Set`'s iteration order is its hash order and differs
            // between processes.
            defaults.set(newValue.sorted(), forKey: Self.integrationsDisabledKey)
        }
    }

    /// Whether `id` may fetch (FR-6's per-integration toggle).
    ///
    /// Read per dispatch by `SourceRegistry`, so a toggle takes effect without a
    /// relaunch (D-216).
    public func isIntegrationEnabled(_ id: String) -> Bool {
        !disabledIntegrationIDs.contains(id)
    }

    /// Switch one integration on or off.
    ///
    /// **Writes the whole set, which is what keeps an unknown id harmless.** A
    /// connector that no longer ships stays in the stored set and simply never
    /// matches anything, rather than needing a migration.
    public func setIntegration(_ id: String, enabled: Bool) {
        var ids = disabledIntegrationIDs
        if enabled {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        disabledIntegrationIDs = ids
    }
```

- [ ] **Step 4: Update the §8 audit's count**

`AISecretsTests.swift:47` asserts `AppSettings.allKeys.count == 9`. Change it to `10`. This is the
guard working as designed — a new key that is not listed turns the audit red rather than quietly
shrinking its coverage.

- [ ] **Step 5: Run the harness. Expected: GREEN.**

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Settings/AppSettings.swift StenoTests/Settings/AppSettingsTests.swift StenoTests/AI/AISecretsTests.swift
git commit -m "feat: store which integrations are switched off, in one settings key"
```

---

## Task 2: `SourceDispatch.disabled`, and the silence it keeps

**Files:**
- Modify: `StenoKit/Integrations/SourceRegistry.swift`,
  `StenoKit/Integrations/RefreshOutcome.swift`,
  `StenoKit/Integrations/SourceRefreshService.swift`,
  `StenoKit/Integrations/SourceRefreshService+Reads.swift`,
  `StenoKit/Integrations/SourceRefreshService+Write.swift`
- Test: `StenoTests/Integrations/SourceRegistryTests.swift`

**Interfaces:**
- Consumes: `AppSettings.isIntegrationEnabled(_:)` from Task 1.
- Produces: `SourceDispatch.disabled`,
  `SourceRegistry.init(connectors:isEnabled:)` where
  `isEnabled: @escaping @Sendable (String) -> Bool = { _ in true }`,
  `SourceRegistry.enabled: [any SourceConnector]`, `RefreshOutcome.disabled: Int`,
  `SourceRefreshService.classify(_:) -> DispatchTally`.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Integrations/SourceRegistryTests.swift`. **First** extend the test-only
`Equatable` conformance at the bottom of that file, or `.disabled == .disabled` falls through to
`default: return false` and every assertion below passes for the wrong reason:

```swift
        case (.notConfigured, .notConfigured), (.unhandled, .unhandled), (.disabled, .disabled):
            return true
```

Then:

```swift
@Test("D-216: a switched-off claimant dispatches .disabled, not .notConfigured")
func aDisabledClaimantIsDisabled() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira")], isEnabled: { $0 != "jira" })

    #expect(registry.dispatch(ref()) == .disabled)
}

@Test("D-216: a disabled connector is skipped even though it has a credential")
func aDisabledConnectorWithACredentialStillDoesNotFetch() {
    // The fourth acceptance criterion: disabling stops fetches without deleting
    // the credential, so `isConfigured` is true here and must not matter.
    let configured = StubSourceConnector(id: "jira", isConfigured: true)
    let registry = SourceRegistry(connectors: [configured], isEnabled: { _ in false })

    #expect(registry.dispatch(ref()) == .disabled)
}

@Test("D-216: an enabled-but-unconfigured claimant outranks a disabled one")
func notConfiguredOutranksDisabled() {
    // The disabled connector is listed *first*, so a registry that returned the
    // first claimant's verdict rather than applying precedence fails here.
    let switchedOff = StubSourceConnector(id: "confluence", isConfigured: true, kinds: [.jiraIssue])
    let unconfigured = StubSourceConnector(id: "jira", isConfigured: false, kinds: [.jiraIssue])
    let registry = SourceRegistry(
        connectors: [switchedOff, unconfigured], isEnabled: { $0 != "confluence" })

    #expect(registry.dispatch(ref()) == .notConfigured)
}

@Test("D-216: disabling every claimant does not turn an unhandled ref into .disabled")
func anUnclaimedRefStaysUnhandledWhenEverythingIsOff() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", kinds: [.jiraIssue])],
        isEnabled: { _ in false })

    #expect(registry.dispatch(ref(.url)) == .unhandled)
}

@Test("D-216: `enabled` hides what the user switched off and `all` still lists it")
func enabledAndAllDisagreeDeliberately() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira"), StubSourceConnector(id: "confluence")],
        isEnabled: { $0 != "confluence" })

    #expect(registry.enabled.map(\.id) == ["jira"])
    // The pane reads `all`: an integration that vanished when switched off would
    // offer no way to switch it back on.
    #expect(registry.all.map(\.id) == ["jira", "confluence"])
}

@Test("D-216: the toggle is read per dispatch, so it takes effect without a relaunch")
func theToggleIsReadPerDispatch() {
    // **The guarantee a registry filtered at construction would lose.**
    let box = DisabledIDBox()
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira")],
        isEnabled: { !box.contains($0) })

    #expect(registry.dispatch(ref()) != .disabled)

    box.insert("jira")

    #expect(registry.dispatch(ref()) == .disabled)
}

/// A mutable, `Sendable` box, so the `@Sendable` closure above can observe a
/// change made after the registry was built.
private final class DisabledIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) { lock.withLock { ids.insert(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}
```

**Do not name a local `on` or `off`** — SwiftLint's `identifier_name` requires three characters and
`--strict` makes it a build failure.

- [ ] **Step 2: Run them and confirm they fail**

Expected: BUILD FAILED, `type 'SourceDispatch' has no member 'disabled'`.

- [ ] **Step 3: Add the case, the closure, and `enabled`**

In `SourceRegistry.swift`, add the case to `SourceDispatch` before `.unhandled`:

```swift
    /// A connector claims this ref, and the user has switched it off (D-216).
    ///
    /// **Its own case because the user must not be told to set up something they
    /// deliberately turned off.** Folding this into `.notConfigured` makes the
    /// stand-up sheet say "some references have no integration set up yet" — false,
    /// and an instruction they have already declined. `SourceNotice` says nothing
    /// about this case; `RefreshOutcome` counts it so the log still can.
    case disabled
```

Then the stored closure, the initializer, the new `dispatch`, and `enabled`:

```swift
    /// Whether a connector id may fetch — FR-6's per-integration toggle (D-216).
    private let isEnabled: @Sendable (String) -> Bool

    public init(
        connectors: [any SourceConnector] = [],
        isEnabled: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.connectors = connectors
        self.isEnabled = isEnabled
    }

    /// The first enabled, configured connector that claims `ref`, or why none did.
    ///
    /// **Precedence: `.ready` > `.notConfigured` > `.disabled` > `.unhandled`**
    /// (D-216). A sentence the user can act on outranks silence.
    public func dispatch(_ ref: SourceRefSnapshot) -> SourceDispatch {
        var claimedByEnabled = false
        var claimedByDisabled = false
        for connector in connectors where connector.canHandle(ref) {
            guard isEnabled(connector.id) else {
                claimedByDisabled = true
                continue
            }
            claimedByEnabled = true
            if connector.isConfigured { return .ready(connector) }
        }
        if claimedByEnabled { return .notConfigured }
        return claimedByDisabled ? .disabled : .unhandled
    }

    /// The connectors the user has not switched off (D-216).
    ///
    /// **What `credentialWarnings()` reads.** Both Atlassian connectors share one
    /// credential (§5.3), so a user who switches Confluence off to stop its noise
    /// would otherwise keep being warned about the token it is no longer using.
    public var enabled: [any SourceConnector] { connectors.filter { isEnabled($0.id) } }
```

The default closure is what keeps every existing `SourceRegistry(connectors:)` call site and test
behaving identically. Verify that by mutating it to `{ _ in false }` in Step 6.

- [ ] **Step 4: Make `AppSettings` `@unchecked Sendable`**

The closure is `@Sendable` and must capture `AppSettings`, and `UserDefaults` declares its
`Sendable` conformance **unavailable** — verify with
`xcrun swiftc -swift-version 6 -typecheck` on a two-line file if you doubt it. So:

```swift
public struct AppSettings: @unchecked Sendable {
```

with this on the type, because the assertion has to be stated rather than inferred:

```swift
/// **`@unchecked Sendable`, and the "unchecked" is load-bearing** (D-216).
/// `SourceRegistry` stores FR-6's enablement check as a `@Sendable` closure — it is
/// a `Sendable` struct whose `dispatch` is called from the refresh service's task
/// group — so the closure the composition root passes has to capture this type.
/// `UserDefaults` declares its `Sendable` conformance *unavailable*, so a checked
/// conformance is not reachable however this type is written.
///
/// What makes the assertion sound: this is a stateless facade with exactly one
/// stored property, a `UserDefaults` reference, and `UserDefaults` is documented
/// thread-safe. Nothing here caches, and no property is mutable. A stored property
/// added later that is *not* thread-safe would silently invalidate this, which is
/// why it is stated here rather than left to be inferred.
```

- [ ] **Step 5: Count it, and keep the banner silent**

`RefreshOutcome` gains `public let disabled: Int`, an initializer parameter
`disabled: Int = 0` placed after `notConfigured`, the assignment, and the pass-through inside
`warning(about:)`. Then `SourceRefreshService.run` must count it — and the compiler will tell you
exactly where, because its `switch registry.dispatch(ref)` stops being exhaustive.

**Adding the fourth case pushes `SourceRefreshService.swift` past SwiftLint's 400-line limit.**
Move the whole dispatch loop into `SourceRefreshService+Reads.swift` as:

```swift
    // MARK: - Routing

    /// What `registry.dispatch` said about each ref in a pass.
    struct DispatchTally {
        var claimed: [(snapshot: SourceRefSnapshot, connector: any SourceConnector)] = []
        var notConfigured = 0
        /// Refs claimed only by connectors the user switched off (D-216).
        var disabled = 0
    }

    /// Route every ref, and count the ones that go nowhere.
    func classify(_ refs: [SourceRefSnapshot]) -> DispatchTally {
        var tally = DispatchTally()
        for ref in refs {
            switch registry.dispatch(ref) {
            case .ready(let connector):
                tally.claimed.append((ref, connector))
            case .notConfigured:
                tally.notConfigured += 1
            case .disabled:
                // Counted for the log and said nowhere else (D-216).
                tally.disabled += 1
            case .unhandled:
                // Silent, by D-166.
                break
            }
        }
        return tally
    }
```

and in `run`, replace the inline loop with `let tally = classify(refs)`, threading
`tally.disabled` into all three `RefreshOutcome` constructions and into `PassContext`
(which gains `let disabled: Int`, forwarded in `applyAndSave`).

**`SourceNotice` needs no change at all** — it never reads `disabled`, which is the behaviour.
Pin that with a test in Task 3's file rather than trusting it.

Finally, `SourceRefreshService+Reads.swift`'s `credentialWarnings()` changes one word:

```swift
    func credentialWarnings() -> [SourceCredentialWarning] {
        // **`enabled`, not `all`** (D-216). Both Atlassian connectors read one
        // credential (§5.3), so a user who switches Confluence off to stop its
        // noise would otherwise keep being warned about the token it is no longer
        // using. Jira keeps warning while it is on: the token still matters there.
        registry.enabled.compactMap(\.credentialWarning)
    }
```

- [ ] **Step 6: Mutate, to prove the tests can fail**

Invert the precedence:

```swift
        if claimedByDisabled { return .disabled }
        return claimedByEnabled ? .notConfigured : .unhandled
```

Expected: RED, at `D-216: an enabled-but-unconfigured claimant outranks a disabled one`. Revert,
confirm the revert landed (`grep -n "if claimedByEnabled"`), and re-run for GREEN.

- [ ] **Step 7: `make lint > /tmp/lint.log 2>&1; echo $?` must print 0. Then commit.**

```bash
git add StenoKit/Integrations StenoTests/Integrations/SourceRegistryTests.swift
git commit -m "feat: route a switched-off integration to silence, not to \"not set up yet\""
```

---

## Task 3: `SourceError.siteNotFound`

**Files:**
- Modify: `StenoKit/Integrations/SourceError.swift`,
  `StenoKit/Integrations/Atlassian/AtlassianErrors.swift`,
  `StenoKit/Integrations/SourceNotice.swift`
- Test: `StenoTests/Integrations/SourceErrorTests.swift`,
  `StenoTests/Integrations/Atlassian/AtlassianErrorsTests.swift`,
  `StenoTests/Integrations/SourceNoticeTests.swift`

**Interfaces:**
- Consumes: `RefreshOutcome.disabled` from Task 2 (for the silence test).
- Produces: `SourceError.siteNotFound`.

> **Read this before writing the mapping.** The spec argues for mapping this case from DNS errors,
> and Task 9's live probe disproves that: `*.atlassian.net` has wildcard DNS, so a mistyped site
> resolves and answers **404**. Task 9 corrects it. Implement the DNS mapping here anyway — it is
> correct for a host that genuinely does not resolve, and keeping the two tasks separate is what
> makes the sequence legible — then expect Task 9 to add the 404 half.

- [ ] **Step 1: Write the failing tests**

In `AtlassianErrorsTests.swift`, **first fix the existing parameterized test**, which asserts
`.cannotFindHost == .network` and is the reason the wrong sentence was a documented behaviour:

```swift
@Test(
    "the transport's own failures are network failures",
    arguments: [
        URLError.Code.notConnectedToInternet, .secureConnectionFailed,
        // **`.cannotConnectToHost` belongs here, not with the two below** (D-217).
        // A host that resolves and then refuses the connection is a proxy, a
        // captive portal or a firewall — not a typo.
        .cannotConnectToHost, .timedOut, .networkConnectionLost,
    ])
func transportFailuresAreNetwork(code: URLError.Code) {
    #expect(AtlassianErrors.error(forTransport: URLError(code)) == .network)
}

@Test(
    "D-217: a host that does not resolve is a wrong site address, not a network failure",
    arguments: [URLError.Code.cannotFindHost, .dnsLookupFailed])
func unresolvableHostsAreSiteNotFound(code: URLError.Code) {
    #expect(AtlassianErrors.error(forTransport: URLError(code)) == .siteNotFound)
}

@Test("D-217: the two site-shaped failures do not collapse into one another")
func siteAndNetworkStayDistinct() {
    // Mutation: map `.cannotConnectToHost` to `.siteNotFound` as well. Red —
    // which is the point, because the generous mapping is the tempting one.
    #expect(AtlassianErrors.error(forTransport: URLError(.cannotFindHost)) != .network)
    #expect(AtlassianErrors.error(forTransport: URLError(.cannotConnectToHost)) != .siteNotFound)
}
```

In `SourceErrorTests.swift`:

```swift
@Test("D-217: siteNotFound has its own sentence, and it names a setting rather than the network")
func siteNotFoundPointsAtSettings() {
    let sentence = try? #require(SourceError.siteNotFound.errorDescription)

    #expect(SourceError.siteNotFound.errorDescription != SourceError.network.errorDescription)
    #expect(sentence?.contains("Settings") == true)
    // And it names no host: the type carries none, which is what keeps every
    // `SourceError` safe to log (D-165).
    #expect(sentence?.contains("atlassian.net") == false)
}

@Test("D-217: siteNotFound has its own metrics label")
func siteNotFoundHasItsOwnLabel() {
    #expect(SourceError.siteNotFound.metricsLabel == "siteNotFound")
    #expect(SourceError.siteNotFound.metricsLabel != SourceError.network.metricsLabel)
}
```

In `SourceNoticeTests.swift` — this file has a private `sentence(for:now:)` helper and a
`failure(_:cachedAt:)` builder; use both. The exact strings are Task 9's, so write these
assertions now and expect Task 9 to update two of them:

```swift
@Test("D-216: a pass that only skipped disabled integrations says nothing")
func aDisabledIntegrationIsSilent() {
    // **The whole reason `.disabled` is its own dispatch case.**
    // Mutation: add a `disabled > 0` branch to `SourceNotice.message`. Red.
    #expect(sentence(for: RefreshOutcome(disabled: 3, oldestFetch: nil), now: now) == nil)
}

@Test("D-216: a disabled count does not suppress a real complaint about something else")
func disabledDoesNotMaskAnUnconfiguredIntegration() {
    let outcome = RefreshOutcome(notConfigured: 1, disabled: 2, oldestFetch: nil)

    #expect(
        sentence(for: outcome, now: now) == "Some references have no integration set up yet.")
}

@Test("D-217: a wrong site address does not read as a connection problem")
func aWrongSiteIsNotAConnectionProblem() {
    let site = RefreshOutcome(attempted: 1, failures: [failure(.siteNotFound)])
    let network = RefreshOutcome(attempted: 1, failures: [failure(.network)])

    // Mutation: group `.siteNotFound` with `.network` in `cause`. Red.
    #expect(sentence(for: site, now: now) != sentence(for: network, now: now))
    #expect(sentence(for: network, now: now)?.contains("Couldn't reach Jira") == true)
    #expect(sentence(for: site, now: now)?.contains("Couldn't reach") == false)
}
```

- [ ] **Step 2: Run them and confirm they fail.** Expected: BUILD FAILED on `.siteNotFound`.

- [ ] **Step 3: Add the case**

In `SourceError.swift`, after `.network` — and amend `.network`'s own doc comment, which says "DNS
failure" and is now describing a narrower set:

```swift
    /// Offline, TLS failure — the request never arrived for a reason the user's
    /// settings cannot fix.
    ///
    /// **No longer "DNS failure"**: a name that does not resolve is
    /// `.siteNotFound` below (D-217), because the remedy is a setting rather than
    /// a connection.
    case network

    /// The configured site does not serve this integration's API (D-217).
    ///
    /// **Carries no host**, for this type's reason: the pane interpolates the site
    /// it already holds in view state, and a case with a free-form `String` would
    /// give up the property that makes a `SourceError` always safe to log.
    case siteNotFound
```

Add its `errorDescription` and its `metricsLabel` — both switches are exhaustive, so the compiler
names them. Task 9 revises the sentence; for now:

```swift
        case .siteNotFound:
            return "Couldn't find that site. Check the site address in Settings."
```

- [ ] **Step 4: Map it, narrowly**

In `AtlassianErrors.error(forTransport:)`, replace the single-line `URLError` branch:

```swift
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .timedOut
            case .cannotFindHost, .dnsLookupFailed:
                // D-217: the configured site does not resolve, which is a typo in
                // Settings rather than a connection problem.
                return .siteNotFound
            default:
                // **`.cannotConnectToHost` deliberately stays here.** A host that
                // resolves and then refuses the connection is a proxy, a captive
                // portal or a firewall — not a typo.
                return .network
            }
        }
```

- [ ] **Step 5: Give it its own sentence in the banner**

`SourceNotice.message(for failure:now:)` composes `"\(cause(failure)) — \(fallbackText)."`, which
puts the remedy after the staleness clause and produces two em-dashes. Give the case its own shape
beside `.credentialExpired`'s, and list it in `cause`'s exhaustive switch with a comment saying it
never arrives there — so that adding the *next* error case is still a compile error. Task 9 gives
these their final wording.

- [ ] **Step 6: Run the harness. Expected: GREEN. Confirm the parameterized cases ran:**

```bash
grep -E "D-217" /tmp/mt-test.log | grep -E "passed|failed"
```

`make test` never prints table cases, so absence of output there is not evidence either way.

- [ ] **Step 7: Commit**

```bash
git add StenoKit/Integrations StenoTests/Integrations
git commit -m "feat: tell a mistyped Atlassian site apart from a network failure"
```

---

## Task 4: The purge

**Files:**
- Create: `StenoKit/Integrations/SourceCachePurge.swift`
- Modify: `StenoKit/Models/SourceRef.swift`
- Test: `StenoTests/Integrations/SourceCachePurgeTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SourceRef.clearCache()` (internal),
  `SourceCachePurge(context:save:)` with `func purge() -> SourceCachePurge.Result`, where
  `Result` is `.purged(cleared: Int)` or `.failed(String)`.

**Notes for the implementer.** `RefreshFixture` builds rows directly rather than through the
services, so **it writes no events** — a test asserting "the log survives" over an empty log would
pass against a purge that deleted every event. Write the events the test needs. And see Review
Focus item 3: a purge is not serialized against a refresh pass, deliberately.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Integrations/SourceCachePurgeTests.swift`. The real `ExternalUpdatePayload`
initializer takes `changeIDs:`, `presentIDs:` and `windowCapped:` (not `reportedIDs:` /
`isWindowCapped:`), `Event.payload` is `Data?` so the payload needs `.encoded()`, and a payload is
read back with `ExternalUpdatePayload.decoded(from:)`. All four were got wrong first time.

```swift
/// A second context, because a refetch on the writing context returns the objects
/// already held — so "the cache is gone" would pass even against a rollback.
@MainActor
private func refetch(_ container: ModelContainer) throws -> [SourceRef] {
    try ModelContext(container).fetch(FetchDescriptor<SourceRef>())
}

@Test("a purge clears both cache columns and leaves everything else standing")
@MainActor
func aPurgeClearsTheCacheAndNothingElse() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    let ref = try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")
    let refID = ref.id

    let result = SourceCachePurge(context: fixture.context).purge()

    #expect(result == .purged(cleared: 1))

    let rows = try refetch(fixture.container)
    let purged = try #require(rows.first { $0.id == refID })
    #expect(purged.cachedSummary == nil)
    #expect(purged.lastFetchedAt == nil)
    #expect(rows.count == 1)
    #expect(purged.identifier == "PAY-421")
    #expect(purged.taskID == task.id)
}

@Test("§3.3: a purge writes and removes no event")
@MainActor
func aPurgeLeavesTheEventLogAlone() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    try fixture.ref("PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")

    // **Written here rather than assumed.** `RefreshFixture` writes no events, and
    // the first version of this test asserted over an empty log.
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin, kind: .note,
            body: "spoke to the payments team"))
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin, kind: .externalUpdate,
            body: "PAY-421: In Progress"))
    try fixture.context.save()

    let before = try ModelContext(fixture.container).fetch(FetchDescriptor<Event>())
    #expect(before.count == 2, "the fixture must write events, or this test proves nothing")

    _ = SourceCachePurge(context: fixture.context).purge()

    let after = try ModelContext(fixture.container).fetch(FetchDescriptor<Event>())
    // Mutation: have `purge()` delete the refs it clears. Red here and above.
    #expect(after.count == before.count)
    #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
}

@Test("D-219: a purged ref is not a first observation, so the next pass still reports changes")
@MainActor
func aPurgedRefIsNotAFirstObservation() throws {
    // **The failure mode this decision exists to rule out.** A first observation
    // reports the summary and nothing else (D-169) while recording every id it saw
    // (D-188), so if clearing `lastFetchedAt` made a ref look new, the changes that
    // arrived after the purge would be swallowed and never reported again.
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    let ref = try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")

    let payload = ExternalUpdatePayload(
        refID: ref.id, kind: .jiraIssue, identifier: "PAY-421",
        changes: ["moved to In Progress"], url: nil,
        fetchedAt: RefreshFixture.origin, watermark: RefreshFixture.origin,
        changeIDs: ["change-1"], presentIDs: nil, windowCapped: nil)
    fixture.context.insert(
        Event(
            taskID: task.id, timestamp: RefreshFixture.origin, kind: .externalUpdate,
            body: "PAY-421: In Progress", payload: payload.encoded()))
    try fixture.context.save()

    _ = SourceCachePurge(context: fixture.context).purge()

    let events = try ModelContext(fixture.container)
        .fetch(FetchDescriptor<Event>())
        .filter { $0.kind == .externalUpdate }
    #expect(events.count == 1)
    let survived = try #require(events.first)
    #expect(ExternalUpdatePayload.decoded(from: survived.payload)?.changeIDs == ["change-1"])
}

@Test("the count names refs that held something, not every ref in the store")
@MainActor
func theCountNamesOnlyCachedRefs() throws {
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    try fixture.ref("PAY-1", on: task, fetched: RefreshFixture.origin, summary: "Done")
    try fixture.ref("PAY-2", on: task)
    try fixture.ref("PAY-3", on: task, fetched: RefreshFixture.origin, summary: "In Progress")

    // "Cleared 3" for a store holding two observations is a number the user would
    // reasonably read as three things thrown away.
    #expect(SourceCachePurge(context: fixture.context).purge() == .purged(cleared: 2))
}

@Test("D-172: a refused save rolls back, so the cache is still there")
@MainActor
func aRefusedSaveRollsBack() throws {
    struct Refused: Error {}
    let fixture = try RefreshFixture()
    let task = try fixture.task("Ship payments")
    let ref = try fixture.ref(
        "PAY-421", on: task, fetched: RefreshFixture.origin, summary: "In Progress")
    let refID = ref.id

    let purge = SourceCachePurge(context: fixture.context, save: { _ in throw Refused() })
    guard case .failed = purge.purge() else {
        Issue.record("a refused save must report itself")
        return
    }

    let rows = try refetch(fixture.container)
    #expect(rows.first { $0.id == refID }?.cachedSummary == "In Progress")

    // **A later successful save is what makes the assertion above falsifiable.**
    // Without it, "the cache is still there" also passes when the rollback never
    // happened and nothing was committed either way — and a dirty context is
    // committed by the next unrelated save, which is the bug D-172 exists for.
    try fixture.context.save()
    let afterLaterSave = try refetch(fixture.container)
    #expect(afterLaterSave.first { $0.id == refID }?.cachedSummary == "In Progress")
}
```

- [ ] **Step 2: Run them and confirm they fail.** Expected: BUILD FAILED on `SourceCachePurge`.

- [ ] **Step 3: Add `clearCache()`**

In `SourceRef.swift`, beside `recordFetch`. Both columns are `private(set)`, so this method is how
anything clears them — and the pairing is the point:

```swift
    /// Forget this ref's cached observation — FR-6's "purge cached external data"
    /// (D-219).
    ///
    /// **Both fields together, for `recordFetch`'s reason**: §10.1 resolves them as
    /// a pair, and `ImportReader` rejects a document carrying a `cachedSummary`
    /// with no `lastFetchedAt`. A purge that cleared one would produce exactly the
    /// record that validator exists to refuse.
    ///
    /// **This is not a deletion** (§3.3). No row goes away and no `Event` is
    /// touched.
    func clearCache() {
        cachedSummary = nil
        lastFetchedAt = nil
    }
```

- [ ] **Step 4: Write `SourceCachePurge`**

Create the file as implemented — `@MainActor` because `ModelContext` is not `Sendable`, `save`
injected because a real context cannot be made to fail on demand. Three details are load-bearing:

1. Count over `rows.filter { $0.cachedSummary != nil || $0.lastFetchedAt != nil }`, not
   `rows.count`.
2. With nothing to clear, return `.purged(cleared: 0)` **without saving** — saving a clean context
   posts `.stenoDidWrite` and makes three surfaces refetch for nothing.
3. On a failed save, `context.rollback()` before returning `.failed`, and post `.stenoDidWrite`
   only after a successful save.

- [ ] **Step 5: Mutate twice**

- Replace `row.clearCache()` with `context.delete(row)`. Expected: RED at
  `a purge clears both cache columns and leaves everything else standing`.
- Remove the `context.rollback()` line. Expected: RED at `D-172: a refused save rolls back`, **and
  only on the assertion after the later save** — which is the evidence that line earns its place.

Revert each, confirm with `grep -c "context.rollback()"`, and re-run for GREEN.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Models/SourceRef.swift StenoKit/Integrations/SourceCachePurge.swift StenoTests/Integrations/SourceCachePurgeTests.swift
git commit -m "feat: purge cached external data, two columns and nothing else"
```

---

## Task 5: `IntegrationsSettingsModel`

**Files:**
- Create: `StenoKit/Features/Settings/IntegrationsSettingsModel.swift`,
  `StenoKit/Features/Settings/IntegrationsSettingsModel+Credential.swift`
- Create: `StenoTests/Settings/IntegrationsFixture.swift`,
  `StenoTests/Settings/IntegrationsSettingsModelTests.swift`,
  `StenoTests/Settings/IntegrationsSettingsTogglesTests.swift`
- Modify: `StenoTests/Integrations/StubSourceConnector.swift`,
  `StenoTests/Integrations/Atlassian/AtlassianCredentialTests.swift` (the double lives there)

**Interfaces:**
- Consumes: `AppSettings.isIntegrationEnabled(_:)`/`setIntegration(_:enabled:)` (Task 1),
  `SourceRegistry.all` and `.connector(withID:)` (Task 2), `SourceError.siteNotFound` (Task 3),
  `SourceCachePurge` (Task 4).
- Produces:
  ```swift
  IntegrationsSettingsModel(
      credentials: any AtlassianCredentialStore = AtlassianKeychainStore(),
      registry: SourceRegistry,
      settings: AppSettings = AppSettings(),
      purge: SourceCachePurge? = nil,
      now: @escaping () -> Date = Date.init)
  ```
  with `var site/email/tokenEntry/expiresAt/recordsExpiry`,
  `StoredCredentialState` (`.absent` / `.present(site:email:expiresAt:)` / `.unreadable(String)`),
  `TestState` (`.untested` / `.testing` / `.passed` / `.failed(SourceError)`),
  `Row(id:displayName:isEnabled:isConfigured:test:)`, `rows`, `isBusy`, `hasStoredCredential`,
  `siteHost`, `hasUnsavedChanges`, `expiryWarning`, `storeFailureNote`, `canPurge`, `purgeState`,
  and the actions `saveCredential()`, `removeCredential()`, `forgetEntry()`,
  `setIntegration(_:enabled:)`, `testConnection(id:) async`, `purgeCache()`.

**Four things that will bite, all of which did.**

1. **`private` is file-scoped.** The credential half is a second file, so `credentials`,
   `testStates`, `storedCredential` and `credentialProblem` must be internal —
   `public internal(set)` for the last two. `AISettingsModel` documents the same thing.
2. **Two test doubles need extending.** `StubSourceConnector.testConnection()` can only throw
   `.notConfigured`; add a `connectionFailure: (any Error)? = nil` init parameter typed as
   `any Error` so the broken-contract path is reachable too. And `InMemoryAtlassianStore` needs a
   `writeCount`, because "a refused read does not overwrite the token" cannot be asserted by
   reading a store whose reads fail.
3. **SwiftLint:** the two test files together exceed 400 lines — split them as listed. A helper
   returning `(model, store, settings)` trips `large_tuple` at three members, so use the
   `IntegrationsFixture` struct. And `saveCredential()` exceeds the 50-line body budget, so the
   token decision belongs in a `resolvedToken() -> String?` helper.
4. **A test that sets only `site` on a model whose `load()` was refused** hits the empty-email
   guard first and never reaches the token branch. Set both fields.

- [ ] **Step 1: Write the fixture**

```swift
/// The Integrations pane's model, its credential store and its settings.
///
/// **A type rather than a 3-tuple**, which SwiftLint's `large_tuple` refuses at
/// three members — and which read worse at every call site anyway.
@MainActor
struct IntegrationsFixture {
    let model: IntegrationsSettingsModel
    let store: InMemoryAtlassianStore
    let settings: AppSettings

    nonisolated static let now = Date(timeIntervalSince1970: 1_700_000_000)
    nonisolated static let day: TimeInterval = 24 * 60 * 60

    init(
        credential: AtlassianCredential? = nil,
        readError: (any Error)? = nil,
        writeError: (any Error)? = nil,
        connectors: [any SourceConnector] = [
            StubSourceConnector(id: "jira", displayName: "Jira")
        ],
        purge: SourceCachePurge? = nil,
        clock: Date = IntegrationsFixture.now
    ) throws {
        store = InMemoryAtlassianStore(credential, readError: readError, writeError: writeError)
        let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        self.settings = settings
        model = IntegrationsSettingsModel(
            credentials: store,
            registry: SourceRegistry(
                connectors: connectors, isEnabled: { settings.isIntegrationEnabled($0) }),
            settings: settings,
            purge: purge,
            now: { clock })
    }
}
```

- [ ] **Step 2: Write the failing tests**

`IntegrationsSettingsModelTests.swift` — §8 and the credential. The `Mirror` test is the one that
matters most:

```swift
@Test("§8: the stored token reaches no property of the model")
@MainActor
func theStoredTokenReachesNoProperty() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    #expect(fixture.model.site == JiraFixture.site)
    #expect(fixture.model.email == "leo@example.com")
    #expect(fixture.model.tokenEntry.isEmpty)

    // **A `Mirror`, not a list of properties I remembered to check.** `encodeIfPresent`
    // taught this codebase that an allowlist written by hand misses the field added
    // next; this walks every stored property the type actually has.
    let holders = Mirror(reflecting: fixture.model).children.compactMap { child -> String? in
        guard let value = child.value as? String else { return nil }
        return value.contains("token-value") ? (child.label ?? "<unlabelled>") : nil
    }
    #expect(holders.isEmpty, "these properties hold the token: \(holders)")
}

@Test("D-218: saving with an empty token field keeps the stored token")
@MainActor
func savingWithoutATokenKeepsTheStoredOne() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    fixture.model.site = "newsite.atlassian.net"
    fixture.model.saveCredential()

    let stored = try #require(try fixture.store.credential())
    #expect(stored.site == "newsite.atlassian.net")
    // Mutation: store `tokenEntry` unconditionally. Red — the token becomes "".
    #expect(stored.apiToken == "token-value")
}

@Test("D-218: a refused Keychain read does not overwrite the credential with an empty token")
@MainActor
func aRefusedReadDoesNotOverwriteTheToken() throws {
    struct Refused: Error {}
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), readError: Refused())

    // Both fields by hand: the read that would have prefilled them is the one being
    // refused, so the earlier guards would otherwise reject on an empty email and
    // never reach the token branch under test.
    fixture.model.site = "newsite.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.tokenEntry = ""
    fixture.model.saveCredential()

    // The evidence is the *absence of a write*, because the store this needs is one
    // whose reads fail — so reading it back to check is not available.
    #expect(fixture.model.credentialProblem?.contains("didn't change it") == true)
    #expect(fixture.store.writeCount == 0)
}

@Test("D-190: a site that is not an Atlassian Cloud host is refused before anything is stored")
@MainActor
func aNonCloudSiteIsRefusedLocally() throws {
    let fixture = try IntegrationsFixture()

    fixture.model.site = "evil.com/acme.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.tokenEntry = "token-value"
    fixture.model.saveCredential()

    #expect(try fixture.store.credential() == nil)
    #expect(fixture.model.credentialProblem?.contains("*.atlassian.net") == true)
}

@Test("a Keychain read that is refused is not reported as no credential")
@MainActor
func aRefusedReadIsItsOwnState() throws {
    struct Refused: Error {}
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(), readError: Refused())

    guard case .unreadable = fixture.model.storedCredential else {
        Issue.record("a refused read must be its own state, not .absent")
        return
    }
    #expect(fixture.model.hasStoredCredential == false)
}

@Test("removing the credential clears the fields and leaves the toggles alone")
@MainActor
func removingTheCredentialKeepsTheToggles() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())
    fixture.settings.setIntegration("jira", enabled: false)

    fixture.model.removeCredential()

    #expect(try fixture.store.credential() == nil)
    #expect(fixture.model.storedCredential == .absent)
    // A toggle is not a secret, and a user who rotates a token should not find
    // their integrations silently rearranged.
    #expect(fixture.settings.isIntegrationEnabled("jira") == false)
}
```

`IntegrationsSettingsTogglesTests.swift` — the toggle, the test, the expiry, the purge, and Review
Focus items 1 and 2:

```swift
@Test("D-216: the toggle writes settings and changes routing in the same process")
@MainActor
func theToggleChangesRoutingWithoutARelaunch() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", displayName: "Jira")],
        isEnabled: { fixture.settings.isIntegrationEnabled($0) })
    let ref = SourceRefSnapshot(refID: UUID(), kind: .jiraIssue, identifier: "PAY-421")

    #expect(registry.dispatch(ref) != .disabled)

    fixture.model.setIntegration("jira", enabled: false)

    #expect(registry.dispatch(ref) == .disabled)
}

@Test("the fourth acceptance criterion: disabling does not delete the credential")
@MainActor
func disablingKeepsTheCredential() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    fixture.model.setIntegration("jira", enabled: false)

    #expect(try fixture.store.credential()?.apiToken == "token-value")
}

@Test("toggling an integration drops its stale verdict")
@MainActor
func togglingDropsTheVerdict() async throws {
    let fixture = try IntegrationsFixture()

    await fixture.model.testConnection(id: "jira")
    #expect(fixture.model.rows.first?.test == .passed)

    fixture.model.setIntegration("jira", enabled: false)

    #expect(fixture.model.rows.first?.test == .untested)
}

@Test("a connection test reports the connector's own error, not a generic failure")
@MainActor
func aTestReportsTheConnectorsError() async throws {
    let connector = StubSourceConnector(
        id: "jira", displayName: "Jira", connectionFailure: SourceError.credentialExpired)
    let fixture = try IntegrationsFixture(connectors: [connector])

    await fixture.model.testConnection(id: "jira")

    #expect(fixture.model.rows.first?.test == .failed(.credentialExpired))
}

@Test("an unconfigured connector is refused before any request is made")
@MainActor
func anUnconfiguredConnectorIsNotTested() async throws {
    let connector = StubSourceConnector(id: "jira", displayName: "Jira", isConfigured: false)
    let fixture = try IntegrationsFixture(connectors: [connector])

    await fixture.model.testConnection(id: "jira")

    // The token must not be sent to a host D19 does not allow. Mutation: drop the
    // guard — red, because the stub would then record a call.
    #expect(fixture.model.rows.first?.test == .failed(.notConfigured))
    #expect(connector.testConnectionCalls == 0)
}

@Test("D-194: the expiry warning appears at 14 days and not at 15")
@MainActor
func theWarningBoundaryIsFourteenDays() throws {
    let atFourteen = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(14 * IntegrationsFixture.day)))
    let atFifteen = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(15 * IntegrationsFixture.day)))

    #expect(atFourteen.model.expiryWarning?.daysRemaining == 14)
    #expect(atFifteen.model.expiryWarning == nil)
}

@Test("the warning describes the stored expiry, not the one being typed")
@MainActor
func theWarningIgnoresTheEditedDate() throws {
    let fixture = try IntegrationsFixture(
        credential: JiraFixture.credential(
            expiresAt: IntegrationsFixture.now.addingTimeInterval(90 * IntegrationsFixture.day)))

    // Half-typing a date into the picker is not a fact about the token in the
    // Keychain, and warning on it would fire on every keystroke.
    fixture.model.expiresAt = IntegrationsFixture.now.addingTimeInterval(IntegrationsFixture.day)
    fixture.model.recordsExpiry = true

    #expect(fixture.model.expiryWarning == nil)
}

@Test("a pasted site URL is named back as a host, not as the whole URL")
@MainActor
func aPastedURLIsNamedAsAHost() throws {
    let fixture = try IntegrationsFixture()

    // Review Focus 1. `cloudHost` deliberately accepts a URL, so the pane must not
    // echo it verbatim — PR #44's `ConfluenceSelftest` defect, repeated.
    // Mutation: return `site` from `siteHost`. Red.
    fixture.model.site = "https://acme.atlassian.net/jira/software/projects/PAY/boards/1"

    #expect(fixture.model.siteHost == "acme.atlassian.net")
}

@Test("the pane can tell that a verdict would be about the saved credential, not the typed one")
@MainActor
func unsavedChangesAreDetected() throws {
    let fixture = try IntegrationsFixture(credential: JiraFixture.credential())

    #expect(fixture.model.hasUnsavedChanges == false)

    // Review Focus 2, the sequence that misleads: correct the site, press Test,
    // read a verdict about the credential you were trying to replace.
    fixture.model.site = "corrected.atlassian.net"
    #expect(fixture.model.hasUnsavedChanges)

    fixture.model.saveCredential()
    #expect(fixture.model.hasUnsavedChanges == false)
}

@Test("§13: with no store the purge is unavailable and the credential half still works")
@MainActor
func aFailedStoreDisablesOnlyThePurge() throws {
    let fixture = try IntegrationsFixture()

    #expect(fixture.model.canPurge == false)
    #expect(fixture.model.storeFailureNote?.contains("no cached data to purge") == true)

    // A credential lives in the Keychain, so none of this depends on the store.
    fixture.model.site = "acme.atlassian.net"
    fixture.model.email = "leo@example.com"
    fixture.model.tokenEntry = "token-value"
    fixture.model.saveCredential()

    #expect(try fixture.store.credential()?.site == "acme.atlassian.net")
}
```

- [ ] **Step 3: Run them and confirm they fail.** Expected: BUILD FAILED on
  `IntegrationsSettingsModel`.

- [ ] **Step 4: Extend the two doubles**

In `StubSourceConnector`: add `private let connectionFailure: (any Error)?`, the init parameter
after `fallback:`, and `if let connectionFailure { throw connectionFailure }` at the end of
`testConnection()` — after the `isConfigured` guard.

In `InMemoryAtlassianStore`: add `private var writes = 0`, a `var writeCount: Int` accessor, and
`writes += 1` inside `store(_:)`'s `lock.withLock`.

- [ ] **Step 5: Write the model, in two files**

Write `IntegrationsSettingsModel.swift` (state, rows, the expiry warning, `setIntegration`,
`testConnection`, `purgeCache`, `forgetTestResults`, `presentable`) and
`IntegrationsSettingsModel+Credential.swift` (`load`, `saveCredential`, `resolvedToken`,
`removeCredential`, `forgetEntry`, `detail(for:)`), as implemented. The guard order in
`saveCredential` is: site non-empty → site is a Cloud host → email non-empty → token resolvable.

- [ ] **Step 6: Mutate three times**

- `if typed.isEmpty` → `if false` in `resolvedToken`. Expected: RED at
  `D-218: saving with an empty token field keeps the stored token`.
- Add `tokenEntry = stored.apiToken` to `load()`. Expected: RED at
  `§8: the stored token reaches no property of the model`, on **both** the direct assertion and the
  `Mirror` walk.
- `siteHost` returns `site`. Expected: RED at `a pasted site URL is named back as a host`.

Revert each and re-run for GREEN.

- [ ] **Step 7: `make lint > /tmp/lint.log 2>&1; echo $?` — expect 0. Then `make format`, and
      commit the formatting with the change (CI enforces it, D-075).**

```bash
git add StenoKit/Features/Settings StenoTests/Settings StenoTests/Integrations
git commit -m "feat: the model behind the Integrations pane, with the token write-only"
```

---

## Task 6: The pane, and the composition root

**Files:**
- Create: `Steno/Features/Settings/IntegrationsSettingsPane.swift`
- Modify: `StenoKit/Features/Settings/SettingsPane.swift`,
  `Steno/Features/Settings/SettingsView.swift`, `Steno/App/StenoApp.swift`

**Interfaces:**
- Consumes: everything `IntegrationsSettingsModel` produces (Task 5), `SourceRegistry` (Task 2),
  `SourceCachePurge` (Task 4).
- Produces: `SettingsPane.integrations`, `IntegrationsSettingsPane(model:)`, and
  `SettingsView(model:dataModel:aiModel:integrationsModel:)`.

**This task has no tests, and that is a property of the repo, not an omission.** The test bundle
links `StenoKit`, not the application target (D-010), so the pane is verified by `make build`,
by `make run`, and by Task 9's harness. That is also why Task 5 is as large as it is.

- [ ] **Step 1: Add the pane to the registry**

In `SettingsPane.swift`, replace the commented `// case integrations` sketch with a real case
before the `stale` sketch, and add its `title` ("Integrations") and `systemImage` ("link") arms.
`SettingsView`'s switch is exhaustive with no `default`, so this is a compile error until Step 2 —
which is the mechanism keeping a pane from silently rendering nothing.

Update both files' "Three panes as of M3-04; two more are sketched" doc comments to four and one.

- [ ] **Step 2: Write the pane**

Four sections in a `.grouped` `Form`: **Atlassian account**, the **Token expiry** warning when
`model.expiryWarning` is non-nil, **Integrations** (a row per `model.rows`), and **Cached data**.
`.onAppear` and `.onDisappear` both call `model.forgetEntry()`.

Three details are not free choices:

```swift
// The token field. The string is the `prompt`, not the label, and the style is
// explicit — a grouped `Form` draws a titled field as left-hand static text plus
// whatever width is left, which leaves a caret-width control against the right edge
// that the user clicks with nothing happening.
SecureField(
    "API token", text: $model.tokenEntry,
    prompt: Text(
        model.hasStoredCredential
            ? "Paste a new token to replace the stored one" : "Paste your API token")
)
.textContentType(.password)
.textFieldStyle(.roundedBorder)
.labelsHidden()
```

```swift
// The toggle. Not `$model.rows`: enablement goes through the model, which is what
// puts it in `AppSettings` where `SourceRegistry` reads it per dispatch (D-216).
Toggle(
    row.displayName,
    isOn: Binding(
        get: { row.isEnabled },
        set: { model.setIntegration(row.id, enabled: $0) }))
```

```swift
// The expiry picker, behind its own switch, because the date is genuinely optional:
// `AtlassianLogin` accepts a blank one and §5.2's warning then cannot fire (D-192),
// so a picker with no off switch would invent a date the user never recorded.
Toggle("I recorded an expiry date", isOn: $model.recordsExpiry)
if model.recordsExpiry {
    DatePicker("Token expires", selection: $model.expiresAt, displayedComponents: .date)
        .datePickerStyle(.compact)
}
```

§8's read-only paragraph and §5.2's admin-policy note are always-visible inline text, not a
first-run sheet — a modal shown once is the surface a policy change cannot bring back. The purge
sits behind a `.confirmationDialog` whose message names what survives. Review Focus 2's note goes
above the rows, once, gated on `model.hasUnsavedChanges`.

- [ ] **Step 3: Wire the composition root**

`StenoApp` builds the registry in a property initializer today, and the enablement closure has to
capture `AppSettings` — which a property initializer cannot reach. So:

- Add `private let appSettings = AppSettings()` and change `sourceRegistry` to a plain
  `private let sourceRegistry: SourceRegistry`.
- Add `private static func makeSourceRegistry(settings: AppSettings) -> SourceRegistry` carrying
  D-166's registration-order comment, and call it first in `init`.
- Build `integrationsSettingsModel` in both arms of the `store` switch: with
  `purge: SourceCachePurge(context: container.mainContext)` on success, `purge: nil` otherwise.
- Pass it to `SettingsView`.

**`init` will exceed SwiftLint's 50-line body budget.** Extract the default-project seeding into
`private static func seedDefaultProject(in container: ModelContainer)`, carrying its `mainContext`
reasoning across verbatim rather than summarizing it, and merge the two consecutive
`if case .success(let container) = store` blocks the extraction leaves behind.

- [ ] **Step 4: `make build`, then `make lint > /tmp/lint.log 2>&1; echo $?`, then the harness.
      All three must pass.**

- [ ] **Step 5: See it** — `make run`, open Settings with ⌘, and click Integrations. GUI
      verification is otherwise unavailable to an agent; `log show --info` is the fallback.

- [ ] **Step 6: Commit**

```bash
git add Steno StenoKit/Features/Settings/SettingsPane.swift
git commit -m "feat: the Integrations pane, and the toggle wired to live routing"
```

---

## Task 7: `integrations-selftest` and `make verify-integrations`

**Files:**
- Create: `StenoKit/CLI/IntegrationsSelftest.swift`,
  `StenoTests/CLI/IntegrationsSelftestTests.swift`
- Modify: `StenoKit/CLI/CLICommand.swift`, `StenoKit/CLI/CLIParser.swift`,
  `StenoKit/CLI/CLIEntry.swift`, `StenoKit/CLI/CLIRunner.swift`, `Makefile`
- Test: `StenoTests/CLI/CLIParserTests.swift`

**Interfaces:**
- Consumes: `IntegrationsSettingsModel` (Task 5), `SourceError.siteNotFound` (Task 3).
- Produces: `CLICommand.integrationsSelftest`,
  `IntegrationsSelftest.run(credentials:transport:now:out:) async -> Int32` and
  `.runSynchronously(credentials:out:)`, `IntegrationsSelftest.unresolvableSite`,
  `IntegrationsSelftest.foreignSite`, `FixedCredentialStore`.

- [ ] **Step 1: Write the failing tests**

`IntegrationsSelftestTests.swift`, with a `Transcript` collector so the wording is assertable. The
one that matters:

```swift
@Test("§8: the token never appears in the output, on any path")
func theTokenIsNeverPrinted() async {
    let transcript = Transcript()
    let credential = AtlassianCredential(
        site: JiraFixture.site, email: "leo@example.com",
        apiToken: "SUPER-SECRET-TOKEN-VALUE",
        expiresAt: Date().addingTimeInterval(9 * 24 * 60 * 60))

    _ = await IntegrationsSelftest.run(
        credentials: InMemoryAtlassianStore(credential),
        transport: StubJiraTransport(routes: [:]),
        out: transcript.record)

    // Mutation: print `credential.apiToken` anywhere in `report`. Red.
    #expect(transcript.text.contains("SUPER-SECRET-TOKEN-VALUE") == false)
    // And it does report what §5.2 treats as configuration, so it stays useful.
    #expect(transcript.text.contains("leo@example.com"))
    #expect(transcript.text.contains(JiraFixture.site))
}

@Test("the unresolvable probe site is shaped correctly, or it would prove nothing")
func theProbeSiteReachesTheResolver() {
    // **The point of the probe.** A site refused by `cloudHost` never reaches DNS,
    // so it could not establish what a real resolver or a real edge returns.
    #expect(AtlassianCredential.cloudHost(in: IntegrationsSelftest.unresolvableSite) != nil)
    #expect(AtlassianCredential.cloudHost(in: IntegrationsSelftest.foreignSite) == nil)
}
```

Plus: no credential stored is an instruction naming both `make atlassian-login` and Settings; a
refused Keychain is its own failure and does **not** print that instruction; a non-Cloud stored
site fails before anything is asked; the expiry line states the arithmetic; and a credential with
no expiry says "none recorded".

In `CLIParserTests.swift`, add `(["integrations-selftest"], CLICommand.integrationsSelftest)` to
the parse table and `["integrations-selftest", "--site", "acme.atlassian.net"]` to the
takes-no-flags table. The existing "no harness appears in the usage text" test already covers
hiddenness.

- [ ] **Step 2: Run them and confirm they fail.**

- [ ] **Step 3: Write the harness**

`IntegrationsSelftest.run` reads the credential, refuses a non-Cloud site, prints the credential
report, then runs three checks and sums their failures: both connectors' `testConnection()`, the
unresolvable-site probe, and the foreign-host local refusal. Exit 1 if any failed.

Two details are load-bearing:

- The probe credential carries `apiToken: "selftest-not-a-real-token"`, never the stored token, so
  nothing real travels even if a request got further than expected.
- `FixedCredentialStore`'s stored property is named `fixed`, not `credential` — a property named
  `credential` and the protocol's `credential()` requirement are a redeclaration.

Name the elapsed-milliseconds local `elapsed`, not `ms`: SwiftLint requires three characters.

- [ ] **Step 4: Wire the subcommand**

Add the case to `CLICommand`, the entry to `CLIParser.noFlagSubcommands`, the pre-store branch in
`CLIEntry` (before the store is opened, like its three siblings), and the `misroutedSelftest` arm
in `CLIRunner`.

- [ ] **Step 5: Add the make target**

```makefile
verify-integrations: build ## Test the stored Atlassian credential end to end (signed build; FR-6, D-220)
	@"$(BIN)" integrations-selftest
```

with the explanatory comment block above it and `verify-integrations` added to `.PHONY`.

- [ ] **Step 6: Mutate**

Interpolate `credential.apiToken` into the stored-credential line. Expected: RED at
`§8: the token never appears in the output, on any path`. Revert and confirm.

- [ ] **Step 7: Commit**

```bash
git add StenoKit/CLI StenoTests/CLI Makefile
git commit -m "feat: verify the Integrations pane against the live site and real Keychain"
```

---

## Task 8: The decision log, the README, and two stranded sentences

**Files:**
- Modify: `docs/DECISIONS.md`, `docs/tasks/README.md`,
  `StenoKit/Integrations/SourceConnector.swift`,
  `StenoKit/Features/Settings/SettingsPane.swift`,
  `StenoTests/Integrations/SourceRegistryTests.swift`

- [ ] **Step 1: Check the log's maximum before numbering anything**

```bash
grep -oE "D-[0-9]+" docs/DECISIONS.md | sort -t- -k2 -n | tail -1
```

It was `D-214` when this plan was written, so this task's records are **D-215 … D-220**. Read it
rather than inferring it from a sibling spec — that is how a duplicate D-140 shipped once.

- [ ] **Step 2: Write D-215 through D-220**

One per decision, in the file's existing format: a `###` heading, a
`**date** · task · **Status:** accepted` line with any `**extends …**`, the argument, and a
`**Falsified by**` line naming the tests. D-216 extends D-166, D-217 extends D-165 and D-192,
D-218 extends D-157 and D-190, D-220 extends D-138 and D-197.

- [ ] **Step 3: Correct the two sentences this task strands**

Both are claims no compiler checks, and both are about things this task changed:

- `SourceConnector.swift` says `cachedSummary` is what "§7.4 reads when the network is gone".
  **No code reads it for display** — its only readers are `ExportRecords`, the two `ImportService`
  files and `StoreMerge`, and the staleness wording comes from `lastFetchedAt`. This sentence is
  what the spec's first purge section was written from, and it was wrong the same way. Say the
  surface is owed rather than implying it exists.
- `SettingsPane.data`'s comment says purge "waits for M4". It arrived; it lives in
  `integrations`, because the cache it clears is M4-01's.

Also: D-166's own entry says "three outcomes", which is now four. Add a forward pointer in the
`> **Extended by D-216 …**` form the file already uses at line ~2180, and update
`SourceRegistryTests.swift`'s header sentence.

- [ ] **Step 4: Tick the README**

M4-04's row, **and M4-03's**, which merged unticked in PR #44 — CLAUDE.md's step 4 exists because
nothing else prompts it and §9.5 forbids a direct commit to `main`.

- [ ] **Step 5: Commit**

```bash
git add docs StenoKit
git commit -m "docs: record M4-04's six decisions, and correct two sentences they strand"
```

---

## Task 9: Run the live probe, and fix what it finds

**Files:**
- Modify: `StenoKit/Integrations/Atlassian/AtlassianErrors.swift`,
  `StenoKit/Integrations/Jira/JiraClient.swift`,
  `StenoKit/Integrations/Confluence/ConfluenceClient.swift`,
  `StenoKit/Integrations/SourceError.swift`, `StenoKit/Integrations/SourceNotice.swift`,
  `Steno/Features/Settings/IntegrationsSettingsPane.swift`, `docs/DECISIONS.md`,
  `docs/superpowers/specs/2026-10-01-m4-04-integrations-settings-ui-design.md`
- Test: `StenoTests/Integrations/Atlassian/AtlassianErrorsTests.swift`,
  `StenoTests/Integrations/Jira/JiraClientTests.swift`,
  `StenoTests/Integrations/Confluence/ConfluenceClientTests.swift`,
  `StenoTests/Integrations/SourceNoticeTests.swift`

**This task is not optional, and its outcome is known.** It is written out because the finding is
the whole justification for Task 7, and because an implementer who skips the run ships the defect.

- [ ] **Step 1: Run it**

```bash
make verify-integrations
```

On a machine with a real credential, the first run reports:

```
site probe steno-selftest-no-such-site.atlassian.net: FAIL — reported notFound, so a mistyped site still reads as something else
integrations-selftest: FAIL — 1 check(s) did not hold.
```

- [ ] **Step 2: Diagnose it rather than adjusting the probe**

```bash
host steno-selftest-no-such-site.atlassian.net
curl -s -o /dev/null -w "%{http_code}\n" https://steno-selftest-no-such-site.atlassian.net/rest/api/3/myself
```

`*.atlassian.net` has **wildcard DNS** — the probe host resolves to an Atlassian edge — and the
verify endpoint answers **404**. So Task 3's DNS mapping is never reached for the case it was
written for, and the 404 maps to `.notFound`, whose sentence is "That reference doesn't exist, or
this account can't see it" — which sends the user looking for a ticket they never named.

- [ ] **Step 3: Write the failing tests**

```swift
@Test("D-217 revised: a 404 means what the calling context says it means")
func notFoundIsPerCall() {
    #expect(
        AtlassianErrors.error(forStatus: 404, headers: [:], badRequest: .notFound)
            == .notFound)
    #expect(
        AtlassianErrors.error(
            forStatus: 404, headers: [:], badRequest: .notFound, notFound: .siteNotFound)
            == .siteNotFound)
}

@Test("D-217 revised: parameterizing the 404 leaves every other status alone")
func theNotFoundParameterIsNarrow() {
    // A 401 on a verify is still an expired or revoked token, not a wrong site —
    // §5.2's requirement, and the one this must not have broken.
    #expect(
        AtlassianErrors.error(
            forStatus: 401, headers: [:], badRequest: .notFound, notFound: .siteNotFound)
            == .credentialExpired)
    #expect(
        AtlassianErrors.error(
            forStatus: 403, headers: [:], badRequest: .notFound, notFound: .siteNotFound)
            == .invalidCredential)
}
```

In `JiraClientTests.swift` — note `changeSet(key:since:credential:)` is the fetch entry point, and
it needs `JiraFixture.quietRoutes()` with one route overridden:

```swift
@Test("D-217 revised: a 404 from the verify endpoint is a wrong site, not a missing reference")
func theConnectionTestReportsAWrongSite() async throws {
    // Mutation: drop `notFound: .siteNotFound` from `verify`. Red.
    let wrongSite = StubJiraTransport(routes: ["myself": [.status(404)]])
    await #expect(throws: SourceError.siteNotFound) {
        try await JiraClient(transport: wrongSite).verify(credential: JiraFixture.credential())
    }
}

@Test("D-217 revised: a 404 on a ref fetch still means the reference is missing")
func aFetchStillReportsAMissingReference() async throws {
    // The other half, and the reason the 404 is a parameter rather than a global
    // change: a mistyped ticket key must keep its own sentence.
    var routes = JiraFixture.quietRoutes()
    routes["issue"] = [.status(404)]
    let missing = StubJiraTransport(routes: routes)
    await #expect(throws: SourceError.notFound) {
        _ = try await JiraClient(transport: missing).changeSet(
            key: "PAY-421", since: since, credential: JiraFixture.credential())
    }
}
```

Add the Confluence twin in its own file — and **name it differently**
(`theConfluenceConnectionTestReportsAWrongSite`). Swift-testing's free functions share one module
namespace, so two identically named test functions in different files are a redeclaration error.

- [ ] **Step 4: Parameterize the 404**

`AtlassianErrors.error(forStatus:headers:badRequest:)` gains `notFound: SourceError = .notFound`,
returned from the `case 404` arm. Both clients' private `fetch` gain the same defaulted parameter
and forward it. Both `verify` methods pass `notFound: .siteNotFound`, because
`/rest/api/3/myself` and `/wiki/api/v2/spaces` answer 200 or 401 on a site that serves them.

**Confluence's `fetch` calls `AtlassianErrors.error` with `badRequest: .unavailable(status: 400)`**
— thread the new argument there too, not just in Jira's.

- [ ] **Step 5: Reword, because the 404 has a second cause**

A 404 there can also mean the site is real and simply does not have that product. Both are "the
configured site is not serving this" with one remedy, so they share the case — but the sentences
must stop claiming the site does not exist:

- `SourceError.siteNotFound.errorDescription` → "That site isn't serving this integration. Check
  the site address in Settings."
- `SourceNotice` → "Jira isn't being served from your configured site — using 2 days old data.
  Check the site address in Settings."
- The pane → "Steno reached acme.atlassian.net but found no Jira API there. Check the site address
  — or whether your site has Jira." This needs `row` in scope, so `sentence(for:)` becomes
  `sentence(for:row:)`.

Update the three `SourceNoticeTests` assertions that pin the old strings.

- [ ] **Step 6: Record the revision in both places that state the old premise**

A `> **Revised the same day, by that harness…**` block under D-217 in `DECISIONS.md`, and a
`> **Superseded during implementation…**` block under the spec's D-217 section. A fact in N places
is wrong in N−1 of them once it changes.

- [ ] **Step 7: Re-run everything**

```bash
make verify-integrations   # expect: site probe … siteNotFound (D-217), integrations-selftest: OK
make build && make test && make lint
```

- [ ] **Step 8: Commit**

```bash
git add StenoKit Steno docs
git commit -m "fix: a mistyped Atlassian site answers 404, not a DNS failure"
```

---

## Task 10: Open the PR, and stop

- [ ] **Step 1: `make build && make test && make lint` one final time, from a clean tree.**

- [ ] **Step 2: Read `.github/PULL_REQUEST_TEMPLATE.md` before writing the body.** `gh pr create`
      bypasses the template silently.

- [ ] **Step 3: Push the branch and open the PR.** The body must state, per CLAUDE.md:
  - the deviation `SourceDispatch.disabled` makes to M4-01's contract, and the behaviour change to
    `credentialWarnings()` that no pre-existing test can observe;
  - that `AppSettings` became `@unchecked Sendable`, and why no checked conformance is reachable;
  - that D-217's original premise was wrong and what the live harness found;
  - that `SourceConnector.swift` asserted a reader that does not exist, and that §5.2's
    stale-state surface is therefore still owed — a spec observation, not a change;
  - Review Focus item 3: a purge is not serialized against a refresh pass, accepted deliberately.
  - **No `REQUIREMENTS.md` amendment is needed** and its version is unchanged; nothing here
    contradicts the spec.

- [ ] **Step 4: Run the Copilot review loop** — fix, reply, resolve — and check collapsed body
      sections, because "Findings: None" can still hide real defects with no thread to resolve.

- [ ] **Step 5: Stop. Do not merge.** The user reviews and merges (§9.5).
