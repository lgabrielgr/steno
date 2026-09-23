# M3-03 Summarization Call & Degradation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a gathered stand-up window into a schema-validated AI summary, with §7.4's raw report as the opening state rather than as an error handler.

**Architecture:** Four pure pieces — prompt, schema, draft→sections, and a summarizer that can't throw — sit behind M3-01's `AIProvider` seam. The draft sheet opens on M2-02's raw markdown and upgrades in place only while the user has not typed; `StandupReport.wasAIGenerated` is derived from the model id that produced the text on screen.

**Tech Stack:** Swift 6 (language mode 6.0, macOS 14 floor), SwiftData, Swift Testing (`@Test`/`#expect`), XcodeGen + `make`, SwiftLint + swift-format.

**Spec:** [`docs/superpowers/specs/2026-09-23-m3-03-summarization-call-design.md`](../specs/2026-09-23-m3-03-summarization-call-design.md)

## Global Constraints

- **Branch `feat/summarization-call`, off current `main`. Never commit to `main`; open a PR and do not merge it** (REQUIREMENTS.md §9.5).
- `make build && make test && make lint` must all pass before the PR is opened (§9.5 step 4, §13).
- `make test` runs headless with **outbound networking denied** by `sandbox-exec` (§9.4, D-012). No test here may reach a network.
- The event log is append-only: nothing in this task mutates or deletes an `Event` (§3.3).
- **SwiftLint caps a file at 400 lines** and swift-format holds `lineLength: 100`. Run `make format` before committing; a dirty tree afterwards is your change to commit (D-075).
- `AIProvider` implementations throw `AIError` and nothing else; §7.4 must degrade on any failure regardless (§7.1).
- §8: log AI **metadata only** — token counts, latency, model. Never a prompt, never a draft. No `AIError` case carries free-form text, and none may gain one.
- Decision numbering starts at **D-148**; the log's maximum before this task is D-147. Check `docs/DECISIONS.md` before assigning a number rather than inferring it.
- Section headings come from `ReportHeadings` once it exists. No literal `"Today"` anywhere after Task 1.

---

## File Structure

| File | Responsibility |
|---|---|
| `StenoKit/Report/ReportHeadings.swift` | **New.** The six section titles, one owner for the AI and raw paths |
| `StenoKit/AI/StandupSchema.swift` | **New.** §7.3's two JSON Schemas, selected by cadence |
| `StenoKit/AI/StandupPrompt.swift` | **New.** §7.3's constraints (system) and the event log (user) |
| `StenoKit/AI/DraftSections.swift` | **New.** `StandupDraft` + `GatheredWindow` → `[ReportSection]`, re-attaching ticket keys |
| `StenoKit/AI/StandupSummarizer.swift` | **New.** The call and every path down to §7.4's raw report. Cannot throw |
| `StenoKit/Report/RawReportSections.swift` | Titles move to `ReportHeadings`; no behaviour change |
| `StenoKit/Report/StandupService.swift` | `commit` gains `modelUsed`; `wasAIGenerated` becomes derived |
| `StenoKit/Features/MainWindow/StandupDraftModel.swift` | Owns the polish task and the swap-if-untouched rule |
| `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift` | `standupPolish(settings:)`, the composition root's factory |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | Passes that factory into `StandupDraftModel` |
| `StenoKit/Settings/AppSettings.swift` | `aiSelectedModelID`, declared here and written by M3-04 |
| `Steno/Features/MainWindow/StandupDraftSheet.swift` | The "Polishing…" affordance; Copy stays live |

Tests: `StenoTests/AI/{DraftFixture,StandupSchemaTests,StandupPromptTests,DraftSectionsTests,StandupSummarizerTests}.swift`, `StenoTests/Features/MainWindow/StandupDraftPolishTests.swift`, plus additions to `StandupServiceTests` and a count in `AISecretsTests`.

---

### Task 1: One owner for the section headings

**Files:**
- Create: `StenoKit/Report/ReportHeadings.swift`
- Modify: `StenoKit/Report/RawReportSections.swift` (six string literals → constants)
- Test: `StenoTests/Report/RawReportGoldenTests.swift` (existing; must not move)

**Interfaces:**
- Consumes: `ReportCadence` (`.daily`, `.periodic`) from `StenoKit/Models/`.
- Produces: `ReportHeadings.sinceLastStandup` / `.today` / `.blockers` / `.completed` / `.inFlight` / `.blockersAndRisks`, all `String`, and `ReportHeadings.ordered(for: ReportCadence) -> [String]`. Tasks 4 and 5 read these; nothing may spell a heading as a literal again.

**Why first:** M3-03's sixth acceptance criterion is that the fallback shows *the same three headings* as the AI path. `DraftSections` (Task 4) is about to add a third and fourth copy of those strings, and a criterion stated over four copies holds only until someone edits one.

- [ ] **Step 1: Confirm the golden test currently passes**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`. This is the baseline the move must not disturb — `RawReportGoldenTests` pins the rendered markdown byte for byte.

- [ ] **Step 2: Create `StenoKit/Report/ReportHeadings.swift`**

```swift
/// The section titles both report paths use (FR-4, D17).
///
/// **One owner, because the AI path and the raw path must agree.** M3-03's
/// sixth acceptance criterion is that a failed, unconfigured or offline AI call
/// still produces "the same three headings, rougher content" — and until this
/// type existed the strings lived as literals inside two private functions in
/// `RawReportSections`, with `DraftSections` about to add a third and fourth
/// copy. A criterion stated over two copies of a string holds only until
/// someone edits one of them.
///
/// Imports nothing, for `RawReportSections`' reason: a type that cannot read a
/// clock or a store cannot be the thing that broke §7.4's guarantee.
public enum ReportHeadings {
    /// FR-4's daily set: a DSU's three questions.
    public static let sinceLastStandup = "Since last stand-up"
    public static let today = "Today"
    public static let blockers = "Blockers"

    /// D17's periodic set. Not a rename of the daily headings — *Completed*
    /// means finished, where *Since last stand-up* means everything that moved.
    public static let completed = "Completed"
    public static let inFlight = "In flight"
    public static let blockersAndRisks = "Blockers & risks"

    /// The three titles a cadence's report uses, in the order they are emitted.
    ///
    /// Exists so a test can assert the two paths agree by comparing each
    /// against this list, rather than by comparing them to each other — which
    /// would pass if both drifted the same way.
    public static func ordered(for cadence: ReportCadence) -> [String] {
        switch cadence {
        case .daily:
            [sinceLastStandup, today, blockers]
        case .periodic:
            [completed, inFlight, blockersAndRisks]
        }
    }
}
```

- [ ] **Step 3: Point `RawReportSections` at it**

In `daily(_:)`, replace the three `title:` literals; in `periodic(_:)`, the other three:

```swift
// daily(_:)
ReportSection(
    title: ReportHeadings.sinceLastStandup,
    bullets: tasks.filter(progressed).map { bullet($0, details: authored($0)) }),
ReportSection(
    title: ReportHeadings.today,
    bullets: tasks.filter { $0.status == .inProgress }.map { bullet($0) }),
ReportSection(
    title: ReportHeadings.blockers,
    bullets: tasks.filter { $0.status == .blocked }
        .map { bullet($0, details: reason($0)) }),

// periodic(_:)
ReportSection(title: ReportHeadings.completed, bullets: completed),
ReportSection(title: ReportHeadings.inFlight, bullets: inFlight),
ReportSection(title: ReportHeadings.blockersAndRisks, bullets: blocked),
```

- [ ] **Step 4: Verify nothing moved**

Run: `make build && make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`. A golden test that now fails means a literal was mistyped — compare the constant's value against the string it replaced, not against what you think it said.

- [ ] **Step 5: Commit**

```bash
make format
git add StenoKit/Report/ReportHeadings.swift StenoKit/Report/RawReportSections.swift
git commit -m "refactor: give the report headings one owner

M3-03's AI path renders the same three headings as M2-02's raw path, and
was about to spell them a second time. Two copies of a string make
\"the same headings\" true only until someone edits one of them."
```

---

### Task 2: §7.3's two output schemas

**Files:**
- Create: `StenoKit/AI/StandupSchema.swift`
- Test: `StenoTests/AI/StandupSchemaTests.swift`

**Interfaces:**
- Consumes: `AIOutputSchema(name:json:)` and `StandupDraft.decode(_:cadence:)` from M3-01.
- Produces: `StandupSchema.schema(for: ReportCadence) -> AIOutputSchema`. Task 5 puts it on the request; `AnthropicWire.messagesBody` parses it back out and nests it under `output_config.format`.

**Two things settled here.** `task_id` is a plain string with `format: "uuid"` — the shape is constrained, the *membership* is not (D-149). And the documents are Swift string literals rather than `JSONSerialization` output: an assembled schema has to be `try`-ed at a call site that cannot fail, and its key order becomes an argument about options instead of something a reader can see.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import StenoKit

/// §7.3's two schemas: the shape, and that it agrees with what decodes it.

private func document(for cadence: ReportCadence) throws -> [String: Any] {
    let schema = StandupSchema.schema(for: cadence)
    let parsed = try JSONSerialization.jsonObject(with: schema.json)
    return try #require(parsed as? [String: Any])
}

private func bulletDefinition(in document: [String: Any]) throws -> [String: Any] {
    let defs = try #require(document["$defs"] as? [String: Any])
    return try #require(defs["bullet"] as? [String: Any])
}

@Test("both schemas are JSON, named, and closed to extra properties")
func theSchemasAreWellFormed() throws {
    for cadence in [ReportCadence.daily, .periodic] {
        let document = try document(for: cadence)
        #expect(document["type"] as? String == "object")
        // Required for every object by the structured-output subset, and the
        // reason a section the model invents is a schema violation rather than
        // a silently ignored key.
        #expect(document["additionalProperties"] as? Bool == false)
        #expect(try bulletDefinition(in: document)["additionalProperties"] as? Bool == false)
    }

    #expect(StandupSchema.schema(for: .daily).name == "standup_daily")
    #expect(StandupSchema.schema(for: .periodic).name == "standup_periodic")
}

@Test("daily requires §7.3's three DSU sections; periodic requires its own three")
func eachCadenceRequiresItsOwnSections() throws {
    let daily = try document(for: .daily)
    #expect(daily["required"] as? [String] == ["since_last_standup", "today", "blockers"])

    let periodic = try document(for: .periodic)
    #expect(periodic["required"] as? [String] == ["completed", "in_flight", "blockers_and_risks"])
}

@Test("required and properties name exactly the same keys, both ways round")
func theSchemasAreInternallyConsistent() throws {
    // **Both directions, deliberately.** "Every required key exists" passes on
    // a schema carrying a fourth section the decoder has never heard of, and
    // "every property is required" passes on one whose `required` list has
    // drifted to a name no property defines — which the API rejects as an
    // invalid schema, on the call, in front of the user.
    for cadence in [ReportCadence.daily, .periodic] {
        let document = try document(for: cadence)
        let required = Set(try #require(document["required"] as? [String]))
        let properties = Set(try #require(document["properties"] as? [String: Any]).keys)
        #expect(required == properties, "\(cadence) root")

        let bullet = try bulletDefinition(in: document)
        let bulletRequired = Set(try #require(bullet["required"] as? [String]))
        let bulletProperties = Set(try #require(bullet["properties"] as? [String: Any]).keys)
        #expect(bulletRequired == bulletProperties, "\(cadence) bullet")
    }
}

@Test("the task reference is singular for daily and plural for periodic")
func theCardinalityDiffers() throws {
    // §7.3: the two schemas "are not cosmetic variants of each other — the
    // sections differ, and so does the cardinality of the task reference".
    let daily = try bulletDefinition(in: try document(for: .daily))
    #expect(daily["required"] as? [String] == ["task_id", "text"])
    let dailyID = try #require(
        (daily["properties"] as? [String: Any])?["task_id"] as? [String: Any])
    #expect(dailyID["type"] as? String == "string")
    // Shape, not membership: D-149 rejects constraining *which* ids are legal.
    #expect(dailyID["format"] as? String == "uuid")
    #expect(dailyID["enum"] == nil)

    let periodic = try bulletDefinition(in: try document(for: .periodic))
    #expect(periodic["required"] as? [String] == ["task_ids", "text"])
    let ids = try #require(
        (periodic["properties"] as? [String: Any])?["task_ids"] as? [String: Any])
    #expect(ids["type"] as? String == "array")
    let items = try #require(ids["items"] as? [String: Any])
    #expect(items["format"] as? String == "uuid")
    #expect(items["enum"] == nil)
}

@Test("a response built from the schema's own key names decodes into a draft")
func theSchemaAgreesWithTheDecoder() throws {
    // **The coupling test, and the reason the structural checks above are not
    // enough.** The schema names the wire keys the model will use; the drafts'
    // private `CodingKeys` name the wire keys the app will read, and nothing
    // connects the two but this. A schema key renamed without its `CodingKey`
    // passes every check above and then fails on every real call — reported as
    // a schema violation, which reads as a misbehaving model.
    //
    // The JSON below is built *out of the schema document*, never out of
    // literals: a version of this test that spelled the keys itself would agree
    // with the decoder while the schema drifted away from both.
    let identifier = UUID()

    let daily = try document(for: .daily)
    let dailySections = try #require(daily["required"] as? [String])
    let dailyKeys = try #require(bulletDefinition(in: daily)["required"] as? [String])
    #expect(dailySections.count == 3)
    #expect(dailyKeys.count == 2)

    let dailyBody = try encode([
        dailySections[0]: [[dailyKeys[0]: identifier.uuidString, dailyKeys[1]: "did a thing"]],
        dailySections[1]: [], dailySections[2]: [],
    ])
    guard case .daily(let draft) = try StandupDraft.decode(dailyBody, cadence: .daily) else {
        Issue.record("a daily response decoded as something other than a daily draft")
        return
    }
    #expect(draft.sinceLastStandup == [DailyBullet(taskID: identifier, text: "did a thing")])
    #expect(draft.today.isEmpty)
    #expect(draft.blockers.isEmpty)

    let periodic = try document(for: .periodic)
    let periodicSections = try #require(periodic["required"] as? [String])
    let periodicKeys = try #require(bulletDefinition(in: periodic)["required"] as? [String])
    #expect(periodicSections.count == 3)
    #expect(periodicKeys.count == 2)

    let periodicBody = try encode([
        periodicSections[0]: [
            [periodicKeys[0]: [identifier.uuidString], periodicKeys[1]: "shipped it"]
        ],
        periodicSections[1]: [], periodicSections[2]: [],
    ])
    guard case .periodic(let themed) = try StandupDraft.decode(periodicBody, cadence: .periodic)
    else {
        Issue.record("a periodic response decoded as something other than a periodic draft")
        return
    }
    #expect(themed.completed == [ThemedBullet(taskIDs: [identifier], text: "shipped it")])
    #expect(themed.inFlight.isEmpty)
    #expect(themed.blockersAndRisks.isEmpty)
}

/// A response body with the keys the schema asked for.
private func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}
```

- [ ] **Step 2: Run them to watch them fail**

Run: `make test 2>&1 | grep -E "❌|error:"`
Expected: a compile failure — `cannot find 'StandupSchema' in scope`. That is the correct red for a type that does not exist yet; do not proceed on any other error.

- [ ] **Step 3: Write `StenoKit/AI/StandupSchema.swift`**

```swift
import Foundation

/// §7.3's two output schemas, selected by `project.reportCadence` (D17).
///
/// **They are not cosmetic variants of each other** — §7.3's words. The
/// sections differ, and so does the cardinality of the task reference:
/// `daily` carries `task_id`, `periodic` carries `task_ids`, and that plural
/// is what licenses a themed bullet to span several tasks while the app can
/// still link it back to every one of them.
///
/// **`task_id` is a plain string, not an `enum` of the ids the app sent**
/// (D-149). Constraining it would make a hallucinated id impossible to express
/// — but a model that has invented a sentence still emits that sentence, now
/// attached to a real task, and the user reads a fabricated claim aloud under a
/// correct attribution. §7.3 wants the opposite: "a hallucinated ID is the
/// clearest possible signal the model invented a fact, and it should fail
/// loudly into the §7.4 fallback rather than render."
///
/// **`format: "uuid"` is set, which is a different question from D-149.** The
/// Anthropic structured-output subset supports the `uuid` string format, and
/// constraining the *shape* of an id costs nothing and keeps a malformed UUID
/// out of `StandupDraft.decode`, where it would arrive as a schema violation
/// with no way to tell it from an invented section. Constraining *which* ids
/// are allowed is the thing D-149 rejects, and nothing here does that.
///
/// **Written as literals rather than assembled through `JSONSerialization`.**
/// The assembled version has to be `try`-ed at a call site where it cannot
/// fail, and its key order is an argument about options rather than something
/// a reader can see. A literal is greppable, diffable, byte-stable by
/// construction, and is checked by `StandupSchemaTests` parsing it back.
public enum StandupSchema {
    /// The schema this cadence's response is constrained to.
    public static func schema(for cadence: ReportCadence) -> AIOutputSchema {
        switch cadence {
        case .daily:
            AIOutputSchema(name: "standup_daily", json: Data(daily.utf8))
        case .periodic:
            AIOutputSchema(name: "standup_periodic", json: Data(periodic.utf8))
        }
    }

    /// §7.3's `daily` schema: one bullet per task, three DSU sections.
    ///
    /// `additionalProperties: false` throughout, and every section required:
    /// a response missing `blockers` is a schema violation rather than an empty
    /// section, because "no blockers" is a thing the model must say rather than
    /// omit.
    static let daily = """
        {
          "additionalProperties": false,
          "properties": {
            "blockers": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "since_last_standup": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "today": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" }
          },
          "required": ["since_last_standup", "today", "blockers"],
          "type": "object",
          "$defs": {
            "bullet": {
              "additionalProperties": false,
              "properties": {
                "task_id": { "format": "uuid", "type": "string" },
                "text": { "type": "string" }
              },
              "required": ["task_id", "text"],
              "type": "object"
            }
          }
        }
        """

    /// §7.3's `periodic` schema: themed bullets that may each span several
    /// tasks, hence `task_ids`.
    static let periodic = """
        {
          "additionalProperties": false,
          "properties": {
            "blockers_and_risks": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "completed": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" },
            "in_flight": { "items": {"$ref": "#/$defs/bullet"}, "type": "array" }
          },
          "required": ["completed", "in_flight", "blockers_and_risks"],
          "type": "object",
          "$defs": {
            "bullet": {
              "additionalProperties": false,
              "properties": {
                "task_ids": { "items": {"format": "uuid", "type": "string"}, "type": "array" },
                "text": { "type": "string" }
              },
              "required": ["task_ids", "text"],
              "type": "object"
            }
          }
        }
        """
}
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`.

- [ ] **Step 5: Prove the coupling test can fail**

The most valuable assertion here is the one tying the schema's key names to the decoder's `CodingKeys`. Verify it by mutation, because a version of it that spelled the keys itself would agree with the decoder while the schema drifted away from both:

```bash
sed -i '' 's/"since_last_standup"/"since_the_last_standup"/g' StenoKit/AI/StandupSchema.swift
make test; echo "exit $?"   # must be non-zero
git checkout StenoKit/AI/StandupSchema.swift 2>/dev/null || true
```

**The file is untracked at this point, so `git checkout` will not restore it** — copy it aside first (`cp StenoKit/AI/StandupSchema.swift /tmp/`) and copy it back. This exact trap produced twelve false "caught" results in an earlier task.

Run the `required`-only mutation too, replacing just the `"required"` line, to confirm `theSchemasAreInternallyConsistent` catches a `required` list that has drifted from `properties` — the API rejects that as an invalid schema, on the call, in front of the user.

- [ ] **Step 6: Commit**

```bash
make format
git add StenoKit/AI/StandupSchema.swift StenoTests/AI/StandupSchemaTests.swift
git commit -m "feat: add §7.3's two output schemas

Selected by cadence, with task_id left unconstrained as to membership:
§7.3 wants a hallucinated id to fail loudly, and an enum would coerce an
invented sentence onto a real task instead (D-149)."
```

---

### Task 3: §7.3's prompt

**Files:**
- Create: `StenoKit/AI/StandupPrompt.swift`
- Create: `StenoTests/AI/DraftFixture.swift`
- Test: `StenoTests/AI/StandupPromptTests.swift`

**Interfaces:**
- Consumes: `GatheredWindow`, `GatheredTask`, `GatheredEvent`, `Status`, `EventKind`, `ReportCadence`.
- Produces: `StandupPrompt.system(for: ReportCadence) -> String` and `StandupPrompt.user(for: GatheredWindow, timeZone: TimeZone = .current) -> String`. Task 5 puts both on the request. `DraftFixture.window(_:tasks:)`, `.task(...)`, `.event(...)` are used by Tasks 4 and 5 as well.

**The system half carries no user data and the user half carries no instructions.** That split is what lets a test assert the constraints by equality rather than by substring against a string that grows with the user's task list.

- [ ] **Step 1: Write the fixture**

```swift
import Foundation

@testable import StenoKit

/// Windows built by hand, for the types between the gatherer and the provider.
///
/// **No `ModelContainer` here, unlike `ReportFixture`.** `GatheredWindow` and
/// its parts are plain value types — that is the reason they exist (their own
/// doc comment: "M3-03 hands this to an `AIProvider` across an async boundary")
/// — so a prompt, a schema or a section mapping can be tested without a store
/// at all. `ReportFixture` stays the right tool for anything that must read
/// what the gatherer actually produces.
enum DraftFixture {
    /// 2023-11-14 22:13:20 UTC, matching `ReportFixture.origin` so a reader
    /// comparing the two suites is looking at the same instant.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    static func event(
        _ body: String, kind: EventKind = .note, offset: TimeInterval = 3600
    ) -> GatheredEvent {
        GatheredEvent(timestamp: origin.addingTimeInterval(offset), kind: kind, body: body)
    }

    static func task(
        _ title: String,
        id: UUID = UUID(),
        status: Status = .inProgress,
        keys: [String] = [],
        blockedReason: String? = nil,
        events: [GatheredEvent] = []
    ) -> GatheredTask {
        GatheredTask(
            id: id, title: title, status: status, ticketKeys: keys,
            blockedReason: blockedReason, events: events)
    }

    static func window(
        _ cadence: ReportCadence = .daily, tasks: [GatheredTask]
    ) -> GatheredWindow {
        GatheredWindow(
            projectID: UUID(), cadence: cadence, start: origin,
            end: origin.addingTimeInterval(86_400), tasks: tasks)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing

@testable import StenoKit

// §7.3's constraints and the record they are applied to.

// MARK: - The constraints

@Test("every §7.3 constraint reaches the model, under both cadences")
func theConstraintsAreAllPresent() {
    // Phrases rather than whole sentences: the wording may be tuned against a
    // live model, but a constraint disappearing entirely is the failure this
    // pins. Each line is one requirement from §7.3's "hard requirements" list.
    let required = [
        "Never introduce a fact",
        "probably",
        "Preserve verbatim",
        "ticket keys",
        "error strings",
        "acronyms",
        "Light polish only",
        "enhanced authentication reliability",
        "too thin to summarize",
        "No markdown",
    ]
    for cadence in [ReportCadence.daily, .periodic] {
        let prompt = StandupPrompt.system(for: cadence)
        for phrase in required {
            #expect(prompt.contains(phrase), "\(cadence) prompt lost: \(phrase)")
        }
    }
}

@Test("the daily prompt asks for one line per task and guards D12")
func theDailyPromptGuardsPrioritization() {
    let prompt = StandupPrompt.system(for: .daily)

    #expect(prompt.contains("One line per task"))
    // D-153: `today` is the only forward-looking field in either schema, and
    // D12 forbids focus suggestions and prioritization outright.
    #expect(prompt.contains("Do not recommend what to work on"))
    #expect(prompt.contains("prioritize"))
    // The periodic grouping licence must not leak into a daily prompt: §7.3
    // says "a `daily` bullet that tried to do this would be a bug".
    #expect(!prompt.contains("8–12"))
}

@Test("the periodic prompt asks for 8–12 grouped bullets, not one per task")
func thePeriodicPromptCondenses() {
    let prompt = StandupPrompt.system(for: .periodic)

    #expect(prompt.contains("8–12"))
    #expect(prompt.contains("Condense, do not"))
    #expect(prompt.contains("may cover several tasks"))
    #expect(!prompt.contains("One line per task"))
}

// MARK: - The record

@Test("the window renders as a deterministic record")
func theUserPromptIsExact() throws {
    let first = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    let second = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    let window = DraftFixture.window(tasks: [
        DraftFixture.task(
            "Flaky auth test in CI", id: first, keys: ["STENO-12", "STENO-19"],
            events: [
                DraftFixture.event("found the race in the token refresh", offset: 3600),
                DraftFixture.event("In Progress → Done", kind: .statusChanged, offset: 7200),
            ]),
        DraftFixture.task(
            "Ship the retry fix", id: second, status: .blocked,
            blockedReason: "waiting on infra to bump the runner image"),
    ])

    let expected = """
        Window: 2023-11-14T22:13:20Z to 2023-11-15T22:13:20Z

        TASK 11111111-1111-1111-1111-111111111111  [in progress]  STENO-12, STENO-19
          Title: Flaky auth test in CI
          2023-11-14T23:13:20Z  note  found the race in the token refresh
          2023-11-15T00:13:20Z  status  In Progress → Done

        TASK 22222222-2222-2222-2222-222222222222  [blocked]
          Title: Ship the retry fix
          Blocked: waiting on infra to bump the runner image
          (no events in window)
        """

    #expect(StandupPrompt.user(for: window, timeZone: .gmt) == expected)
}

@Test("a task with no events says so rather than going silent")
func aQuietTaskIsStated() {
    let window = DraftFixture.window(tasks: [DraftFixture.task("nothing said about this one")])

    // `GatheredTask.events` "may be empty, and a renderer must handle that
    // honestly": omitting the line would read to a model as an omission rather
    // than as the fact that nothing was written.
    #expect(StandupPrompt.user(for: window).contains("(no events in window)"))
}

@Test("the time zone is the caller's, not the machine's")
func theTimeZoneIsInjected() throws {
    let window = DraftFixture.window(tasks: [DraftFixture.task("anything")])

    let utc = StandupPrompt.user(for: window, timeZone: .gmt)
    let tokyo = try StandupPrompt.user(
        for: window, timeZone: #require(TimeZone(identifier: "Asia/Tokyo")))

    // Not merely "the parameter is accepted" — the rendered instants differ,
    // which is what makes the suite independent of where it runs.
    #expect(utc != tokyo)
    #expect(utc.contains("22:13:20Z"))
    #expect(tokyo.contains("07:13:20"))
}
```

- [ ] **Step 3: Run them to watch them fail**

Run: `make test 2>&1 | grep -E "❌|error:"`
Expected: `cannot find 'StandupPrompt' in scope`.

- [ ] **Step 4: Write `StenoKit/AI/StandupPrompt.swift`**

```swift
import Foundation

/// §7.3's prompt: the constraints on one side, the event log on the other.
///
/// **The system half carries no user data and the user half carries no
/// instructions.** The split is what makes the constraints assertable by
/// equality in a test rather than by substring against a string that grows with
/// the user's task list — and §7.3's constraints are the property this whole
/// milestone rests on, since a model that elevates register hands the user
/// words they have to say out loud to their team.
///
/// **Authored here rather than in a provider**, per `StandupRequest`'s own doc
/// comment: a provider that composed its own prompt would mean every future
/// provider re-derived these constraints, and the one that got them wrong would
/// inflate the user's language in front of their team.
public enum StandupPrompt {

    // MARK: - System

    /// §7.3's constraints, plus the two it implies rather than prints.
    ///
    /// Cadence-dependent because two of the constraints are: `daily` is "one
    /// line per task", `periodic` is "group into 8–12 themed bullets", and
    /// §7.3 is explicit that the two schemas "are not cosmetic variants of each
    /// other".
    public static func system(for cadence: ReportCadence) -> String {
        (shared + cadenceRules(for: cadence)).joined(separator: "\n")
    }

    /// The constraints that hold under both cadences.
    ///
    /// Copied from §7.3 rather than paraphrased. A paraphrase here is a second
    /// version of the requirement, and the one the model actually reads.
    private static let shared: [String] = [
        "You are summarizing a developer's own work log so they can read it "
            + "aloud at a stand-up.",
        "",
        "Rules, all of them hard:",
        "- Never introduce a fact that is not in the log below. Make no "
            + "inference about what the user \"probably\" did, intended, or "
            + "will do.",
        "- Preserve verbatim: ticket keys, service names, function names, "
            + "error strings, and acronyms. Copy them character for character.",
        "- Light polish only. Organize fragments into clean sentences. Do not "
            + "elevate the register. \"fixed the flaky auth test\" must not "
            + "become \"enhanced authentication reliability\" — the user has to "
            + "say these words out loud, and inflated language is actively "
            + "harmful.",
        "- If a task's events are too thin to summarize, output the raw note "
            + "rather than padding it.",
        "- Write plain sentences. No markdown, no bullet characters, no bold, "
            + "no headings. Formatting is the application's job.",
        "- Reference tasks only by the ids given below, exactly as spelled.",
    ]

    /// The two rules that differ by cadence (D17).
    private static func cadenceRules(for cadence: ReportCadence) -> [String] {
        switch cadence {
        case .daily:
            [
                "- One line per task. Stand-up updates are spoken, not read.",
                // D-153. The only forward-looking field in either schema, and
                // therefore the only structural invitation to violate D12 —
                // which forbids focus suggestions and prioritization outright.
                "- \"today\" restates which tasks are currently in progress, "
                    + "drawn from the log. Do not recommend what to work on, in "
                    + "what order, or what to prioritize.",
            ]
        case .periodic:
            [
                "- This window may cover dozens of tasks. Condense, do not "
                    + "enumerate: group related work into themed bullets and "
                    + "aim for 8–12 bullets in total, regardless of how long "
                    + "the window is.",
                "- A themed bullet may cover several tasks — list every task id "
                    + "it covers. This is the only place you may combine tasks, "
                    + "and you still may not invent facts.",
            ]
        }
    }

    // MARK: - User

    /// The window as a record the model reads (§7.3's "input: the event log").
    ///
    /// Plain text rather than JSON: the model reads this as a record, and the
    /// direction that needs a schema already has one.
    ///
    /// **`timeZone` is injected.** A formatter reading `TimeZone.current`
    /// directly makes these tests pass in one time zone and fail in another,
    /// which this repo has already paid for once in its date handling.
    ///
    /// Task order is `ReportGatherer`'s, preserved and never recomputed —
    /// ordering has exactly one owner, and it is not this file.
    public static func user(
        for window: GatheredWindow, timeZone: TimeZone = .current
    ) -> String {
        let formatter = Self.formatter(in: timeZone)
        var lines = [
            "Window: \(formatter.string(from: window.start)) to "
                + "\(formatter.string(from: window.end))"
        ]
        for task in window.tasks {
            lines.append("")
            lines.append(contentsOf: block(task, formatter: formatter))
        }
        return lines.joined(separator: "\n")
    }

    /// One task: its header, its title, its blocked reason, and its events.
    private static func block(
        _ task: GatheredTask, formatter: ISO8601DateFormatter
    ) -> [String] {
        let keys = task.ticketKeys.isEmpty ? "" : "  " + task.ticketKeys.joined(separator: ", ")
        var lines = [
            "TASK \(task.id.uuidString)  [\(label(task.status))]" + keys,
            "  Title: \(task.title)",
        ]
        if let reason = task.blockedReason {
            lines.append("  Blocked: \(reason)")
        }
        if task.events.isEmpty {
            // Emitted rather than omitted. `GatheredTask.events` "may be empty,
            // and a renderer must handle that honestly": a task admitted to the
            // window because it is currently in progress with nothing said
            // about it is precisely the task Monday's stand-up is about, and
            // silence here reads to a model as an omission rather than a fact.
            lines.append("  (no events in window)")
        }
        for event in task.events {
            lines.append(
                "  \(formatter.string(from: event.timestamp))  "
                    + "\(label(event.kind))  \(event.body)")
        }
        return lines
    }

    /// **Every kind the gatherer returns is sent, including the machine-authored
    /// ones.** §7.3 asks for "all events in [windowStart, now] with timestamps",
    /// and a status transition is a fact the summary needs — D-072 keeps
    /// `created` and `statusChanged` out of what the *user* reads aloud, not out
    /// of what the model reads. `standupReported` cannot appear: D-066 keeps it
    /// out of every window.
    private static func label(_ kind: EventKind) -> String {
        switch kind {
        case .created: "created"
        case .note: "note"
        case .statusChanged: "status"
        case .blockedReason: "blocked"
        case .externalUpdate: "external"
        case .standupReported: "reported"
        }
    }

    /// Prompt vocabulary, declared here rather than borrowed from the UI: a
    /// wording change in a menu must not silently change what is sent to a
    /// model.
    private static func label(_ status: Status) -> String {
        switch status {
        case .todo: "to do"
        case .inProgress: "in progress"
        case .blocked: "blocked"
        case .done: "done"
        }
    }

    /// Seconds precision, no fractional part: §10.2 needs milliseconds because
    /// it arbitrates merges by timestamp, and nothing here does.
    private static func formatter(in timeZone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`. If `theUserPromptIsExact` fails, diff the two strings rather than adjusting the expectation — the whole point of an exact-match test is that drift is visible.

- [ ] **Step 6: Commit**

```bash
make format
git add StenoKit/AI/StandupPrompt.swift StenoTests/AI/DraftFixture.swift StenoTests/AI/StandupPromptTests.swift
git commit -m "feat: author §7.3's prompt, constraints apart from the record

The system half holds every hard requirement in §7.3 plus two it implies:
no markdown (formatting is the app's job) and a D12 guard on the daily
schema's forward-looking \"today\" section, which is the one place our own
schema invites the prioritization D12 forbids (D-153)."
```

---

### Task 4: The draft becomes sections

**Files:**
- Create: `StenoKit/AI/DraftSections.swift`
- Test: `StenoTests/AI/DraftSectionsTests.swift`

**Interfaces:**
- Consumes: `StandupDraft` / `DailyDraft` / `PeriodicDraft` / `DailyBullet` / `ThemedBullet` (M3-01), `ReportSection` / `ReportBullet` (M2-02), `ReportHeadings` (Task 1), `DraftFixture` (Task 3).
- Produces: `DraftSections.build(from: StandupDraft, window: GatheredWindow) -> [ReportSection]`. Task 5 renders the result through `SlackMarkdown.render`.

**Two rules live here.** Ticket keys the model dropped are re-attached in the raw path's exact format (D-150), and bullets with no words are dropped (D-152).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import StenoKit

/// Turning §7.3's validated bullets into the sections M2-02 already renders.

@Test("a daily draft becomes the same three headings the raw path uses")
func dailySectionsMatchTheRawPath() {
    let task = DraftFixture.task("anything")
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: task.id, text: "found the race")],
            today: [DailyBullet(taskID: task.id, text: "still on it")],
            blockers: []))

    let sections = DraftSections.build(from: draft, window: window)

    // Compared against `ReportHeadings` rather than against
    // `RawReportSections`' output: two paths that drifted the same way would
    // still agree with each other.
    #expect(sections.map(\.title) == ReportHeadings.ordered(for: .daily))
    #expect(sections.map(\.title) == RawReportSections.build(from: window).map(\.title))
    #expect(sections[0].bullets.map(\.text) == ["found the race"])
    #expect(sections[1].bullets.map(\.text) == ["still on it"])
    #expect(sections[2].bullets.isEmpty)
    // One line per bullet: `ReportBullet.details`' default is what an AI bullet
    // uses, and a detail line here would be something the model did not write.
    #expect(sections[0].bullets.allSatisfy { $0.details.isEmpty })
}

@Test("a periodic draft becomes the periodic headings, in the order returned")
func periodicSectionsKeepTheModelsOrder() {
    let first = DraftFixture.task("one")
    let second = DraftFixture.task("two")
    let window = DraftFixture.window(.periodic, tasks: [first, second])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [
                ThemedBullet(taskIDs: [second.id], text: "second"),
                ThemedBullet(taskIDs: [first.id], text: "first"),
            ],
            inFlight: [], blockersAndRisks: []))

    let sections = DraftSections.build(from: draft, window: window)

    #expect(sections.map(\.title) == ReportHeadings.ordered(for: .periodic))
    // The model's order, not the window's: a themed bullet has no task order to
    // inherit, and re-sorting would break the narrative it grouped them into.
    #expect(sections[0].bullets.map(\.text) == ["second", "first"])
}

// MARK: - D-150, the ticket keys

@Test("a key the model dropped is re-attached in the raw path's format")
func aDroppedKeyIsReattached() {
    let task = DraftFixture.task("auth", keys: ["STENO-12", "STENO-19"])
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: task.id, text: "fixed the flaky auth test")],
            today: [], blockers: []))

    let text = DraftSections.build(from: draft, window: window)[0].bullets.first?.text
    #expect(text == "fixed the flaky auth test (STENO-12, STENO-19)")
}

@Test("a key the model kept is not appended twice, whatever its case")
func aKeptKeyIsNotDuplicated() {
    let task = DraftFixture.task("auth", keys: ["STENO-12"])
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [
                DailyBullet(taskID: task.id, text: "landed STENO-12 behind a flag"),
                DailyBullet(taskID: task.id, text: "landed steno-12 behind a flag"),
            ],
            today: [], blockers: []))

    let texts = DraftSections.build(from: draft, window: window)[0].bullets.map(\.text)
    #expect(texts[0] == "landed STENO-12 behind a flag")
    // Preserved badly is still preserved: a second copy would read worse than
    // the imperfect original.
    #expect(texts[1] == "landed steno-12 behind a flag")
}

@Test("a themed bullet gathers every task's keys, deduped, first occurrence first")
func themedKeysAreGatheredAndDeduped() {
    let first = DraftFixture.task("one", keys: ["STENO-12", "STENO-30"])
    let second = DraftFixture.task("two", keys: ["STENO-12", "STENO-44"])
    let window = DraftFixture.window(.periodic, tasks: [first, second])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [ThemedBullet(taskIDs: [first.id, second.id], text: "cleaned up retries")],
            inFlight: [], blockersAndRisks: []))

    let text = DraftSections.build(from: draft, window: window)[0].bullets.first?.text
    #expect(text == "cleaned up retries (STENO-12, STENO-30, STENO-44)")
}

@Test("a task id the window does not hold contributes no keys and no crash")
func anUnknownIDIsInert() {
    let task = DraftFixture.task("known", keys: ["STENO-12"])
    let window = DraftFixture.window(tasks: [task])
    // Unreachable through a provider — `StandupDraft.validated(against:)` runs
    // first — but this type must not be the thing that traps if it ever is.
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: UUID(), text: "from nowhere")],
            today: [], blockers: []))

    let text = DraftSections.build(from: draft, window: window)[0].bullets.first?.text
    #expect(text == "from nowhere")
}

// MARK: - D-152, blank bullets

@Test("a bullet with no words is dropped, keys and all")
func blankBulletsAreDropped() {
    let task = DraftFixture.task("auth", keys: ["STENO-12"])
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [
                DailyBullet(taskID: task.id, text: "   \n  "),
                DailyBullet(taskID: task.id, text: "a real sentence"),
            ],
            today: [DailyBullet(taskID: task.id, text: "")],
            blockers: []))

    let sections = DraftSections.build(from: draft, window: window)

    // Without the drop these render as `• (STENO-12)` and `• ` — a bullet the
    // user reads aloud that says nothing at all.
    #expect(sections[0].bullets.map(\.text) == ["a real sentence (STENO-12)"])
    #expect(sections[1].bullets.isEmpty)
}

@Test("a bullet with words and no task ids is kept")
func anUnattributedBulletSurvives() {
    let window = DraftFixture.window(.periodic, tasks: [DraftFixture.task("one")])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [ThemedBullet(taskIDs: [], text: "tidied up the CI config")],
            inFlight: [], blockersAndRisks: []))

    // `StandupDraft.isEmpty`'s own doc comment: "a bullet with an empty
    // `task_ids` array is still a bullet the model wrote, and losing it
    // silently would be worse than surfacing it." D-152 narrows nothing there.
    #expect(
        DraftSections.build(from: draft, window: window)[0].bullets.map(\.text)
            == ["tidied up the CI config"])
}
```

- [ ] **Step 2: Run them to watch them fail**

Run: `make test 2>&1 | grep -E "❌|error:"`
Expected: `cannot find 'DraftSections' in scope`.

- [ ] **Step 3: Write `StenoKit/AI/DraftSections.swift`**

```swift
import Foundation

/// §7.3's returned structure, rendered into the sections M2-02 already emits.
///
/// **The same `[ReportSection]` the raw path produces, so both end at the same
/// `SlackMarkdown.render`.** §7.3: "The app renders markdown from whichever
/// structure came back. Never ask the model to format the final Slack text —
/// formatting is the app's job, and separating them makes output stable."
/// `ReportSection`'s own doc comment named this type before it existed: "M3-03
/// produces them from schema-validated AI bullets."
///
/// A stenographer, like `RawReportSections`, with one licence the raw path does
/// not have: it appends ticket keys (D-150). Everything else the model wrote
/// reaches the user unedited.
public enum DraftSections {
    /// Build the three sections this draft's cadence calls for.
    ///
    /// **Cadence comes from the draft's own case, not from the window.** The
    /// two agree by construction — the request carried the window's cadence —
    /// and reading it here means a mismatched pair cannot be assembled at all.
    public static func build(from draft: StandupDraft, window: GatheredWindow) -> [ReportSection] {
        let keys = ticketKeys(in: window)
        switch draft {
        case .daily(let daily):
            return [
                ReportSection(
                    title: ReportHeadings.sinceLastStandup,
                    bullets: bullets(daily.sinceLastStandup, keys: keys)),
                ReportSection(
                    title: ReportHeadings.today, bullets: bullets(daily.today, keys: keys)),
                ReportSection(
                    title: ReportHeadings.blockers, bullets: bullets(daily.blockers, keys: keys)),
            ]
        case .periodic(let periodic):
            return [
                ReportSection(
                    title: ReportHeadings.completed,
                    bullets: bullets(periodic.completed, keys: keys)
                ),
                ReportSection(
                    title: ReportHeadings.inFlight, bullets: bullets(periodic.inFlight, keys: keys)),
                ReportSection(
                    title: ReportHeadings.blockersAndRisks,
                    bullets: bullets(periodic.blockersAndRisks, keys: keys)),
            ]
        }
    }

    /// Each task's ticket keys, already sorted by the gatherer (D-065).
    ///
    /// `uniquingKeysWith` rather than `uniqueKeysWithValues`: the gatherer
    /// cannot return one task twice, and a trap on an invariant held elsewhere
    /// is a crash in a stand-up rather than a report.
    private static func ticketKeys(in window: GatheredWindow) -> [UUID: [String]] {
        Dictionary(
            window.tasks.map { ($0.id, $0.ticketKeys) },
            uniquingKeysWith: { first, _ in
                first
            })
    }

    private static func bullets(_ source: [DailyBullet], keys: [UUID: [String]]) -> [ReportBullet] {
        source.compactMap { bullet(text: $0.text, taskIDs: [$0.taskID], keys: keys) }
    }

    /// An overload rather than a protocol over the two bullet types: they carry
    /// their ids under different names and different cardinalities, which is
    /// §7.3's whole point about the two schemas not being cosmetic variants.
    private static func bullets(_ source: [ThemedBullet], keys: [UUID: [String]]) -> [ReportBullet]
    {
        source.compactMap { bullet(text: $0.text, taskIDs: $0.taskIDs, keys: keys) }
    }

    /// One bullet: the model's sentence, plus any ticket key it left out.
    ///
    /// **Blank bullets are dropped** (D-152). `StandupDraft.isEmpty` counts
    /// bullets rather than content, deliberately — its subject is a bullet's
    /// *identity*, not its text — so a model that answers with empty strings
    /// passes validation and would render as `• ` in Slack, or as `• (STENO-12)`
    /// once the keys below are appended.
    ///
    /// **Keys are re-attached rather than trusted** (D-150). A ticket key is a
    /// fact in the event log, on the task this bullet is about, and
    /// `RawReportSections` already emits it on the same bullet in the fallback
    /// path — so the AI path emitting less would be a regression, not restraint.
    /// The prompt still asks the model to preserve keys: this covers the case
    /// where it does not.
    ///
    /// **Presence is checked case-insensitively; the appended form is verbatim.**
    /// A model that wrote "landed steno-12 behind a flag" preserved the key
    /// badly but did preserve it, and appending a second copy would read worse
    /// than the imperfect original.
    ///
    /// `details` stays empty: an AI bullet is one line, which is what
    /// `ReportBullet.details`' default was added for.
    private static func bullet(
        text: String, taskIDs: [UUID], keys: [UUID: [String]]
    ) -> ReportBullet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let haystack = trimmed.lowercased()
        var missing: [String] = []
        for key in taskIDs.flatMap({ keys[$0] ?? [] })
        where !missing.contains(key) && !haystack.contains(key.lowercased()) {
            missing.append(key)
        }

        guard !missing.isEmpty else { return ReportBullet(text: trimmed) }
        return ReportBullet(text: trimmed + " (\(missing.joined(separator: ", ")))")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`.

- [ ] **Step 5: Commit**

```bash
make format
git add StenoKit/AI/DraftSections.swift StenoTests/AI/DraftSectionsTests.swift
git commit -m "feat: render §7.3's bullets into M2-02's sections

Both paths now end at the same SlackMarkdown.render. The renderer
re-attaches any ticket key the model left out: a key is a fact in the
event log, the raw path already emits it, and the AI path emitting less
would be a regression rather than restraint (D-150)."
```

---

### Task 5: The summarizer, and every path to §7.4's raw report

**Files:**
- Create: `StenoKit/AI/StandupSummarizer.swift`
- Test: `StenoTests/AI/StandupSummarizerTests.swift`

**Interfaces:**
- Consumes: `AIProvider`, `AIError`, `StandupRequest`, `AnthropicProvider.recommendedDraftTimeout` (at the call site, not here), Tasks 2–4.
- Produces: `SummarizedStandup(markdown:modelUsed:)`, `StandupSummarizer(provider:modelID:timeout:timeZone:)`, `summarize(_:) async -> SummarizedStandup` (no `throws`), and `StandupSummarizer.rawMarkdown(for:)` — which Task 8 uses as the draft model's default.

**`summarize` cannot throw, and that is §7.4 as a type**: there is no error a caller could be handed, so there is no path on which a caller could forget to degrade.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import StenoKit

/// §7.4: "the user must never arrive at a stand-up empty-handed."

private let modelID = "claude-test-1"

/// A window with one task and something to say about it.
private func window(_ cadence: ReportCadence = .daily) -> GatheredWindow {
    DraftFixture.window(
        cadence,
        tasks: [
            DraftFixture.task(
                "Flaky auth test in CI", keys: ["STENO-12"],
                events: [DraftFixture.event("found the race in the token refresh")])
        ])
}

/// A draft the model could plausibly have returned for `window`.
private func draft(for window: GatheredWindow, text: String = "Fixed the flaky auth test")
    -> StandupDraft
{
    let ids = window.tasks.map(\.id)
    switch window.cadence {
    case .daily:
        return .daily(
            DailyDraft(
                sinceLastStandup: ids.map { DailyBullet(taskID: $0, text: text) },
                today: [], blockers: []))
    case .periodic:
        return .periodic(
            PeriodicDraft(
                completed: [ThemedBullet(taskIDs: ids, text: text)],
                inFlight: [], blockersAndRisks: []))
    }
}

private func summarizer(
    provider: (any AIProvider)?, modelID: String? = modelID
) -> StandupSummarizer {
    StandupSummarizer(
        provider: provider, modelID: modelID, timeout: .seconds(20),
        timeZone: .gmt)
}

// MARK: - The AI path

@Test("a validated draft becomes the report, and records the model that wrote it")
func aSuccessfulDraftIsRendered() async {
    let window = window()
    let provider = StubAIProvider(draft: .success(draft(for: window)))

    let result = await summarizer(provider: provider).summarize(window)

    #expect(result.modelUsed == modelID)
    #expect(result.markdown.contains("Fixed the flaky auth test (STENO-12)"))
    // **The load-bearing half of the degradation table below.** Without this,
    // a summarizer that ignored its provider and always returned the raw report
    // would pass every fallback row and the whole suite would be green.
    #expect(result.markdown != StandupSummarizer.rawMarkdown(for: window))
}

@Test("the request carries §7.3's prompt, schema, ids and budget")
func theRequestIsAssembledHere() async throws {
    let window = window(.periodic)
    let provider = StubAIProvider(draft: .success(draft(for: window)))

    _ = await summarizer(provider: provider).summarize(window)

    let request = try #require(await provider.received.first)
    #expect(request.modelID == modelID)
    #expect(request.cadence == .periodic)
    #expect(request.systemPrompt == StandupPrompt.system(for: .periodic))
    #expect(
        request.userPrompt
            == StandupPrompt.user(for: window, timeZone: .gmt))
    #expect(request.outputSchema == StandupSchema.schema(for: .periodic))
    // §7.3's hallucination check runs inside the provider, so the ids have to
    // ride on the request rather than stay with the caller.
    #expect(request.allowedTaskIDs == Set(window.tasks.map(\.id)))
    #expect(request.maxOutputTokens == StandupSummarizer.maxOutputTokens)
    #expect(request.timeout == .seconds(20))
}

// MARK: - §7.4, every way down

@Test(
    "every provider failure produces the raw report instead",
    arguments: [
        AIError.notConfigured,
        .invalidCredential,
        .invalidRequest,
        .network,
        .timedOut,
        .rateLimited(retryAfter: nil),
        .rateLimited(retryAfter: .seconds(3)),
        .providerUnavailable(status: 503),
        .invalidResponse(.undecodable),
        .invalidResponse(.schemaViolation),
        .invalidResponse(.emptyDraft),
        .invalidResponse(.refused),
        .invalidResponse(.truncated),
        .unknownTaskIDs(count: 2),
    ])
func everyFailureDegrades(_ error: AIError) async {
    let window = window()
    let provider = StubAIProvider(draft: .failure(error))

    let result = await summarizer(provider: provider).summarize(window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
}

/// A provider that breaks `AIProvider`'s error contract.
///
/// The protocol says an implementation throws `AIError` and nothing else, so
/// this cannot happen today — and the catch-all it exercises is what keeps a
/// future provider's leaked `URLError` from taking down the draft path instead
/// of roughening it.
private struct ContractBreakingProvider: AIProvider {
    let id = "contract-breaker"
    let displayName = "Contract Breaker"
    func availableModels() async throws -> [AIModel] { [] }
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        throw URLError(.badServerResponse)
    }
    func testConnection() async throws {}
}

@Test("an error the protocol forbids still degrades rather than escaping")
func aNonAIErrorDegrades() async {
    let window = window()

    let result = await summarizer(provider: ContractBreakingProvider()).summarize(window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
}

@Test("a draft of nothing but blank bullets is treated as no draft at all")
func aBlankDraftDegrades() async {
    let window = window()
    let blank = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: window.tasks.map { DailyBullet(taskID: $0.id, text: "  ") },
            today: [], blockers: []))
    let provider = StubAIProvider(draft: .success(blank))

    let result = await summarizer(provider: provider).summarize(window)

    // It passed `validated(against:)` — which counts bullets, not words — and
    // would otherwise render as three headings of empty bullets. §7.4's rough
    // report is strictly better (D-152).
    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
}

// MARK: - The rows that never reach the network

@Test("no provider, no selected model, or no tasks: no call is made at all")
func theUnconfiguredRowsMakeNoCall() async {
    let window = window()
    let raw = StandupSummarizer.rawMarkdown(for: window)

    let noModel = StubAIProvider(draft: .success(draft(for: window)))
    let withoutModel = await summarizer(provider: noModel, modelID: nil).summarize(window)
    #expect(withoutModel.markdown == raw)
    #expect(withoutModel.modelUsed == nil)
    #expect(await noModel.received.isEmpty)

    let withoutProvider = await summarizer(provider: nil).summarize(window)
    #expect(withoutProvider.markdown == raw)
    #expect(withoutProvider.modelUsed == nil)

    // An empty window is not an error — D-074 renders it as three headings that
    // each say `_None_` — and the only answer a call could return is an empty
    // draft, reached more slowly and for money.
    let empty = DraftFixture.window(tasks: [])
    let quiet = StubAIProvider(draft: .success(draft(for: window)))
    let result = await summarizer(provider: quiet).summarize(empty)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: empty))
    #expect(result.modelUsed == nil)
    #expect(await quiet.received.isEmpty)
}

@Test("the fallback is the same text M2-02 renders, byte for byte")
func theFallbackIsM2s() async {
    let window = window(.periodic)

    let result = await summarizer(provider: nil).summarize(window)

    // Not a paraphrase of the raw path and not a second renderer: §7.4's
    // "rougher content, same three headings" is literally M2-02's output.
    #expect(result.markdown == SlackMarkdown.render(RawReportSections.build(from: window)))
    #expect(result.markdown.contains(ReportHeadings.completed))
}
```

- [ ] **Step 2: Run them to watch them fail**

Run: `make test 2>&1 | grep -E "❌|error:"`
Expected: `cannot find 'StandupSummarizer' in scope`.

- [ ] **Step 3: Write `StenoKit/AI/StandupSummarizer.swift`**

```swift
import Foundation

/// A report and how it was produced (§7.3, §7.4).
///
/// **`modelUsed == nil` is the fallback**, and it is the only carrier of that
/// fact: `StandupReport.wasAIGenerated` is derived from it (D-151) rather than
/// set beside it, so the two cannot disagree about what the user copied.
public struct SummarizedStandup: Sendable, Equatable {
    public let markdown: String

    /// The model id that produced this, or `nil` when §7.4's raw path did.
    public let modelUsed: String?

    public init(markdown: String, modelUsed: String?) {
        self.markdown = markdown
        self.modelUsed = modelUsed
    }
}

/// §7.3's call and §7.4's degradation, in one place that cannot throw.
///
/// **`summarize` has no `throws`, and that is §7.4 expressed as a type.** "The
/// user must never arrive at a stand-up empty-handed because of a network
/// error" — so there is no error a caller could be handed, and therefore no
/// path on which a caller could forget to degrade. Every failure below returns
/// the same raw report M2-02 built for this window.
///
/// **The fallback is not the error handler.** §7.4 required the raw path be
/// built *first*, and M3-03's reading is that the draft sheet opens on it
/// (D-148): this type is what upgrades that text, not what rescues it.
public struct StandupSummarizer: Sendable {
    /// D-154: one budget for both cadences. A worst-case `daily` answer under
    /// D18's 20-task cap is roughly 3,000 tokens, and `periodic` is capped at
    /// 8–12 bullets by the prompt. Erring high costs nothing — output tokens
    /// are billed as used — while erring low makes the AI silently never work.
    public static let maxOutputTokens = 4096

    private let provider: (any AIProvider)?
    private let modelID: String?
    private let timeout: Duration
    private let timeZone: TimeZone

    /// - Parameters:
    ///   - provider: `nil` when no provider is configured at all.
    ///   - modelID: the user's selection from M3-04's picker; `nil` until they
    ///     have made one, which is every launch until M3-04 ships.
    ///   - timeout: passed in rather than read from a vendor constant — the
    ///     composition root already chooses the provider, so it supplies the
    ///     budget with it. A vendor-neutral type naming one vendor's constant
    ///     would make §7.1's neutrality true by convention rather than by
    ///     construction.
    ///   - timeZone: injected for the prompt's timestamps, so a test does not
    ///     depend on the machine's zone.
    public init(
        provider: (any AIProvider)?,
        modelID: String?,
        timeout: Duration,
        timeZone: TimeZone = .current
    ) {
        self.provider = provider
        self.modelID = modelID
        self.timeout = timeout
        self.timeZone = timeZone
    }

    /// The best report this window can produce right now.
    public func summarize(_ window: GatheredWindow) async -> SummarizedStandup {
        let fallback = SummarizedStandup(markdown: Self.rawMarkdown(for: window), modelUsed: nil)

        // No provider, no selected model, or nothing to summarize: the raw
        // report without a network call. An empty window is not an error — it
        // is three headings that each say `_None_` (D-074) — and paying for a
        // call whose only possible answer is an empty draft would be a slower
        // way to reach this same string.
        guard let provider, let modelID, !window.tasks.isEmpty else { return fallback }

        do {
            let draft = try await provider.generateStandup(
                request(for: window, modelID: modelID))
            let sections = DraftSections.build(from: draft, window: window)

            // D-152. `StandupDraft.validated(against:)` already rejected an empty
            // draft inside the provider, but it counts bullets rather than
            // content: a model answering with blank strings passes there and
            // arrives here as three empty sections.
            guard sections.contains(where: { !$0.bullets.isEmpty }) else {
                degraded(.invalidResponse(.emptyDraft))
                return fallback
            }

            return SummarizedStandup(
                markdown: SlackMarkdown.render(sections), modelUsed: modelID)
        } catch let error as AIError {
            degraded(error)
            return fallback
        } catch {
            // **An error the protocol says cannot occur.** `AIProvider`'s
            // contract is that an implementation throws `AIError` and nothing
            // else. This is one line, and without it a future provider leaking
            // a `URLError` takes the draft path down instead of roughening it —
            // which is the one outcome §7.4 exists to prevent.
            Log.report.error("the summarizer caught a non-AIError; a provider broke its contract")
            return fallback
        }
    }

    /// §7.4's raw report for this window: M2-02's two pure functions, unchanged.
    ///
    /// `static` and free of everything this type holds, so "the fallback needs
    /// no provider, no key, and no network" is visible in the signature.
    ///
    /// `public` because it is also what `StandupDraftModel` opens the sheet
    /// with when no polish is configured: one name for §7.4's raw report keeps
    /// the two paths from drifting into two spellings of the same two calls.
    public static func rawMarkdown(for window: GatheredWindow) -> String {
        SlackMarkdown.render(RawReportSections.build(from: window))
    }

    /// Everything §7.3 sends, assembled where the constraints live.
    private func request(for window: GatheredWindow, modelID: String) -> StandupRequest {
        StandupRequest(
            modelID: modelID,
            cadence: window.cadence,
            systemPrompt: StandupPrompt.system(for: window.cadence),
            userPrompt: StandupPrompt.user(for: window, timeZone: timeZone),
            outputSchema: StandupSchema.schema(for: window.cadence),
            // Every id the prompt mentions, so the provider can run §7.3's
            // hallucination check before a draft reaches anything that renders.
            allowedTaskIDs: Set(window.tasks.map(\.id)),
            maxOutputTokens: Self.maxOutputTokens,
            timeout: timeout
        )
    }

    /// Why this report is the rough one.
    ///
    /// **`Log.report`, not `Log.aiLayer`.** This is a decision the report path
    /// made, not a measurement of an AI call — §8 gives the `ai` category to
    /// `AIMetricsLog.record` as its only emitter, and the provider has already
    /// written this call's metrics line there.
    ///
    /// Carries `metricsLabel` and nothing else: it is a word from a fixed
    /// vocabulary, and no `AIError` case holds free-form text precisely so that
    /// logging one cannot leak a stand-up (§8).
    private func degraded(_ error: AIError) {
        Log.report.info(
            "standup fell back to the raw report: \(error.metricsLabel, privacy: .public)")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`.

- [ ] **Step 5: Prove the degradation table can fail**

**On its own it cannot.** A summarizer that ignored its provider entirely and always returned the raw report passes every row of `everyFailureDegrades`. The success case is what holds it honest, so verify the pair by mutation:

```bash
cp StenoKit/AI/StandupSummarizer.swift /tmp/summarizer.bak
# make the success path return the fallback
python3 - <<'EOF'
import pathlib
p = pathlib.Path("StenoKit/AI/StandupSummarizer.swift")
s = p.read_text()
s = s.replace("            return SummarizedStandup(\n                markdown: SlackMarkdown.render(sections), modelUsed: modelID)", "            return fallback")
p.write_text(s)
EOF
make test; echo "exit $?"   # must be non-zero
cp /tmp/summarizer.bak StenoKit/AI/StandupSummarizer.swift
```

Repeat for the blank-draft guard, the `!window.tasks.isEmpty` guard, and the non-`AIError` catch-all. All four must turn the suite red.

- [ ] **Step 6: Commit**

```bash
make format
git add StenoKit/AI/StandupSummarizer.swift StenoTests/AI/StandupSummarizerTests.swift
git commit -m "feat: add the summarizer, with §7.4 wired as a first-class path

Every failure — no key, no model, offline, rate limited, refused,
truncated, a hallucinated id, an error the protocol forbids — returns the
same raw report M2-02 renders. summarize() has no throws, so there is no
path on which a caller could forget to degrade."
```

---

### Task 6: The settings key M3-04 will write

**Files:**
- Modify: `StenoKit/Settings/AppSettings.swift`
- Test: `StenoTests/AI/AISecretsTests.swift` (the `allKeys` count)

**Interfaces:**
- Produces: `AppSettings.aiSelectedModelIDKey` and `var aiSelectedModelID: String?`. Task 9 reads it per call; M3-04 writes it.

- [ ] **Step 1: Add the key, the property, and the `allKeys` entry**

```swift
    // MARK: - §7.1, the AI provider

    /// The model id `StandupSummarizer` sends (§7.1, D-141).
    ///
    /// **Declared here by M3-03 and written by M3-04.** The summarizer needs
    /// somewhere to read a selection from before the picker that writes it
    /// exists; until then this is always absent, every stand-up takes §7.4's
    /// raw path, and that is this task's sixth acceptance criterion rather than
    /// a gap in it.
    ///
    /// **A model id, not a provider id.** Only Anthropic ships, §7.1's
    /// abstraction is exercised by `StubAIProvider`, and a setting with one
    /// possible value and no UI is a field M3-04 would have to either use or
    /// delete.
    ///
    /// Not a credential and never near one: §8 keeps keys in the Keychain, and
    /// `AISecretsTests` reads `allKeys` to assert exactly that.
    public static let aiSelectedModelIDKey = "com.lgabrielgr.steno.ai.selectedModelID"

    /// The user's chosen model, or `nil` when they have not chosen one.
    ///
    /// An empty string reads as `nil`: `UserDefaults` will happily store one,
    /// and a model id of `""` reaches the API as a 400 the user cannot explain.
    public var aiSelectedModelID: String? {
        get {
            let raw = defaults.string(forKey: Self.aiSelectedModelIDKey)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        nonmutating set {
            guard let newValue, !newValue.isEmpty else {
                defaults.removeObject(forKey: Self.aiSelectedModelIDKey)
                return
            }
            defaults.set(newValue, forKey: Self.aiSelectedModelIDKey)
        }
    }

    // MARK: - §10.5, auto-export
```

Add `aiSelectedModelIDKey` to the `allKeys` array as well — the array is what §8's audit reads.

- [ ] **Step 2: Watch the audit go red**

Run: `make test 2>&1 | grep "recorded an issue"`
Expected: `Expectation failed: AppSettings.allKeys.count == 8`. **This failure is the guard working.** A new key must be listed in `allKeys`, and listing it moves the number — that is what stops the credential-pattern audit from passing by covering nothing.

- [ ] **Step 3: Move the number**

In `StenoTests/AI/AISecretsTests.swift`, `#expect(AppSettings.allKeys.count == 8)` becomes `== 9`.

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`. The other assertion in that test — that no key is *named* like a credential — still holds: `ai.selectedModelID` is a model id, and the key itself lives in the Keychain (§8).

- [ ] **Step 5: Commit**

```bash
make format
git add StenoKit/Settings/AppSettings.swift StenoTests/AI/AISecretsTests.swift
git commit -m "feat: declare the selected-model setting M3-04 will write

The summarizer needs somewhere to read a selection from before the picker
that writes it exists. Until M3-04 it is always absent, every stand-up
takes §7.4's raw path, and that is this task's sixth acceptance criterion."
```

---

### Task 7: `wasAIGenerated` becomes derived

**Files:**
- Modify: `StenoKit/Report/StandupService.swift`
- Modify (call sites): `StenoTests/Report/StandupUndoServiceTests.swift`, `StenoTests/Report/StandupUndoRoundTripTests.swift`, `StenoTests/Portability/ExportFixture.swift`, `StenoTests/Portability/LastStandupClockTests.swift`, `StenoTests/Notes/EventLogInvariantTests.swift`
- Test: `StenoTests/Report/StandupServiceTests.swift`

**Interfaces:**
- Produces: `commit(_:of:for:modelUsed:) throws -> StandupCommit`. **No default value on `modelUsed`** — Task 8 is the only production caller.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
@Test("wasAIGenerated is derived from modelUsed, in both directions")
func theAIFlagFollowsTheModel() throws {
    let fixture = try ReportFixture()
    let window = try windowWithOneTask(fixture)

    _ = try fixture.standupService(nowOffset: 900)
        .commit(editedDraft, of: window, for: fixture.alpha, modelUsed: "claude-test-1")

    let reported = try #require(fixture.reportsInStore().first)
    #expect(reported.modelUsed == "claude-test-1")
    // D-151: derived rather than passed beside it, so the two fields cannot
    // disagree about what produced the text the user copied.
    #expect(reported.wasAIGenerated)

    let second = try ReportFixture()
    let secondWindow = try windowWithOneTask(second)
    _ = try second.standupService(nowOffset: 900)
        .commit(editedDraft, of: secondWindow, for: second.alpha, modelUsed: nil)

    let fallback = try #require(second.reportsInStore().first)
    #expect(fallback.modelUsed == nil)
    #expect(fallback.wasAIGenerated == false)
}
```

- [ ] **Step 2: Run it to watch it fail**

Run: `make test 2>&1 | grep -E "❌|error:"`
Expected: `extra argument 'modelUsed' in call`.

- [ ] **Step 3: Change the signature and derive the flag**

```swift
public func commit(
    _ body: String, of window: GatheredWindow, for project: Project, modelUsed: String?
) throws -> StandupCommit {
```

and, in the `StandupReport` it inserts:

```swift
            markdownBody: body,
            wasAIGenerated: modelUsed != nil,
            modelUsed: modelUsed
        )
```

- [ ] **Step 4: Update the existing call sites**

Every one passes `modelUsed: nil` — they are all testing the pre-AI path:

```bash
grep -rn "\.commit(" StenoTests | grep -v "field.commit\|model.commit\|noteComposer"
```

Expected after editing: `make build` is clean. **Resist adding a default value to make this step go away** — a defaulted `nil` means every future caller silently records an AI report as a fallback, and the compiler stops asking (D-151).

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`.

- [ ] **Step 6: Commit**

```bash
make format
git add StenoKit/Report/StandupService.swift StenoTests
git commit -m "feat: derive wasAIGenerated from the model that wrote the draft

Two independently written fields are one refactor away from a report
marked AI-generated with no model recorded — the exact state that makes
the field useless for the debugging its own declaration names (D-151)."
```

---

### Task 8: The sheet opens on the raw report and upgrades in place

**Files:**
- Modify: `StenoKit/Features/MainWindow/StandupDraftModel.swift`
- Test: `StenoTests/Features/MainWindow/StandupDraftPolishTests.swift`

**Interfaces:**
- Consumes: `SummarizedStandup`, `StandupSummarizer.rawMarkdown(for:)` (Task 5), `commit(_:of:for:modelUsed:)` (Task 7).
- Produces: `StandupDraftModel(service:undoService:polish:)` where `polish` is `@MainActor (GatheredWindow) async -> SummarizedStandup`, plus `isPolishing` and `aiModelUsed`. Task 9 supplies the closure; Task 10's sheet reads `isPolishing`.

**This is D-148.** `begin(window:text:)` starts the polish itself rather than leaving a second call for the caller to remember — a step that cannot be forgotten beats one documented as required.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

// D-148: the sheet opens on M2-02's raw report and upgrades in place, but only
// while the user has not touched it.

/// A string the renderer would never produce, so "the user's edit wins" cannot
/// pass against an implementation that re-renders or re-installs.
private let editedDraft = "the user rewrote every word of this by hand"

/// A draft sheet whose §7.3 call answers with `result`.
@MainActor
private func draftBeingPolished(
    _ fixture: ReportFixture, answering result: SummarizedStandup
) throws -> (model: StandupDraftModel, window: GatheredWindow) {
    let task = try fixture.task("ship the thing", in: fixture.alpha, status: .inProgress)
    try fixture.event("found the race in setUp", on: task, at: 60)
    try fixture.setLastStandup(ReportFixture.origin, on: fixture.alpha)
    let window = try fixture.gatherer(nowOffset: 300).gather(for: fixture.alpha)

    let model = StandupDraftModel(
        service: fixture.standupService(nowOffset: 900),
        undoService: fixture.standupUndoService(),
        polish: { _ in result })
    model.begin(window: window, text: "generated text")
    return (model, window)
}

/// Let the polish task run to completion.
///
/// Bounded rather than `while model.isPolishing`: a defect that leaves the flag
/// set should fail the assertion that follows, not hang the suite.
@MainActor
private func settle(_ model: StandupDraftModel) async {
    for _ in 0..<1000 {
        if !model.isPolishing { return }
        await Task.yield()
    }
}

@MainActor
@Test("the AI draft replaces the raw one when the user has not typed")
func thePolishInstallsOverAnUntouchedDraft() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))

    // The sheet is usable from the first frame — §7.4's guarantee is that the
    // user is never holding nothing while a network call decides.
    #expect(model.text == "generated text")
    #expect(model.canCopy)

    await settle(model)

    #expect(model.text == "polished")
    #expect(model.aiModelUsed == "model-x")
    #expect(model.phase == .editing)
}

@MainActor
@Test("a draft the user has started editing is never overwritten")
func thePolishYieldsToTheUser() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))

    // FR-4 step 6 and §7.3: the user's phrasing is the final word. Text
    // replaced under a cursor would violate both.
    model.text = editedDraft
    await settle(model)

    #expect(model.text == editedDraft)
    #expect(model.aiModelUsed == nil, "an AI draft that was discarded did not produce this report")
}

@MainActor
@Test("a fallback result leaves the raw draft and the flag alone")
func aFallbackChangesNothing() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "some other text", modelUsed: nil))

    await settle(model)

    // Nothing is installed when `modelUsed` is nil. In production the fallback
    // markdown is byte-identical to what `begin` installed; the answer here is
    // deliberately different, so a version that assigned it would be caught.
    #expect(model.text == "generated text")
    #expect(model.aiModelUsed == nil)
}

@MainActor
@Test("copying marks the report with the model that wrote it")
func theCommittedReportRecordsTheModel() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))
    await settle(model)

    #expect(model.commit(to: fixture.alpha))

    let report = try #require(fixture.reportsInStore().first)
    #expect(report.markdownBody == "polished")
    #expect(report.wasAIGenerated)
    #expect(report.modelUsed == "model-x")
}

@MainActor
@Test("a report from the raw draft is not marked AI-generated")
func aRawReportIsNotMarkedAIGenerated() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "unused", modelUsed: nil))
    await settle(model)

    #expect(model.commit(to: fixture.alpha))

    let report = try #require(fixture.reportsInStore().first)
    #expect(report.wasAIGenerated == false)
    #expect(report.modelUsed == nil)
}

@MainActor
@Test("editing the AI's words keeps the report marked AI-generated")
func editingAfterThePolishKeepsTheFlag() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))
    await settle(model)

    // The report *was* AI-generated and the user polished it, which is what
    // FR-4 step 6 intends. A flag that flipped on the first keystroke would
    // mark nearly every real AI report as a fallback.
    model.text = editedDraft
    #expect(model.commit(to: fixture.alpha))

    let report = try #require(fixture.reportsInStore().first)
    #expect(report.markdownBody == editedDraft)
    #expect(report.wasAIGenerated)
    #expect(report.modelUsed == "model-x")
}

@MainActor
@Test("dismissing stops the polish and forgets the model")
func dismissEndsThePolish() async throws {
    let fixture = try ReportFixture()
    let (model, _) = try draftBeingPolished(
        fixture, answering: SummarizedStandup(markdown: "polished", modelUsed: "model-x"))

    model.dismiss()
    await settle(model)

    #expect(model.isPolishing == false)
    #expect(model.aiModelUsed == nil)
    #expect(model.text == "")
}
```

- [ ] **Step 2: Run them to watch them fail**

Run: `make test 2>&1 | grep -E "❌|error:"`
Expected: `extra argument 'polish' in call`, and `value of type 'StandupDraftModel' has no member 'isPolishing'`.

- [ ] **Step 3: Add the state and the seam**

```swift
    /// Whether §7.3's call is still in flight (D-148).
    ///
    /// Drives the sheet's "Polishing…" affordance and nothing else. **Copy is
    /// deliberately live while this is true**: the text on screen is M2-02's
    /// raw report, which is a usable stand-up, and §7.4's promise is that the
    /// user is never left holding nothing while a network call decides.
    public private(set) var isPolishing = false

    /// The model that produced the text now on screen, or `nil` for the raw
    /// report (D-151).
    ///
    /// Set in exactly one place — `install(_:)` — and never cleared while the
    /// draft stands, so editing AI text keeps the report marked AI-generated.
    /// That is the honest record: it *was* AI-generated, and FR-4 step 6
    /// intends the user to polish it.
    public private(set) var aiModelUsed: String?

    /// The text as last installed, against which "has the user typed?" is
    /// answered.
    ///
    /// **A stored string rather than a dirty flag.** A user who types and then
    /// undoes back to the original still receives the upgrade, which is what
    /// they would expect, and it costs one comparison.
    private var pristineText = ""

    private var polishTask: Task<Void, Never>?

    private let service: StandupService
    private let undoService: StandupUndoService
    private let polish: @MainActor (GatheredWindow) async -> SummarizedStandup

    /// - Parameter polish: §7.3's call, injected as a closure for the reason
    ///   `service` and `copy` are injected — a seam the headless suite can
    ///   drive without a provider, a credential, or a network (§9.4).
    ///
    ///   **`@MainActor`, like `copy`.** The work inside it is one string build
    ///   and then a suspension on the network, so nothing blocks; isolating the
    ///   closure is what lets the composition root capture `AppSettings` and
    ///   read the selected model at call time rather than at launch.
    ///
    ///   **The default performs no polish**, returning the same raw report the
    ///   caller already rendered. That is not a stub: it is exactly what an
    ///   unconfigured install does, and it is what every launch does until
    ///   M3-04 ships the key field and the model picker.
    public init(
        service: StandupService,
        undoService: StandupUndoService,
        polish: @escaping @MainActor (GatheredWindow) async -> SummarizedStandup = {
            SummarizedStandup(markdown: StandupSummarizer.rawMarkdown(for: $0), modelUsed: nil)
        }
    ) {
        self.service = service
        self.undoService = undoService
        self.polish = polish
    }
```

- [ ] **Step 4: Start the polish in `begin`, and add `install`**

```swift
    /// **Starting the polish is this method's job, not a second call the
    /// caller must remember** (D-148). A step that cannot be forgotten beats
    /// one documented as required, and every path into the sheet goes through
    /// here.
    public func begin(window: GatheredWindow, text: String) {
        polishTask?.cancel()
        self.window = window
        self.text = text
        pristineText = text
        phase = .editing
        committedReport = nil
        lastError = nil
        notice = nil
        aiModelUsed = nil
        isPolishing = true
        polishTask = Task { [weak self] in
            let result = await self?.polish(window)
            guard let self, let result else { return }
            install(result)
        }
    }

    /// The AI draft, if it is still wanted (D-148).
    ///
    /// Four conditions, and each one is a way the result stops being wanted:
    /// the task was cancelled, the sheet moved past `.editing`, the user typed,
    /// or the summarizer fell back.
    ///
    /// **Nothing is installed when `modelUsed` is `nil`.** The fallback markdown
    /// is byte-identical to the text `begin` already installed — same pure
    /// functions, same frozen window — so assigning it would be a no-op that
    /// relied on that coincidence. Skipping it makes the no-op a fact about the
    /// branch instead.
    private func install(_ result: SummarizedStandup) {
        isPolishing = false
        guard !Task.isCancelled, phase == .editing, text == pristineText,
            let model = result.modelUsed
        else { return }

        text = result.markdown
        pristineText = result.markdown
        aiModelUsed = model
    }
```

- [ ] **Step 5: Cancel on dismiss and on commit, and pass the model through**

In `dismiss()`, add `polishTask?.cancel()`, `polishTask = nil`, `isPolishing = false`, `pristineText = ""`, `aiModelUsed = nil` alongside the existing resets.

In `commit(to:)`, immediately after the existing guard:

```swift
        // The window is about to be reported; a draft that arrived after this
        // could not be installed anyway (`install` requires `.editing`), and
        // leaving the call in flight would keep "Polishing…" on screen above a
        // stand-up that has already been copied.
        polishTask?.cancel()
        isPolishing = false
```

and the service call becomes:

```swift
            let result = try service.commit(
                draft, of: window, for: project, modelUsed: aiModelUsed)
```

- [ ] **Step 6: Run the tests**

Run: `make test 2>&1 | grep -E "recorded an issue|Test Execute"`
Expected: `Test Execute Succeeded`.

- [ ] **Step 7: Split the test file if SwiftLint objects**

`make lint` caps a file at 400 lines. The polish tests live in their own file for that reason; if you appended them to `StandupDraftModelTests.swift` instead, move them now rather than shortening the comments.

- [ ] **Step 8: Prove the guard can fail**

```bash
cp StenoKit/Features/MainWindow/StandupDraftModel.swift /tmp/draft.bak
# drop the untouched check
python3 - <<'EOF'
import pathlib
p = pathlib.Path("StenoKit/Features/MainWindow/StandupDraftModel.swift")
s = p.read_text()
s = s.replace("phase == .editing, text == pristineText,", "phase == .editing,")
p.write_text(s)
EOF
make test; echo "exit $?"   # must be non-zero — thePolishYieldsToTheUser
cp /tmp/draft.bak StenoKit/Features/MainWindow/StandupDraftModel.swift
```

Repeat with `let model = result.modelUsed` changed to `result.modelUsed ?? "unknown"`; `aFallbackChangesNothing` must go red.

- [ ] **Step 9: Commit**

```bash
make format
git add StenoKit/Features/MainWindow/StandupDraftModel.swift StenoTests/Features/MainWindow/StandupDraftPolishTests.swift
git commit -m "feat: open the draft on the raw report and upgrade it in place

§7.4 asked for the fallback to be built first; this makes it the opening
state rather than the catch block. The AI draft replaces it only while the
user has not typed — FR-4 step 6 makes their phrasing final (D-148)."
```

---

### Task 9: Wiring, and the affordance

**Files:**
- Modify: `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Modify: `Steno/Features/MainWindow/StandupDraftSheet.swift`

**Interfaces:**
- Consumes: everything above, plus `AnthropicProvider`, `KeychainCredentialStore`, `AppSettings`.
- Produces: `MainWindowModel.standupPolish(settings:)`, and a running app in which Prepare Stand-up takes the AI path as soon as M3-04 stores a key and a model.

- [ ] **Step 1: Add the factory next to the rest of FR-4's wiring**

```swift
    /// §7.3's call, as `StandupDraftModel` takes it (D-148).
    ///
    /// **Assembled here because this is where the concrete provider is
    /// chosen** — which is also why `StandupSummarizer` takes its timeout as a
    /// parameter instead of reading one vendor's constant from inside a
    /// vendor-neutral type (§7.1).
    ///
    /// **Built per call, and the model id read per call.** M3-04's picker
    /// writes `aiSelectedModelID` while this model is alive, and a summarizer
    /// captured at launch would go on sending the model the user had just
    /// changed away from until the app was relaunched.
    ///
    /// With no key in the Keychain the provider throws `.notConfigured` and the
    /// draft stays exactly as M2-02 rendered it. That is every launch until
    /// M3-04 ships the key field — §7.4 working, rather than a gap.
    ///
    /// `static`, so `init` can call it before `self` exists.
    static func standupPolish(
        settings: AppSettings
    ) -> @MainActor (GatheredWindow) async -> SummarizedStandup {
        { window in
            await StandupSummarizer(
                provider: AnthropicProvider(credentials: KeychainCredentialStore()),
                modelID: settings.aiSelectedModelID,
                timeout: AnthropicProvider.recommendedDraftTimeout
            ).summarize(window)
        }
    }

    /// FR-4 needs exactly one project to report on.
```

**It lives here rather than inline in `init` because `MainWindowModel.swift` is at 400 lines** — SwiftLint's cap — and because this is where the rest of the stand-up wiring already is.

- [ ] **Step 2: Pass it in**

In `MainWindowModel.init`, the `StandupDraftModel` construction becomes:

```swift
        self.standupDraft = StandupDraftModel(
            service: StandupService(context: context, now: now, save: save, copy: copy),
            undoService: StandupUndoService(context: context, save: save),
            polish: Self.standupPolish(settings: settings))
```

- [ ] **Step 3: Add the affordance to the sheet**

In `StandupDraftSheet`'s `buttons`, after the `⌘↩ to copy` hint and before `Spacer()`:

```swift
            // D-148: the AI call is in flight and the text on screen is
            // M2-02's raw report. Copy stays live throughout — §7.4's promise
            // is that the user is never left holding nothing while a network
            // call decides, and a disabled button during a 20-second call is
            // exactly that.
            if draft.isPolishing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Polishing…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Verify**

Run: `make build && make test && make lint`
Expected: `Build Succeeded`, `Test Execute Succeeded`, `Found 0 violations`.

**GUI verification is not available to an implementing agent** — there is no way to click Prepare Stand-up and look. Every assertion about this behaviour lives on `StandupDraftModel` in `StenoKit`; the visual check belongs to the user at review. Do not claim the affordance was seen working.

- [ ] **Step 5: Commit**

```bash
make format
git add StenoKit/Features/MainWindow Steno/Features/MainWindow/StandupDraftSheet.swift
git commit -m "feat: wire the summarizer into Prepare Stand-up

Built per call and the model id read per call: M3-04's picker writes the
selection while this model is alive, and a summarizer captured at launch
would keep sending the model the user had just changed away from."
```

---

### Task 10: The record — decisions, the README, and the PR

**Files:**
- Modify: `docs/DECISIONS.md` (D-148 … D-154)
- Modify: `docs/tasks/README.md` (this task's row, plus any merged-but-unticked rows)
- Modify: `docs/superpowers/specs/2026-09-23-m3-03-summarization-call-design.md` if implementation contradicted it

- [ ] **Step 1: Check the decision log's maximum before writing a number**

Run: `grep -oE 'D-[0-9]{3}' docs/DECISIONS.md | sort -u | tail -3`
Expected: `D-147` is the maximum. **Read it; do not infer it from a sibling spec** — inferring it once shipped a duplicate D-140 that a diff could not see, and needed its own follow-up PR to renumber.

- [ ] **Step 2: Write D-148 through D-154**

One entry each, in the spec's order: the fallback-first sheet, the unconstrained `task_id`, app-side key re-attachment, the derived `wasAIGenerated`, blank-bullet dropping, the D12 guard on `today`, and the 4096-token budget. Each states the decision, the rejected alternative, and why the alternative loses — the spec already argues all seven; the entries are the short form.

- [ ] **Step 3: Tick the README rows**

Check `docs/tasks/README.md` for rows that merged without being ticked and tick them in this PR alongside M3-03's — CLAUDE.md's working-a-task step 4 exists because nothing else prompts it and §9.5 forbids a direct commit to `main`. M2.5-01's row is known to be outstanding.

- [ ] **Step 4: Note the spec deviation**

Implementation changed one thing the spec asserts: the schemas are **Swift string literals**, not `JSONSerialization` output with `.sortedKeys`. Amend that line in the spec and say so in the PR body rather than letting the two disagree.

- [ ] **Step 5: Run the full gate**

Run: `make build && make test && make lint`
Expected: all three green. Then `git status` — `Steno.xcodeproj` and `Local.xcconfig` must not appear.

- [ ] **Step 6: Open the PR**

Read `.github/pull_request_template.md` **before** writing the body — `gh pr create` bypasses it silently.

The body must state, in these terms:

> **Acceptance criteria 3 (partly), 4 and 5 are not verified.** No live model has seen this prompt: `make test` denies the network by design (§9.4, D-012) and this task ships no CLI seam around it. What the suite proves is that each §7.3 constraint is present in the bytes that will be sent, that the ticket-key half of criterion 3 holds by construction (D-150), and that every failure of the live call degrades to M2-02's report. Register, grouping, and the survival of service names and error strings are verified in M3-04, alongside the key field and `make verify-models`.

- [ ] **Step 7: Decide whether this plan survives**

M3-02 removed its plan before merge, and recorded why: a plan generated from a
built tree earns its keep by finding defects before the first commit, then
becomes a stale-claim generator once the tree exists and review starts changing
it. That entry was explicit that it is **not** a precedent for skipping the
plan — which is why this one was written. Decide now, with the diff in front of
you: keep it if the embedded code still matches the tree, delete it if review
has moved the tree out from under it. Either way `DECISIONS.md` and the spec
carry the reasoning.

- [ ] **Step 8: Surface §12's Q(M3) in the PR body**

"Should the app retain a history of past reports for browsing?" is due before M3
ships and this task does not answer it. `StandupReport` already persists every
report with its window and its `markdownBody`, so the data exists; what is
missing is a decision about whether anything reads it. Name it in the PR body so
it does not reach M3-04 — the milestone's last task — still open.

- [ ] **Step 9: Work the review to green**

Run the Copilot fix / reply / resolve loop without being asked, and check collapsed body sections — a "Findings: None" summary has hidden real defects before. Report only when the PR is green.

**Do not merge.** The user reviews and merges (§9.5 step 7).

---

## Verification Summary

| Command | Gate |
|---|---|
| `make build` | Compiles. Grep for `❌`, not `error:` — xcbeautify prints the latter for other things and neither for a failing build |
| `make test` | Headless, no network. Check the exit code; `Test Execute Succeeded` is the human-readable form |
| `make lint` | `Found 0 violations`. File length ≤ 400 lines is the one that bites here |
| `make format` | Run before every commit; a dirty tree afterwards is your change (D-075) |

**Fifteen mutations must turn the suite red.** Four in the summarizer (ignore the draft, keep a blank draft, call on an empty window, mark a contract-breaking provider as AI), four in `DraftSections` (drop the keys, match case-sensitively, keep blank bullets, hardcode a heading), two in the draft model (overwrite the user's words, install the fallback), two in the prompt (lose the D12 guard, hide a quiet task), two in the schema (a key drifting everywhere, `required` drifting from `properties`), and one in the service (always claim AI). A survivor means a mis-aimed mutation, a weak test, or a fix at the wrong level — in that order of likelihood.

**Restore mutated files from a copy, not from `git checkout`.** New files are untracked until their task commits, and `git checkout` silently leaves them mutated — which once produced twelve false "caught" results in a row.
