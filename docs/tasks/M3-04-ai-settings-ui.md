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
