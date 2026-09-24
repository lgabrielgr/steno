# M3-04 — AI Settings UI: design

**Date:** 2026-09-24 · **Task:** [`M3-04`](../../tasks/M3-04-ai-settings-ui.md) ·
**Requirements:** FR-6, §7.1, §7.2, §7.4, §8, §9.4, §13, D-138, D-141, D-145 ·
**Branch:** `feat/ai-settings-ui`

## What this builds

The pane that makes M3 reachable. M3-01 defined the seam, M3-02 filled it with transport and a
runtime model list, M3-03 wrote the prompt and §7.4's fallback — and every one of them ships in a
build where the AI path can never run, because nothing writes a key into the Keychain and nothing
writes `AppSettings.aiSelectedModelID`. Both of those are this task, and they are the whole of
why it exists.

The surface: a provider picker, a key field backed by `KeychainCredentialStore`, a model picker
populated from `availableModels()`, a "Test connection" that tells a rejected key apart from an
unreachable network, and §8's disclosure of what leaves the Mac. Plus `make verify-models` — the
network twin of `make verify-keychain`, filed from M3-02 (PR #35), which is the first thing in
this repo ever to execute `URLSessionTransport`.

**The stand-up path needs no change at all.** `MainWindowModel.standupPolish(settings:)` already
builds `AnthropicProvider(credentials: KeychainCredentialStore())` per call and reads
`settings.aiSelectedModelID` per call, precisely so that a picker writing that key takes effect
without a relaunch. This task writes the two values that function already reads.

## What this task decides

| | Decision |
|---|---|
| D-157 | The key field is entry-only; nothing is ever read back out of the Keychain into view state |
| D-158 | `/v1/models` is called only on an explicit act — never merely because the pane appeared |
| D-159 | Saving a key selects element zero, and that is what turns AI on |
| D-160 | The provider picker renders a list and stores nothing |
| D-161 | `models-selftest` and `make verify-models`, D-138's shape applied to the network |

Each is argued below. The numbering continues from D-156, which is the log's current maximum —
checked in `DECISIONS.md` rather than inferred from a sibling spec, which is how a duplicate
D-140 shipped once already.

---

## D-157 — The key field is entry-only

`AISettingsModel` holds `keyEntry: String`, bound to a `SecureField`. It starts empty on every
appearance, including when a key is already stored, and it is cleared the instant a save
succeeds. **The pane never reads a credential's value back out of the Keychain.** The only
Keychain read it performs is a presence check, whose returned `Credential` is tested for `nil`
and discarded.

The acceptance criterion is "the key is never displayed in full after entry and never appears in
logs". A field that loaded the stored key so it could be edited in place would satisfy that
through AppKit's secure-entry behaviour — dots on screen, and `NSSecureTextField`'s exclusion
from screen capture — which makes §8 a property of a framework rather than of this code.
Entry-only makes it a property of the code: there is no path on which the stored value reaches
view state, so no future edit to the pane can expose it, and a screenshot, an accessibility dump or a
scrollback cannot contain what was never loaded.

The cost is that "what key is stored?" has no answer beyond "one is". That is the right trade for
a single-user recall tool with one provider: the user's remedy for a key they no longer recognise
is to paste a new one, which is one click either way.

**Removing a key leaves `aiSelectedModelID` alone.** The model id is not a secret, the picker
should not lose its place because the user rotated a key, and re-entering a key then restores the
previous behaviour with nothing to redo. §7.4 covers the interval: the provider throws
`.notConfigured`, and the stand-up is the raw report.

**What the pane shows instead:** a caption reading that a key is stored, alongside "Replace" and
"Remove". With no key stored it reads that stand-ups are built from the log alone until one is
set — §7.4 stated as an ordinary fact rather than as a warning, because the AI is an upgrade
here, never a prerequisite.

---

## D-158 — Only an explicit act calls `/v1/models`

Three things fetch the list: saving a key, pressing "Refresh models", and "Test connection"
(which is `availableModels()` under another name — see `AnthropicProvider.testConnection`).
Opening the AI tab does not.

The alternative — fetch on appear — makes the picker always current, and it was rejected because
it makes opening a settings tab a network event. The user who opens Settings to change their
capture hotkey has no interest in Anthropic's catalogue, and a tab that silently spends a request
(and, offline, ten seconds of `settingsTimeout` before it can say anything) is doing work nobody
asked for. This is a recall tool; the pane's job is to be small.

**The visible consequence, stated rather than hidden:** opening the pane with a key stored and no
fetch yet shows a model picker containing exactly one row — the stored model id — selected.
Changing models is then two acts, Refresh and then choose. That is the honest rendering of "we
have not asked", and it is also the offline rendering, which is why it doubles as the second
acceptance criterion: an unreachable model list cannot block using a previously selected model,
because the selection was never sourced from the list in the first place.

**No cache, deliberately.** Persisting the last good list would fill the offline picker with
every model seen last time, at the price of a new `AppSettings` key — one that grows `allKeys`,
which `AISecretsTests` counts, and holds vendor ids that go stale with nothing to notice. The
stored selection is the only piece of that list this app actually needs to keep.

---

## D-159 — Saving a key selects element zero, and that is what turns AI on

On a successful save, the model fetches the list and then writes `models[0].id` to
`AppSettings.aiSelectedModelID` — but only when the current selection is `nil`, or names a model
the fetched list does not contain. An existing, still-offered selection is never overwritten.

§7.1 asks for a default of "a mid-tier model … this is not a reasoning-heavy workload", and
D-141 put that choice in the provider's ordering: element zero is the recommended default. This
is the one place that ordering is consumed. Without it, a user pastes a key, presses nothing
else, and gets raw reports forever with a picker cheerfully displaying a model that is not in
use — the state where the app looks configured and is not.

So entering a key is read as intent to use the AI. The user can change the model, and can undo
the whole thing by removing the key. What this deliberately does not add is a separate on/off
switch: the key is the switch, and a second control that can disagree with it is a state to
explain.

**A fetch that fails after a successful save leaves the key stored and the selection exactly as
it was** — which on a first key means no selection at all. AI stays off in that case, the pane
says the list could not be fetched and offers Refresh, and §7.4 does the rest. The key is not
rolled back — it is almost certainly correct, and the network is what failed.

---

## D-160 — The provider picker renders a list and stores nothing

`AISettingsModel` takes `providers: [any AIProvider]` — one in production, two in tests — and
holds `selectedProviderID` in memory, defaulting to the first. Nothing is persisted, and the
picker disables itself while there is one provider.

FR-6 names a provider picker and §7.1's whole point is that a second provider can be plugged in,
so the pane renders from a list rather than hard-coding "Anthropic" in a `Text`. But a *setting*
with one possible value is the field D-141 already refused: it would add a key to `AppSettings`,
grow `allKeys` and the count `AISecretsTests` asserts, and give a future task a stored value it
must either honour or migrate. Holding the selection in memory costs nothing and keeps the
abstraction exercised — the tests drive the model with two `StubAIProvider`s and assert that
switching routes the next call to the other one, which is more than a disabled picker could ever
demonstrate.

**§7.2's credential rule is already enforced one layer down.** `CredentialKind.userSelectable`
is `[.apiKey]`, and the pane renders from it rather than from `allCases`; D-136 built it for
exactly this pane. With one selectable kind there is no kind picker on screen — the rule is that
API key is the *only enabled option*, and a picker of one is a label.

---

## D-161 — `models-selftest`, and `make verify-models`

A hidden `steno models-selftest` subcommand, modelled line for line on `KeychainSelftest` and
D-138: absent from `CLIUsage.text`, handled in `CLIEntry` **before** the store is opened, and
exposed as `make verify-models` so a human runs it against a signed build.

It reads the stored Anthropic credential, calls `availableModels()` through the real
`URLSessionTransport`, and prints the ranked list — id and display name, with element zero marked
as the default the picker will preselect. It closes the two gaps M3-02's task file filed:

- **`URLSessionTransport` has no automated test at all** (D-143). Until this exists, the real
  adapter's first execution is by a user, in a pane, at the moment they are trying to configure
  the app.
- **`/v1/models`'s shape was confirmed by hand once, on 2026-09-22.** A renamed field a year from
  now fails silently: the paging guards turn it into a short list rather than an error, and the
  ranking dedupes by id, so nothing complains. A repeatable target is the point — and printing
  the ranked order is also how D-141's preference (sonnet, then haiku, then the rest; newest
  first within a family) gets checked against what the API actually returns rather than against
  what `ModelRanking`'s unit tests assume.

**It never prints the key**, on any path, including failure — `KeychainSelftest.describe`'s rule,
for §8's reason. A missing credential is reported as "no key is stored", not as an error, since
that is an ordinary state and the message is the instruction.

The provider id it reads is the real one (`anthropic`), unlike `KeychainSelftest`'s `selftest`
sentinel: there is no way to ask Anthropic a question with a fake key, and the command only
reads.

---

## Layout

```
StenoKit/Features/Settings/AISettingsModel.swift   new   — every decision the pane makes
StenoKit/Features/Settings/SettingsPane.swift      edit  — `case ai` replaces its comment
StenoKit/AI/ModelsSelftest.swift                   new   — D-161's harness, over a CredentialStore
StenoKit/CLI/CLICommand.swift                      edit  — `case modelsSelftest`
StenoKit/CLI/CLIParser.swift                       edit  — one arm, flags refused
StenoKit/CLI/CLIEntry.swift                        edit  — handled before the store opens
Steno/Features/Settings/AISettingsPane.swift       new   — Form, and no logic
Steno/Features/Settings/SettingsView.swift         edit  — one switch arm
Steno/App/StenoApp.swift                           edit  — builds the model once, both branches
Makefile                                           edit  — `verify-models`
```

`AppSettings` is untouched: `aiSelectedModelIDKey` was declared by M3-03 for this task to write,
so `allKeys` does not change and neither does `AISecretsTests`' count.

### `AISettingsModel`

Sketch, not final source — the plan verifies every block against a built tree.

```swift
@Observable @MainActor
public final class AISettingsModel {
    public enum ListState: Equatable { case idle, loading, failed(AIError) }
    public enum ConnectionState: Equatable { case untested, testing, passed, failed(AIError) }

    public var keyEntry: String = ""            // the SecureField's binding; never loaded
    public private(set) var hasStoredKey: Bool
    public private(set) var models: [AIModel] = []
    public private(set) var listState: ListState = .idle
    public private(set) var connection: ConnectionState = .untested
    public private(set) var selectedModelID: String?
    public var selectedProviderID: String

    public var providerNames: [(id: String, name: String)]   // D-160's picker rows
    public var modelRows: [AIModel]                          // fetched ∪ the stored selection
    public var isBusy: Bool                                  // listState == .loading || .testing

    public init(providers: [any AIProvider],
                credentials: any CredentialStore = KeychainCredentialStore(),
                settings: AppSettings = AppSettings())

    public func saveKey() async
    public func refreshModels() async
    public func testConnection() async
    public func removeKey()
    public func select(modelID: String)
}
```

**The actions are `async` methods, and the pane wraps each in a `Task`.** A model that started
its own detached `Task` would hand a test nothing to await, and this repo has already recorded
what that costs: a `Task` has not started when the function that created it returns, so the test
either polls or asserts against a state the work has not reached. Awaiting the method directly
removes the question.

**`modelRows` is derived, not stored.** It is the fetched list, plus the stored selection when
the list does not contain it, so the picker can never silently reassign a selection it failed to
find. The stored-but-unoffered row is labelled as such in the pane.

### Errors the user reads

`AIError.errorDescription` already distinguishes what the third acceptance criterion needs —
`.invalidCredential` is "The provider rejected this credential", `.network` is "Couldn't reach
the provider" — so the pane renders that string and does not invent a second vocabulary. What the
pane adds is the *symbol*: a rejected credential points at the field above it, a network failure
points at nothing the user can fix here. The mapping lives on the model (a small `enum
Advice { fixTheKey, tryAgainLater }`), because a rule only a view knows is a rule no test can
hold — `DataSettingsModel.canBackUpNow` records the same reasoning for the same reason.

### §8's disclosure

Inline, above the key field, always visible: no dismissal state, no `hasSeen…` flag, one copy.
§8 asks for this "so the user can re-evaluate if their employer's policy changes", and a modal
shown once on first launch is exactly the surface a policy change cannot bring back.

Every clause below was checked against `StandupPrompt.user`, `ReportGatherer.gather` and
`EventQueries.inWindow` rather than written from memory:

> **What Steno sends to Anthropic.** When a stand-up is polished, Steno sends one project's
> report window: its start and end, and for every task in it — the title, the status, any Jira
> ticket keys, the blocked reason, and every event inside that window — your notes, status
> changes, blocked reasons and when the task was created — each with its timestamp, in the words
> you typed. Notes are sent whole; nothing is shortened or stripped first. Each task also
> carries a random identifier so the model can refer to it.
>
> **What is not sent:** other projects, tasks outside the window, notes you have redacted, and
> anything you have not reported on. Your API key is sent as the request's authorization header
> and is stored only in your login Keychain — never in Steno's data file, its preferences, or
> its logs.
>
> **With no key set, or no model selected, Steno never contacts Anthropic** and builds your
> stand-up from your log alone.

**This describes what ships today, and M4 must amend it.** The prompt's own doc comment already
anticipates `externalUpdate` bodies fetched from Jira and Confluence, which D4 permits sending —
but that is M4-02 and M4-03, and a disclosure that named them now would be false for three
milestones. The spec files for both carry a line saying so, and the risk is listed below.

### The pane

A `Form` in the shape `CaptureSettingsPane` and `DataSettingsPane` already use, four sections:
Provider (the picker, plus the disclosure), API key (`SecureField`, Save, Remove, the stored
caption), Model (picker, Refresh, the "couldn't refresh" note), Connection (Test, and its
result). Every control is disabled while `isBusy`.

**It has no store dependency and therefore no `storeFailureNote`.** Both sibling panes carry one
because a failed store takes their subject away; a credential and a model id live in the Keychain
and `UserDefaults`, so this pane is fully functional in a build whose store will not open. That
is worth a sentence here because its absence otherwise looks like an oversight against two
siblings that have it.

`StenoApp` builds the model once, outside the `store` switch, for the same reason it builds the
others once: the `Settings` scene's content is rebuilt freely by SwiftUI and the state behind it
must not be.

## Verification

`make build && make test && make lint`, then:

**Automated** — `StenoTests/Settings/AISettingsModelTests.swift`, over `StubAIProvider`,
`InMemoryCredentialStore` and a scratch `UserDefaults` suite (§9.4). Every one of these is
mutation-checked before it is trusted: break the line it covers, watch it fail, restore.

1. A save trims surrounding whitespace, stores `.apiKey`, clears `keyEntry`, sets `hasStoredKey`.
2. A save of only whitespace stores nothing and reports nothing stored.
3. A save whose fetch succeeds writes `models[0].id` into the injected `AppSettings`.
4. A save whose fetch succeeds does **not** overwrite an existing selection the list still offers.
5. A save whose fetch succeeds **does** re-point a selection the list no longer offers.
6. A save whose fetch fails with `.network` keeps the key, leaves the selection untouched, and
   lands in `.failed(.network)`.
7. With no fetch and a stored selection, `modelRows` contains exactly that id.
8. A fetched list lacking the stored id keeps it in `modelRows`, still selected.
9. `testConnection()` reaches `.failed(.invalidCredential)` and `.failed(.network)` from the two
   scripted providers, and the two produce different advice.
10. `removeKey()` deletes the credential and leaves `aiSelectedModelID` in place.
11. Two providers: switching `selectedProviderID` routes the next `refreshModels()` to the other
    one (D-160's abstraction, exercised rather than asserted in a comment).

`StenoTests/AI/ModelsSelftestTests.swift`: the success path prints every id and marks element
zero; a thrown `AIError` exits non-zero and prints no key; an absent credential prints the
"no key is stored" instruction. `CLIParserTests` gains `models-selftest` parsing, its refusal of
flags, and an assertion that `CLIUsage.text` does not mention it.

**By hand, by the user** — recorded in the PR body, because agents cannot click this app and
`make test` denies the network:

- `make verify-models` on a signed build: the ranked list prints, sonnet-family first.
- Paste a wrong key → Test connection says the credential was rejected.
- Turn off Wi-Fi → Test connection says the provider could not be reached; Refresh leaves the
  stored model selected and usable.
- Paste a real key → the picker preselects a sonnet model; prepare a stand-up and confirm the
  draft is marked AI-generated.

## The plan document

Written next, by `writing-plans`, against a built tree — every code block generated from code
that compiled, per the standing rule that type-checking a snippet proves syntax and nothing else.

## Out of scope

The other Settings panes (Integrations M4-04, Stale M6-01); subscription sign-in (§7.2 —
API key is the only enabled option); a second provider; caching the model list (D-158); an
on/off switch separate from the key (D-159); key-format validation beyond trimming and refusing
empty — Anthropic's own 401 is the authority, and a client-side prefix check would refuse a
valid key the day the prefix changes.

## Risks

- **The typed key lives in view state until it is saved.** Entry-only (D-157) bounds it to the
  interval between typing and Save, and the field is cleared on success — but a user who types a
  key and leaves Settings open has it in memory. Accepted deliberately by the user, who chose the
  `SecureField` shape over a write-only field.
- **The disclosure goes stale when M4 lands.** It names what is sent today; fetched Jira and
  Confluence text will be sent and must be added to this paragraph by M4-02/M4-03. Recorded in
  `DECISIONS.md` so the amendment has somewhere to point.
- **`make verify-models` spends a real request against the user's key.** One `GET /v1/models`
  per run, which is the cheapest call the API has — but it is not free, and it is a human-run
  target for that reason, never part of `make test`.
- **The offline picker shows one row.** By design (D-158), and it is the acceptance criterion's
  "must not block using a previously selected model" — but it will read as a bug to someone who
  expects a settings pane to be current without being asked. The pane says so in a caption.
