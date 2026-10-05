# M4-04 — Integrations Settings UI: design

**Date:** 2026-10-01 · **Task:** [`M4-04`](../../tasks/M4-04-integrations-settings-ui.md) ·
**Requirements:** FR-6, §5.1, §5.2, §5.3, §5.5, §7.4, §8, §9.4, §13, D5, D19, D-134, D-166,
D-179, D-184, D-190, D-192, D-193, D-194, D-197 ·
**Branch:** `feat/integrations-settings-ui`

## What this builds

The pane that makes M4 reachable from the app. M4-01 shipped the protocol, the registry and a
refresh that cannot block a report; M4-02 and M4-03 filled the registry with two real connectors
on one credential. All three ship in a build where the only way to store that credential is
`make atlassian-login` — a hidden CLI harness D-197 introduced precisely because FR-6's pane was
two tasks away. This is that pane.

The surface: the Atlassian site, email, API token and user-entered expiry date (§5.2); a
per-integration enable toggle and connection test (FR-6); the 14-day expiry warning; the in-app
statement that credentials must be read-scoped (§8); and "Purge cached external data" — the
remaining half of FR-6's Data area, which lands here because the cache it clears is M4-01's.

**Three things outside the pane change, and they are the interesting part of this task.**
`SourceDispatch` gains a fourth case so a deliberately disabled integration is silent rather than
reported as unconfigured; `SourceError` gains `siteNotFound` so a mistyped site stops being
reported as a network failure; and `AppSettings` gains one key. Everything else is a view over
rules that already exist.

## What this task decides

| | Decision |
|---|---|
| D-215 | One settings key holding the *disabled* set, not a flag per integration |
| D-216 | `SourceDispatch.disabled`, and the silence that goes with it |
| D-217 | `SourceError.siteNotFound`, mapped from DNS failures and nothing else |
| D-218 | The credential is rewritten from the Keychain, never from view state |
| D-219 | Purge clears two columns, and the event log is what makes that safe |
| D-220 | `integrations-selftest`, and `make verify-integrations` |

The numbering continues from D-214, which is the log's current maximum — checked in
`DECISIONS.md` rather than inferred from a sibling spec, which is how a duplicate D-140 shipped
once already.

---

## D-215 — One settings key holding the disabled set

```swift
public static let integrationsDisabledKey = "com.lgabrielgr.steno.integrations.disabled"

/// The integrations the user has switched off. **Absent means none**, so a
/// fresh install has every connector enabled.
public var disabledIntegrationIDs: Set<String> { get nonmutating set }

public func isIntegrationEnabled(_ id: String) -> Bool
```

A JSON array of disabled connector ids, stored under one key.

**Not one key per connector.** `jira.enabled` and `confluence.enabled` would be the obvious
shape, and it does not survive the next milestone: M5-02 adds MCP servers whose ids the user
chooses, so there is no static list of keys to declare — and `AppSettings.allKeys` is a static
list whose count `AISecretsTests.swift:47` asserts, which is the mechanism that keeps §8's
"secrets are never exported" audit honest. A key that cannot be listed is a key the audit cannot
see. One key absorbs any number of integrations with no migration.

**Disabled rather than enabled, so absence is the permissive answer.** This is the posture
`AppSettings.flag()` already takes for §10.5's opt-out: `UserDefaults` returns nothing for a key
never written, and the correct reading of "nothing" here is "the user has not switched anything
off". The inverse spelling would make a fresh install's integrations silently inert — in the one
direction nobody notices, because an integration that never fetches looks exactly like one with
nothing to report.

`allKeys` grows to ten entries, so `AISecretsTests`'s count assertion goes red until the key is
listed.

## D-216 — `SourceDispatch.disabled`, and the silence that goes with it

```swift
public enum SourceDispatch: Sendable {
    case ready(any SourceConnector)
    case notConfigured
    case disabled        // new
    case unhandled
}

public init(
    connectors: [any SourceConnector] = [],
    isEnabled: @Sendable (String) -> Bool = { _ in true })
```

**The default closure is what keeps this a non-event for M4-01's tests and call sites.** Every
existing `SourceRegistry(connectors:)` keeps compiling and keeps behaving identically; the
composition root passes `{ settings.isIntegrationEnabled($0) }`.

**Read per dispatch, not at construction.** `StenoApp` builds the registry once for the process
(D-166 keeps registration order at the composition root), so a registry filtered at construction
would honour a toggle only after a relaunch — and nothing on screen would say so. Asking the
closure inside `dispatch` is what makes the toggle live.

**Precedence: `.ready` > `.notConfigured` > `.disabled` > `.unhandled`.** A sentence the user can
act on outranks silence. Where two connectors claim one ref and one is enabled-but-unconfigured
while the other is switched off, "this integration isn't set up yet" is the useful answer; the
disabled one is reported only when nothing enabled claims the ref at all.

**And the silence is the point of the case.** Today a connector with no credential dispatches
`.notConfigured`, and `SourceNotice` turns that into "Some references have no integration set up
yet." Telling a user who deliberately switched Jira off that Jira is not set up is both false and
an instruction they have already declined. So `RefreshOutcome` gains a `disabled` counter for the
log, and `SourceNotice` deliberately never mentions it — FR-5's reasoning: a warning that always
fires is one the user learns to ignore.

Two consequences follow, and both are requirements rather than conveniences:

- `SourceRefreshService.credentialWarnings()` changes from `registry.all` to enabled connectors
  only (`SourceRegistry.enabled`). Otherwise switching Confluence off leaves its expiry warning
  nagging about a credential it is no longer using. Both connectors share one credential (§5.3),
  so Jira keeps warning while it is on — which is correct, because the token still matters.
- The pane keeps reading `registry.all`. A pane listing only enabled integrations would offer no
  way to switch one back on.

## D-217 — `SourceError.siteNotFound`, mapped from DNS failures and nothing else

The third acceptance criterion requires the connection test to distinguish bad credentials, an
expired token, a wrong site URL and a network failure. Three of those already exist. The fourth
does not: a site that is shaped correctly but does not exist — `acmee.atlassian.net` — fails DNS,
`AtlassianErrors.error(forTransport:)` maps every `URLError` but `.cancelled` to `.network`, and
the user is told to check their connection. That is exactly the generic failure §5.2 forbids,
reached by the most likely real typo.

```swift
case siteNotFound   // "Couldn't reach that Atlassian site. Check the site address in Settings."
```

Mapped from `URLError.cannotFindHost` and `URLError.dnsLookupFailed`.

> **Superseded during implementation by D-217's revision; see `DECISIONS.md`.** `*.atlassian.net`
> has wildcard DNS, so a mistyped site resolves and answers **404** on the verify endpoint — the
> DNS branch is never reached for the case this section was written about. `make verify-integrations`
> found it on its first run. The 404 is now parameterized per call, the way D-214 parameterized the
> 400: a ref fetch's 404 stays `.notFound`, and `verify`'s becomes `.siteNotFound`. The DNS mapping
> is kept, and the wording grew to cover a real site that lacks the product.

**Not `.cannotConnectToHost`.** A host that resolves and then refuses the connection is a proxy,
a captive portal or a firewall — not a typo — and telling that user to edit a correct setting
sends them to fix the wrong thing. It stays `.network`.

**No associated value.** The obvious shape carries the host, and D-165 exists to refuse exactly
that: no `SourceError` case carries a free-form `String`, which is what makes "a `SourceError` is
always safe to log" a property of the type rather than of every future connector's discipline.
The pane interpolates the site it already holds in view state.

**It is worth more than the test button.** The same mapping improves the stand-up sheet: a
mistyped site currently makes every refresh say "check your connection" during stand-up prep.
`SourceNotice` today groups `case .network, .timedOut:` into one sentence; `.siteNotFound` gets
its own branch pointing at Settings. Both `errorDescription` and `metricsLabel` grow a case, and
every existing sentence about `.network` is re-read rather than assumed still true — a widened
behaviour that strands its prose is the recurring defect on this codebase.

## D-218 — The credential is rewritten from the Keychain, never from view state

Site, email and expiry are not secrets, so the pane prefills them: a user who cannot see what
site is configured cannot fix a typo in it. The token is never prefilled (§8, and the second
acceptance criterion).

All four live in **one Keychain item** (D-190), so changing only the site means rewriting the
whole item — which needs the token. The rule:

```
saveCredential():
  read the stored credential (one Keychain read)
  token = tokenEntry.isEmpty ? stored?.apiToken : tokenEntry
  refuse if there is no token from either source
  store AtlassianCredential(site:email:apiToken:expiresAt:)
  clear tokenEntry
```

**The token exists only as a local inside that function.** It never becomes a property of
`IntegrationsSettingsModel`, which is what makes "never displayed in full after entry" a property
of this code rather than of `SecureField`'s drawing behaviour — D-157 took the same posture on the
AI pane, and the difference here is that a partial edit genuinely needs the stored value. A
`Mirror` over the model's properties asserts no stored property holds it.

**A site that is not an Atlassian Cloud host is refused locally, before any request.** The
credential travels as HTTP Basic, so a mistyped host would send the user's work token wherever it
named (D-190, D19). `AtlassianCredential.cloudHost(in:)` already decides this, and
`AtlassianLogin` already refuses on it; the pane uses the same function and says so in its own
words.

## D-219 — Purge clears two columns, and the event log is what makes that safe

```swift
extension SourceRef {
    /// Clear what a purge removes. Both together, for `recordFetch`'s reason:
    /// §10.1 resolves them as a pair.
    func clearCache()   // cachedSummary = nil; lastFetchedAt = nil
}
```

`SourceCachePurge` (`@MainActor`, `StenoKit/Integrations/`) fetches every `SourceRef`, clears it,
saves, and reports a count — rolling back on a save failure. The task file is explicit about the
scope: "Purging must not delete tasks, events, or refs, only `cachedSummary` and
`lastFetchedAt`."

**It does not touch the event log, and nothing here is an exception to §3.3.** A cache column on
a `SourceRef` is not an `Event`; no row is deleted; `ImportPlan.deletions` is not involved. The
one sanctioned deletion path stays the one §10.1 already owns.

**And that is also why the purge is safe against the failure mode it looks like it should have.**
Clearing `lastFetchedAt` could plausibly make the next pass treat every ref as a first
observation — and a first observation reports the summary and nothing else (D-169) while still
recording every id it saw (D-188), so real changes would be swallowed and never reported again.
It does not happen, because `SourceRefreshService+Write.swift:143` computes

```swift
let isFirst = row.lastFetchedAt == nil && resume[row.id] == nil
```

and the resume point is recovered from `externalUpdate` payloads in the log (D-184), which a purge
leaves untouched. This is the same reasoning that fixed the post-import case in PR #43: first
observation means the log has never reported this ref, not that the cache column is empty.

What the purge costs is stated in the confirmation rather than discovered — and the first draft of
this spec got it wrong, which is worth recording because the wrong version is the one everything in
the repo implies. **Nothing in the app displays `cachedSummary`.** Its only readers are
`ExportRecords`, `ImportService+Merge`, `ImportService+Delete` and `StoreMerge`; the staleness
banner is built from `lastFetchedAt` via `RefreshOutcome.Failure.cachedAt` and
`SourceNotice.staleness(oldestFetch:)`, never from the summary text. So the real costs are:

- Every ref becomes due immediately (`RefreshPolicy` returns `true` for a `nil` `lastFetchedAt`),
  so the next pass fetches everything. Bounded by D18's 20-task window cap and
  `SourceRefreshService.maxInFlight == 4`, which is the same shape as a first launch.
- Until that pass, a *failed* fetch can no longer say how old the data it fell back on is —
  `failure.cachedAt` is `nil`, so "using 2 days old data" becomes silence about age.
- An export taken with `--include-cached` carries nothing for those refs, because §10.2 writes
  `cachedSummary` and `lastFetchedAt` together or omits both.

**`SourceConnector.swift:43` claims a reader that does not exist** — "Stored as
`SourceRef.cachedSummary`, which §7.4 reads when the network is gone." No code reads it for
display. That comment is corrected in this PR: it is the sentence that made the first version of
this section false, it is about the exact field being purged, and a comment asserting a property
nothing implements is this codebase's most frequently rediscovered defect. Whether §5.2's
"what the app shows when it tells the user their integration data is stale" should become a real
surface is M4-05's or a later task's question, and it is raised in the PR body rather than answered
here.

A plain confirmation alert, **not** §10.1's typed confirmation. Typed confirmation exists for an
irreversible wipe of the user's own authored data; this removes only data the app can re-fetch,
and a ceremony disproportionate to the risk is one users learn to click through.

`SettingsPane.data`'s doc comment currently says purge "waits for M4 — there is no cached
external data until integrations exist". That sentence is corrected in this PR rather than left
behind as the last place in the repo claiming this does not exist.

## D-220 — `integrations-selftest`, and `make verify-integrations`

A hidden, store-free subcommand in `CLIParser.noFlagSubcommands`, absent from `CLIUsage.text`,
run by `make verify-integrations` — the naming `verify-jira` and `verify-confluence` already set.
D-138's shape, applied to this pane.

```
$ make verify-integrations
stored credential: me@acme.com at acme.atlassian.net
jira        reached in 218ms
confluence  reached in 184ms
site probe  acmee.atlassian.net -> siteNotFound
site probe  example.com         -> refused locally, no request sent
expiry      61 days remaining, no warning
```

**It exists because the four-way taxonomy is the point of the pane, and a taxonomy verified only
against doubles is verified against doubles I wrote to agree with me.** `make test` denies
outbound networking (§9.4, D-012), so nothing in the unit suite can prove that a nonexistent
Atlassian subdomain produces `siteNotFound` rather than `network` — that depends on which
`URLError` the real resolver returns. The probe is the check that can disagree.

It runs against `AtlassianKeychainStore`, so it also covers the real store's `credential()` read,
which `make test` cannot reach (D-134): that code path is exercised only by the signed binary.

> **Narrowed during implementation; see D-220 (Copilot, PR #45).** This paragraph claimed the
> harness "drives the real `IntegrationsSettingsModel`", and it does not — it reads the store
> directly and builds the connectors itself. Nor can it: the model is `@MainActor`, and
> `CLISync.runSynchronously` blocks the main thread on a semaphore while the work runs on the
> cooperative pool, so a main-actor hop inside that work deadlocks the bridge. The model's
> `load()`, `saveCredential()` and `resolvedToken()` are covered by
> `IntegrationsSettingsModelTests` against a double; the real Keychain round trip is covered by the
> *pair* `make atlassian-login` (writes) and `make verify-integrations` (reads). The claim appeared
> in four places and was corrected in three of them first, which is the point
> "widening a behaviour strands its prose" keeps making.

Nothing it prints contains the token, on any path.

---

## Layout

```
StenoKit/
  Features/Settings/
    IntegrationsSettingsModel.swift        # new — every rule
    SettingsPane.swift                     # + case integrations
  Integrations/
    SourceRegistry.swift                   # + isEnabled, + .disabled, + .enabled
    SourceDispatch (in SourceRegistry.swift)
    SourceError.swift                      # + .siteNotFound
    SourceNotice.swift                     # + its sentence
    RefreshOutcome.swift                   # + disabled counter
    SourceCachePurge.swift                 # new
    SourceRefreshService+Reads.swift       # credentialWarnings() -> enabled only
    Atlassian/AtlassianErrors.swift        # URLError -> .siteNotFound
  Models/SourceRef.swift                   # + clearCache()
  Settings/AppSettings.swift               # + the one key
  CLI/
    IntegrationsSelftest.swift             # new
    CLICommand.swift, CLIParser.swift      # + the subcommand
Steno/
  Features/Settings/
    IntegrationsSettingsPane.swift         # new — arranges controls, owns no rule
    SettingsView.swift                     # + one switch arm
  App/StenoApp.swift                       # builds the model, passes isEnabled
Makefile                                   # + verify-integrations
```

### `IntegrationsSettingsModel`

`@Observable @MainActor`, built once in `StenoApp.init` and held for the process — the posture
all three sibling models take, because the `Settings` scene's content is rebuilt freely by SwiftUI
and the state behind it must not be.

```swift
public init(
    credentials: any AtlassianCredentialStore = AtlassianKeychainStore(),
    registry: SourceRegistry,
    settings: AppSettings = AppSettings(),
    purge: SourceCachePurge?,                     // nil when the store failed to open
    now: @escaping () -> Date = Date.init)
```

State:

| | |
|---|---|
| `site`, `email`, `tokenEntry`, `expiresAt`, `recordsExpiry` | what the user is editing |
| `storedCredential: StoredCredentialState` | `.absent` / `.present(site, email, expiresAt)` / `.unreadable(detail)` |
| `credentialProblem: String?` | why the last store or delete was refused |
| `rows: [IntegrationRow]` | id, display name, `isEnabled`, `test: TestState` |
| `expiryWarning: SourceCredentialWarning?` | derived from the stored date and `now` |
| `purgeState` | idle / purging / purged(count) / failed(detail) |

`.unreadable` is not merged into `.absent`, for `AISettingsModel`'s reason: telling a user with a
locked keychain that no credential is stored sends them to retype a token that is already there.
`storeFailureNote` appears only for the purge section — the credential half of this pane is fully
functional in a build whose store will not open (§13).

Every rule lives here rather than in the pane, because the unhosted test bundle cannot reach the
app target (D-010) — a rule only a view knows is a rule no test can hold.

### Errors the user reads

| Cause | Sentence | Action |
|---|---|---|
| `.credentialExpired` (401) | Your token expired or was revoked. Create a new one. | link to `AtlassianTokenExpiry.renewalURL` |
| `.invalidCredential` (403) | Atlassian rejected this email and token. + the admin note below | — |
| `.siteNotFound` | Steno couldn't find `acme.atlassian.net`. Check the site above. | — |
| `.network`, `.timedOut` | Couldn't reach Atlassian. Check your connection. | — |
| `.rateLimited`, `.unavailable`, `.invalidResponse`, `.notFound` | `SourceError.errorDescription` | — |
| site is not `*.atlassian.net` | Refused before any request; the token is not sent. | — |
| nothing stored | This integration isn't set up yet. | — |

The sentences come from `SourceError.errorDescription`, so the pane and the stand-up banner cannot
drift apart — with `.siteNotFound` interpolating the site, which the pane holds and the type
deliberately does not carry.

### What the pane states in words

Two of the acceptance criteria are sentences rather than behaviour, and both are checked against
code rather than against this document:

- **Read-only (§8, D5, the sixth criterion).** "Steno only ever sends GET requests. It cannot
  change a ticket, a page or a comment — and it refuses your credential to any host but your
  Atlassian site." Clause one is true because `ReadOnlyTransport.isAllowed` permits `.get` and
  nothing else and `send` calls `preconditionFailure` on anything else — a trap rather than a
  thrown error, so there is no degradation path that could paper over it (D-191) — and because
  `JiraEndpoint.request` and `ConfluenceEndpoint.request` hard-code `method: .get`. Clause two is
  true because `AtlassianCredential.baseURL` builds its own `https` URL from a validated
  `*.atlassian.net` host. A privacy claim verified
  against a design doc instead of the transport is how three of four wrong sentences shipped on
  M3-02.
- **The org-policy caveat (§5.2).** "If your Atlassian admin has blocked API token creation,
  nothing here can work around it — that's an admin conversation." Shown as a standing note under
  the token field and again beside a rejected-credential verdict, which is the 403 that an
  authentication policy produces.

### The pane

Four sections in a `.grouped` `Form`: **Atlassian account** (site, email, token, expiry, the
read-only line, the admin note), **Integrations** (a row per `registry.all`), **Cached data**
(purge), and the expiry warning, which renders inside the account section when it fires.

Two details that are not free choices:

- The token's `SecureField` puts its string in `prompt:` with `.textFieldStyle(.roundedBorder)`
  and `.labelsHidden()`. A grouped `Form` renders a titled field as left-hand static text plus
  whatever width is left, which drew the AI pane's key field as a caret-width control the user
  clicked and nothing happened.
- The expiry is a `.compact` `DatePicker` gated behind an "I recorded an expiry date" toggle.
  `expiresAt` is genuinely optional — `AtlassianLogin` accepts a blank date and §5.2's warning
  then cannot fire (D-192) — and a date picker with no off switch would invent a date the user
  never recorded.

`.onAppear` and `.onDisappear` clear `tokenEntry`, for D-157's reason: this model lives for the
process, so an unsaved token would otherwise sit in memory until the app quit.

## Verification

Unit tests, each written to fail first and then mutation-tested on a clean tree — `git checkout`
skips untracked files, which produced twelve false "caught" results once.

1. **`IntegrationsSettingsModelTests`** — saving with an empty token entry preserves the stored
   token; saving with no token from either source is refused; a `Mirror` over the model asserts no
   stored property holds a token; a non-Atlassian site is refused with no request made; removing
   the credential leaves the enable flags alone.
2. **The toggle is live** — flipping it writes `AppSettings` and changes `dispatch`'s answer in
   the same process. This is the guarantee a registry filtered at construction would lose, so it
   is a test rather than a comment.
3. **`SourceRegistryTests`** — the four-case precedence, including two connectors claiming one
   ref with one disabled; and `credentialWarnings()` skipping a disabled connector while its
   enabled sibling still warns on the shared credential.
4. **`AtlassianErrorsTests`** — `cannotFindHost` and `dnsLookupFailed` map to `.siteNotFound`;
   `cannotConnectToHost` stays `.network`; `cancelled` stays `.timedOut`.
5. **`SourceNoticeTests`** — `.siteNotFound` produces its own sentence, and a `.disabled` count
   alone produces none.
6. **Expiry** — a warning at 14 days and silence at 15, parameterized. `make test` prints no
   table cases, so the absence of output is not evidence either way; the cases are verified by
   mutation.
7. **`SourceCachePurgeTests`** — both columns cleared; tasks, events and the refs themselves
   intact; a purged ref whose log carries an `externalUpdate` payload is **not** treated as a
   first observation on the next pass; after a purge a failed fetch's notice says nothing about
   age rather than something false; an injected throwing save rolls back, with a later successful
   save proving the assertion can go red.
8. **`AppSettingsTests` / `AISecretsTests`** — the new key round-trips, absence means nothing is
   disabled, and `allKeys` is ten entries with no name resembling a credential.
9. **`CLIParserTests`** — `integrations-selftest` parses, rejects a flag, and stays out of
   `CLIUsage.text`.

Then `make build && make test && make lint`, and `make verify-integrations` against the real site.
`make test` regenerates the xcodeproj every run, which can disturb an open Xcode session, and
`CLIBinaryTests` fails while Steno is running — a local-only red CI never sees.

## The plan document

`docs/superpowers/plans/2026-10-01-m4-04-integrations-settings-ui.md`, written by the
writing-plans skill from this spec. Code blocks in it are generated from a built tree rather than
type-checked standalone: a snippet that compiles alone still fails inside `#expect` or a `Logger`
interpolation, and plan blocks "verified" that way have shipped four real defects.

## Out of scope

- **MCP server management** — M5-02, though FR-6 groups it in this pane. The pane renders a row
  per registered connector, so an MCP connector appears here with no change when it exists.
- **Scheduled refresh and its time setting** — M4-05, which this task blocks.
- **The global stale threshold** — M6-01.
- **Connector logic** — M4-02 and M4-03 own it. The only connector-layer changes here are the
  ones the pane's error vocabulary requires.
- **Removing `make atlassian-login`.** It stays: it is the harness `verify-jira` and
  `verify-confluence` depend on, and the GUI is not reachable from a test.

## Risks

- **The compiler finds three of the new case's sites; it cannot find the fourth kind.** Exhaustive
  switches over `SourceError` live in two files only — `errorDescription` and `metricsLabel` in
  `SourceError.swift`, and `SourceNotice.swift:160`, which today groups `case .network, .timedOut`
  — so adding the case is a compile error in each. What no compiler checks is the prose: every
  sentence in this repo that explains `.network` as "the request never arrived" is now describing a
  narrower set, and those are re-read in this PR.
- **An enabled-only `credentialWarnings()` is a behaviour change to M4-01's output.** With both
  integrations on — the only state that exists before this PR — the result is identical, so no
  existing test can notice. The new test for it is the only thing standing behind it.
- **The purge's confirmation carries claims about what is lost.** The first draft of this spec
  asserted a §7.4 fallback that no code implements. The wording that ships is checked against
  `RefreshOutcome.Failure.cachedAt` and `SourceNotice.staleness(oldestFetch:)` — the two things
  that actually read what a purge clears — and against `ExportRecords`, not against this
  document.
- **One Keychain item, two editable halves.** D-218's read-then-rewrite is the first code in this
  repo that reads a token in order to store it again. A failure between read and store leaves the
  stored credential untouched, because `AtlassianKeychainStore.store` is add-then-update rather
  than delete-then-add — but the model must not treat a failed read as "no token" and store a
  credential without one, which is why the refusal is a test.
