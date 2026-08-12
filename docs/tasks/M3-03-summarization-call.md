# M3-03 — Summarization Call & Degradation

**Milestone:** M3 — AI summarization
**Depends on:** M3-02
**Blocks:** M3-04
**Requirements:** §7.3, §7.4, D12, D13, D17
**Branch:** `feat/summarization-call`

## Goal

Turn a gathered window into a structured, schema-validated summary — with the M2-02 fallback
wired in as a first-class path, not an error handler.

## In scope

- Build `StandupRequest` from M2-01's output: per task, title, status, ticket key, and all
  events in the window with timestamps, plus any external updates.
- **Both output schemas (§7.3), selected by `project.reportCadence`:**

*daily* — one bullet per task:
```json
{
  "since_last_standup": [{ "task_id": "...", "text": "..." }],
  "today":              [{ "task_id": "...", "text": "..." }],
  "blockers":           [{ "task_id": "...", "text": "..." }]
}
```

*periodic* — themed bullets spanning several tasks:
```json
{
  "completed":          [{ "task_ids": ["...", "..."], "text": "..." }],
  "in_flight":          [{ "task_ids": ["..."],        "text": "..." }],
  "blockers_and_risks": [{ "task_ids": ["..."],        "text": "..." }]
}
```

- The §7.3 prompt constraints, all of them.
- Rendering markdown from the returned structure, reusing M2-02's renderer.
- Falling back to M2-02's raw output on failure, missing config, or offline.
- Setting `wasAIGenerated` and `modelUsed` on the report.

## Out of scope

- Settings UI — M3-04.
- Focus suggestions, prioritization, "what should I work on" — **D12 forbids these outright.**
- Formatting the final Slack text in the model. §7.3: formatting is the app's job.

## Acceptance criteria

- [ ] Cadence selects the correct schema; `periodic` uses `task_ids` (plural).
- [ ] A `task_id` the app did not send fails loudly into the fallback rather than rendering
      (v1.7 — a hallucinated ID is the clearest signal the model invented a fact).
- [ ] Ticket keys, service names, function names, error strings, and acronyms survive
      **verbatim**.
- [ ] Register is not elevated. Test with a fixture: "fixed the flaky auth test" must not come
      back as "enhanced authentication reliability."
- [ ] A `periodic` window covering dozens of tasks produces roughly 8–12 grouped bullets, not
      one line per task.
- [ ] With no API key, no network, or an API error, a usable report still appears — same three
      headings, rougher content.
- [ ] `wasAIGenerated` is false on the fallback path, true otherwise; `modelUsed` is recorded.

## Notes for the spec/plan phase

- **The AI summarizes a factual record; it never invents history** (§7.3). Never introduce a
  fact absent from the event log, and make no inference about what the user "probably" did.
  This is the property that makes the output trustworthy enough to say out loud.
- **Inflated language is actively harmful** (§7.3) — the user has to speak these words to their
  team. D13 caps the AI's job at light polish: organize and clean, never rewrite, preserve the
  user's technical vocabulary.
- If a task's events are too thin to summarize, output the raw note rather than padding (§7.3).
- The fallback is not error handling — §7.4 built it first, at M2-02, precisely so this task
  merely selects it. "The user must never arrive at a stand-up empty-handed because of a
  network error."
- D18 notes the whole dataset fits one AI call at this scale, so no chunking is needed.
