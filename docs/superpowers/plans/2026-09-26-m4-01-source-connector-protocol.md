# M4-01 — SourceConnector Protocol, Cache & Refresh Policy: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship §5.1's `SourceConnector`, the registry that routes a `SourceRef` to it, the durable
cache, and §5.5's refresh policy — such that a failed or absent integration can never block a
stand-up report.

**Architecture:** A pure connector protocol (values in, values out, `SourceError` and nothing
else); a `SourceRegistry` that routes on `canHandle` plus configuration; a non-throwing
`SourceRefreshService` that is the only writer of external state; and a refresh stage in front of
M3-03's polish stage inside `StandupDraftModel`. External state reaches a report only as
`externalUpdate` events, which both report paths now speak.

**Tech Stack:** Swift 6.0, SwiftData, swift-testing, XcodeGen, SwiftLint + swift-format.

**Spec:** [`docs/superpowers/specs/2026-09-25-m4-01-source-connector-protocol-design.md`](../specs/2026-09-25-m4-01-source-connector-protocol-design.md)

---

## How this plan was produced, and what "execution" means

**The tree is already built and verified on `feat/source-connector-protocol`.** Every code block
below was copied out of a tree where `make build && make test && make lint` all pass (933 tests,
0 lint violations), and every mutation in the table at the end was actually applied and observed
to fail the suite. That ordering is deliberate: writing plan code from imagination has shipped
defects in "verified" blocks on this project before.

So execution is **staging the built tree in this task order** — one commit per task, each
independently building and testing — not re-typing the implementation. Do not delete the
implementation to re-execute the plan.

Seven things this ordering found that the spec did not, listed here because they are the
highest-value part of the document:

1. **The pass budget could not fire.** It was checked only when a fetch result arrived, so a pass
   whose connectors all hang ran for the *per-fetch* deadline instead. Now a sentinel task inside
   the group. (Task 7)
2. **M2-02's renderer drops `externalUpdate`**, while §7.3's prompt already sends it — so "events
   are the route into a report" was silently false for the offline path, and the AI path was
   strictly better than its own fallback. `RawReportSections`' doc comment had explicitly deferred
   this decision to this task. (Task 6, D-180)
3. **The two refresh paths disagreed about what "this task's refs" means** — one read the SwiftData
   relationship, the other the authoritative `taskID`. (Task 7)
4. **`RefreshOutcome` needed `readFailed`** as well as `saveFailed`: a candidate query that fails
   means the pass never ran, which is a different fact from a write that was refused. (Task 7)
5. **The test double raced itself.** Four concurrent fetches appended to an unsynchronized array
   and a record was lost, which showed up as a test asserting a ref had never been fetched when it
   had. An unsynchronized recorder does not just race — it makes the double lie. (Task 2)
6. **`MainWindowModel.swift` was at 398 lines of a 400 limit** and `StenoApp.init` at 49 of 50, so
   this task's wiring broke both. Split along the seams the files already use. (Tasks 9, 10)
7. **One test could not fail.** "No notification for a pass that wrote nothing" used a pass that
   returned *before* the write phase, so a mutation posting unconditionally survived it. (Task 7)

## Global Constraints

- **Never commit to `main`.** One branch, one PR, do not merge (§9.5). Branch:
  `feat/source-connector-protocol`.
- **`make build && make test && make lint` all pass before the PR** (§9.5 step 4, §13).
- **`make test` runs with networking denied** by a `sandbox-exec` profile (§9.4). No `URLSession`
  in this PR; the only `SourceConnector` conformances are test doubles.
- **The event log is append-only.** No mutation or deletion of an `Event`; a found change is a new
  row (§3.3).
- **`SourceConnector` and `AIProvider` stay independent** (§13, ARCH §2 rule 1). The one file under
  `StenoKit/AI/` this task edits beyond a moved utility is `StandupSummarizer.swift`, one predicate,
  declared in the PR body (Task 6).
- **Views never touch the store** (ARCH §2 rule 2): no `@Query`, no `@Environment(\.modelContext)`.
- **Swift 6.0 strict concurrency.** No `@Model` row crosses an isolation boundary.
- **Lint limits are hard:** file ≤ 400 lines, function body ≤ 50 lines excluding comments, no force
  unwrapping, no 2-character identifiers, `swift-format` owns layout (`lineLength` 100).
- **Decision numbers D-164 … D-180.** `DECISIONS.md`'s maximum was D-163; re-check before writing
  (Task 11).
- **Commits** are Conventional-Commits-prefixed and end with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Review Focus

Five conditions the spec implies but does not pin, each now covered by a test in the task that owns
the code:

1. **A connector that throws something other than `SourceError`.** The protocol forbids it; a
   future connector will do it anyway. Expected: the pass degrades and the log names the
   connector — never an error escaping a non-throwing method. → Task 7,
   `aBrokenContractDegrades`.
2. **Two `SourceRef` rows for the same ticket on different tasks.** Expected: two fetches, each
   with its own `since`, and no duplicated `externalUpdate`. → Task 7,
   `rowsSharingAnIdentifierAreNotCoalesced`.
3. **A connector that answers with blank strings.** Expected: no event at all, rather than
   `"PAY-421: "` in a stand-up. → Task 5, `blankContentSaysNothing`.
4. **A ref whose kind nothing handles** — every pasted URL, forever. Expected: silent, not counted
   as a failure, no log line. → Task 3 `anUnclaimedRefIsUnhandled`, Task 7 `unhandledRefsAreSilent`.
5. **A refresh landing while the user has typed in the draft.** Expected: their text and their
   window both survive, and the refresh's events fall into the next report. → Task 9,
   `aTypedDraftIsNotOverwritten`.

---

## Task 1: The shared deadline moves to `Support/`

**Files:**
- Move: `StenoKit/AI/Deadline.swift` → `StenoKit/Support/Deadline.swift`
- Modify: `StenoKit/AI/Anthropic/AnthropicProvider.swift:128`,
  `StenoKit/AI/Anthropic/AnthropicProvider+Draft.swift:62`
- Test: `StenoTests/AI/DeadlineTests.swift` (4 call sites)

**Interfaces:**
- Produces: `withDeadline<T: Sendable, E: Error & Sendable>(_ duration: Duration, throwing timeoutError: E, operation: @escaping @Sendable () async throws -> T) async throws -> T`

- [ ] **Step 1: Move the file, keeping history**

```bash
git mv StenoKit/AI/Deadline.swift StenoKit/Support/Deadline.swift
```

- [ ] **Step 2: Parameterize the timeout error**

The source layer needs the same wall clock and may not name an `AIError` (§13). Both the deadline
branch and the `CancellationError` mapping throw the given error:

```swift
func withDeadline<T: Sendable, E: Error & Sendable>(
    _ duration: Duration,
    throwing timeoutError: E,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await race(duration, throwing: timeoutError, operation: operation)
    } catch is CancellationError {
        throw timeoutError
    }
}

private func race<T: Sendable, E: Error & Sendable>(
    _ duration: Duration,
    throwing timeoutError: E,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw timeoutError
        }

        guard let first = try await group.next() else {
            throw timeoutError
        }
        group.cancelAll()
        return first
    }
}
```

**Required, not defaulted.** A default would put one layer's error type in a signature both layers
share. Keep the existing doc comment — its cancellation reasoning cost a review round and a CI
flake — and update its prose from "`.timedOut`" to "`timeoutError`".

- [ ] **Step 3: Update all six call sites**

```swift
// AnthropicProvider.swift
try await withDeadline(timeout, throwing: AIError.timedOut) {
// AnthropicProvider+Draft.swift
return try await withDeadline(request.timeout, throwing: AIError.timedOut) {
// DeadlineTests.swift — all four
try await withDeadline(.seconds(30), throwing: AIError.timedOut) { 42 }
```

- [ ] **Step 4: Verify — the AI deadline suite is the gate**

```bash
make build && make test
```
Expected: green. This is a pure refactor; `DeadlineTests`, `AnthropicProviderBudgetTests` and
`AnthropicProviderTests` all still pass unchanged in behaviour.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/AI/Anthropic StenoKit/Support/Deadline.swift StenoTests/AI/DeadlineTests.swift
git commit -m "refactor: move withDeadline to Support with an injected timeout error"
```

---

## Task 2: The protocol, the snapshot, the error, and the doubles

**Files:**
- Create: `StenoKit/Integrations/SourceConnector.swift`, `StenoKit/Integrations/SourceError.swift`
- Create: `StenoTests/Integrations/StubSourceConnector.swift`,
  `StenoTests/Integrations/SourceErrorTests.swift`

**Interfaces:**
- Consumes: `SourceRefKind` (M0-03).
- Produces: `SourceRefSnapshot(refID:kind:identifier:url:lastFetchedAt:)`,
  `SourceUpdate(summary:changes:url:fetchedAt:)`, `protocol SourceConnector: Sendable`,
  `enum SourceError` with `metricsLabel` and `LocalizedError`; test doubles
  `StubSourceConnector`, `AlwaysFailingConnector`, `ContractBreakingConnector`,
  `SourceUpdate.stub(...)`.

- [ ] **Step 1: Write `SourceConnector.swift`**

```swift
public struct SourceRefSnapshot: Sendable, Equatable {
    public let refID: UUID
    public let kind: SourceRefKind
    public let identifier: String
    public let url: String?
    public let lastFetchedAt: Date?

    public init(
        refID: UUID, kind: SourceRefKind, identifier: String,
        url: String? = nil, lastFetchedAt: Date? = nil
    ) { … }
}

public struct SourceUpdate: Sendable, Equatable {
    public let summary: String
    public let changes: [String]
    public let url: URL?
    public let fetchedAt: Date
}

public protocol SourceConnector: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool
    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate
    func testConnection() async throws
}
```

**Two deviations from §5.1's printed signature, both declared in the PR body per CLAUDE.md:**
`Sendable` is added (D-131's reason — `fetch` is awaited across an isolation boundary), and the
parameter is a `SourceRefSnapshot` rather than a `SourceRef`, because `SourceRef` is an `@Model`
class and Swift 6 rejects sending it (D-164). `since` stays in the signature even though the
snapshot carries `lastFetchedAt`, so refresh policy stays in the service.

- [ ] **Step 2: Write `SourceError.swift`**

Eight cases, `LocalizedError`, and a `metricsLabel`; **no case carries a free-form `String`**
(D-165, inheriting D-132's security property — a reason string built from an API response puts
ticket titles in the log, against §8). `.notFound` is its own case because it is permanent.

- [ ] **Step 3: Write the doubles, with a locked recorder**

```swift
final class StubSourceConnector: SourceConnector, @unchecked Sendable {
    enum Script: Sendable { case success(SourceUpdate), failure(SourceError), hang }

    private let lock = NSLock()
    private var recorded: [(identifier: String, since: Date?)] = []
    var asked: [(identifier: String, since: Date?)] { lock.withLock { recorded } }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        lock.withLock { recorded.append((ref.identifier, since)) }
        switch scripts[ref.identifier] ?? fallback { … }
    }
}
```

**The lock is not optional.** The service runs four fetches at once; the first version appended to
a plain array from every one of them and lost a record, which surfaced as a test claiming a ref was
never fetched when it had been.

`AlwaysFailingConnector` takes a `kinds:` set. **Do not default a double to claiming every kind
without thinking**: registered first, a greedy double shadows every other connector, which made
the "one failure does not stop the others" test pass for the wrong reason (both refs went to the
failing connector and the working one was never asked).

- [ ] **Step 4: Write `SourceErrorTests`, then run them**

```swift
@Test("every case has its own metrics label")
func labelsAreDistinct() {
    let labels = everyCase.map(\.metricsLabel)
    #expect(Set(labels).count == labels.count)
    #expect(!labels.contains { $0.isEmpty })
}

@Test("§8: no label or message carries an associated value")
func labelsCarryNoPayload() {
    #expect(SourceError.rateLimited(retryAfter: .seconds(30)).metricsLabel == "rateLimited")
    #expect(SourceError.unavailable(status: 503).errorDescription?.contains("503") == false)
}
```

**Do not assert "the message must not contain its label"** — `.unavailable`'s message says
"unavailable" because that is the English word for it, and that assertion fails on correct copy.
Assert the message is a sentence instead: `!= metricsLabel`, contains a space, ends with a period.

```bash
make generate && make build && make test
```

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Integrations/SourceConnector.swift StenoKit/Integrations/SourceError.swift \
        StenoTests/Integrations/StubSourceConnector.swift StenoTests/Integrations/SourceErrorTests.swift
git commit -m "feat: add §5.1's SourceConnector protocol and its error contract"
```

---

## Task 3: The registry

**Files:**
- Create: `StenoKit/Integrations/SourceRegistry.swift`
- Test: `StenoTests/Integrations/SourceRegistryTests.swift`

**Interfaces:**
- Consumes: `SourceConnector`, `SourceRefSnapshot` (Task 2).
- Produces: `enum SourceDispatch { case ready(any SourceConnector), notConfigured, unhandled }`,
  `SourceRegistry(connectors:)` with `dispatch(_:)`, `connector(withID:)`, `all`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("D-166: a claimant with no credential dispatches .notConfigured, not .unhandled")
func anUnconfiguredClaimantIsNotConfigured() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", isConfigured: false)])
    #expect(registry.dispatch(ref()) == .notConfigured)
}

@Test("D-166: registration order is priority among two claimants")
func registrationOrderDecides() {
    // The expectation order disagrees with a plausible implementation's: "second"
    // is declared after "first" and must win when listed first, so a registry that
    // ignored order — or returned the last match — fails here.
    let second = StubSourceConnector(id: "second")
    let first = StubSourceConnector(id: "first")
    guard case .ready(let winner) = SourceRegistry(connectors: [second, first]).dispatch(ref())
    else { Issue.record("expected .ready"); return }
    #expect(winner.id == "second")

    guard case .ready(let reversed) = SourceRegistry(connectors: [first, second]).dispatch(ref())
    else { Issue.record("expected .ready"); return }
    #expect(reversed.id == "first")
}

@Test("configuration is part of routing: an unconfigured first claimant does not shadow")
func anUnconfiguredClaimantDoesNotShadow() { … #expect(winner.id == "jira") }

@Test("D-166: a ref no connector claims is unhandled, and that is not an error")
func anUnclaimedRefIsUnhandled() {
    let registry = SourceRegistry(
        connectors: [StubSourceConnector(id: "jira", kinds: [.jiraIssue])])
    #expect(registry.dispatch(ref(.url)) == .unhandled)
}
```

Plus a test-only `SourceDispatch: @retroactive Equatable` comparing `.ready` by connector id
(`any SourceConnector` is not `Equatable`).

- [ ] **Step 2: Run them — expect failures**

```bash
make generate && make build
```
Expected: `❌ cannot find 'SourceRegistry' in scope`.

- [ ] **Step 3: Implement**

```swift
public func dispatch(_ ref: SourceRefSnapshot) -> SourceDispatch {
    var claimed = false
    for connector in connectors where connector.canHandle(ref) {
        claimed = true
        if connector.isConfigured { return .ready(connector) }
    }
    return claimed ? .notConfigured : .unhandled
}
```

No `register()`: registration order is priority and it lives at the composition root, as one
readable array literal, rather than depending on which Settings pane the user opened first.

- [ ] **Step 4: Verify**

```bash
make build && make test
```
Expected: the six registry tests pass.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Integrations/SourceRegistry.swift StenoTests/Integrations/SourceRegistryTests.swift
git commit -m "feat: route a SourceRef to the connector that handles it"
```

---

## Task 4: The refresh policy

**Files:**
- Create: `StenoKit/Integrations/RefreshPolicy.swift`
- Test: `StenoTests/Integrations/RefreshPolicyTests.swift`

**Interfaces:**
- Produces: `RefreshPolicy.launchStaleness: Duration`,
  `RefreshPolicy.due(_ refs: [SourceRefSnapshot], now: Date, olderThan: Duration) -> [SourceRefSnapshot]`,
  and an internal `Duration.seconds: TimeInterval`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("§5.5: fetched longer ago than the staleness window is due, sooner is not")
func theStalenessWindowSplitsRefs() {
    let refs = [
        snapshot("stale", fetched: origin.addingTimeInterval(-1801)),
        snapshot("fresh", fetched: origin.addingTimeInterval(-1799)),
    ]
    // Both directions in one assertion: naming only the survivor would pass
    // against a policy that returned everything.
    #expect(RefreshPolicy.due(refs, now: origin, olderThan: .seconds(1800))
        .map(\.identifier) == ["stale"])
}

@Test("the boundary is strict: exactly the staleness window old is not due")
func theBoundaryIsStrict() { … #expect(due.isEmpty) }

@Test("a sub-second staleness window is not truncated to zero")
func subSecondWindowsSurvive() {
    // Every service test injects millisecond budgets; a `Duration.seconds`
    // accessor that dropped the attosecond term would make `.milliseconds(50)`
    // behave as zero and every ref look due.
    let refs = [
        snapshot("stale", fetched: origin.addingTimeInterval(-0.100)),
        snapshot("fresh", fetched: origin.addingTimeInterval(-0.010)),
    ]
    #expect(RefreshPolicy.due(refs, now: origin, olderThan: .milliseconds(50))
        .map(\.identifier) == ["stale"])
}
```

- [ ] **Step 2: Run — expect failure**, then implement:

```swift
public static let launchStaleness: Duration = .seconds(30 * 60)

public static func due(
    _ refs: [SourceRefSnapshot], now: Date, olderThan staleness: Duration
) -> [SourceRefSnapshot] {
    let cutoff = now.addingTimeInterval(-staleness.seconds)
    return refs.filter { ref in
        guard let fetched = ref.lastFetchedAt else { return true }
        return fetched < cutoff
    }
}

extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
```

A ref never fetched is always due — that is the pass D-169 seeds the cache on.

- [ ] **Step 3: Verify and commit**

```bash
make build && make test
git add StenoKit/Integrations/RefreshPolicy.swift StenoTests/Integrations/RefreshPolicyTests.swift
git commit -m "feat: decide which refs §5.5 considers stale"
```

---

## Task 5: The event body and its payload

**Files:**
- Create: `StenoKit/Integrations/ExternalUpdate.swift`
- Test: `StenoTests/Integrations/ExternalUpdateTests.swift`

**Interfaces:**
- Produces: `ExternalUpdateBody.text(identifier:summary:changes:isFirstObservation:) -> String?`;
  internal `ExternalUpdatePayload` with `encoded() -> Data?` and `decoded(from:) -> Self?`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("D-169: the first observation of a ref reports its summary")
func theFirstObservationSpeaks() {
    #expect(
        ExternalUpdateBody.text(
            identifier: "PAY-421", summary: "In Review, assigned to Dana", changes: [],
            isFirstObservation: true) == "PAY-421: In Review, assigned to Dana")
}

@Test("a later fetch with no changes says nothing")
func noChangesIsSilent() { … == nil }

@Test("§3.3: a later fetch reports its changes, not its summary")
func changesAreWhatGetsReported() { … == "PAY-421: moved to In Review; 2 new comments" }

@Test("blank content is dropped on both paths")
func blankContentSaysNothing() {
    // A blank among real changes is dropped without taking the event with it.
    #expect(
        ExternalUpdateBody.text(
            identifier: "PAY-421", summary: "In Review", changes: ["", "reopened"],
            isFirstObservation: false) == "PAY-421: reopened")
}

@Test("D-174: the payload's keys are sorted, so an unchanged store re-exports byte-identically")
func thePayloadsKeysAreSorted() throws {
    let encoded = try #require(payload.encoded())
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json == """
        {"changes":["reopened"],"fetchedAt":"2023-11-14T22:13:20Z",\
        "identifier":"PAY-421","kind":"jiraIssue",\
        "refID":"0BC7A3A0-0000-4000-8000-000000000001",\
        "url":"https:\\/\\/example.atlassian.net\\/browse\\/PAY-421"}
        """)
}
```

**The sorted-keys test is built so it can fail.** `Codable` emits keys in a per-process hash order,
so a round-trip assertion would pass with `.sortedKeys` removed. Asserting exact bytes fails
whenever the order is anything but sorted, and the declaration order (refID, kind, identifier,
changes, url, fetchedAt) is deliberately *not* the sorted order. Two further notes: do not nest
`#require` inside `#require` (the macro cannot expand recursively — it fails the build with
"recursive expansion of macro"), and use a `?? UUID()` constant rather than `UUID(uuidString:)!`
(SwiftLint forbids force unwrapping).

- [ ] **Step 2: Run — expect failure**, then implement:

```swift
public static func text(
    identifier: String, summary: String, changes: [String], isFirstObservation: Bool
) -> String? {
    if isFirstObservation {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\(identifier): \(trimmed)"
    }
    let stated = changes
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return stated.isEmpty ? nil : "\(identifier): \(stated.joined(separator: "; "))"
}
```

```swift
func encoded() -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .iso8601
    return try? encoder.encode(self)
}
```

`Data?` rather than `throws`, following `StandupReportedPayload`: a payload that cannot be encoded
must not abort a pass whose cache write is fine.

- [ ] **Step 3: Verify and commit**

```bash
make build && make test
git add StenoKit/Integrations/ExternalUpdate.swift StenoTests/Integrations/ExternalUpdateTests.swift
git commit -m "feat: decide what a found change says on an externalUpdate event"
```

---

## Task 6: Both report paths speak `externalUpdate` (D-180)

**Files:**
- Modify: `StenoKit/Models/EventKind.swift` (add `isReportable`)
- Modify: `StenoKit/Report/RawReportSections.swift` (`isBullet`, rename `authored` → `reportable`)
- Modify: `StenoKit/AI/StandupSummarizer.swift` (one predicate + rename)
- Test: `StenoTests/Models/EnumTests.swift`, `StenoTests/Report/RawReportSectionsTests.swift`,
  `StenoTests/AI/StandupCoverageTests.swift`

**Interfaces:**
- Produces: `EventKind.isReportable: Bool`.

**Why this task exists.** `RawReportSections.authored` filtered on `isUserAuthored`, which is
`false` for `externalUpdate`, and its doc comment said the decision belonged to "whoever adds
`externalUpdate`" — this task. §7.3's prompt already sends these events, so leaving the renderer as
it was made the AI draft strictly better than its own fallback, which is the asymmetry the coverage
rule exists to forbid. And with events as the only route external state takes into a report
(D-168), a renderer that drops them means §5.2's offline guarantee is unmet outright.

**This is the one place this task edits the AI layer.** It is one predicate and one rename in
`StandupSummarizer`, it introduces no reference to the source layer, and it is declared in the PR
body rather than absorbed silently.

- [ ] **Step 1: Write the failing tests**

```swift
// EnumTests.swift
@Test("D-180: externalUpdate is reportable but not user-authored")
func externalUpdateIsReportableButNotAuthored() {
    // Two predicates, two questions. `isUserAuthored` must stay false: FR-2's
    // correction and redaction scope reads it, and an integration's sentence must
    // never become editable as though the user had typed it.
    #expect(EventKind.externalUpdate.isReportable)
    #expect(!EventKind.externalUpdate.isUserAuthored)
}

@Test("D-072: the machine-authored kinds are neither reportable nor user-authored")
func machineKindsAreNeitherReportableNorAuthored() {
    for kind in [EventKind.created, .statusChanged, .standupReported] {
        #expect(!kind.isReportable, "\(kind.rawValue) should not be reportable")
        #expect(!kind.isUserAuthored, "\(kind.rawValue) should not be user-authored")
    }
}
```

```swift
// RawReportSectionsTests.swift
@Test("D-180: §7.4's fallback speaks an integration's update")
func theFallbackSpeaksExternalUpdates() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Flaky auth test", status: .inProgress, ticketKeys: ["PAY-421"],
                    events: [
                        SectionInput.event("PAY-421: moved to In Review", kind: .externalUpdate)
                    ])
            ]))
    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(
                    text: "Flaky auth test (PAY-421)",
                    details: ["PAY-421: moved to In Review"])])
}

@Test("D-180: a task whose only news is an external update still counts as progressed")
func anExternalUpdateAloneIsProgress() { /* a `.todo` task with one externalUpdate */ }

@Test("D-072 still holds: created and statusChanged stay out of the report")
func machineAuthoredKindsStayOut() {
    // The widening admits exactly one kind. Without this, swapping the predicate
    // for `true` would pass every other test in this file.
}
```

```swift
// StandupCoverageTests.swift
@Test("D-180: a draft that omits a task whose only news is an external update falls back")
func droppedExternalUpdateDegrades() async {
    // `.todo` deliberately: an `.inProgress` or `.blocked` task is already covered
    // by status alone, so it could not tell the two predicates apart.
    let updated = DraftFixture.task(
        "the one it forgot", status: .todo,
        events: [DraftFixture.event("PAY-421: moved to In Review", kind: .externalUpdate)])
    let mentioned = DraftFixture.task(
        "the one it kept", events: [DraftFixture.event("quick fix")])
    let window = DraftFixture.window(tasks: [updated, mentioned])
    let partial = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: mentioned.id, text: "shipped the quick fix")],
            today: [], blockers: []))

    let result = await summarizer(provider: StubAIProvider(draft: .success(partial)))
        .summarize(window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown.contains("PAY-421: moved to In Review"))
}
```

- [ ] **Step 2: Run — expect three failures** (`make build && make test`): the renderer drops the
      event, so both section tests fail, and the coverage test's draft is accepted rather than
      degraded.

- [ ] **Step 3: Add `EventKind.isReportable`**

```swift
public var isReportable: Bool {
    switch self {
    case .note, .blockedReason, .externalUpdate:
        true
    case .created, .statusChanged, .standupReported:
        false
    }
}
```

A second property, not a wider `isUserAuthored`: FR-2's correction scope reads the first, and
widening it would have made a Jira comment user-correctable. Exhaustive, with no `default`, so a
seventh kind is a compile error here.

- [ ] **Step 4: Switch both readers**

```swift
// RawReportSections.isBullet
guard event.kind.isReportable else { return false }

// StandupSummarizer
return task.blockedReason != nil || task.events.contains { $0.kind.isReportable }
```

Rename `RawReportSections.authored` → `reportable` and `StandupSummarizer.carriesUserWords` →
`carriesReportableContent`, updating all call sites. **Both renames are required, not cosmetic:**
the old names asserted "the user typed this", which the bodies no longer check, and a comment or
name asserting a false property is this project's most frequently repeated defect.

- [ ] **Step 5: Verify**

```bash
make build && make test
```
Expected: green, including the pre-existing `RawReportGoldenTests` — no fixture in them carries an
`externalUpdate` event, so the golden output is unchanged.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Models/EventKind.swift StenoKit/Report/RawReportSections.swift \
        StenoKit/AI/StandupSummarizer.swift StenoTests/Models/EnumTests.swift \
        StenoTests/Report/RawReportSectionsTests.swift StenoTests/AI/StandupCoverageTests.swift
git commit -m "feat: let both report paths speak an integration's update"
```

---

## Task 7: The refresh service

**Files:**
- Create: `StenoKit/Integrations/RefreshOutcome.swift`,
  `StenoKit/Integrations/SourceRefreshService.swift`,
  `StenoKit/Integrations/SourceRefreshService+Write.swift`
- Modify: `StenoKit/Support/Logging.swift` (add `Log.sources`)
- Test: `StenoTests/Integrations/RefreshFixture.swift`,
  `StenoTests/Integrations/SourceRefreshServiceTests.swift`,
  `StenoTests/Integrations/RefreshNeverBlocksTests.swift`

**Interfaces:**
- Consumes: `SourceRegistry`, `RefreshPolicy`, `ExternalUpdateBody`, `ExternalUpdatePayload`,
  `withDeadline` (Tasks 1–5); `SourceRef.recordFetch(summary:at:)` (internal, M0-03).
- Produces: `RefreshOutcome` (with nested `Failure`, `.idle`, `didWrite`), `RefreshedWindow`,
  `SourceRefreshService(context:registry:now:save:perFetch:budget:)` with
  `refreshDue(olderThan:) async -> RefreshOutcome` and
  `refresh(taskIDs:) async -> RefreshOutcome`; `Log.sources`.

- [ ] **Step 1: Write `RefreshOutcome`**

Counts, not collections — D-163's lesson: an empty array is never evidence that nothing was
fetched, so `attempted` is carried explicitly. `Failure` carries the connector's `displayName` so
the banner can name the integration; `readFailed` and `saveFailed` are **separate**, because a
candidate query that failed means the pass never ran while a refused write means it ran and was
discarded.

- [ ] **Step 2: Write the fixture and the failing tests**

`RefreshFixture` holds the container as well as the context, so `eventsInStore` / `refInStore` /
`taskInStore` read through a **second** `ModelContext` — a refetch on the writing context returns
the object already in hand and would pass against a rollback. It creates refs the way
`CaptureService` does, `taskID` **and** the relationship (D-016), because the production shape is
what the service reads. Budgets default to milliseconds.

The tests that pin the contract (17 in two files); each names its mutation:

```swift
@Test("§3.4: a successful fetch caches the summary and stamps the app's clock")
func aFetchWritesTheCache() async throws {
    // D-171: our clock, not the connector's `fetchedAt` — which `.stub` sets to the
    // fixture's origin, so a service reading the wrong one lands elsewhere.
    #expect(stored.lastFetchedAt == RefreshFixture.origin.addingTimeInterval(60))
}

@Test("a later fetch that finds nothing writes no event but still advances the cache")
func anUnchangedFetchIsSilentButNotIdle() async throws {
    // Both directions: "no event was appended" passes trivially if the fetch never
    // happened, so the same test asserts the cache moved forward.
    #expect(try fixture.eventsInStore(kind: .externalUpdate).isEmpty)
    #expect(outcome.cached == 1)
}

@Test("the connector is asked for changes since the row's previous observation")
func sinceIsThePreviousObservation() async throws {
    // `#require` on each entry, not a dictionary lookup: `[String: Date?]`
    // subscripting yields `Date??`, so `asked["PAY-9"] == nil` is true both when the
    // ref was fetched with no `since` and when it was never fetched at all.
    let seen = try #require(connector.asked.first { $0.identifier == "PAY-421" })
    #expect(seen.since == previously)
    let unseen = try #require(connector.asked.first { $0.identifier == "PAY-9" })
    #expect(unseen.since == nil)
}

@Test("D-173: a refresh never stamps task.modifiedAt")
@Test("D-172: one .stenoDidWrite per writing pass, and none for a pass that wrote nothing")
func theNotificationIsPostedOncePerWritingPass() async throws {
    _ = await fixture.service(connectors: [StubSourceConnector()]).refresh(taskIDs: [task.id])
    #expect(counter.posts == 1)
    _ = await fixture.service(connectors: []).refresh(taskIDs: [task.id])
    #expect(counter.posts == 1)

    // **And a pass that fetched and failed.** The case above returns before the
    // write phase is reached at all, so on its own it cannot see a post moved out
    // from under `didWrite` — a mutation that posted unconditionally survived it.
    let failed = await fixture.service(connectors: [AlwaysFailingConnector()])
        .refresh(taskIDs: [task.id])
    #expect(failed.attempted == 2)
    #expect(!failed.didWrite)
    #expect(counter.posts == 1)
}

@Test("D-172: a failed save rolls back, and a later successful pass finds no phantom rows")
func aFailedSaveLeavesNothingBehind() async throws {
    // The later save is what makes "the store is empty" falsifiable: without the
    // rollback the refused event sits in the context and the *next* save commits it.
    failing.shouldFail = false
    let second = await fixture.service(…, nowOffset: 120, save: failing.save)
        .refresh(taskIDs: [task.id])
    #expect(second.changed == 1)
    #expect(try fixture.eventsInStore(kind: .externalUpdate).map(\.body) == ["PAY-421: Done"])
}

@Test("§5.5: the launch pass skips done and archived tasks")
func theLaunchPassSkipsFinishedWork() async throws {
    // The live ref must be fetched, so this cannot pass by fetching nothing.
    #expect(connector.asked.map(\.identifier) == ["PAY-LIVE"])
}

@Test("D-170: two rows sharing one identifier are each fetched with their own since")
@Test("D-166: a ref no connector claims is not attempted and not a failure")
@Test("a claimant with no credential is counted, not fetched")
@Test("refreshing no tasks is idle, not an error")
```

```swift
// RefreshNeverBlocksTests.swift — the acceptance criteria
@Test("§5.5: a connector that always throws does not block report generation")
func aFailingIntegrationNeverBlocksAReport() async throws {
    let outcome = await fixture.service(connectors: [AlwaysFailingConnector()])
        .refresh(taskIDs: [task.id])
    #expect(outcome.failures.map(\.error) == [.network])

    // And the report still generates, from the log and the cache the failed pass
    // left untouched.
    let window = try ReportGatherer(context: fixture.context, now: { RefreshFixture.origin })
        .gather(for: fixture.project)
    #expect(window.tasks.first?.events.map(\.body) == ["found the race in the retry handler"])
    #expect(try fixture.refInStore("PAY-421")?.cachedSummary == "In Review")
}

@Test("§5.5: one connector failing does not stop the others")
func oneFailureDoesNotStopTheRest() async throws {
    // The failing connector claims only `.jiraIssue` and is registered first, so an
    // implementation that abandoned the pass on the first failure never reaches the
    // second ref. Both halves asserted: the survivor's cache *and* its event.
    let failing = AlwaysFailingConnector(error: .invalidCredential, kinds: [.jiraIssue])
}

@Test("§5.2: with nothing configured, the report still generates and is labeled stale")
@Test("D-178: one hanging fetch times out without taking the pass with it")
@Test("D-178: the pass budget keeps completed fetches and counts the rest as skipped")
func theBudgetKeepsWhatItAlreadyHas() async throws {
    // Eight refs, all hanging, `perFetch: .seconds(30)`, `budget: .milliseconds(120)`.
    #expect(outcome.skipped > 0)
    #expect(outcome.failures.isEmpty)   // skipped is not failed
    #expect(outcome.skipped + outcome.cached + outcome.failures.count == outcome.attempted)
}

@Test("a connector that breaks the error contract degrades rather than escaping")
@Test("D-163: a pass that attempted nothing is distinguishable from one that failed")
```

- [ ] **Step 3: Write the service's read and dispatch half**

```swift
public func refreshDue(
    olderThan staleness: Duration = RefreshPolicy.launchStaleness
) async -> RefreshOutcome {
    let rows: [SourceRef]
    do { rows = try activeRefs() } catch {
        Log.sources.error(
            "could not read refs to refresh: \(String(describing: error), privacy: .public)")
        return RefreshOutcome(readFailed: true)
    }
    let due = RefreshPolicy.due(rows.map(\.snapshot), now: now(), olderThan: staleness)
    return await run(due, rows: rows)
}
```

**Both candidate queries key on `SourceRef.taskID`, never on `TaskItem.sourceRefs`.** The first
draft read the relationship in the launch path and the key in the Prepare path; D-016 keeps both,
and `SourceRef` names the key as authoritative, so a fixture setting only one of them would pass
one path and silently skip the other:

```swift
private func activeRefs() throws -> [SourceRef] {
    let tasks = try context.fetch(
        FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isArchived }))
    let active = Set(tasks.filter { $0.status != .done }.map(\.id))
    return try refs(forTaskIDs: active)
}

private func refs(forTaskIDs taskIDs: Set<UUID>) throws -> [SourceRef] {
    guard !taskIDs.isEmpty else { return [] }
    return try context.fetch(FetchDescriptor<SourceRef>())
        .filter { taskIDs.contains($0.taskID) }
}
```

`Status` is an enum, and an enum inside a SwiftData `#Predicate` does not compile in either
spelling (`EventQueries` records this), so the status filter runs in memory. A
`taskIDs.contains(...)` predicate is the other construct that compiles and then throws at fetch
time. D18 caps the dataset, so the fetch is the cost and the filter is free.

- [ ] **Step 4: Write the bounded, budgeted fetch**

```swift
private enum GroupEvent: Sendable {
    case fetched(FetchResult)
    case budgetExpired
}
```

**The clock is a member of the group, not a check between results.** The first version tested the
elapsed time each time `group.next()` returned, which cannot fire while every fetch is still in
flight — so a pass whose connectors all hang ran for the *per-fetch* deadline instead of the pass
budget, and the first hang to time out was recorded as a failure rather than skipped. The budget
test caught it on `failures.isEmpty`.

```swift
await withTaskGroup(of: GroupEvent.self) { group in
    var pending = ready.makeIterator()

    func startNext() -> Bool {
        guard let next = pending.next() else { return false }
        group.addTask {
            .fetched(await Self.fetch(next.snapshot, from: next.connector, within: deadline))
        }
        return true
    }

    let passBudget = budget
    group.addTask {
        try? await Task.sleep(for: passBudget)
        return .budgetExpired
    }

    for _ in 0..<Self.maxInFlight where startNext() { }

    while let event = await group.next() {
        switch event {
        case .budgetExpired:
            guard !expired else { continue }
            expired = true
            group.cancelAll()
            while pending.next() != nil { skipped += 1 }

        case .fetched(let result):
            if expired, case .failure = result.outcome {
                skipped += 1
            } else {
                results.append(result)   // a fetch that beat the cancellation still carries data
            }
            guard !expired else { continue }
            if ContinuousClock.now - started >= budget {
                expired = true
                group.cancelAll()
                while pending.next() != nil { skipped += 1 }
                continue
            }
            _ = startNext()
        }
    }
}
```

The per-ref fetch is `nonisolated static`, so it runs off the main actor, and it catches the
contract violation the protocol says cannot happen:

```swift
private nonisolated static func fetch(
    _ ref: SourceRefSnapshot, from connector: any SourceConnector, within deadline: Duration
) async -> FetchResult {
    do {
        let update = try await withDeadline(deadline, throwing: SourceError.timedOut) {
            try await connector.fetch(ref, since: ref.lastFetchedAt)
        }
        return result(.success(update))
    } catch let error as SourceError {
        return result(.failure(error))
    } catch {
        Log.sources.error(
            "\(connector.id, privacy: .public) threw a non-SourceError; contract broken")
        return result(.failure(.invalidResponse))
    }
}
```

- [ ] **Step 5: Write the write half (`+Write.swift`)**

Split into `apply` (rows → counts) and `persist` (one save, `false` on refusal), because
`applyAndSave` as one function is 68 lines and SwiftLint's limit is 50.

```swift
row.recordFetch(summary: update.summary, at: stamp)   // D-171: `stamp`, never update.fetchedAt
```

Nothing stamps `task.modifiedAt` (D-173): a refresh did not modify the task, and the launch pass
runs on every launch, so bumping it would routinely outrank a real title edit from another Mac in
§10.1's merge.

```swift
private func persist() -> Bool {
    do { try save(context); return true } catch {
        context.rollback()   // load-bearing: see below
        Log.sources.error(
            "refresh could not be saved, rolled back: \(String(describing: error), privacy: .public)")
        return false
    }
}
```

**The rollback is load-bearing, not tidiness.** Inserted events left in a dirty context are
committed by the next unrelated save — a capture, a status change, a note — which turns a refresh
failure into phantom `externalUpdate` rows in a later report with nothing to trace them to.

Post `.stenoDidWrite` once, after a successful save, and only when `outcome.didWrite`.

- [ ] **Step 6: Add `Log.sources`** to `Logging.swift`, with the `log show` recipe its siblings
      carry, and the §8 note: counts and connector ids only.

- [ ] **Step 7: Verify**

```bash
make generate && make build && make test && make lint
```
Expected: green. If `file_length` fires on `SourceRefreshService.swift`, the `+Write` split is what
resolves it; the stored properties become `internal` (nothing outside the module can reach them —
the type's only `public` members are its initializer and its two refresh methods).

- [ ] **Step 8: Commit**

```bash
git add StenoKit/Integrations/RefreshOutcome.swift \
        StenoKit/Integrations/SourceRefreshService.swift \
        StenoKit/Integrations/SourceRefreshService+Write.swift \
        StenoKit/Support/Logging.swift StenoTests/Integrations/
git commit -m "feat: refresh source refs best-effort, and never block a report"
```

---

## Task 8: The staleness wording

**Files:**
- Create: `StenoKit/Integrations/SourceNotice.swift`
- Test: `StenoTests/Integrations/SourceNoticeTests.swift`

**Interfaces:**
- Produces: `SourceNotice.text(for outcome: RefreshOutcome, now: Date) -> String?`

- [ ] **Step 1: Write the failing tests** — eleven cases: a clean pass is silent; a failure names
      the integration and the age; a failure with no cache says "no cached data yet"; one day is
      singular; under a day is "today's"; a save failure outranks a fetch failure; `notConfigured`
      has its own sentence; `readFailed` has its own; quietly-old data is reported only past a day.

```swift
@Test("a clean pass says nothing")
func aCleanPassIsSilent() {
    let outcome = RefreshOutcome(
        attempted: 2, cached: 2, changed: 1, oldestFetch: now.addingTimeInterval(-30))
    #expect(SourceNotice.text(for: outcome, now: now) == nil)
}

@Test("a failed fetch names the integration and how old the data is")
func aFailureNamesTheIntegration() {
    #expect(SourceNotice.text(for: outcome, now: now)
        == "Couldn't reach Jira — using 2 days old data.")
}
```

- [ ] **Step 2: Run — expect failure**, then implement. One sentence only, in priority order:
      `saveFailed`, then the first fetch failure, then `notConfigured`, then `readFailed`, then
      quietly-old data past a day. A banner listing three complaints about a report the user is
      about to read aloud is one they stop reading, and the failure is the most actionable.

- [ ] **Step 3: Verify and commit**

```bash
make build && make test
git add StenoKit/Integrations/SourceNotice.swift StenoTests/Integrations/SourceNoticeTests.swift
git commit -m "feat: say how stale a draft's integration data is"
```

---

## Task 9: The two-stage draft chain

**Files:**
- Modify: `StenoKit/Features/MainWindow/StandupDraftModel.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel+Standup.swift`
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift`
- Create: `StenoKit/Features/MainWindow/MainWindowModel+Fetching.swift`
- Test: `StenoTests/Features/MainWindow/StandupDraftRefreshTests.swift`

**Interfaces:**
- Consumes: `RefreshedWindow`, `SourceRefreshService`, `SourceNotice`, `SourceRegistry`.
- Produces: `StandupDraftModel(service:undoService:polish:refresh:now:)` — two new defaulted
  parameters — plus `isRefreshing`, `sourceNotice`;
  `MainWindowModel.sourceRefresh(context:registry:now:save:)`;
  `MainWindowModel(… sourceRegistry: SourceRegistry = SourceRegistry() …)`.

- [ ] **Step 1: Write the failing tests**

The scripted stage suspends until released, so "is the sheet still refreshing?" is a real question
rather than a race:

```swift
@MainActor
private final class ScriptedRefresh {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var polishedWindows: [GatheredWindow] = []

    func finish() async {
        while release == nil { await Task.yield() }
        release?.resume()
        release = nil
        for _ in 0..<8 { await Task.yield() }
    }

    func waitUntilRefreshing() async { while release == nil { await Task.yield() } }
}
```

**The waiting matters.** A `Task` has not started when `begin` returns, so a test that dismissed
immediately, or asserted immediately, would be asserting against a stage that had not run.

```swift
@Test("FR-4 step 4: the sheet is refreshing before it is polishing, and Copy stays live")
func theRefreshIsVisibleAndNonBlocking() async throws {
    await scripted.waitUntilRefreshing()
    #expect(model.isRefreshing)
    #expect(model.text == "generated text")
    #expect(model.canCopy)                      // §7.4: never left holding nothing
    #expect(scripted.polishedWindows.isEmpty)   // and the polish has not started
    await scripted.finish()
    #expect(!model.isRefreshing)
    #expect(scripted.polishedWindows.count == 1)
}

@Test("D-175: a pass that wrote something replaces the window and re-renders the draft")
func aWritingPassReplacesTheWindow() async throws {
    #expect(model.window == updated)
    #expect(model.text.contains("moved to In Review"))
    #expect(scripted.polishedWindows == [updated])   // polish ran on the replaced window
}

@Test("D-175: a typed draft keeps its own text and its original window")
func aTypedDraftIsNotOverwritten() async throws {
    await scripted.waitUntilRefreshing()
    model.text = typedByHand
    await scripted.finish()
    #expect(model.text == typedByHand)
    #expect(model.window == window)
    #expect(scripted.polishedWindows == [window])
}

@Test("D-175: a pass that wrote nothing leaves the window and the text alone")
@Test("§5.2: the staleness label reaches the sheet and never the clipboard")
func theStalenessLabelIsAppSideOnly() async throws {
    #expect(model.sourceNotice == "Couldn't reach Jira — using 2 days old data.")
    #expect(!model.text.contains("Jira"))
    #expect(model.commit(to: fixture.alpha))
    #expect(try fixture.reportsInStore().first?.markdownBody == model.text)
}

@Test("dismissing during a refresh touches no state, and skips the polish entirely")
@Test("preparing a second window supersedes the first refresh")
```

- [ ] **Step 2: Run — expect failure** on the new parameter names.

- [ ] **Step 3: Add the stage to `StandupDraftModel`**

```swift
polishTask = Task { [weak self] in
    guard let refreshed = await self?.refresh(window) else { return }
    guard let current = self?.adopt(refreshed, from: generation) else { return }
    guard let result = await self?.polish(current) else { return }
    self?.install(result, from: generation)
}
```

One task for both stages, in FR-4's order. `isPolishing` is still set in `begin`, so every existing
assertion about it holds; the sheet shows "Refreshing…" while `isRefreshing` and "Polishing…"
after.

```swift
private func adopt(_ refreshed: RefreshedWindow, from generation: Int) -> GatheredWindow? {
    guard generation == polishGeneration else { return nil }

    isRefreshing = false
    sourceNotice = SourceNotice.text(for: refreshed.outcome, now: now())

    guard !Task.isCancelled, phase == .editing, text == pristineText,
        refreshed.outcome.didWrite
    else { return window ?? refreshed.window }

    window = refreshed.window
    text = SlackMarkdown.render(RawReportSections.build(from: refreshed.window))
    pristineText = text
    return refreshed.window
}
```

Returning `nil` for a superseded generation means the polish is not started at all. The pristine
guard is why a typed draft keeps its window: replacing it would advance `lastStandupAt` past
`externalUpdate` events the user's text never mentions — consuming them from the window and losing
them from recall, D-076's harm. `dismiss()` clears `isRefreshing` and `sourceNotice` too.

- [ ] **Step 4: Assemble the closure at the composition root**

```swift
static func sourceRefresh(
    context: ModelContext, registry: SourceRegistry,
    now: @escaping () -> Date, save: @escaping (ModelContext) throws -> Void
) -> @MainActor (GatheredWindow) async -> RefreshedWindow {
    { window in
        let outcome = await SourceRefreshService(
            context: context, registry: registry, now: now, save: save
        ).refresh(taskIDs: window.tasks.map(\.id))

        guard outcome.didWrite else { return RefreshedWindow(window: window, outcome: outcome) }

        let projectID = window.projectID
        guard
            let project = try? context.fetch(
                FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })).first,
            let regathered = try? ReportGatherer(context: context, now: now).gather(for: project)
        else {
            Log.sources.error("refresh could not re-gather the window; keeping the original")
            return RefreshedWindow(window: window, outcome: outcome)
        }
        return RefreshedWindow(window: regathered, outcome: outcome)
    }
}
```

A failed re-gather returns the original window rather than failing: the events are already saved,
and the worst case is that they appear in the next report instead of this one — better than
refusing a draft.

- [ ] **Step 5: Thread the registry through `MainWindowModel`** — one new defaulted `init`
      parameter, one stored `let`, and `refresh:`/`now:` passed to `StandupDraftModel`.

- [ ] **Step 6: Resolve `file_length`** — `MainWindowModel.swift` was at 398 of 400, so this task
      pushes it over. Move `fetchProjects`, `doneCutoff` and `fetchTasks` to
      `MainWindowModel+Fetching.swift` (the same grounds on which `+Status.swift` already holds the
      status actions — the file says so in its `MainWindowActions` section). The moved methods and
      the shared `fetch` helper become `internal`, because `reload()` stays behind and `private` is
      file-scoped.

- [ ] **Step 7: Verify**

```bash
make generate && make build && make test && make lint
```

- [ ] **Step 8: Commit**

```bash
git add StenoKit/Features/MainWindow/ StenoTests/Features/MainWindow/StandupDraftRefreshTests.swift
git commit -m "feat: refresh a window's refs before polishing its draft"
```

---

## Task 10: The app wiring

**Files:**
- Modify: `Steno/Features/MainWindow/StandupDraftSheet.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift`
- Modify: `Steno/App/StenoApp.swift`

**Interfaces:**
- Consumes: `StandupDraftModel.isRefreshing`/`.sourceNotice`, `SourceRegistry`,
  `SourceRefreshService.refreshDue()`.

- [ ] **Step 1: Add the sheet's two affordances**

The staleness banner goes **above** `notice`: it describes the data the draft was built from, which
the user needs before reading it out, while `notice` and `lastError` describe what a Copy just did.

```swift
if let sourceNotice = draft.sourceNotice {
    Label(sourceNotice, systemImage: "clock.badge.exclamationmark")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

"Refreshing…" shares the footer slot with "Polishing…" — one slot, because the stages are
sequential:

```swift
if draft.isRefreshing {
    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Refreshing…") }
        .font(.caption).foregroundStyle(.secondary)
} else if draft.isPolishing {
    …
}
```

- [ ] **Step 2: Thread the registry** — `MainWindowView(container:registry:)`, defaulted empty,
      forwarded to `MainWindowModel(sourceRegistry:)`.

- [ ] **Step 3: Build the registry and fire the launch pass in `StenoApp`**

```swift
private let sourceRegistry = SourceRegistry(connectors: [])

private static func startLaunchRefresh(container: ModelContainer, registry: SourceRegistry) {
    let context = container.mainContext
    Task { @MainActor in
        _ = await SourceRefreshService(context: context, registry: registry).refreshDue()
    }
}
```

Initialized at its declaration and extracted to a `static` function because `init` is at
SwiftLint's 50-line body limit — adding two lines inline fails the build. Called inside the
`case .success(let container)` branch, beside the auto-export controller.

**Not in `MainWindowModel.init`** (D-179): the CLI bundle builds a store too, and `steno export`
must not open network connections. `mainContext`, for the same reason the default-project seeding
uses it.

- [ ] **Step 4: Verify**

```bash
make build && make test && make lint
```

The sheet's two affordances are **not visually verified this milestone** (D-179): with the registry
empty, `isRefreshing` is never true long enough to see and `sourceNotice` is always `nil` in the
shipping app. Their state is covered by Task 9's view-model tests, and M4-02's first manual run is
where the pixels get checked. Say so in the PR body; do not claim otherwise.

- [ ] **Step 5: Commit**

```bash
git add Steno/
git commit -m "feat: show refresh progress and staleness in the stand-up sheet"
```

---

## Task 11: The records

**Files:**
- Modify: `docs/DECISIONS.md` (append D-164 … D-180)
- Modify: `docs/REQUIREMENTS.md` (§5.2 amendment, bump to v1.22, changelog line)
- Modify: `docs/ARCHITECTURE.md` (source-layer rows and the layer map's status)
- Modify: `docs/tasks/README.md` (tick M4-01)

- [ ] **Step 1: Re-check the decision log's maximum**

```bash
grep -n "^### D-1[6-9]" docs/DECISIONS.md | tail -5
```
Expected: D-163 is the maximum. **A number inferred from a sibling spec instead of checked here
once shipped a duplicate D-140, and a diff cannot see it.** If the maximum has moved, renumber
D-164 … D-180 and update every citation in the code comments this branch added:

```bash
grep -rn "D-1[6-8][0-9]" StenoKit/ StenoTests/ Steno/ docs/superpowers/
```

- [ ] **Step 2: Write the seventeen decisions** — the spec's sections are the text; each needs its
      code pointer. D-180 is the one the spec does not contain: it was found by building, and it is
      the decision M2-02 deferred to this task.

- [ ] **Step 3: Amend §5.2 and bump to v1.22**

The cache bullet gains where last-known state appears: as `externalUpdate` events, not by
injecting `cachedSummary` into the report text or the prompt. Changelog line as drafted at the end
of the spec, ending "Found while designing M4-01; the implementation choice is `DECISIONS.md`
D-168, which points here."

- [ ] **Step 4: Update `ARCHITECTURE.md`** — the "Integrations never block" invariant row now
      points at `SourceRefreshService`, and the source-layer box in §2's diagram is no longer
      unbuilt.

- [ ] **Step 5: Tick the README**

Check for rows that merged without being ticked, per CLAUDE.md step 4, and tick them here:

```bash
grep -n "^- \[ \]" docs/tasks/README.md | head
```

- [ ] **Step 6: Verify and commit**

```bash
make lint
git add docs/
git commit -m "docs: record M4-01's decisions and amend §5.2 to v1.22"
```

---

## Verification, as actually run

| Gate | Result |
|---|---|
| `make build` | Build Succeeded |
| `make test` | 933 tests, 0 issues, networking denied |
| `make lint` | 0 violations in 330 files |
| `make format` | clean tree after running |

**Mutation testing.** Eleven mutations were applied one at a time to the verified tree, each
followed by a full `make test`, and each restored afterwards by rewriting the saved file contents —
**not** `git checkout`, which does not revert the untracked files this branch adds.

| Mutation | Result |
|---|---|
| `RawReportSections.isBullet`: `isReportable` → `isUserAuthored` | caught |
| `carriesReportableContent`: `isReportable` → `isUserAuthored` | caught |
| `ExternalUpdatePayload.encoded`: drop `.sortedKeys` | caught |
| `ExternalUpdateBody`: append a body even with no changes | caught |
| `persist()`: drop `context.rollback()` | caught |
| `recordFetch(at:)`: `stamp` → `update.fetchedAt` | caught |
| `adopt`: drop the pristine/phase/cancellation guard | caught |
| `SourceRegistry.dispatch`: ignore `isConfigured` | caught |
| `fetchAll`: remove the budget sentinel task | caught |
| `activeRefs`: drop the `status != .done` filter | caught |
| `applyAndSave`: post `.stenoDidWrite` unconditionally | **survived**, then caught |

The survivor was a weak test, not a mis-aimed mutation: the "wrote nothing" case used a pass with
no configured connector, which returns *before* the write phase, so it could never observe a post
moved out from under `didWrite`. Strengthened with a pass that attempts two fetches and fails both;
the mutation is now caught.

---

## Out of scope

- **Jira and Confluence** — M4-02, M4-03. No `URLSession`, no Atlassian URL, no credential read.
- **Background scheduling** — M4-05. `refreshDue()` is called once at launch; the timer, the
  catch-up rule and the 08:00 setting are that task's.
- **MCP** — M5.
- **Credential entry, the expiry warning, the per-integration test button** — M4-04.
  `SourceRegistry.connector(withID:)` and `.all` exist for it; nothing reads a token here.
- **Source state in the report text or the AI prompt** — D-168. External state travels as events.
- **Retry suppression** for a permanently `.notFound` ref — D-165.
- **Fetch coalescing** across rows sharing an identifier — D-170.
- **Q(M4)** (auto-transitioning a task when its ticket closes) stays open; D5 makes it a read-side
  question only.

## Risks

| Risk | Mitigation |
|---|---|
| `StandupDraftModel` is a heavily-reviewed async file; a third stage is where a generation bug hides | Reuses the existing counter and pristine guard rather than adding a parallel mechanism; dismiss-during-refresh and supersede-by-second-prepare are both tested against real suspension |
| Window replacement is subtle and its failure is silent — a lost event noticed weeks later | Pristine-gated, replaced at most once, before polish; asserted in both directions and mutation-checked |
| `Deadline.swift`'s move touches code whose semantics cost a review round and a CI flake | Pure refactor; the existing AI deadline and budget tests are the gate and the doc comment moves intact |
| Editing `StandupSummarizer` crosses the boundary the task file draws | One predicate and one rename, no reference to the source layer, declared in the PR body — and the alternative ships a draft that can say less than its own fallback |
| The subsystem is inert in production, so a reviewer may read the criteria as unverified | D-179 says so plainly; every criterion names the double that discharges it |
| Two files were at their lint limits before this task | Split along seams those files already use (`+Fetching`, `+Write`), stated in the commits that do it |
