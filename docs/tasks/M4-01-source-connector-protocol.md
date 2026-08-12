# M4-01 — SourceConnector Protocol, Cache & Refresh Policy

**Milestone:** M4 — Atlassian
**Depends on:** M3-04
**Blocks:** M4-02
**Requirements:** §5.1, §5.5, §3.4
**Branch:** `feat/source-connector-protocol`

## Goal

The single protocol all external data flows through, plus the caching and refresh policy that
guarantee a failed integration never blocks a report.

## In scope

- The §5.1 protocol and `SourceUpdate` struct, exactly as specified:

```swift
protocol SourceConnector {
    var id: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }

    func canHandle(_ ref: SourceRef) -> Bool
    func fetch(_ ref: SourceRef, since: Date?) async throws -> SourceUpdate
    func testConnection() async throws
}

struct SourceUpdate {
    let summary: String
    let changes: [String]
    let url: URL?
    let fetchedAt: Date
}
```

- A registry dispatching a `SourceRef` to the connector that `canHandle`s it.
- Caching into `SourceRef.cachedSummary` / `lastFetchedAt` (§3.4).
- The §5.5 refresh policy: on launch, refresh refs on non-done tasks older than 30 minutes; on
  "Prepare Stand-up", refresh all refs in the window.
- Appending `externalUpdate` events when a fetch finds a change (§3.3).
- The non-blocking progress indicator in the FR-4 step 4 flow.
- A test double connector.

## Out of scope

- Jira and Confluence themselves — M4-02, M4-03.
- Background scheduling — M4-05.
- MCP — M5.

## Acceptance criteria

- [ ] **A failed integration never blocks report generation** (§5.5). Verify with a connector
      that always throws: the report still generates, from cached data, with a visible
      staleness indicator.
- [ ] All fetches are best-effort; one connector failing does not stop others.
- [ ] A report generates fully offline from `cachedSummary`, **clearly labeled as stale**
      (§5.2).
- [ ] A change found on fetch appends an `externalUpdate` event.
- [ ] Refresh progress is visible but non-blocking (FR-4 step 4).
- [ ] `make test` passes with networking disabled, via the test double.

## Notes for the spec/plan phase

- **§13: `SourceConnector` and `AIProvider` are independent.** Nothing in this task may
  reference the AI layer. A task touching both is two tasks.
- §14 lists this protocol as deliberately retained, justified on testability grounds alone.
- The cache is not an optimization — it is what makes offline report generation possible, which
  §7.4 makes a P0 guarantee. Design it as a durable last-known-state store, not a TTL cache.
- Degradation ships in the same task as the feature (§13), never as a follow-up. That is why
  the cache and the never-block rule live here rather than after the connectors.
