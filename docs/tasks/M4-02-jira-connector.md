# M4-02 — Jira Connector

**Milestone:** M4 — Atlassian
**Depends on:** M4-01
**Blocks:** M4-03
**Requirements:** §5.2, D5, D19, §8
**Branch:** `feat/jira-connector`

## Goal

A read-only Jira connector against Atlassian Cloud REST v3, with token expiry handled as the
scheduled certainty it is.

## In scope

- Atlassian Cloud only (D19) — REST API v3, `*.atlassian.net`.
- Auth: email + API token over HTTP Basic, **read-only scopes**.
- Endpoints per §5.2: issue detail, issue changelog, issue comments.
- Fetch on `since`: status transitions, new comments, assignee changes, linked PR references.
- Caching `cachedSummary` through M4-01.
- **Token expiry handling**, all three parts of §5.2:
  - Store the user-entered expiry date alongside the token.
  - Warn in-app 14 days before expiry.
  - On `401`, show "your Atlassian token expired — create a new one" with a direct link.

## Out of scope

- Confluence — M4-03, though it shares the credential.
- Credential entry UI — M4-04.
- **Any write to Jira.** See below.
- Data Center compatibility. D19 locks this to Cloud; §5.2 says do not write that code.

## Acceptance criteria

- [ ] **The connector is read-only, permanently** (D5). No code path issues a POST, PUT, or
      DELETE against Jira. Assert it, do not merely intend it.
- [ ] A `401` produces the specific expiry message with a link — **never a generic network
      error** (§5.2).
- [ ] Expiry within 14 days produces an in-app warning.
- [ ] A fetch failure degrades to cached data and does not block a report (§5.5).
- [ ] Ticket detail appears in a generated report — the M4 exit criterion.
- [ ] `make test` passes with networking disabled, against recorded fixtures.

## Notes for the spec/plan phase

- **Token expiry is not an edge case.** §5.2: Atlassian Cloud tokens created since December
  2024 expire, maximum lifetime one year, set at creation. It is "a scheduled, guaranteed
  failure." And "a silent 401 during stand-up prep is the worst possible time to debug auth" —
  which is exactly when it will happen, since that is when the app fetches.
- **D5 is permanent, not a v1 limitation.** The app must never mutate team tickets. This also
  makes open question Q(M4) — auto-transitioning a task when its Jira ticket closes — a
  read-side question only; it is unresolved, so do not implement it.
- Org policy caveat (§5.2): enforced SAML SSO does *not* break API tokens, but an org admin can
  separately block token creation via authentication policy. If that is the case, nothing in
  the app can work around it and the user needs an admin conversation.
- Jira and Confluence are distinct REST APIs on one credential (§5.3). Do not conflate them.
