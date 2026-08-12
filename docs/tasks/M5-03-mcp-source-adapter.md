# M5-03 — MCP Source Adapter

**Milestone:** M5 — MCP
**Depends on:** M5-02
**Blocks:** M5 exit criterion
**Requirements:** §5.4, §5.1, §3.4
**Branch:** `feat/mcp-source-adapter`

## Goal

Make MCP servers behave like any other source: an adapter conforming to `SourceConnector`, plus
MCP tools available to the AI layer during enrichment.

## In scope

- A `SourceConnector` adapter over M5-01's client, so MCP-backed refs flow through M4-01's
  registry, cache, and refresh policy unchanged.
- Handling `SourceRef` kinds `githubPR` and `mcpResource` (§3.4).
- Exposing MCP tools to the AI layer during enrichment (§5.4).
- GitHub and Google Calendar working end to end via off-the-shelf servers — the M5 exit
  criterion.

## Out of scope

- Native GitHub or Calendar connectors. §5.4: MCP is attempted first; native moves to v1.1 only
  if MCP proves awkward.
- Any change to `SourceConnector` itself. If the protocol needs to change to accommodate MCP,
  that is a finding worth raising, not a silent edit (§9.5).

## Acceptance criteria

- [ ] A GitHub PR URL captured at quick-add resolves through an MCP server and its state appears
      in a report.
- [ ] Calendar data is reachable through the same path.
- [ ] MCP-backed refs use M4-01's cache and degrade offline exactly like Jira refs (§5.5).
- [ ] A failed or missing MCP server never blocks report generation (§5.5).
- [ ] `make test` passes with networking disabled, against a stub server.

## Notes for the spec/plan phase

- **The point of the adapter is that nothing downstream knows the difference.** §5.1 routes all
  external data through one protocol; if MCP needs special cases in the report path, the
  abstraction has leaked and it is worth stopping to reconsider.
- §5.4's honest caveat is worth holding onto: if MCP proves awkward in practice for these two
  specific sources, native connectors move to v1.1. If that happens, say so in the PR — that is
  a real finding about the architecture, not a failure.
- §13: this task touches the source layer only. Exposing tools to the AI layer is the one
  sanctioned point of contact, and it is specified in §5.4 — keep it narrow.
