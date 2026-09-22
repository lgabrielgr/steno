# M3-02 — Anthropic Provider: design

**Date:** 2026-09-22 · **Task:** [`M3-02`](../../tasks/M3-02-anthropic-provider.md) ·
**Requirements:** §7.1, §7.3, §7.4, §8, §9.4, §13, D14 ·
**Branch:** `feat/anthropic-provider`

## What this builds

The first implementation behind M3-01's seam, and the first network code in the app: an
`AnthropicProvider` that fetches its model list at runtime, sends one `POST /v1/messages`, maps
every vendor failure onto `AIError`, and returns a `StandupDraft` that has already been
validated against the ids the app sent.

It is transport and nothing else. The prompt, the schema and §7.4's fallback are M3-03's; the
picker and the key field are M3-04's. This task supplies the timeout budget M3-03 wires the
fallback to, and the ordered model list M3-04 renders.

**Nothing here is reachable from the running app either.** M3-01 had no call site because the
provider did not exist; M3-02 has none because nothing calls `generateStandup` until M3-03.
The difference is that this task's code talks to a real service over a network that `make test`
denies (§9.4, D-012), so the verification story is about the transport seam rather than about
mutation-tested audits.

## What this task decides

Seven things §7.1 leaves open. Each gets a `DECISIONS.md` entry, D-140 through D-146.

| Question | Decision |
|---|---|
| How a mid-tier default is chosen without compiling in a model ID | Family-word ranking over the fetched list; the list is returned *ordered* and its first element is the default |
| What the request body carries, when the user picks the model | The minimal body — no `thinking`, no `effort`, no sampling parameters |
| How a network provider is tested with networking denied | An injected `HTTPTransport` over plain value types; the `URLSession` adapter is the uncovered seam |
| Where 4xx, refusal and truncation land | `AIError.invalidRequest`, `.invalidResponse(.refused)`, `.invalidResponse(.truncated)` — an extension of D-132, not a spec amendment |
| The timeout budget, since §7.4's fallback waits on it | 20s for a draft, 10s for the two Settings calls, wall clock covering retries |
| How that budget is actually enforced | A racing deadline with cancellation; `URLError.cancelled` maps to `.timedOut`, never `.network` |
| Which calls emit §8's metrics line | `generateStandup` only |

**No REQUIREMENTS.md amendment.** The error vocabulary this task extends is `AIError`, which
REQUIREMENTS.md never names — §7.1 prints the protocol, and D-132 decided the error type. The
`availableModels()` ordering contract is likewise a doc-comment addition to a signature §7.1
prints unchanged. If review disagrees that these stay below the spec line, the fix is a §7.1
amendment in this same PR, not a silent divergence (CLAUDE.md).

---

## D-140 — The model list is returned ordered, and the first element is the default

§7.1 sets two rules that pull against each other. The list "must be fetched at runtime via the
Anthropic `/v1/models` endpoint, not hardcoded", and the default selection should be "a
mid-tier model … this is not a reasoning-heavy workload, and cost per stand-up should stay
negligible." The wire response carries `id`, `display_name`, `created_at`, `max_input_tokens`,
`max_tokens` and a `capabilities` tree. It carries no tier and no pricing, so nothing in the
response distinguishes mid-tier from top-tier.

**The provider ranks the fetched list by family word and returns it in that order.**
`availableModels()` gains a documented contract: the result is ordered by the provider's own
preference, and element zero is what a caller should select when the user has expressed no
choice.

```swift
/// §7.1: fetched at runtime, never hardcoded, so a new model needs no release.
///
/// **Ordered.** Element zero is the provider's recommended default …
func availableModels() async throws -> [AIModel]
```

Ranking is `(familyRank, createdAt descending, id ascending)`, where `familyRank` is 0 for an id
containing `sonnet`, 1 for `haiku`, and 2 for everything else. The `id ascending` tiebreak
exists so the order is total and the test is not at the mercy of two models sharing a timestamp.

This satisfies the acceptance criterion literally — no model ID is compiled in as the source of
the picker's contents, and `claude-sonnet-6` is preferred the day it appears without a release.
What *is* compiled in is a preference among family words, which is the honest description of
what §7.1 is asking for: it names a tier, and the tier is not on the wire.

Haiku ranks above the rest rather than below, because the fallback from "no sonnet exists" should
move toward §7.1's cost sentence, not away from it. Summarizing a factual log is the workload
Haiku is for.

**Models that cannot do the job are dropped**, and only those: a model whose
`capabilities.structured_outputs.supported` is present and explicitly `false` is filtered out,
because §7.3 requires a schema-constrained response and such a model would fail every draft with
a 400. A missing or unrecognised `capabilities` shape filters nothing — a vendor response that
grows a field must not empty the user's picker.

**Ranking runs on the wire records, not on `AIModel`.** `AIModel` is two fields by D-129's
reasoning and carries no `created_at`, and sorting ids as strings puts `claude-sonnet-10` below
`claude-sonnet-5`. So `ModelRanking.ordered(_:)` takes `[AnthropicModel]` — the wire record —
and returns `[AIModel]`; it is a pure function and the recency rule is tested with an input order
that disagrees with the expected order.

**Paging.** `/v1/models` uses the `after_id`/`before_id` cursor scheme and returns
`has_more`/`first_id`/`last_id`. The provider requests `?limit=1000` and, while `has_more` is
true, re-requests with `after_id=<last_id>`, accumulating. If the endpoint caps `limit` below
what was asked, the only consequence is more iterations of the same loop. A page that reports
`has_more: true` with no `last_id` terminates the loop rather than spinning.

**Rejected: a preferred-ID hint list** (`["claude-sonnet-5", …]`, first match wins). Precise
today, stale on exactly the schedule §7.1 warns about, and a reviewer reading
`claude-sonnet-5` in the source cannot tell from the line whether it is a hint or the picker's
contents. **Rejected: ranking on `max_input_tokens`/`capabilities`** — data-driven but
meaningless, since the current models nearly all report 1M/128K, which makes the "middle" one
arbitrary. **Rejected: no default at all** — it implements §7.1's sentence by ignoring it, and
leaves first run with a picker and no selection.

## D-141 — The minimal request body, because the user picks the model

The model ID is whatever the user chose from a runtime list, so the provider cannot assume which
parameters that model accepts. The current API is full of parameters that are fine on one model
and a 400 on another: `thinking: {type: "enabled", budget_tokens:}` is removed on the newer
models, `{type: "disabled"}` is rejected above effort `high` on Opus 5, `effort` errors on Sonnet
4.5 and Haiku 4.5, and `temperature`/`top_p`/`top_k` are removed across the Opus 5 and Fable
families.

**The body carries `model`, `max_tokens`, `system`, `messages`, and `output_config.format`.
Nothing else.**

```jsonc
{
  "model": "<request.modelID>",
  "max_tokens": 1024,                 // request.maxOutputTokens, verbatim
  "system": "<request.systemPrompt>",
  "messages": [{ "role": "user", "content": "<request.userPrompt>" }],
  "output_config": {
    "format": { "type": "json_schema", "schema": { /* request.outputSchema.json */ } }
  }
}
```

Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. No
`anthropic-beta` — nothing used here is in beta, and an unrecognised beta value is itself a 400.

A parameter that 400s on one model would make that model unusable from a picker that offers it,
with an error the user cannot act on. The tuning those parameters buy is not worth that: the
workload is summarizing a factual log, and D-140 already defaults to the tier that does it
cheaply.

`AIOutputSchema.name` is unused by this provider — Anthropic's `json_schema` format takes a
schema, not a name. That is not a defect in M3-01's type; the field exists "where a provider's
API wants one", and this one does not.

**The schema reaches the API as the JSON value M3-03 authored** — parsed once and re-serialized
as part of the body, not spliced in as bytes. Semantic identity, not byte identity: an `Encoder`
has no way to emit raw bytes, and hand-splicing a body around them would be the fussier and more
breakable of the two. The parse is also what catches a schema that is not a JSON object, locally,
before a network call. Body keys are sorted, because `JSONSerialization`'s unsorted order is hash
order and differs between processes — which would make a body assertion flake.

## D-142 — `HTTPTransport` over value types, not `URLProtocol` and not `URLSession`

`make test` denies outbound IP entirely (D-012), so every test of this provider runs against a
double. The seam is a one-method protocol the provider depends on:

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct HTTPRequest: Sendable, Equatable { /* method, url, headers, body */ }
public struct HTTPResponse: Sendable, Equatable { /* status, headers, body */ }
```

This follows the shape the repo already uses for exactly this problem — `CredentialStore` so
tests never touch the login keychain, `StubFilePanels` so tests never open an `NSOpenPanel`.

**Plain values rather than `URLRequest`/`HTTPURLResponse`**, for two reasons. `HTTPURLResponse`
is a Foundation class whose `Sendable` status is a poor thing to bet a Swift 6 module on, and
error mapping over `(status, headers)` is a pure function — which is what makes the whole mapping
table in D-143 a table test rather than a fixture exercise. `URLSessionTransport` is where
`URLRequest` gets built and is the only place Foundation's networking types appear.

**`URLSessionTransport` is deliberately not covered.** It is a ~30-line adapter with no branch
except the `as? HTTPURLResponse` cast. Covering it means a `URLProtocol` stub, which needs a
process-global registry, `@unchecked Sendable`, and careful ordering under parallel Swift
Testing runs — real machinery, standing between the suite and a file whose only untested
behaviour is "Foundation does what Foundation does". The risk is accepted and recorded in
"Risks".

## D-143 — Three new error cases, because the honest mapping needs them

`AIError` (D-132) has no case for a request the provider rejects as malformed, and no case for a
response that arrived intact but says the model declined or ran out of room. Three additions:

```swift
case invalidRequest                       // non-retryable 4xx that is not an auth failure

public enum InvalidResponseReason {
    case undecodable, schemaViolation, emptyDraft
    case refused                          // stop_reason == "refusal"
    case truncated                        // stop_reason == "max_tokens"
}
```

Full mapping:

| Wire | `AIError` |
|---|---|
| 401, 403 | `.invalidCredential` |
| 429 | `.rateLimited(retryAfter:)`, from `retry-after` when it is integer seconds |
| 500, 529, any other 5xx | `.providerUnavailable(status:)` |
| 400, 404, 413, any other 4xx | `.invalidRequest` |
| `URLError` — offline, DNS, TLS, connection lost | `.network` |
| deadline lost, `URLError.cancelled` | `.timedOut` (D-145) |
| no credential in the store | `.notConfigured` |
| `stop_reason: "refusal"` | `.invalidResponse(.refused)` |
| `stop_reason: "max_tokens"` | `.invalidResponse(.truncated)` |
| body is not JSON / breaks the schema / is empty | existing `StandupDraft.decode` + `validated(against:)` cases |

404 belongs with 400 rather than with `.providerUnavailable`, because the two 404s this app can
provoke are a stale model ID and a typo'd path — both ours, neither Anthropic's. Routing them to
`.providerUnavailable` would put "The provider is unavailable right now" in front of a user whose
real problem is a model that was retired since they picked it, sending them to a status page
instead of the picker.

`.refused` and `.truncated` earn their place the same way: without them a refusal decodes as
`.undecodable` and a truncated draft as `.schemaViolation`, which files two provider-side
outcomes under the label §7.3 reserves for a model that broke the schema — and makes a real
hallucination indistinguishable from a client bug in §8's metrics.

Neither addition breaks D-132's rule. No new case carries a `String`, `.invalidRequest` carries
nothing at all, and the API's `error.message` — which can quote the request — is never read into
a value, only dropped.

This extends a decision record; §7.1 prints the protocol, not the error type, so REQUIREMENTS.md
is unchanged. `metricsLabel` and `errorDescription` grow the matching arms, and `AIError`'s
existing exhaustiveness tests grow with them.

## D-144 — 20 seconds for a draft, 10 for the Settings calls

The task file is explicit that this is the decision M3-02 owes M3-03: "If the API is slow, the
user is standing in a meeting; §7.4's fallback must engage promptly rather than after a long
hang."

| Call | Budget | Retries |
|---|---|---|
| `generateStandup` | 20s | one, on 429 / 529 / 5xx only |
| `availableModels` | 10s | none |
| `testConnection` | 10s | none |

Twenty seconds is the wall clock for the whole operation — attempt, backoff, retry, parse. It is
not `URLSession`'s `timeoutIntervalForRequest`, which is an inactivity timer and can outlast any
budget while bytes trickle. Streaming is out of scope (the task file: "a stand-up draft is short
and appears at once"), so the entire draft lands in one response and a Sonnet-class summarization
typically takes 5–15s. Twelve seconds would cut off legitimate periodic windows; thirty would
spend most of the time the user has before they speak.

The retry is worth one attempt and not two: a 529 is Anthropic being briefly overloaded, and
dropping to raw events for something a one-second wait would fix is a worse stand-up than the
user could have had. The backoff is `retry-after` when the header is present and integer-valued,
and one second otherwise. The retry runs **only if at least `backoff + 2s` of budget remains** —
a retry certain to be cancelled mid-flight is a slower failure, not a second chance — and when a
`retry-after` cannot fit, the call fails immediately with `.rateLimited(retryAfter:)` so M3-03
can say something specific rather than after a wait it already knows is futile. 4xx is never
retried.

The two Settings calls get the tighter budget and no retry because they are interactive: a user
who clicked "Test connection" is watching, and a fast honest `.network` beats a slow correct one.

`StandupRequest.timeout` stays caller-supplied, as M3-01 designed it. This task supplies the
value as a documented constant on the provider's config, which M3-03 passes.

## D-145 — The deadline races the work, and losing it is `.timedOut`

```swift
func withDeadline<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T
```

A throwing task group runs the operation against a `Task.sleep(for:)`; the first result wins and
the group is cancelled. The retry loop runs *inside* the deadline, which is what makes the budget
cover backoff rather than resetting on the second attempt.

**The subtle part is the error the loser throws.** Cancelling an in-flight `URLSession` task
surfaces as `URLError.cancelled`, which sits in the same error domain as the genuine
connectivity failures. Mapping it by domain — the obvious mapping — reports `.network` for a
request that timed out, and §7.4 tells the user they are offline while their connection is fine.
So cancellation is disambiguated by the deadline that caused it, not by inspecting the error:
the deadline branch throws `.timedOut`, and `URLError.cancelled` arriving through the operation
branch maps to `.timedOut` as well, since nothing else in this provider cancels.

## D-146 — Only `generateStandup` emits §8's metrics line

`AIRequestMetrics` requires a `modelID`, and §8 asks for "token counts, latency, model". A model
list has no model and no token usage; a connection test has neither either. Emitting a line for
them means inventing a `modelID` — `"-"`, `"none"` — in a field D-137 built to be one word from a
fixed vocabulary, and putting rows in the log that no reading of §8 asks for.

So `generateStandup` records one line per call, success or failure: `latency` measured across the
whole budgeted operation, `inputTokens`/`outputTokens` from `usage` when the response carried it
and `nil` when it did not, `outcome` from `AIError.metricsLabel`. The other two calls log
nothing.

D-137's rule is inherited whole: the mapping functions take a status code and a header dictionary,
never a body, so there is no path by which a draft, a prompt, or an API error message reaches a
log line even on the error branches.

## Layout

```
StenoKit/AI/
  HTTPTransport.swift             protocol + HTTPRequest/HTTPResponse values (D-142)
  URLSessionTransport.swift       the adapter; the one place URLRequest exists (D-142)
  Deadline.swift                  withDeadline (D-145)
  AIProvider.swift                availableModels() ordering contract added to the doc (D-140)
  AIError.swift                   + .invalidRequest, .refused, .truncated, labels (D-143)
  Anthropic/
    AnthropicProvider.swift       the conformance: auth, the model list, plumbing
    AnthropicProvider+Draft.swift §7.3's call, D-144's retry, DraftFailure — its own
                                  file because SwiftLint caps one at 400 lines
    AnthropicWire.swift           request builders + the internal Codable response types
                                  (D-141). Named `Anthropic*` at file scope rather than nested,
                                  because each needs its own CodingKeys and SwiftLint caps
                                  nesting at one level. No type for the API's error envelope:
                                  its `message` can quote the request (§8).
    AnthropicErrors.swift         status + URLError -> AIError, pure (D-143)
    ModelRanking.swift            ordered(_:) -> [AIModel], pure (D-140)

StenoTests/AI/
  StubHTTPTransport.swift         scripted responses, recorded requests
  AnthropicFixture.swift          the fixtures both provider suites share
  AnthropicProviderTests.swift    credentials, request body, draft path
  AnthropicProviderBudgetTests.swift  budget, retry, model list — split out because
                                  SwiftLint caps a file at 400 lines
  AnthropicErrorMappingTests.swift
  ModelRankingTests.swift
  DeadlineTests.swift
```

Everything under `Anthropic/` is `internal`. `AnthropicProvider` itself is `public` (the app
constructs it); no signature on it mentions a wire type, which is the acceptance criterion.
`StenoKit/AI/` still imports nothing from `Capture/`, `Portability/` or any connector (§13).

## Verification

**The transport double** scripts a queue of `HTTPResponse`s or thrown `URLError`s, records every
`HTTPRequest` it received, and can hold before answering so the deadline is exercised. Recording
the request is what makes the §8 and D-141 assertions possible — that the body contains exactly
five keys, that the schema arrives as the value M3-03 authored, that `x-api-key` is present, and that no request
is sent at all when the store holds no credential.

| Area | What is asserted |
|---|---|
| Error mapping | A table over every row of D-143's table, including `retry-after` present / absent / non-integer |
| Ranking | Input order disagrees with expected order; recency within a family; haiku above opus; `structured_outputs: false` dropped; unknown `capabilities` shape drops nothing; paging accumulates across two pages |
| Budget | A held transport loses the deadline and throws `.timedOut`, not `.network`; a 529 retries once and succeeds; a 400 retries zero times; a `retry-after` longer than the budget fails immediately |
| Draft path | §7.3's literal JSON decodes; a hallucinated `task_id` throws `.unknownTaskIDs`; `stop_reason: refusal` and `max_tokens` map to their reasons |
| §8 | The emitted line for a success and for each failure contains no body bytes; a planted sentinel in a response body and in an API error message never appears in `AIMetricsLog.line(for:)` |
| Credentials | `.notConfigured` when the store is empty, and the transport was never called |

**Mutation-checked, not just green** (the standing lesson from M1-04 and M2.5-01): before the PR
opens, each row above is run against a stated mutation that must turn it red — invert the family
rank, return `.network` from the cancellation branch, drop the `has_more` loop, skip
`validated(against:)`, remove the retry guard. Survivors are reported as survivors. A ranking
test whose input is already in the expected order proves nothing, and a deadline test against a
transport that answers immediately proves less.

**Plan-phase rule:** the implementation plan's code blocks are generated from a built tree, not
typed into the plan and type-checked standalone — including every `#expect` inside its macro.
Snippets in *this* document are signatures and JSON shapes, and are not the plan's blocks.

**Gates:** `make build && make test && make lint`, the mutation results in the PR body, and the
`docs/tasks/README.md` row for M3-02 ticked (plus any earlier row that merged unticked).

## Out of scope

- **Prompt construction and output schemas** — M3-03. `AIOutputSchema` is still a carrier here,
  and the provider never reads inside it.
- **§7.4's fallback** — M3-03. This task supplies the budget it waits on and the error vocabulary
  it switches over; it does not implement degradation.
- **Settings UI** — M3-04. The ordered list and `testConnection`'s two distinguishable failures
  are what this task owes it.
- **Streaming.** Nothing in §7 needs it (task file); the draft is short and appears at once.
- **Prompt caching, `thinking`, `effort`, batch.** D-141.
- **A second provider.** §7.1's abstraction is exercised by this one plus `StubAIProvider`.

## Risks

1. **`URLSessionTransport` ships uncovered** (D-142). Its failure mode is total and immediate —
   nothing works — rather than subtle, and M3-04's "Test connection" is the first human check.
   If it grows a branch, it needs a test, and that is the moment to pay for the `URLProtocol`
   harness.
2. **The family-word ranking is a heuristic against a vendor's naming** (D-140). A future
   line named neither `sonnet` nor `haiku` ranks last and stops being the default, which is a
   quiet degradation rather than a failure: the list is still complete, still fetched, and the
   user can still pick. The ranking is one pure function with one test file, which is the
   cheapest possible place to revise it.
3. **The `/v1/models` path was confirmed against the live API on 2026-09-22**, after review, and
   this risk is closed: `has_more`, `last_id`, `data[].{id, display_name, created_at}`, the
   `capabilities.structured_outputs.supported` nesting, `limit=1000` accepted, and `after_id`
   advancing the window. The residue is drift, not error — a vendor can rename a field later, and
   only a repeatable check catches that. M3-04's `make verify-models` is the repeatable check,
   and `ModelRanking.ordered` dedupes by id so that a future paging change costs at worst a short
   list rather than a picker with the same model in it twice.
4. **20 seconds is reasoned, not measured** (D-144). Nothing in this task can measure it, since
   the suite has no network. M3-03 is where a real draft is timed, and if the number is wrong
   it is one constant in the provider's config.
