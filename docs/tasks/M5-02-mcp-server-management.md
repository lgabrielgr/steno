# M5-02 — MCP Server Management

**Milestone:** M5 — MCP
**Depends on:** M5-01
**Blocks:** M5-03
**Requirements:** §5.4, FR-6, §8, §10.3
**Branch:** `feat/mcp-server-management`

## Goal

Add, configure, enable, and test MCP servers from Settings.

## In scope

- Server definitions: command, arguments, environment, enabled flag.
- Add / edit / remove, with a per-server enable toggle and connection test (FR-6).
- Secrets in server environments stored in Keychain, never in SwiftData or plists (§8).
- Server definitions **minus secrets** are exportable (§10.3), with the target machine
  prompting for credentials on first use.

## Out of scope

- The client itself — M5-01.
- Source mapping — M5-03.

## Acceptance criteria

- [ ] A server added here starts via M5-01 and its tools are enumerable.
- [ ] The enable toggle stops a server without deleting its definition.
- [ ] Connection test reports a specific failure — command not found, non-zero exit, protocol
      error, timeout — not a generic one.
- [ ] **Server credentials live in Keychain only** and never appear in an export (§8, §10.3).
      Assert it in a test, per §10.3's rule.
- [ ] Exported server definitions carry no secrets and prompt on the target machine.

## Notes for the spec/plan phase

- **This is the delivery mechanism for GitHub and Google Calendar** (§5.4). The user asked for
  both; rather than hand-building two OAuth clients and their token-refresh logic, they are
  satisfied by off-the-shelf MCP servers — "same outcome, materially less code, and it
  generalizes to any future source at zero marginal engineering cost."
- MCP server environments are the most likely place for a token to leak into a config file.
  §10.3's warning applies directly: the failure mode is a work token sitting in a file the user
  AirDrops or drops in a shared folder.
- Since servers are arbitrary local commands, the configuration UI should make it obvious what
  will be executed. This is the one place the app runs code the user supplied.
