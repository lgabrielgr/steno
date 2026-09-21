# M3-01 — AIProvider Protocol & Credential Storage: design

**Date:** 2026-09-21 · **Task:** [`M3-01`](../../tasks/M3-01-ai-provider-protocol.md) ·
**Requirements:** §7.1, §7.2, §7.3, §7.4, §6, §8, §13, D14, D17 ·
**Branch:** `feat/ai-provider-protocol`

## What this builds

The vendor-neutral seam the whole of M3 hangs off: §7.1's `AIProvider` protocol, the value
types that cross it, one neutral error, and a Keychain-backed credential layer. No provider
implementation, no prompt, no UI — M3-02, M3-03 and M3-04 respectively.

**Nothing in this PR is reachable from the running app.** There is no call site, because the
first one arrives with M3-02 and the first *visible* one with M3-04. That is the defining
constraint on how this task is verified, and section "Verification" is mostly about it.

The counterweight is that every interface decided here is one three later tasks bind to
without renegotiation. §14 lists this protocol as deliberately retained and justifies it on
testability alone: it is what lets M3-03's summarization be tested with networking denied
(§9.4). A protocol that leaks a vendor type defeats the only reason it exists.

## What this task decides

Eleven things §7 leaves open. Each gets a `DECISIONS.md` entry, D-129 through D-139.

| Question | Decision |
|---|---|
| What `StandupDraft` carries back | Cadence-tagged neutral bullets; `ReportSection` mapping stays in M3-03 |
| What `StandupRequest` carries in | Prompt **and** schema, built upstream; the provider is transport |
| Whether §7.1's printed signature is copied verbatim | No — `AIProvider: Sendable`, declared as a deviation |
| What the neutral error may carry | Typed cases only; no free-form `String` anywhere in `AIError` |
| Where §7.3's hallucinated-ID rejection runs | On `StandupDraft`, called by the provider, not by M3-03 |
| Which keychain, given CI signs ad-hoc | The login keychain — the data-protection one was probed and breaks CI; §6 is amended |
| How the item is shaped | One generic password per provider; `synchronizable: false`; add-then-update |
| How `KeychainCredentialStore` is covered | Pure query and status-mapping tests; the round trip belongs to the harness |
| What keeps the unreachable `.oauth` case honest | The store serializes the enum; `userSelectable` encodes §7.2's UI rule |
| The §8 logging shape M3-02/M3-03 inherit | One shared emitter, no payload path in the codebase at all |
| How the real Keychain gets executed before M3-04 | `make verify-keychain` + a hidden `keychain-selftest` subcommand |

---

## D-129 — `StandupDraft` is cadence-tagged neutral bullets, not report sections

§7.3 defines two output schemas selected by `project.reportCadence` (D17), and is explicit that
they are not cosmetic variants: the sections differ, and so does the cardinality of the task
reference. `StandupDraft` mirrors that directly.

```swift
public enum StandupDraft: Sendable, Equatable {
    case daily(DailyDraft)
    case periodic(PeriodicDraft)
}

public struct DailyDraft: Sendable, Equatable, Codable {
    public let sinceLastStandup: [DailyBullet]   // since_last_standup
    public let today: [DailyBullet]
    public let blockers: [DailyBullet]
}

public struct PeriodicDraft: Sendable, Equatable, Codable {
    public let completed: [ThemedBullet]
    public let inFlight: [ThemedBullet]          // in_flight
    public let blockersAndRisks: [ThemedBullet]  // blockers_and_risks
}

public struct DailyBullet: Sendable, Equatable, Codable {
    public let taskID: UUID      // task_id
    public let text: String
}

public struct ThemedBullet: Sendable, Equatable, Codable {
    public let taskIDs: [UUID]   // task_ids
    public let text: String
}
```

`CodingKeys` are §7.3's wire names, so the type *is* the contract and M3-02 decodes straight
into it rather than hand-writing a mapping that can drift from the schema it was built to match.

**The rejected alternative was returning `[ReportSection]`** — the type `RawReportSections`
already produces, which would let M3-03 hand the result straight to `SlackMarkdown.render`. It
loses on the layer rule: the provider would then own §7.3's section names and D17's cadence
wording, so prompt knowledge lives in the vendor layer and every future provider re-implements
it. `ReportSection`'s own doc comment already anticipated this split — "M3-03 produces them from
schema-validated AI bullets" — and this is the type those bullets arrive as.

**Also rejected: raw JSON.** Maximum neutrality, but `StandupDraft` stops being a type anyone
can reason about, and §7.3's rejection rule (below, D-133) has nowhere typed to live.

## D-130 — The request carries prompt and schema; the provider knows nothing about stand-ups

```swift
public struct StandupRequest: Sendable, Equatable {
    public let modelID: String
    public let cadence: ReportCadence      // selects the StandupDraft case
    public let systemPrompt: String
    public let userPrompt: String
    public let outputSchema: AIOutputSchema
    public let allowedTaskIDs: Set<UUID>
    public let maxOutputTokens: Int
    public let timeout: Duration
}

public struct AIOutputSchema: Sendable, Equatable {
    public let name: String
    public let json: Data     // a JSON Schema document, authored by M3-03
}
```

M3-02 knows HTTP, auth, retries and error mapping. It does not know what a stand-up is. §7.3's
prompt constraints — never introduce a fact, preserve ticket keys verbatim, do not elevate
register, 8–12 bullets for `periodic` — are M3-03's scope per its own task file, and putting
them behind the seam means a second provider inherits them instead of re-deriving them.

`AIOutputSchema` is opaque bytes rather than a typed `JSONValue` tree because nothing in
M3-01..M3-04 inspects a schema; they transmit it. A tree would be machinery with no reader.

**`timeout` and `maxOutputTokens` get no default value here.** M3-02's task file says the
timeout budget is decided there — "if the API is slow, the user is standing in a meeting" — and
a default in M3-01 would quietly pre-empt that decision.

## D-131 — `AIProvider` is `Sendable`, which §7.1's printed signature is not

```swift
public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func availableModels() async throws -> [AIModel]
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft
    func testConnection() async throws
}

public struct AIModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
}
```

§7.1 and the task file both print the protocol without a conformance, and the task says
"exactly as specified". `SWIFT_VERSION` is 6.0, `generateStandup` is called across an isolation
boundary, and a non-`Sendable` provider cannot be held by the caller that awaits it. This is the
same reasoning `GatheredWindow`'s doc comment already records for why the report layer returns
value types rather than `@Model` rows.

**This is a deviation from a quoted spec and is declared in the PR body**, not absorbed
silently (CLAUDE.md, "When the spec is wrong"). It does not amend REQUIREMENTS.md: §7.1's intent
is about vendor neutrality, and a language-mode conformance does not touch it.

`AIModel` carries id and display name only. No context window, no pricing, no tier — M3-04's
picker renders a list, and M3-02 picks its mid-tier default from the fetched list by its own
rule, not from a field invented here for it.

## D-132 — No case of `AIError` carries a free-form `String`

```swift
public enum AIError: Error, Equatable, Sendable {
    case notConfigured
    case invalidCredential
    case network
    case timedOut
    case rateLimited(retryAfter: Duration?)
    case providerUnavailable(status: Int)
    case invalidResponse(InvalidResponseReason)
    case unknownTaskIDs(count: Int)
}

public enum InvalidResponseReason: Equatable, Sendable {
    case undecodable, schemaViolation, emptyDraft
}
```

The obvious shape is `.invalidResponse(reason: String)`, and the obvious reason string is built
from the model's output — which puts a stand-up's text inside an error that §8's logging path
then prints. Typed reasons make "an `AIError` is always safe to log" a property of the type
rather than a rule each future provider must remember.

`.unknownTaskIDs` carries a **count, not the ids**, for the same reason: what §8 permits logging
is metadata.

`.network` and `.timedOut` are separate because §7.4's fallback says different things to the
user — offline versus the model did not answer in time — and because M3-02's retry policy
applies to one and not the other. `.invalidCredential` is separate from both because M3-02's
acceptance criterion requires `testConnection()` to distinguish an invalid key from a network
failure.

`AIError` conforms to `LocalizedError` so M3-04 has strings to render, and exposes a
`metricsLabel` (`"invalidCredential"`, `"timedOut"`, …) so D-137's logging has a fixed
vocabulary rather than `String(describing:)`, whose output is a refactor away from changing.

**The protocol's doc comment states the contract: an `AIProvider` throws `AIError` and nothing
else.** A `URLError` or `DecodingError` escaping M3-02 is a defect there, and this is the
written thing its tests assert against.

## D-133 — §7.3's hallucinated-ID rejection lives on `StandupDraft`, and the provider calls it

```swift
extension StandupDraft {
    /// Throws `.unknownTaskIDs` if any bullet references an id the app did not send.
    public func validated(against allowed: Set<UUID>) throws -> StandupDraft
}
```

§7.3: "Both schemas must reject a `task_id` the app didn't send — a hallucinated ID is the
clearest possible signal the model invented a fact, and it should fail loudly into the §7.4
fallback rather than render."

This is why `allowedTaskIDs` rides on the request rather than staying in M3-03. Two placements
were possible: M3-03 validates after the call, or the provider validates before returning. The
second wins because the rule then lives in one place and a second provider inherits it, where
the first leaves a future provider free to ship with nothing checking, and no test failing to
say so. The protocol doc says `generateStandup` returns only validated drafts.

`.emptyDraft` is `InvalidResponseReason`'s third case and not a success: a draft with no bullets
in any section means the model returned nothing usable, and §7.4's raw fallback is strictly
better than an empty report.

## D-134 — The login keychain, because the data-protection one breaks CI

**This decision reverses the design's first draft on probe evidence.** §6 names
`kSecAttrAccessibleAfterFirstUnlock`, which on macOS only means anything to the data-protection
keychain (`kSecUseDataProtectionKeychain: true`). Four configurations were probed before any
code was written:

| configuration | result |
|---|---|
| data-protection, ad-hoc signed (CI's shape) | `-34018` errSecMissingEntitlement |
| data-protection, Apple Development identity, no entitlement | `-34018` errSecMissingEntitlement |
| data-protection + `keychain-access-groups`, bare `codesign` | **SIGKILL** — amfid: "no eligible provisioning profiles found" |
| data-protection + entitlement, real app target, `-allowProvisioningUpdates` | works |
| **login keychain, ad-hoc signed** | **PASS** — add 0, read 0, delete 0 |

The fourth row works and is still unusable, for three reasons found by running it:

1. **It breaks the required CI check.** `make build XCFLAGS="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual"` — the workflow's exact signing shape, per D-053 — fails with *"Steno requires a provisioning profile"*. `keychain-access-groups` is a restricted entitlement; a GitHub runner has no certificate and no profile to satisfy it.
2. **`make build` stops working offline.** It needs `-allowProvisioningUpdates`, a network, and a live Apple ID session — against §9.2's requirement that the app be fully buildable from the command line.
3. **The minted profile expires in seven days.** Free Personal Team: created 2026-09-21, expires 2026-09-28. A weekly re-mint is a standing tax on every build, and §6.1 rules out the paid membership that would not fix CI anyway.

So Steno uses the login keychain, and **§6 is amended in this PR** — version bumped to v1.20 with
a changelog entry, per CLAUDE.md's "When the spec is wrong". §6's actual requirement is
unchanged and fully met: keys live in the Keychain and never in SwiftData, `UserDefaults`,
plists, or logs. What is given up is an accessibility attribute whose practical effect on a Mac
that is logged in, with its login keychain unlocked, is nil.

The layering is unchanged from the original design and still carries its own weight:

```swift
public protocol CredentialStore: Sendable {
    func store(_ credential: Credential, for providerID: String) throws
    func credential(for providerID: String) throws -> Credential?
    func delete(for providerID: String) throws
}
```

`KeychainCredentialStore` is the real one; `InMemoryCredentialStore` (in `StenoTests`) backs
every test that needs *a* store rather than *the* store, so nothing in `make test` writes into
the developer's login keychain — the same hygiene §9.4 already requires of `UserDefaults`.

## D-135 — One generic-password item per provider, and no inert attributes

| attribute | value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `com.lgabrielgr.steno.ai` |
| `kSecAttrAccount` | provider id (`anthropic`) |
| `kSecValueData` | JSON-encoded `Credential` |
| `kSecAttrSynchronizable` | `false`, set explicitly |

Account is the provider id, so a second provider is a second item rather than a migration.

**`kSecAttrAccessible` is deliberately absent.** The probe confirmed the login keychain accepts
it and returns `errSecSuccess` — it is accepted and inert. Passing it would leave a line of code
that looks like it enforces §6's accessibility rule and does not, which is this repo's
most-repeated defect shape: a comment or a call asserting a property the code does not have. The
constraint is recorded in the amended §6 and in a doc comment that says the attribute is
*omitted on purpose*, not forgotten.

`synchronizable` is **set**, not defaulted: iCloud Keychain would put the API key on the user's
other machines, and D1/§14 cancelled sync. Leaving it to the platform default would make that a
platform decision rather than ours.

Writes are `SecItemAdd`, falling back to `SecItemUpdate` on `errSecDuplicateItem` — not
delete-then-add, which loses the stored key if the add half fails and leaves the user with an
AI provider that silently stopped working.

`credential(for:)` returns `Credential?` with absence as `nil`: `errSecItemNotFound` is a normal
answer, not a failure, and it is what becomes `AIError.notConfigured` one layer up.

`KeychainError` maps `OSStatus` into typed cases — `.duplicateItem`, `.interactionNotAllowed`,
`.userCancelled`, `.unexpected(OSStatus)` — and deliberately does **not** fold into `AIError`:
credential storage is its own layer with its own owner, and the AI layer's view of it is exactly
two outcomes, a credential or none.

## D-136 — The unreachable `.oauth` case is exercised, and §7.2's UI rule is a value

```swift
public enum Credential: Sendable, Equatable, Codable {
    case apiKey(String)
    case oauth(TokenSet)
}

public struct TokenSet: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
}

public enum CredentialKind: String, Sendable, CaseIterable {
    case apiKey, oauth
    /// What Settings may offer (§7.2). M3-04 renders from this, not from `allCases`.
    public static let userSelectable: [CredentialKind] = [.apiKey]
}
```

§7.2 requires the enum so a subscription flow can be added later without refactoring, and is
equally explicit that no OAuth flow is implemented or reverse-engineered here. The risk is a
case nothing constructs, nothing calls, and nothing tests — which this repo's history says
becomes the next task's bug.

Two things keep it honest. The store serializes the **enum**, not a bare string, so `.oauth`
round-trips through `CredentialStore` under test alongside `.apiKey`; it is exercised code, not
a declaration. And `userSelectable` turns "only `.apiKey` is reachable from the UI" into a value
M3-01 can assert today, a milestone before M3-04's picker exists, rather than a doc comment a
future UI author has to find and honour.

## D-137 — One metrics emitter, and no payload-logging code anywhere

```swift
public struct AIRequestMetrics: Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let latency: Duration
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let outcome: Outcome

    public enum Outcome: Sendable, Equatable {
        case ok
        case failed(label: String)    // AIError.metricsLabel — a fixed vocabulary
    }
}

public enum AIMetricsLog {
    public static func record(_ metrics: AIRequestMetrics)
}
```

§8: log AI request metadata — token counts, latency, model — but never full payloads by
default. The task file says to decide the shape here so M3-02 and M3-03 inherit it.

**One emitter with one call site, rather than a category and a doc comment.** A `Log.ai` logger
plus a written field list makes §8 a convention every future provider must remember, with
nothing failing when one forgets. A single `record` leaves no seam for a provider to invent its
own line through.

**No payload-logging path exists in the codebase at all** — not even behind `#if DEBUG` and a
`UserDefaults` flag. That opt-in is the literal reading of "by default", and it writes a
stand-up's contents to the unified log, where `log show` retrieves them long afterwards. M3-03
can add it if working on §7.3's prompt actually demands it; adding it now is a documented
exception with no current consumer.

`Log.ai` joins `Log.report` in `Support/Logging.swift` in the same house style, carrying the
retrieval recipe with `/usr/bin/log` spelled out — zsh shadows `log` with a builtin.

Every interpolation in the emitted line carries explicit `privacy: .public`. `Logger` redacts
non-literal strings by default, so a model id logged without it arrives as `<private>` and §8's
metadata requirement is silently defeated — the failure mode is invisible in code review and
visible only in `log show`.

## D-138 — `make verify-keychain` is how the real store gets executed before M3-04

`make verify-keychain` runs the built, signed app binary with a hidden `keychain-selftest`
first argument (D-113: a bare first argument is what makes the binary a CLI). It stores a
sentinel under provider id `selftest`, reads it back, deletes it, and prints PASS or FAIL with
the raw `OSStatus`. It is not listed in `--help`.

**This is outside M3-01's stated scope and is declared in the PR body.** The justification is
D-134's consequence: with no automated test touching the real keychain and no Settings UI until
M3-04, there would otherwise be no way — for the user or for an agent — to execute a single
line of `KeychainCredentialStore` in this PR or the two after it. This repo has learned twice
that the unexecuted path is where the defects sit, most recently when running the app found two
faults that eleven review rounds and the whole test suite did not.

`selftest` is a provider id no real provider uses, so the harness cannot overwrite a stored key.
It round-trips **twice** — store, read, store again, read — so the `errSecDuplicateItem` →
`SecItemUpdate` fallback of D-135 is exercised, which is the one sequence D-139's pure tests
cannot reach.

## D-139 — `KeychainCredentialStore` is tested as pure functions, not against a scratch keychain

With the login keychain in play, a genuine round trip inside `make test` became possible: a
throwaway keychain file (`SecKeychainCreate` + `kSecUseKeychain`) was probed and passes
ad-hoc signed, inside the test sandbox. It is still rejected.

It costs five deprecation warnings — `SecKeychainCreate`, `SecKeychainDelete`, `kSecUseKeychain`,
`kSecMatchSearchList` — and one of them is structural rather than local: redirecting the store
at a keychain means `SecKeychain` appears in a **production** initializer signature, so a type
Apple deprecated in 2014 becomes part of `StenoKit`'s public surface in order to serve a test.

Instead the store is split so that what can be tested purely, is:

```swift
enum KeychainQuery {
    static func lookup(providerID: String) -> [String: Any]
    static func insert(_ data: Data, providerID: String) -> [String: Any]
    static func update(_ data: Data) -> [String: Any]
}

extension KeychainError {
    static func from(_ status: OSStatus) -> KeychainError
}
```

Query construction and `OSStatus` mapping are the parts with branches, and both are tested
without `SecItem*` running at all: the tests assert the exact dictionaries — service, account,
`kSecAttrSynchronizable == false`, and that **no** `kSecAttrAccessible` key is present (D-135's
absence is asserted, not merely commented). What is left for D-138's harness is the part that
genuinely needs a keychain: that the calls succeed and that the second store overwrites.

---

## Layout

```
StenoKit/AI/
  AIProvider.swift              protocol (D-131) + the throws-AIError contract
  AIModel.swift
  StandupRequest.swift          + AIOutputSchema (D-130)
  StandupDraft.swift            the enum, bullets, wire CodingKeys, validated(against:) (D-129, D-133)
  AIError.swift                 + InvalidResponseReason, LocalizedError, metricsLabel (D-132)
  AIRequestMetrics.swift        + AIMetricsLog (D-137)
  Credential.swift              Credential, TokenSet, CredentialKind (D-136)
  CredentialStore.swift         protocol (D-134)
  KeychainCredentialStore.swift + KeychainQuery + KeychainError (D-135, D-139)

StenoKit/Support/Logging.swift  Log.ai added
docs/REQUIREMENTS.md            §6 amended, Status -> v1.20, changelog entry (D-134)
StenoKit/CLI/                   keychain-selftest subcommand (D-138)
Makefile                        verify-keychain target

StenoTests/AI/
  StubAIProvider.swift          the §9.4 double
  InMemoryCredentialStore.swift
  …tests
```

`StenoKit/AI/` imports nothing from `Capture/`, `Portability/`, or any future source connector.
§13: `AIProvider` and `SourceConnector` are independent layers; M4 must not reference this one.

## Verification

**The test double** is an `actor StubAIProvider` with `nonisolated let id`/`displayName` — an
actor rather than a lock-guarded class because `Mutex` requires macOS 15 and the deployment
floor is 14 (D2). It records received `StandupRequest`s and returns a scripted `Result` per
method, plus an optional `delay`. Scripting *failure* is its main job, not an afterthought:
M3-02 needs a provider that hangs to test its timeout budget, and M3-03 needs one that throws
each `AIError` case to test §7.4's fallback.

**§8's acceptance criterion is three tests, each with a stated mutation**, run against that
mutation before the PR opens, with the results in the PR body:

| test | the mutation that must turn it red |
|---|---|
| SwiftData schema audit — walk `Schema`'s properties, fail any name matching `key\|token\|secret\|credential` | add `apiKey` to a `@Model` |
| `AppSettings` key audit — the same match over its declared keys, **plus an exact count assertion** | add any new settings key |
| log-line audit — render `AIMetricsLog`'s output and every `AIError.localizedDescription` with a sentinel key planted, assert the sentinel never appears | interpolate the key into the emitted line |

The count assertion in the middle row is what stops that test being vacuous: without it, it
passes forever by matching nothing.

Beyond those: `KeychainQuery`'s three builders are asserted dictionary-for-dictionary, including
that `kSecAttrAccessible` is absent and `kSecAttrSynchronizable` is `false`, and
`KeychainError.from` is a table test over every mapped `OSStatus` (D-139); `Credential`
round-trips through `InMemoryCredentialStore` in **both** cases (D-136); `StandupDraft` decodes from §7.3's literal JSON, keys included; `validated(against:)`
rejects an id the app did not send and accepts one it did, in both cadences; `AIError` is
`Equatable` across every case including associated values.

**Gates:** `make build && make test && make lint`, the three §8 tests against their mutations,
and `make verify-keychain` run by the user on a signed build.

## Out of scope

- **The Anthropic implementation** — M3-02. No vendor type, no `/v1/models` call, no default
  model choice, no timeout value.
- **Prompts and schemas** — M3-03. `AIOutputSchema` is a carrier here and stays empty.
- **Settings UI** — M3-04. `CredentialKind.userSelectable` is the only thing this task says
  about it.
- **Any OAuth flow** — §7.2. The enum case exists; nothing constructs it outside tests.
- **Wiring `AIMetricsLog` to a call site.** Nothing calls `generateStandup` until M3-02.

## Risks

1. **§6's amendment is a real reduction in stated posture**, not a clarification. The probe
   evidence is in D-134 and the amendment says plainly what was given up and why, so a future
   reader meets a decision rather than a silent omission. If Steno is ever distributed — §6.1
   says it will not be — this is the line to revisit.
2. **`AIOutputSchema` as opaque `Data` defers all schema validation to M3-02/M3-03.** Accepted:
   nothing here can validate a schema it does not author, and `StandupDraft`'s decode is the
   real gate.
3. **`.oauth` still has no production constructor.** Accepted per §7.2 and §14, bounded by
   D-136's two mitigations.
