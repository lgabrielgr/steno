# M1-01 — Passive Reference Extraction

**Milestone:** M1 — Capture
**Depends on:** M0-05
**Blocks:** M1-02
**Requirements:** FR-1.5, §3.4, D7
**Branch:** `feat/reference-extraction`

## Goal

A pure, dependency-free function that scans text and returns `SourceRef`s — no UI, no store,
no network.

## Why this is first in M1

It is the only part of capture that is fully testable headless, and M1-02 consumes it. Building
it first means the capture path is assembled from an already-verified piece.

## In scope

- Jira keys via the exact regex from FR-1.5: `\b[A-Z][A-Z0-9]{1,9}-\d+\b`
- Confluence page URLs, GitHub PR URLs, bare URLs.
- Mapping each match to a `SourceRef` with the right `kind` and `identifier`.
- Applying M0-03's dedup rule so the same key found twice yields one ref.
- Table-driven unit tests.

## Out of scope

- Fetching anything. This task extracts references; M4 resolves them.
- Project auto-routing from a matched key — M1-02 owns that.
- Any command grammar. See the note below.

## Acceptance criteria

- [ ] Extraction is a pure function: same input, same output, no I/O, no store access.
- [ ] Tests cover, at minimum: a bare key (`PAY-421`), a key inside a sentence, multiple keys
      in one line, a key at string start and end, a lowercase key (must **not** match), a
      hyphenated non-key word, a bare URL, a GitHub PR URL, a Confluence URL, a URL that also
      contains a Jira key, and the same key twice (yielding one ref).
- [ ] Runs headless with networking disabled.

## Notes for the spec/plan phase

- **No special syntax, ever.** FR-1.5 records that the user *explicitly declined* a
  natural-language command grammar — no `@project`, no `#tag`. Extraction is passive and
  silent. A proposal to add "just a little" syntax is a proposal to reintroduce the schema that
  made the paper notebook faster, and should be declined with reference to §1.1.
- The regex is given verbatim in FR-1.5. Use it as written. If it proves wrong in practice, say
  so in the PR body rather than silently improving it (§9.5).
- This runs on the capture path, which is latency-critical (§1.1, §13). It must be fast enough
  to run on save without being noticeable. Measure rather than assume.
- Extraction also runs on note bodies (FR-1.5 says "task title and note bodies"), so M1-06 will
  call this too. Keep the interface free of any assumption that the input is a title.