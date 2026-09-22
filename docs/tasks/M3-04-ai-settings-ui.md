# M3-04 — AI Settings UI

**Milestone:** M3 — AI summarization
**Depends on:** M3-03
**Blocks:** M3 exit criterion
**Requirements:** FR-6, §7.1, §7.2, §8
**Branch:** `feat/ai-settings-ui`

## Goal

The Settings surface for the AI layer: provider picker, Keychain-backed key field, runtime
model picker, and a working "Test connection".

## In scope

- Provider picker (only Anthropic ships, but the picker reflects §7.1's abstraction).
- API key field, stored via M3-01's Keychain layer, never echoed back in full.
- Model picker populated at runtime from `availableModels()` (§7.1).
- "Test connection" surfacing a clear result.
- The §8 onboarding disclosure: state plainly which content is transmitted to the AI provider.

## Out of scope

- Other Settings panes: Integrations (M4-04), Capture, Stale threshold (M6-01), Data (M2.5).
- Subscription sign-in. §7.2: surface API key as the **only enabled option** in Settings v1.

## Acceptance criteria

- [ ] A key entered here is usable by M3-03 and is stored only in Keychain (§8).
- [ ] The model picker is populated from the network, and degrades gracefully when offline —
      an unreachable model list must not block using a previously selected model.
- [ ] "Test connection" distinguishes an invalid key from a network failure.
- [ ] The key is never displayed in full after entry and never appears in logs.
- [ ] The data-transmission disclosure is present and specific.

## Notes for the spec/plan phase

- §8 requires onboarding to state plainly what is sent to the AI provider "so the user can
  re-evaluate if their employer's policy changes." D4 permits sending Jira/Confluence content
  and requires no redaction layer in v1 — but that permission is only meaningful if the user
  can see what the policy is. Write it concretely, not as boilerplate.
- Everything here must degrade. §7.4's guarantee is that the app produces a report with no key
  configured at all, so Settings must never present the AI as required.
- Keep this pane small. The product is a recall tool; configuration is not where its value is.
- **Add `make verify-models`, the network twin of `make verify-keychain`** (filed from M3-02,
  PR #35). D-138 set the precedent: what `make test` cannot reach gets a hidden CLI subcommand
  and a `make` target, so a human can run it on a signed build. M3-02 left two things in exactly
  that position and added no such target:
  - **`URLSessionTransport` has no test at all** (D-143). Its only untested behaviour is
    "Foundation does what Foundation does", so a `URLProtocol` harness was judged not worth its
    cost — but that leaves the real adapter first executed by a human in this task.
  - **`/v1/models` was confirmed by hand on 2026-09-22 — shape, paging and all.** `has_more`,
    `last_id`, the three `data[]` fields, the `structured_outputs` nesting, `limit=1000`, and
    `after_id` advancing the window are each verified against the live API. What a one-off check
    cannot cover is drift: a renamed field a year from now fails silently, and the paging loop's
    guards turn that into a short list rather than an error (duplicates are handled — the ranking
    dedupes by id). A repeatable target is the point.

  A `models-selftest` subcommand that reads the stored key, calls `availableModels()`, and prints
  the ranked list closes both: it exercises the real transport end to end and prints enough to
  check D-141's ordering against what the API actually returns. Model it on
  `KeychainSelftest` — hidden from `CLIUsage.text`, handled before the store opens.

  **Until it exists, the check is manual:**

  ```
  curl -s "https://api.anthropic.com/v1/models?limit=3" \
    -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
    | jq '{has_more, last_id, first: .data[0]}'
  ```
