# M5-01 — MCP Client (stdio)

**Milestone:** M5 — MCP
**Depends on:** M4-05
**Blocks:** M5-02
**Requirements:** §5.4, §5.1, D1
**Branch:** `feat/mcp-stdio-client`

## Goal

A generic MCP client speaking JSON-RPC over pipes to a local subprocess. **stdio only.**

## In scope

- Spawning an MCP server as a subprocess and speaking JSON-RPC over its pipes.
- Lifecycle: start, health, restart on crash, clean shutdown on app quit.
- Listing and invoking the tools and resources a server exposes.
- Timeouts and failure isolation — a wedged server must not hang the app.

## Out of scope

- **HTTP/SSE transport.** §5.4 and §5.1: stdio only in v1. Add HTTP/SSE *only* if a required
  server offers no local option, and say so explicitly in the PR.
- Server management UI — M5-02.
- Mapping MCP results onto `SourceRef` — M5-03.

## Acceptance criteria

- [ ] A local MCP server starts, responds, and shuts down cleanly with the app.
- [ ] A server that crashes is detected and does not take the app with it.
- [ ] A server that hangs hits a timeout rather than blocking the UI or a report.
- [ ] No HTTP or SSE transport code exists.
- [ ] Subprocesses do not leak across app restarts.
- [ ] `make test` passes with networking disabled, against a stub server.

## Notes for the spec/plan phase

- **This is the simplification macOS-only bought.** §5.1: with iOS out of scope, M5 drops from
  "two transports plus a platform-capability matrix" to "spawn a subprocess and speak JSON-RPC
  over pipes." §5.1 says plainly: take it. Building HTTP transport now is speculative work for
  a phone app that is not planned (§14).
- Process lifecycle is the real risk here, not the protocol. Leaked subprocesses and zombie
  servers are the failure modes that will actually show up.
- §5.4's fallback position: if MCP proves awkward in practice for GitHub and Calendar
  specifically, native connectors move to v1.1 — but MCP is attempted first. Report the
  experience honestly in the PR rather than quietly working around friction.
