# M5-01 — MCP Client (stdio): design

**Date:** 2026-10-09 · **Task:** [`M5-01`](../../tasks/M5-01-mcp-stdio-client.md) ·
**Requirements:** §5.1, §5.4, §8, §9.4, §13, D1, D-012, D-146, D-162, D-165, D-177 ·
**Branch:** `feat/mcp-stdio-client`

## Amended during the build

Building the code before writing the plan changed eight things below. Where this document and
`DECISIONS.md` disagree, the decision record is current.

| Was | Now | Why |
|---|---|---|
| `PATH` = Homebrew prefixes + system | The command's own directory is prepended too | Measured: nvm's `npx` is a `#!/usr/bin/env node` script and fails without its directory (D-239) |
| Ledger entry `{pgid, leaderStartTime}` | `{owner, leader}`; reaped only if the owner is dead | `mcp-selftest` beside a running app would reap the app's live servers (D-236) |
| Ledger beside the store | `Application Support/com.lgabrielgr.steno/` | The store directory is Replace's unit of deletion (D-236) |
| Non-blocking write (`O_NONBLOCK`) | Blocking write on a per-process serial queue | Same property, no writability loop (D-238) |
| Timeout fails the request | Timeout also ends the process; counts toward the cap | A wedged server's blocked write is released only by the kill (D-237) |
| `.crashLoop` after 3 crashes | `.failedRepeatedly` after 3 failures of any kind; new `.stopped` case | A server that hangs every time is the same problem (D-237) |
| Notifications logged by method name | Dropped silently | The method name is server-supplied text (§8) |
| A replaced or shut-down server is stopped | It is *closed*: later requests throw `.stopped` | A caller still holding it would respawn a process the host no longer tracks (D-237) |

## What this builds

A generic MCP client that spawns a local server as a subprocess and speaks JSON-RPC over its
pipes — **stdio only** (§5.1, §5.4). It can list and call tools, and list and read resources. It
has no caller in the app yet: M5-02 adds server definitions and a Settings pane, M5-03 adapts it
to `SourceConnector`.

**The risk is process lifecycle, not the protocol** (the task file says so, and this design takes
it literally). The protocol surface is six methods. The failure modes that will actually show up
are a server that outlives the app, a grandchild that outlives its parent, a pipe that fills and
blocks, and a server that stops answering. Every decision below exists to close one of those.

## What this task decides

| | Decision |
|---|---|
| D-234 | The protocol is hand-written; no MCP SDK, no package dependency |
| D-235 | `posix_spawn` with a new process group and close-on-exec by default, not `Foundation.Process` |
| D-236 | A ledger of `{pgid, leaderStartTime}` reaped at launch, keyed on start time so a reused pid is never killed |
| D-237 | Lazy start, kept alive until quit or stop; restart on next request; 3 crashes in 60 s is `failed` |
| D-238 | A reader task resolves continuations; writes are non-blocking; stderr is drained into an unlogged ring |
| D-239 | The child gets a minimal environment with Homebrew prefixes on `PATH`, never the app's own |
| D-240 | `MCPError` carries no server-supplied text; a tool's `isError` result is not an error |
| D-241 | The test double is a real subprocess: an `MCPStubServer` Swift tool target |
| D-242 | A SwiftLint custom rule makes "no HTTP or SSE transport code" a check, not a promise |

Numbering continues from **D-233**, `DECISIONS.md`'s maximum as read from that file on
2026-10-09. Re-read it before writing the records: another PR may land first.

## Components

All of it lives in `StenoKit/Integrations/MCP/`, one unit per file.

| Unit | Responsibility | Depends on |
|---|---|---|
| `MCPServerDefinition` | Value type: `id`, `command`, `arguments`, `environment`. Not persisted here — M5-02 owns persistence and Keychain | — |
| `SpawnedProcess` | `posix_spawn` wrapper (D-235). Returns pid and the three pipe fds; observes exit with a `DispatchSource` process source and reaps with `waitpid`, so no zombie survives. `terminate(grace:)` runs the escalation below | Darwin |
| `ProcessLedger` | JSON file in Application Support; entry added on spawn, removed on confirmed exit. `reapOrphans()` (D-236) | Darwin, `FileManager` |
| `JSONRPCMessage` | Codec: request, response, error response, notification. Newline-framed, 8 MB per-line cap | Foundation |
| `MCPConnection` (actor) | One live process: reader task, pending-request table, `initialize` handshake, request deadlines | the three above |
| `MCPServer` (actor) | The public surface: lazy start, state machine, crash cap. `listTools`, `callTool`, `listResources`, `readResource`, `ping`, `stop`, `restart`, `recentStderr` | `MCPConnection` |
| `MCPHost` | Owns every `MCPServer`; `reapOrphans()` at launch, `shutdownAll(budget:)` at quit | `MCPServer`, `ProcessLedger` |
| `MCPError` | Typed failure (D-240) | — |

**Layering (ARCHITECTURE §2, rule 1).** Nothing here conforms to `SourceConnector` or names an AI
type. §5.4's "tools exposed to the AI layer during enrichment" is M5-03's narrow point of contact,
not this task's.

**App wiring** is two calls in `Steno/App/AppDelegate.swift`: `reapOrphans()` at launch (off the
main thread, before any server could start) and `shutdownAll()` from
`applicationShouldTerminate`, which returns `.terminateLater` and replies when the budget is
spent or every server has exited.

## Data flow

### Start

`MCPServer` is lazy (D-237). The first request finds it `idle` and starts it:

1. Spawn; write the ledger entry.
2. Send `initialize` with `clientInfo` (`steno`, the bundle version) and **empty
   `capabilities`** — Steno offers no sampling, roots, or elicitation.
3. Check the returned `protocolVersion` against `MCPProtocol.supportedVersions`, one constant.
   Outside the set: stop the process, throw `.unsupportedProtocolVersion`.
4. Send `notifications/initialized`. State becomes `ready`.

The startup deadline is **20 s**: an `npx` cold start downloads and links before it answers.
Requests arriving while `starting` await the same startup task; they never spawn a second
process.

**The contents of `supportedVersions` are verified against a real server**, through
`mcp-selftest` below, not written from memory. The list is the one place this design states a
fact about the outside world.

### Request

- Ids are a per-connection incrementing `Int`.
- The continuation enters the pending table **before** the write, so a reply that arrives
  before the writer returns still finds someone waiting.
- **Writes are non-blocking** (D-238). A wedged server stops reading stdin; once its 64 KB pipe
  buffer fills, a blocking `write` would hang the caller with no deadline able to interrupt it
  (`withDeadline`'s documented limit, D-146). Our end of stdin is `O_NONBLOCK`; the write waits
  for writability on a dispatch source, and the request deadline covers it.
- Deadlines: `ping` 5 s, everything else 30 s, both overridable per call and injected in tests.
  On expiry the pending entry is removed and its continuation resumed with `.timedOut`. A reply
  that arrives later carries an unknown id and is dropped.
- `tools/list` and `resources/list` follow `nextCursor`, at most **20 pages**, then
  `.protocolViolation(.paginationRunaway)`.

**Why continuations, not a blocking read.** `withDeadline` cannot return while its operation
ignores cancellation (D-146). A request awaiting a continuation honours cancellation by
construction: the deadline resumes it, and nothing is left blocked on a file descriptor.

### Reader

- stdout → line splitter → decode → match by id. A line longer than 8 MB fails the connection
  with `.protocolViolation(.oversizedMessage)`; the alternative is unbounded memory.
- A line that is not valid JSON-RPC is dropped and logged **by length only**. Its request, if
  any, times out. One stray line does not end the connection.
- A request *from* the server is answered `-32601 method not found`. A notification is dropped
  and logged by method name.
- **stderr is drained continuously** (D-238). A server that writes to stderr faster than anyone
  reads fills that pipe and blocks — a second hang path. Bytes go into a 64 KB in-memory ring,
  readable through `recentStderr()` for M5-02's connection test, and **never logged**: server
  stderr is where a token in an environment variable is most likely to be echoed (§8).

### Crash

The exit source fires → every pending continuation is resumed with `.crashed` → the ledger
entry is removed → state `down`, crash time recorded. The next request restarts the server,
unless this was the third crash inside 60 s: then state `failed`, and every request throws
`.crashLoop` until `restart()` is called. Nothing restarts without a caller, so a broken server
costs nothing while nobody is asking it anything.

## Shutdown and orphans

### Escalation

`SpawnedProcess.terminate(grace:)`: close stdin → wait `grace` → `SIGTERM` the **group** → wait
`grace` → `SIGKILL` the group. Each wait ends early on exit. The group is the point: `npx`
starts `node` as a child, and killing `npx` alone leaves `node` running.

### Clean quit

`shutdownAll` stops every server in parallel within a **3 s total budget** (grace 1 s). Quit
never waits on a server longer than that. A ledger entry is removed only once exit is
confirmed, so a server the budget did not cover is still in the ledger for the next launch.

### Orphan reap (D-236)

At launch, before any server can start, for each `{pgid, leaderStartTime}`:

| State | Verdict |
|---|---|
| Leader (pid = pgid) alive, start time matches | Ours: `SIGTERM` the group, 1 s, `SIGKILL` |
| Leader alive, start time differs | The pid was reused by a stranger: skip, drop the entry |
| Leader dead, group members alive (`npx` exited, `node` did not) | Ours: kill the group |
| Nothing alive | Drop the entry |

The third row is sound because **POSIX never allocates a pid equal to the id of a process group
that still exists**, so a live group with our pgid is the group we created. Start time comes
from `proc_pidinfo(PROC_PIDTBSDINFO)`; group membership from `proc_listpids(PROC_PGRP_ONLY)`.

Without the start-time check, a ledger left by a crash weeks ago would `SIGKILL` whatever
process now holds that pid.

## Child environment (D-239)

**An app launched from Finder has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.** `npx` and `node` live
in `/opt/homebrew/bin` or `/usr/local/bin`, so every off-the-shelf server — including both §5.4
names — would fail with `.commandNotFound` on first use.

The child gets: `HOME`, `USER`, `LANG`, `TMPDIR` from the app, and
`PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, with the definition's
`environment` applied on top (so a definition can override `PATH`). The command is resolved
against that `PATH`, not the app's. The app's full environment is never passed: inheriting
`xctest`'s already broke a subprocess test once (`OS_ACTIVITY_DT_MODE`), and the app's
environment is not the server's business.

## Errors (D-240)

| What happens | `MCPError` |
|---|---|
| Command not on `PATH`, or not executable | `.commandNotFound` |
| Any other spawn failure | `.launchFailed(errno:)` |
| Exit before `initialize` answers | `.exitedDuringStartup(status:)` |
| Exit while `ready` | `.crashed` |
| Third crash inside 60 s | `.crashLoop` |
| Startup or request deadline | `.timedOut` |
| Version outside `supportedVersions` | `.unsupportedProtocolVersion` |
| JSON-RPC error response | `.serverError(code:)` — the message is discarded |
| Framing, oversized line, pagination runaway, malformed result | `.protocolViolation(Kind)` |

**No case carries a `String`** (D-165's rule, extended): JSON-RPC error messages and stderr are
written by the server and may contain anything a tool returned. A `MCPError` is therefore always
safe to log.

**A `tools/call` result with `isError: true` is not an `MCPError`.** The transport worked; the
tool reported a failure. It is returned to the caller as a result, which is how the MCP spec
separates the two.

**Logging:** server id, method name, latency, and error case, through the existing `Logging`
facade. Never params, results, or stderr.

## Live probe: `steno mcp-selftest`

The `*-selftest` precedent (`IntegrationsSelftest`, D-220): the one path that runs this client
against a real server, outside `make test`.

```
steno mcp-selftest -- npx -y @modelcontextprotocol/server-everything
```

It starts the server through `MCPHost`, prints the negotiated protocol version, tool and
resource counts, calls `ping`, stops, and **checks that no process in the group survives**. It
is how `supportedVersions` is verified, and how the PR reports §5.4's "MCP in practice"
experience honestly rather than from the stub alone. Network access is the server's, not the
test suite's.

## Testing

Everything below runs under `make test` with networking denied (§9.4).

### Stub server (D-241)

`MCPStubServer` is a new command-line tool target in `project.yml`; `StenoTests` depends on it
so it builds first, and tests locate it beside the test bundle in the build products directory.
It is about 200 lines of Swift. A Python or shell stub was rejected: `/usr/bin/python3` on a
clean Mac is a shim that prompts to install developer tools, and JSON in `sh` is fragile.

`--mode` selects behaviour: `normal`, `hang-on-init`, `hang-on-call`, `crash-on-call`,
`exit-before-init`, `garbage-stdout`, `flood-stderr`, `ignore-eof`, `spawn-grandchild`,
`bad-version`, `paginate-forever`, `stop-reading-stdin`. `spawn-grandchild` reports the
grandchild's pid through a tool result, so a test can check it is gone.

### Acceptance criteria → tests

| # | Criterion | Test |
|---|---|---|
| 1 | Starts, responds, shuts down cleanly | Handshake; list/call tools; list/read resources; pagination and its cap. `ignore-eof` + `spawn-grandchild` → `stop()` → `kill(pid, 0)` is `ESRCH` for **both** pids. `shutdownAll` returns within its budget |
| 2 | A crash is detected, app survives | `crash-on-call` → `.crashed`; next call restarts; third crash → `.crashLoop`; `restart()` clears it. `exit-before-init` → `.exitedDuringStartup` |
| 3 | A hang hits a timeout | `hang-on-init`, `hang-on-call`, `stop-reading-stdin` (with a payload larger than the pipe buffer), `flood-stderr` → `.timedOut`, measured well under a generous bound over the injected deadline |
| 4 | No HTTP/SSE code | D-242: a SwiftLint custom rule rejecting `URLSession`, `URLRequest`, and `EventSource` in `StenoKit/Integrations/MCP/`. `make lint` is the check |
| 5 | No leak across restarts | Spawn, abandon without `stop()`; a fresh `ProcessLedger` over the same file reaps it. A ledger entry naming a **live** process with a wrong start time (the test runner's own pid) is **not** killed. Leader-dead, member-alive (`spawn-grandchild`, leader `SIGKILL`ed) is reaped |
| 6 | `make test` passes offline | The whole suite, against the stub |

Plus a pure codec suite: framing, the 8 MB cap, id matching, a late reply to a removed id, a
server→client request answered `-32601`.

### Rules carried from earlier PRs

- **Deadlines are injected.** Tests use ~300 ms; timing assertions use generous bounds, never
  worst-of-N (D-162).
- **Every awaiting test has its own bound.** A mutation that deletes a resume makes an
  unbounded test hang instead of fail.
- **Mutate every guard before the PR.** Remove the group kill, the start-time check,
  `O_NONBLOCK`, the stderr drain, the pending-before-write ordering, and the crash cap; each must
  turn a test red. A survivor is a mis-aimed mutation, a weak test, or dead code.
- Each test uses its own ledger file in a scratch directory, never the app's.

## Documentation in this PR

- `ARCHITECTURE.md` §5: `Integrations/MCP/` as built; §3: a new invariant row, *a server never
  outlives the app* — enforced in `SpawnedProcess.terminate`, `MCPHost.shutdownAll`, and
  `ProcessLedger.reapOrphans`.
- `DECISIONS.md`: D-234 through D-242.
- `docs/tasks/README.md`: tick any merged-but-unticked rows (CLAUDE.md step 4).

## Out of scope

- **HTTP/SSE transport** (§5.1, §5.4) — and D-242 makes adding it fail lint.
- Server definitions' persistence, Keychain-held secrets, Settings UI — M5-02.
- `SourceConnector` adapter, `SourceRef` mapping, AI-layer tool exposure — M5-03.
- `notifications/*/list_changed` handling: a caller re-lists when it needs to. Nothing in M5-03
  needs push updates.
- Server-initiated sampling, roots, or elicitation: declined by empty `capabilities` and
  `-32601`.
