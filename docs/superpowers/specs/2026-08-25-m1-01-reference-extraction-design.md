# M1-01 — Passive Reference Extraction — Design

**Task:** [`docs/tasks/M1-01-reference-extraction.md`](../../tasks/M1-01-reference-extraction.md)
**Requirements:** [FR-1.5](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[§3.4](../../REQUIREMENTS.md#34-sourceref),
[§1.1](../../REQUIREMENTS.md#1-problem-statement),
[§9.4](../../REQUIREMENTS.md#94-test-constraints),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents),
[D7](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/reference-extraction`
**Date:** 2026-08-25

## Goal

A pure function that scans text and returns the external references it mentions. No UI, no
store, no network, no clock. M1-02 calls it on a task title; M1-06 calls the same entry point on
a note body.

---

## 1. The interface

Extraction returns a **value type**, not `SourceRef`.

```swift
public struct ExtractedRef: Hashable, Sendable {
    public let kind: SourceRefKind
    public let identifier: String
    public let url: String?
}

public enum ReferenceExtractor {
    public static func extract(from text: String) -> [ExtractedRef]
}

extension ExtractedRef {
    public func sourceRef(taskID: UUID) -> SourceRef
}
```

`SourceRef` is a SwiftData `@Model` that requires a `taskID` at init, and on the capture path
the task does not exist yet when its title is scanned. Returning `ExtractedRef` keeps the
function `Sendable`, keeps it testable against literal arrays with no container, and leaves the
`@Model` allocation to the caller that already knows the task. The adapter is one initializer
call, so nothing is duplicated by having both.

This is a small deviation from the task file's "mapping each match to a `SourceRef`". It changes
where the mapping happens, not whether it happens.

The parameter is `from text: String`, carrying no assumption that the input is a title — the
task file requires this because M1-06 calls the same function for note bodies.

### 1.1 The units

| File | Responsibility | Tested against |
|---|---|---|
| `StenoKit/Capture/ExtractedRef.swift` | The value type and the `sourceRef(taskID:)` adapter | Literal values |
| `StenoKit/Capture/SourceURLClassifier.swift` | One `URL` → `(kind, identifier)` by path shape | Literal `URL`s |
| `StenoKit/Capture/ReferenceExtractor.swift` | Scan, overlap-filter, merge, order | Literal strings |

`StenoKit/Capture/` is where ARCHITECTURE §5 already reserves this work. The classifier is split
out because it holds the densest rules in the task and is worth testing without constructing
input strings around it.

---

## 2. The pipeline

### 2.1 Link spans come first

A cached `static let` `NSDataDetector(types: .link)`. Verified under Swift 6 strict concurrency:
`NSDataDetector` and `NSRegularExpression` are `Sendable` in the macOS SDK, so the static needs
no `nonisolated(unsafe)` and no actor isolation.

Only `http` and `https` links survive. The detector synthesizes a `mailto:` link from a bare
email address — verified: `"mail me at bob@example.com"` yields `mailto:bob@example.com` — and an
email address is not a `SourceRef`.

The detector normalizes a scheme-less match, so `github.com/acme/api/pull/421` arrives as
`http://github.com/acme/api/pull/421` and still classifies correctly. It also excludes trailing
punctuation from the span: `"see https://example.com/a/b."` yields the URL without the period,
and a URL inside parentheses or before a comma is matched cleanly. All verified.

### 2.2 Each span is classified by path shape, not by hostname

| Shape | `kind` | `identifier` |
|---|---|---|
| `…/browse/<KEY>`, `<KEY>` matching FR-1.5's pattern in full | `.jiraIssue` | the key, e.g. `PAY-421`; `url` set to the link |
| `…/wiki/…/pages/<digits>/…`, `…/pages/<digits>`, or `?pageId=<digits>` | `.confluencePage` | the digits |
| host `github.com` (or `www.github.com`), path `/<owner>/<repo>/pull/<n>` | `.githubPR` | `<owner>/<repo>#<n>` |
| anything else | `.url` | the detector's normalized `absoluteString` |

**Every ref derived from a link span carries that link in `url`**, including the `.url` kind,
where `identifier` and `url` hold the same string. Only a ref from a bare Jira key in prose has
`url == nil` — it is a reference to a ticket, not to a page, and §2.3's overlap rule guarantees
no link was available to attach.

Host-agnostic on purpose. A self-hosted `jira.corp.net/browse/PAY-421` is as much a Jira issue
as `acme.atlassian.net/browse/PAY-421`, and the extractor cannot read configuration without
ceasing to be pure. GitHub is the single host check, because `/<a>/<b>/pull/<n>` alone is too
generic to claim.

Trailing segments on a PR URL — `/files`, `/commits`, a `#discussion_r…` fragment — do not change
the identifier, so a PR linked twice at different depths dedups to one ref.

A Confluence URL with **no numeric page ID** (the legacy `/display/SPACE/Title` form) falls back
to `.url`. §3.4 says the identifier *is* the page ID, and M4-03 needs one to fetch; inventing a
substitute would put a value in that field no connector can use.

### 2.3 Jira keys are read from the text outside those spans

FR-1.5's pattern, verbatim, as a compile-time-checked `Regex` literal:

```swift
/\b[A-Z][A-Z0-9]{1,9}-\d+\b/
```

A literal rather than `NSRegularExpression` because `make lint --strict` opts into
`force_unwrapping` and enables `force_try` by default, so `try!` on a known-good pattern is a
build failure. `Regex` is **not** `Sendable` (verified — it cannot be a `static let` under Swift
6), so the literal is a computed property, constructed per call. Measured cost of that choice:
91 µs per extraction versus 44 µs for a cached `NSRegularExpression`. Both are noise against
§1.1's three-second budget, and the literal is the one that cannot ship a malformed pattern.

Any key whose range overlaps an `http(s)` span is discarded. That single rule produces every
overlap behaviour the task asks for:

```
"Fixed PAY-421, see https://acme.atlassian.net/browse/PAY-421"
  → jiraIssue "PAY-421", url = the browse URL                        (1 ref)

"https://github.com/acme/api/tree/PAY-421-fix"
  → url "https://github.com/acme/api/tree/PAY-421-fix"               (1 ref)

"See https://ex.com/reports/AWS-2024/q3"
  → url only — no phantom "AWS-2024" ticket                          (1 ref)
```

The third line is why the rule is worth having. Slugs, path segments, and query values are full
of things shaped like ticket keys, and a ref card for a ticket that does not exist is a lie the
user has to read past at stand-up.

---

## 3. Order and deduplication

**Order is first occurrence in the text** — keys and URLs interleaved by offset, not keys first
and URLs after. Deterministic, and it matches the order the user typed them.

**Dedup within one pass is on `(kind, identifier)`** — §3.4's `DedupKey` minus the `taskID`,
which is constant across a single call. The first occurrence sets the position; `url` is filled
from the first occurrence that has one:

```
"PAY-421 — see https://acme.atlassian.net/browse/PAY-421"
  → jiraIssue "PAY-421", url = the browse URL                        (1 ref)
```

Keeping the first occurrence wholesale would discard that URL, and the ref would arrive at M4
with nothing to fetch.

**Dedup across saves is not this task's job.** M0-03 already built `SourceRef.newRefs(from:existing:)`
for it, and M1-02 calls it. This function has no way to know what is already stored, and
acquiring one would cost it its purity.

---

## 4. Failure modes

There is no I/O, so there is nothing to degrade *to* — but there is one failure worth designing.
The detector is built with `try?`; if it were ever nil, `extract` still returns Jira-key refs,
because the regex path does not depend on the detector. Losing URL detection should not also
cost the user their ticket references. A test asserts the detector is non-nil, so a silent total
failure cannot ship.

No input length cap. Cost is linear in length and stays far inside the budget: measured against
the finished implementation, a realistic capture string is **91 µs** and a ~7 KB note body is
**1.9 ms** — three orders of magnitude under §1.1's three seconds, on the slowest input this
product can produce. A cap is a silent data-loss rule that would need a justification this task
does not have.

---

## 5. Test plan

Table-driven `@Test(arguments:)` over `(input, expected [ExtractedRef])`, asserting the full
array so that order and `url` are covered rather than just membership.

The eleven rows the task file requires:

| Case | Expectation |
|---|---|
| Bare key `PAY-421` | one `.jiraIssue` |
| Key inside a sentence | one `.jiraIssue` |
| Multiple keys on one line | one ref each, in text order |
| Key at string start, key at string end | both match — `\b` holds at both boundaries |
| Lowercase `pay-421` | no match |
| Hyphenated non-key word (`well-known`) | no match |
| Bare URL | one `.url` |
| GitHub PR URL | one `.githubPR`, identifier `acme/api#421` |
| Confluence URL | one `.confluencePage`, identifier is the page ID |
| URL that also contains a Jira key | per §2.3 — browse URL yields one `.jiraIssue` |
| Same key twice | one ref |

Plus the cases the design probes turned up, each guarding a specific decision:

| Case | Guards |
|---|---|
| `bob@example.com` in the text | the `mailto:` filter — no ref |
| `github.com/acme/api/pull/421`, no scheme | scheme normalization still classifies as `.githubPR` |
| `acme/api#421` and `acme/web#421` in one input | **two** refs — this is the test that fails under §3.4's pre-v1.10 wording |
| Bare key followed by its browse URL | one ref, `url` populated — the merge rule in §3 |
| `?pageId=` form and `/display/` form | both Confluence shapes; `/display/` falls back to `.url` |
| PR URL with `/files` and a fragment | same identifier as the plain PR URL |
| `ABCDEFGHIJ-9` (10-char prefix) and an 11-char prefix | the regex's upper bound, matched and not matched |
| Empty string, whitespace-only string | `[]` |

**Performance.** An `XCTestCase` using `measure` — the one exception D-011 reserves, since Swift
Testing has no equivalent and §1.1's budget must be measured rather than assumed. Its PR body
note is D-011's required justification. Two cases, each asserting a ceiling with roughly an
order of magnitude of headroom over the measured value, so it catches a real regression without
flaking on a shared runner:

| Input | Measured | Asserted ceiling |
|---|---|---|
| Realistic capture string | 91 µs | 1 ms |
| ~7 KB note body | 1.9 ms | 20 ms |

The measured numbers go in the PR body per §13, and M1-02 inherits the harness for its own
latency claim.

All of it runs headless with networking denied; the function makes no calls that a sandbox could
block.

---

## 6. What this lands beyond code

- **`REQUIREMENTS.md` §3.4 amended to v1.10** (done on this branch): "PR number" was not a
  viable identifier, because the same section makes a ref unique per `(taskID, kind, identifier)`
  — two PRs numbered 421 in different repositories collapse into one row and the second reference
  is silently dropped. The column now requires uniqueness within a kind and specifies GitHub's
  identifier as repo-qualified. Pointer recorded as **D-022**.
- **`ARCHITECTURE.md` §5**: mark `Capture/` as existing.
- **`docs/tasks/README.md`**: tick the M1-01 row. M0-05's row was already ticked by PR #10, so
  there is no outstanding checkbox to carry.

---

## 7. For the PR body: FR-1.5's regex has false positives

Verified, not theorized. `\b[A-Z][A-Z0-9]{1,9}-\d+\b` matches all four of these:

```
"UTF-8 and COVID-19 and ISO-8601 and M1-01"
  → UTF-8, COVID-19, ISO-8601, M1-01
```

Per the task file the regex is used **verbatim, with no stoplist**, and reported rather than
silently improved. The blast radius is genuinely small, which is why this is a note and not a
blocker:

- A phantom key produces a stray `SourceRef` card. It cannot misroute a task, because FR-1.4's
  auto-routing fires only when the prefix matches a configured `Project.jiraProjectKeys` entry.
- M4's fetch for a non-existent issue fails and degrades to cache per §5.5.

Worth a decision later — a stoplist, or requiring the prefix to match a configured project key
before creating a `.jiraIssue` ref. Both are behaviour changes that belong to a task that owns
the tradeoff, not to a "while I was in there" edit in M1-01.

---

## 8. Out of scope

- **Fetching anything.** M4 resolves refs; this task only finds them.
- **Project auto-routing from a matched key.** FR-1.4's rule is M1-02's.
- **Any command grammar.** FR-1.5 records that the user explicitly declined one — no `@project`,
  no `#tag`. Extraction is passive and silent. A proposal to add "just a little" syntax is a
  proposal to reintroduce the schema that made the paper notebook faster (§1.1).
- **Cross-save dedup and persistence.** `SourceRef.newRefs` exists; M1-02 calls it.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| `NSDataDetector` behaviour changes across macOS releases | Its behaviour is pinned by the table-driven tests, so a change surfaces as a test failure rather than as odd refs |
| Shape-based classification misreads an unrelated site's `/browse/…` path | Produces one wrong ref kind on one task; the URL is still captured and the user can see what it points at |
| Per-call `Regex` construction shows up in a future hot loop | Measured and asserted by the `measure` test; if extraction ever moves somewhere hotter, the cached `NSRegularExpression` variant is a drop-in at 44 µs |
