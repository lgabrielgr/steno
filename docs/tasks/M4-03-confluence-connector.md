# M4-03 — Confluence Connector

**Milestone:** M4 — Atlassian
**Depends on:** M4-02
**Blocks:** M4-04
**Requirements:** §5.3, D5, D19
**Branch:** `feat/confluence-connector`

## Goal

A read-only Confluence connector sharing the Atlassian credential — one config, two APIs.

## In scope

- Reuse of the M4-02 credential (§5.3: same credential, different API).
- Fetch per §5.3: page title, last-modified timestamp, last editor, and version delta since
  `since`.
- Handling `SourceRef`s of kind `confluencePage`, extracted by M1-01.
- Caching through M4-01.

## Out of scope

- Credential entry UI — M4-04.
- Any write to Confluence (D5).

## Acceptance criteria

- [ ] Read-only. No mutating request anywhere (D5).
- [ ] A Confluence URL captured during quick-add resolves to a page whose title and last editor
      appear in the report.
- [ ] Version delta since `since` is reported, not just current state.
- [ ] Shares the M4-02 credential — configuring Atlassian once enables both.
- [ ] Token expiry handling from M4-02 applies here too; a `401` gives the same specific message.
- [ ] Degrades to cache on failure without blocking a report (§5.5).

## Notes for the spec/plan phase

- §5.3 warns explicitly: "Jira and Confluence are distinct REST APIs; do not conflate them."
  Shared credential, separate clients. Attempting to reuse the Jira client's endpoint shapes
  will produce confusing failures.
- Everything §5.5 requires of Jira applies identically here — best-effort fetch, cached
  fallback, visible staleness. Reuse M4-01's machinery rather than reimplementing it.
- Confluence refs are likely rarer than Jira ones (D7: nearly all tasks reference a ticket).
  Keep the implementation proportionate.
