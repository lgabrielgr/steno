# M4-04 — Integrations Settings UI

**Milestone:** M4 — Atlassian
**Depends on:** M4-03
**Blocks:** M4-05
**Requirements:** FR-6, §5.2, §8
**Branch:** `feat/integrations-settings-ui`

## Goal

The Settings pane for Atlassian: site URL, email, API token, expiry date, per-integration
enable toggle, and connection test.

## In scope

- Fields: Atlassian site URL, email, API token, and the user-entered token expiry date (§5.2).
- Token stored in Keychain (§8); the expiry date is not a secret and can live elsewhere.
- Per-integration enable toggle and connection test (FR-6).
- The 14-day expiry warning surfaced here as well as wherever a fetch fails.
- Onboarding note that Atlassian credentials must be read-scoped (§8).
- **"Purge cached external data"** — the remaining half of FR-6's Data area, which belongs here
  because the cache it clears is M4-01's. Purging must not delete tasks, events, or refs, only
  `cachedSummary` and `lastFetchedAt`.

## Out of scope

- MCP server management — M5-02, though FR-6 groups them in the same pane.
- Connector logic — M4-02, M4-03.

## Acceptance criteria

- [ ] Credentials entered here reach the connectors and are stored in Keychain only (§8).
- [ ] The token is never displayed in full after entry and never appears in logs.
- [ ] "Test connection" distinguishes bad credentials, an expired token, a wrong site URL, and a
      network failure. A single generic failure message is not acceptable (§5.2).
- [ ] Disabling an integration stops its fetches without deleting its credential.
- [ ] The expiry warning appears at 14 days and does not nag before that.
- [ ] Documentation in-app states that credentials must be read-scoped (§8).

## Notes for the spec/plan phase

- The specificity of error messages is the point of this pane. §5.2 forbids a generic network
  error on `401`, and the same reasoning applies to every failure the user can actually fix —
  a wrong site URL and an expired token need different words.
- §5.2's org-policy caveat is worth surfacing here: if an admin has blocked API token creation
  via authentication policy, no in-app workaround exists and the user needs an admin
  conversation. Better said in Settings than discovered during stand-up prep.
- Keep the read-only scoping visible. D5 makes it permanent, and the user should be able to
  confirm at a glance that the app cannot touch team tickets.
