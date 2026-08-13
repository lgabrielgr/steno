# AGENTS.md

**See [`CLAUDE.md`](CLAUDE.md).** It is the entry point for every agent working in this
repository, regardless of which tool you are.

This file exists because different coding agents look for different filenames. It deliberately
contains no instructions of its own — two copies of the same guidance drift, and a drifted
instruction is worse than a missing one, because an agent will follow it confidently.

The short version, so this file is not useless if you read only it:

- **`CLAUDE.md`** — how to work here: the workflow, the non-negotiables, the commands.
- **`docs/REQUIREMENTS.md`** — the source of truth for what to build.
- **`docs/tasks/`** — what to build right now, one file per branch and PR.
- **Never commit to `main`.** Every task is a branch and a pull request you do not merge.