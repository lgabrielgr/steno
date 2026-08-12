# M3-02 — Anthropic Provider

**Milestone:** M3 — AI summarization
**Depends on:** M3-01
**Blocks:** M3-03
**Requirements:** §7.1, D14, §8
**Branch:** `feat/anthropic-provider`

## Goal

`AnthropicProvider` conforming to `AIProvider`, with a **runtime-fetched** model list.

## In scope

- API client using the stored API key.
- `availableModels()` fetching from the Anthropic `/v1/models` endpoint — **not hardcoded**
  (§7.1).
- `testConnection()`.
- Error mapping into the neutral error type from M3-01 — no vendor enums escaping.
- Retry/timeout behavior appropriate to a call made while the user is about to walk into a
  stand-up.

## Out of scope

- Prompt construction and output schemas — M3-03.
- Settings UI — M3-04.
- Streaming. Nothing in §7 needs it; a stand-up draft is short and appears at once.

## Acceptance criteria

- [ ] The model list is fetched at runtime. Confirm no model ID is compiled in as the source of
      the picker's contents (§7.1: "model IDs change; the app shouldn't need a release to
      expose a new model").
- [ ] `testConnection()` distinguishes an invalid key from a network failure — the user needs to
      know which.
- [ ] All Anthropic types stay inside this file/module. Callers see only M3-01's neutral types.
- [ ] `make test` passes with networking disabled, using the M3-01 test double.
- [ ] Logs contain metadata only — token counts, latency, model — never full payloads (§8).

## Notes for the spec/plan phase

- **Default model: mid-tier.** §7.1 is explicit that this is not a reasoning-heavy workload —
  it is summarization of a factual log — and that cost per stand-up should stay negligible.
  Resist defaulting to the largest model.
- Consult the `claude-api` skill for current model IDs, pricing, and the structured-output
  mechanism rather than relying on recall. Model IDs in particular go stale.
- Timeouts matter more than usual here. If the API is slow, the user is standing in a meeting;
  §7.4's fallback must engage promptly rather than after a long hang. Decide the budget in this
  task, since M3-03 wires the fallback.
