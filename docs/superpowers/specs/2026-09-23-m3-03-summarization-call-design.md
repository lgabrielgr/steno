# M3-03 — Summarization Call & Degradation: design

**Date:** 2026-09-23 · **Task:** [`M3-03`](../../tasks/M3-03-summarization-call.md) ·
**Requirements:** §7.3, §7.4, §8, §9.4, §13, D12, D13, D17, D18 ·
**Branch:** `feat/summarization-call`

## What this builds

The half of M3 that has an opinion. M3-01 defined a seam and M3-02 filled it with transport;
neither wrote a word of the prompt, and nothing in the running app has ever called
`generateStandup`. This task authors §7.3's prompt and its two schemas, turns the returned
`StandupDraft` into the `[ReportSection]` M2-02 already renders, selects §7.4's raw fallback on
every failure, and wires the whole thing into FR-4's Prepare Stand-up so that `wasAIGenerated`
and `modelUsed` describe what the user actually copied.

**The fallback is not the error handler here; it is the opening state.** §7.4 required the raw
path be built *before* the AI path, and M2-02 built it. This task's reading of that instruction
is stronger than "call the AI, catch the throw": the draft sheet opens on the raw report, at
once, with Copy live, and the AI result replaces it later only if it arrives and only if the
user has not started typing. A user whose network is down, whose key is missing, or who simply
speaks before the call returns is looking at a usable stand-up the entire time. §7.4's sentence
— "the user must never arrive at a stand-up empty-handed because of a network error" — becomes a
property of the first frame rather than of a catch block.

**The AI path is unreachable from the app when this merges, and that is the design.** M3-04 owns
the key field and the model picker, so no user can have a credential stored or a model selected.
Every run at this commit therefore takes the fallback — which is the literal statement of this
task's sixth acceptance criterion, and is exercised by the test suite rather than assumed.
M3-04 adds a pane and the AI path lights up with no further wiring.

## What this task decides

Seven things §7.3 and §7.4 leave open. Each gets a `DECISIONS.md` entry, D-148 through D-154.
The log's maximum before this task is D-147.

| Question | Decision |
|---|---|
| What the user sees during a call that may take 20s | Fallback first, upgraded in place only if untouched (D-148) |
| Whether the schema should make a hallucinated `task_id` impossible | No — an `enum` coerces invention onto a real task; the loud failure is the feature (D-149) |
| Who guarantees ticket keys survive verbatim | The renderer re-attaches them; the prompt only asks (D-150) |
| How `wasAIGenerated` and `modelUsed` stay in agreement | Derived — `commit` takes `modelUsed` with no default and computes the flag (D-151) |
| What a well-formed draft of blank strings is | An empty draft, which falls back (D-152) |
| How the `daily` schema's `today` section avoids D12 | An explicit prompt guard: restate, never recommend (D-153) |
| The output-token budget for each cadence | 4096 for both, because truncation degrades silently (D-154) |

---

## D-148 — The sheet opens on the fallback and upgrades in place

**Decision.** `prepareStandup()` stays synchronous and side-effect-free: it gathers, renders the
raw report, and opens the sheet. `StandupDraftModel.begin(window:text:)` then starts an `async`
polish. When the summarizer answers with an AI draft, the model installs it **only** when the
phase is still `.editing`, the task was not cancelled, and the text is byte-identical to what
`begin` installed. Otherwise the result is discarded and the user's words stand.

**Why not a spinner.** The obvious shape is a loading state with Copy disabled until something
arrives. D-145 budgets 20 seconds for a draft, and the user pressing ⌘R is frequently already in
the meeting. A spinner withholds, for up to twenty seconds, a report the app had finished
rendering in microseconds — and then, on a failure, shows them that same report anyway. The
worst case of the chosen design is that the user reads the raw draft aloud and never learns the
AI was going to improve it. The worst case of the spinner is that they stand there in silence.

**Why not await before opening the sheet.** Same cost, plus ⌘R appears to do nothing at all for
the duration, which reads as a broken keyboard shortcut rather than as work in progress.

**The untouched check is the whole safety argument.** FR-4 step 6 makes the draft editable and
§7.3's philosophy is that the user's phrasing is final; text replaced under a cursor would
violate both. Comparing against a stored `pristineText` rather than against a dirty flag means
a user who types and then undoes back to the original still gets the upgrade, which is the
behaviour they would expect and costs nothing to provide.

**Nothing is installed when the summarizer fell back.** The check is `let model = result.modelUsed`,
not `result.markdown != text`. The fallback markdown the summarizer returns is byte-identical to
the text already on screen — same pure functions, same frozen window — so installing it would be
a no-op. Skipping it makes that true by construction rather than by coincidence, and it means
`aiModelUsed` is set in exactly one place.

**Cancellation.** `dismiss()` cancels the task. A cancelled polish that completes anyway is
caught by the same guard: the phase is no longer `.editing`.

---

## D-149 — The schema does not constrain `task_id` to the ids that were sent

**Decision.** Both JSON Schemas type `task_id` as a plain string. The ids the app sent ride on
`StandupRequest.allowedTaskIDs`, and `StandupDraft.validated(against:)` — which M3-01 deliberately
placed inside the provider — rejects anything else into the §7.4 fallback.

**The rejected alternative is genuinely tempting.** Structured outputs would accept an `enum` of
the twenty-odd UUIDs actually in the window, and a hallucinated id would become impossible rather
than merely detected. D18 caps the store at under 20 live tasks, so the schema would stay small.

**It is rejected because it does not prevent invention; it hides it.** §7.3 is explicit about what
the rejection is *for*: "a hallucinated ID is the clearest possible signal the model invented a
fact, and it should fail loudly into the §7.4 fallback rather than render." A model that has
invented a sentence about work that did not happen still emits that sentence under an `enum` — it
simply attaches it to whichever real task id the constraint permits. The user then reads a
fabricated claim, correctly attributed, out loud to their team. The unconstrained schema turns the
same failure into a rough-but-true raw report. Between a false report and a plain one, §7.3 has
already chosen.

---

## D-150 — The renderer re-attaches ticket keys; the prompt only asks

**Decision.** `DraftSections` appends each referenced task's ticket keys to the bullet text, in
the exact `" (STENO-12, STENO-19)"` form `RawReportSections.bullet` already emits, skipping any
key the model's sentence already contains. The §7.3 constraint telling the model to preserve keys
verbatim stays in the prompt as well.

**Why both.** The task file's third acceptance criterion — "ticket keys, service names, function
names, error strings, and acronyms survive **verbatim**" — is one criterion covering five things,
and only one of them is machine-checkable. Service names, function names, error strings and
acronyms live inside free text with no separate record; nothing but the prompt can protect them.
A ticket key is different: `GatheredTask.ticketKeys` is a sorted list of facts drawn from the
event log (D-065), so the app knows exactly what should be there and can put it there. Leaving
the only checkable member of the list to a prompt would be choosing not to check the one thing
that can be.

**Re-attaching is not inventing.** §7.3's prohibition is on facts absent from the event log. A
ticket key is present in the event log, on the task the bullet is about, and `RawReportSections`
already emits it on the same bullet in the fallback path. The AI path emitting less than the raw
path would be a regression dressed as purity.

**The skip-if-present check is case-insensitive; the appended form is verbatim.** A model that
writes "landed steno-12 behind a flag" has preserved the key badly but has preserved it, and
appending a second copy would produce "…behind a flag (STENO-12)". Presence and spelling are
different questions, and only presence governs whether to append.

**Ordering is deterministic.** Keys are collected by walking the bullet's task ids in the order
the model returned them, taking each task's already-sorted `ticketKeys`, and deduping on first
occurrence. The model's ordering is arbitrary but fixed for a given response, which is what a
test needs; nothing here introduces a `Set` or `Dictionary` iteration order into the output.

**A task id that does not resolve contributes no keys and no error.** It cannot occur — the
provider ran `validated(against:)` before returning — and a second rejection path here would be
a branch whose only reachable behaviour is already covered upstream.

---

## D-151 — `wasAIGenerated` is derived from `modelUsed`, and `commit` takes no default

**Decision.** `StandupService.commit` gains `modelUsed: String?` as a required parameter and
writes `wasAIGenerated: modelUsed != nil`. `StandupDraftModel` passes its `aiModelUsed`, which is
set in exactly one place — the install step of D-148 — and never cleared.

**Why derived.** The two fields answer the same question and the model's own doc comment already
ties them ("nil for a fallback report"). Two independently written fields is one refactor away
from a report marked AI-generated with no model recorded, which is precisely the state that makes
the field useless for its stated purpose of "debugging quality regressions".

**Why no default value.** A defaulted `modelUsed: String? = nil` keeps the existing call sites
compiling, which is its entire appeal and also its defect: every future caller silently records a
fallback, and the compiler stops asking. The cost of omitting the default is touching a handful
of test call sites once.

**Editing AI text keeps the flag true.** The report *was* AI-generated; the user polished it, as
FR-4 step 6 intends them to. A flag that flipped to false on the first keystroke would mark
nearly every real AI report as a fallback.

---

## D-152 — Blank bullets are dropped, and a draft of nothing but blanks is empty

**Decision.** `DraftSections` drops any bullet whose text is empty or whitespace-only. If that
leaves all three sections without bullets, the summarizer treats the result as
`.invalidResponse(.emptyDraft)` and takes the fallback.

**Why this is not already handled.** `StandupDraft.isEmpty` counts bullets, not content, and its
doc comment is deliberate about why: "a bullet with an empty `task_ids` array is still a bullet
the model wrote, and losing it silently would be worse than surfacing it." That reasoning is
about *identity*, not about *text* — a bullet with task ids and no sentence surfaces as `- ` in
Slack, or as `- (STENO-12)` once D-150 has run, which is not surfacing anything.

**An empty `task_ids` array on a bullet with real text is kept**, unchanged, with no keys
appended. That case is exactly what `StandupDraft`'s comment protects, and this decision does not
narrow it.

---

## D-153 — The `today` section carries an explicit D12 guard

**Decision.** The `daily` prompt states that `today` restates which tasks are currently in
progress, drawn from the record, and must not recommend what to work on, in what order, or what
to prioritise.

**Why this needs saying.** D12 forbids focus suggestions and prioritization outright, and the
task file repeats it: "**D12 forbids these outright.**" Every other §7.3 constraint guards
against a model's general tendencies; this one guards against a section name in our own schema.
`today` is the only forward-looking field in either schema, and a summarizer asked for "today"
with no further instruction produces a plan — which is the product Steno's §2.1 non-goals exist
to refuse. The guard costs one sentence and removes the one structural invitation to violate D12.

**The periodic schema needs no equivalent.** `completed`, `in_flight` and `blockers_and_risks`
are all statements about what happened.

---

## D-154 — 4096 output tokens for both cadences

**Decision.** `StandupRequest.maxOutputTokens` is 4096 regardless of cadence.

**The arithmetic.** D18 caps the store at under 20 live tasks. A worst-case `daily` response puts
every task in all three sections — 60 bullets at roughly 50 tokens including the UUID — for about
3,000 tokens. A `periodic` response is capped by its own prompt at 8–12 bullets and is far
smaller, even with several ids per bullet.

**Why one number rather than two.** A tighter periodic budget would save nothing the user can
perceive — output tokens are billed as used, not as reserved — and would add a second constant to
keep in step with a prompt instruction that can change.

**Why generous rather than tight.** Truncation maps to `.invalidResponse(.truncated)`, which
degrades to the raw report. An under-provisioned budget therefore does not fail; it quietly makes
the AI never work, and the symptom the user reports is "the polish never happens" with a metrics
label that says the model's answer was cut off. Erring high costs nothing; erring low costs the
feature.

---

## Layout

```
StenoKit/AI/StandupPrompt.swift        GatheredWindow → (system, user). Pure.
StenoKit/AI/StandupSchema.swift        ReportCadence → AIOutputSchema. Two literal documents.
StenoKit/AI/DraftSections.swift        (StandupDraft, GatheredWindow) → [ReportSection]. Pure.
StenoKit/AI/StandupSummarizer.swift    GatheredWindow → SummarizedStandup. Never throws.
StenoKit/Report/ReportHeadings.swift   Section titles, one owner for both paths.
```

Changed: `StenoKit/Report/RawReportSections.swift` (titles move to `ReportHeadings`),
`StenoKit/Report/StandupService.swift` (`modelUsed` parameter),
`StenoKit/Features/MainWindow/StandupDraftModel.swift` (the polish task and its guard),
`StenoKit/Features/MainWindow/MainWindowModel+Standup.swift` (builds the summarizer),
`StenoKit/Settings/AppSettings.swift` (the selected-model key),
`Steno/Features/MainWindow/StandupDraftSheet.swift` (the "Polishing…" affordance).

### The prompt

The system half carries §7.3's constraints and no user data, so a test can assert it by equality
rather than by substring against a string that grows a task list. The user half carries the
window:

```
Window: 2026-09-22T09:00:00Z to 2026-09-23T09:00:00Z

TASK 3f2a…e91  [in progress]  STENO-12, STENO-19
  Title: Flaky auth test in CI
  2026-09-22T14:03Z  note  found the race in the token refresh
  2026-09-22T16:40Z  note  fixed it, watching the next ten runs

TASK 8c41…0b2  [blocked]  STENO-44
  Title: Ship the retry fix
  Blocked: waiting on infra to bump the runner image
  (no events in window)
```

Plain text rather than JSON: the model reads it as a record, and the app already has a schema for
the direction that matters. Task order is `ReportGatherer`'s, preserved and never recomputed —
the same rule `RawReportSections` records for itself, because ordering has one owner.

`(no events in window)` is emitted rather than the line being omitted. `GatheredTask.events` "may
be empty, and a renderer must handle that honestly rather than emit a blank bullet" — a task
admitted to the window because it is currently in progress with nothing said about it is the task
Monday's stand-up is about, and silence in the prompt reads as an omission rather than as a fact.

**The timestamp formatter is injected**, defaulting to the current time zone. A formatter reading
`TimeZone.current` directly makes the prompt tests pass in one time zone and fail in another,
which this repo has already paid for once in its date handling.

Constraints carried verbatim from §7.3: never introduce a fact absent from the log and make no
inference about what the user "probably" did; preserve ticket keys, service names, function
names, error strings and acronyms; light polish only, with §7.3's own
`fixed the flaky auth test` → not `enhanced authentication reliability` example as the anchor;
one line per task for `daily`; group into 8–12 themed bullets for `periodic` regardless of window
length; output a task's raw note rather than padding when its events are too thin.

Two constraints the spec implies rather than prints:

- **No formatting.** The model returns sentences — no bullet characters, no bold, no markdown.
  §7.3 makes formatting the app's job, and a model emitting `*` produces double-formatted text
  once `SlackMarkdown` has run.
- **The D12 guard on `today`** (D-153).

### The schemas

Two literal JSON Schema documents, `additionalProperties: false`, all three sections required,
items requiring both their task reference and their text. `daily` uses `task_id` (string);
`periodic` uses `task_ids` (array of string), and both carry `format: "uuid"` — a constraint on
an id's *shape*, which is a different question from D-149's constraint on its *membership*, and
which keeps a malformed UUID out of `StandupDraft.decode` where it would arrive as a schema
violation indistinguishable from an invented section.

**Written as Swift string literals, not assembled through `JSONSerialization`** — an amendment to
this design made during implementation. The assembled version has to be `try`-ed at a call site
where it cannot fail, and its key order becomes an argument about encoder options rather than
something a reader can see. A literal is greppable, diffable, byte-stable by construction — the
same reproducibility §10.2 requires of the export, reached more directly — and is checked by
`StandupSchemaTests` parsing it back and building a response out of its own key names.

`AnthropicWire.messagesBody` parses the document back out and nests it under
`output_config.format`; nothing between here and the wire inspects it, which is what
`AIOutputSchema`'s opaqueness was for.

### The summarizer

```swift
public struct SummarizedStandup: Sendable, Equatable {
    public let markdown: String
    public let modelUsed: String?   // nil ⇔ the fallback produced this
}

public struct StandupSummarizer: Sendable {
    init(provider: (any AIProvider)?, modelID: String?, timeout: Duration)
    func summarize(_ window: GatheredWindow) async -> SummarizedStandup   // never throws
}
```

`summarize` has no `throws`, which is §7.4 expressed as a type rather than as a promise: there is
no error a caller could be handed, so there is no path on which a caller could forget to degrade.

**The timeout is injected rather than read from `AnthropicProvider.recommendedDraftTimeout`.**
The composition root already chooses the concrete provider, so it passes the constant with it.
A vendor-neutral type in `StenoKit/AI/` naming one vendor's constant would make §7.1's vendor-neutrality
true by convention where it is currently true by construction.

Every path to the raw report:

| Trigger | Network call |
|---|---|
| No model id stored in `AppSettings` | none |
| `window.tasks` is empty | none |
| `AIError.notConfigured` — no key in Keychain | refused locally by the provider |
| `.network`, `.timedOut`, `.rateLimited`, `.invalidCredential`, `.invalidRequest`, `.providerUnavailable` | yes |
| `.invalidResponse` — undecodable, schema violation, refusal, truncation, empty | yes |
| `.unknownTaskIDs` — §7.3's hallucinated id | yes |
| Every section empty after D-152's drop | yes |
| Any non-`AIError` escaping a provider | yes |

The last row is a catch-all for an error the protocol says cannot occur. It stays: §7.4 must
degrade on *any* failure, and a future provider leaking a `URLError` would otherwise take down
the draft path instead of roughening it — the failure mode `AIProvider`'s own error contract
warns about.

**Logging.** One line per fallback, carrying `AIError.metricsLabel` and nothing else, so
`log show` answers "why was my report rough this morning" without §8's forbidden payload ever
being written. The provider's own §8 metrics line is unchanged; D-147 keeps it the only emitter
for the call itself.

### `ReportHeadings`

Today the three daily titles and three periodic titles are string literals inside two private
functions in `RawReportSections`. The sixth acceptance criterion says the fallback shows the
*same three headings* as the AI path; with two copies of those strings that criterion holds only
until someone edits one. The type is six lines and the change is a move, not a rewrite — the one
piece of existing code this task touches beyond what it strictly must.

### `AppSettings`

One new key, `com.lgabrielgr.steno.ai.selectedModelID`, declared here and written by M3-04. It
must be added to `allKeys` — `AISecretsTests` asserts the count, so adding a key without listing
it turns the audit red rather than quietly shrinking its coverage.

No key is stored for the provider id. Only Anthropic ships, §7.1's abstraction is exercised by
`StubAIProvider`, and a setting with one possible value and no UI is a field M3-04 would have to
either use or delete.

## Verification

`make build && make test && make lint`, with the suite running headless and with outbound
networking denied (§9.4, D-012). Every assertion below runs under that sandbox.

| File | What it pins |
|---|---|
| `StandupPromptTests` | Each §7.3 constraint present; the D12 guard present; deterministic output under an injected time zone; a task with no window events renders `(no events in window)`; ticket keys and blocked reasons reach the prompt |
| `StandupSchemaTests` | Both documents parse as JSON objects; `task_id` singular in `daily`, `task_ids` plural in `periodic`; `additionalProperties: false` and the required lists; byte-identical across two builds |
| `DraftSectionsTests` | Keys appended, skipped when present in any case, deduped across tasks, ordered deterministically; blank bullets dropped; an empty `task_ids` array with real text kept; headings identical to `RawReportSections`' for the same cadence |
| `StandupSummarizerTests` | The degradation table above, row by row; a success case whose markdown *differs* from the raw render; the no-call rows asserted against a stub that records whether it was invoked |
| `StandupDraftModelTests` | Install-if-untouched; discard-if-edited, with `aiModelUsed` still nil; cancel on dismiss; `modelUsed` reaching the service |
| `StandupServiceTests` | `modelUsed` non-nil → `wasAIGenerated` true, and nil → false, in both directions |

**The degradation table cannot fail on its own, and that is the trap this repo keeps walking
into.** A summarizer that ignored its provider entirely and always returned the raw render would
pass every row. It is paired with the success case for that reason, and the whole table is
verified by mutation — inverting the fallback selection must turn rows red — before any claim
that it works.

**What the automated suite cannot verify, stated plainly rather than implied.** Acceptance
criteria 3 (verbatim survival of names and error strings), 4 (register is not elevated) and 5
(8–12 grouped bullets for a long periodic window) are properties of a prompt in front of a live
model. `make test` denies the network by design, and this task ships no CLI seam to reach around
it, so **the suite has never sent this prompt anywhere**.

> **Verified by hand before merge, 2026-09-23.** The user planted an API key in the login
> keychain and a model id in `UserDefaults` directly — the two things M3-04's pane will write —
> ran the real draft path against their own event log, and confirmed all three: register held,
> technical vocabulary survived, and a periodic window grouped rather than enumerated. The key
> was removed afterwards. This is a human observation on one run, not a repeatable check; the
> repeatable one arrives with M3-04's Settings pane and `make verify-models`. What the suite proves is that each constraint is present in
the bytes that will be sent, that the ticket-key half of criterion 3 holds by construction
(D-150), and that every failure of the live call degrades correctly. The remaining verification
lands in M3-04 alongside the key field and `make verify-models`. The PR body says this in these
terms; it is not an acceptance criterion this task may tick.

**GUI verification is blocked for implementing agents** — the sheet's "Polishing…" affordance is
three lines keyed on `isPolishing`, every assertion about the behaviour lives on
`StandupDraftModel` in `StenoKit`, and the visual check is the user's at review.

## The plan document

M3-02 removed its plan before merge and recorded why: a plan generated from a built tree earns
its keep by finding defects before the first commit, then becomes a stale-claim generator once
the tree it describes exists and review starts changing it. That entry was explicit that it is
"not a precedent for skipping the plan."

So: write the plan, build from it, let it find the defects, and decide at PR time whether keeping
it honest through review is worth more than the duplication it creates. This spec and
`DECISIONS.md` D-148 through D-154 are the surviving record either way.

## Out of scope

- **Settings UI** — M3-04. This task declares the settings key it will write and nothing else.
- **Focus suggestions, prioritization, "what should I work on"** — D12, and D-153 is this task's
  active defence of that line rather than a passive omission.
- **Formatting in the model.** §7.3: formatting is the app's job. The model returns sentences;
  `SlackMarkdown` renders.
- **Streaming, prompt caching, a second provider.** M3-02's out-of-scope list stands.
- **Report history browsing.** §12's Q(M3) is open and this task does not answer it; see below.
- **Chunking.** D18 puts the whole dataset in one call.

## Risks

- **The prompt is unexercised.** The largest risk in the task and the one the verification section
  refuses to paper over. Its mitigation is structural rather than textual: every way the prompt
  can disappoint — a bad shape, a hallucinated id, an empty answer, a truncation — lands in the
  raw report the user already had, so the failure mode of a bad prompt is a rough stand-up rather
  than a wrong one.
- **The in-place upgrade is a text swap the user did not ask for.** Guarded by the untouched
  check, and the worst case is that a user who blinked sees better words appear. If it proves
  disruptive in practice, the fix is an explicit "Polish" button, not a spinner.
- **`ReportHeadings` touches M2-02's tested code.** A move with no behaviour change, and
  `RawReportGoldenTests` is the check: the golden output must not move by a byte.
- **4096 tokens is arithmetic, not measurement** (D-154). Under-provisioning degrades silently,
  which is the direction that hides itself; the metrics label `.truncated` is where it would
  surface, and M3-04's live run is where it would first be seen.

## An open question this task surfaces and does not answer

**§12's Q(M3)** — "should the app retain a history of past reports for browsing (e.g. for writing
self-reviews or promo packets)?" — is due before M3 ships. `StandupReport` already persists every
report with its window and its `markdownBody`, so the data exists; what is missing is a decision
about whether anything reads it. This task does not need the answer and does not force it, but
M3-04 is the last task in the milestone and it should not merge with the question still open.
