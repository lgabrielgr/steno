# M3-01 — AIProvider Protocol & Credential Storage

**Milestone:** M3 — AI summarization
**Depends on:** M2.5-05
**Blocks:** M3-02
**Requirements:** §7.1, §7.2, §8, D14
**Branch:** `feat/ai-provider-protocol`

## Goal

The vendor-neutral `AIProvider` protocol and a credential layer backed by Keychain — with no
Anthropic types anywhere in the abstraction.

## In scope

- The §7.1 protocol, exactly as specified:

```swift
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }

    func availableModels() async throws -> [AIModel]
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft
    func testConnection() async throws
}
```

- Supporting vendor-neutral types: `AIModel`, `StandupRequest`, `StandupDraft`, and a neutral
  error type.
- Credential enum `.apiKey(String)` / `.oauth(TokenSet)` per §7.2, with only `.apiKey` enabled.
- Keychain storage using `kSecAttrAccessibleAfterFirstUnlock` (§6).
- A test double implementing the protocol, for §9.4.

## Out of scope

- The Anthropic implementation — M3-02.
- Prompt and schemas — M3-03.
- Settings UI — M3-04.
- Any OAuth flow. See the note below.

## Acceptance criteria

- [ ] **No Anthropic-specific type appears in any protocol signature** (§7.1) — no message-block
      shapes, no vendor error enums leaking into calling code.
- [ ] API keys are written to Keychain only. A test asserts they never reach SwiftData,
      `UserDefaults`, plists, or logs (§8).
- [ ] The credential enum has both cases; only `.apiKey` is reachable from the UI.
- [ ] The test double satisfies the protocol and lets `make test` pass with networking disabled.

## Notes for the spec/plan phase

- **Do not attempt subscription sign-in.** §7.2 is explicit: there is no publicly documented
  OAuth flow permitting a third-party app to consume a Claude.ai consumer subscription, and
  reverse-engineering unofficial auth flows is out of bounds. The enum exists so the option can
  be added later without a refactor — that is all it is for.
- §14 lists this protocol as deliberately retained and not to be stripped, justified on
  testability grounds alone: it is what lets M3-03 be tested without a network.
- §13: `AIProvider` and `SourceConnector` are independent layers. Nothing here may reference an
  integration, and M4 must not reference this.
- §8 requires logging AI request *metadata* — token counts, latency, model — but never full
  payloads by default. Decide the logging shape here so M3-02 and M3-03 inherit it.
