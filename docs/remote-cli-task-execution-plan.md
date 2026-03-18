# Remote CLI Task Execution Plan

Status: planning

Last reviewed: 2026-03-18

## Summary

This document scopes and proposes a first implementation for running `task`
subtasks on other hosts using remote `codex` and `claude` CLI processes.

The key decision is to treat remote execution as a generic runner backend, not
as a distributed BEAM problem and not as a coding-project-specific workflow.

## Scope

Phase 1 supports only:

- `task` runs using `engine: "codex"` or `engine: "claude"`
- execution on either the local machine or a configured remote host
- optional `cwd` supplied by the model
- remote default working directory of the remote user's home directory

Phase 1 explicitly does not support:

- remote internal Lemon sessions
- distributed Erlang / clustered BEAM task placement
- workspace materialization, syncing, cloning, or worktree management
- generic remote engines beyond `codex` and `claude`

## Goals

- Keep the `task` tool interface simple for the model.
- Let the model choose a remote host when it needs one.
- Preserve the existing local task path.
- Reuse the current CLI runner stack instead of adding a parallel execution
  system.
- Return clear errors when the remote environment is missing a requested `cwd`
  or engine binary.

## Non-Goals

- Making remote execution transparent across all Lemon runtimes
- Cross-host OTP supervision semantics
- Remote tool execution for the internal `engine: "internal"` path
- Automatic repo/bootstrap logic on the remote machine

## Decision

Remote execution should be implemented as a launcher/backend beneath the CLI
runner layer.

`engine` continues to answer "which CLI runs the task". A separate field should
answer "where it runs".

This keeps the current engine split intact:

- `codex` and `claude` remain engine-specific command builders
- local vs remote becomes transport/launcher policy

## Why Not Distributed BEAM

Distributed Erlang is not the right first boundary for this problem.

- The problem is remote process execution, not remote OTP process placement.
- The current internal session path is tightly coupled to local supervisors,
  registries, ETS/DETS stores, and session lineage state.
- BEAM clustering would add cookie trust, version skew, and networking
  complexity without solving remote `cwd`, remote credentials, or remote binary
  availability.

If Lemon later needs remote internal sessions, that should be treated as a
separate design, likely with an explicit worker protocol rather than an ad hoc
cluster.

## Proposed Interface

Add a target field to `task` runs. Two reasonable shapes are:

### Option A: minimal

```json
{
  "engine": "codex",
  "host": "box-1",
  "cwd": "/tmp",
  "prompt": "..."
}
```

### Option B: more explicit

```json
{
  "engine": "codex",
  "executor": {
    "kind": "ssh",
    "host": "box-1"
  },
  "cwd": "/tmp",
  "prompt": "..."
}
```

For phase 1, `host` is likely enough.

Recommended behavior:

- no `host`: run locally
- `host` present: run on that configured remote host

## `cwd` Semantics

Local runs keep current behavior.

- local run with no `cwd`: inherit the caller's cwd
- local run with `cwd`: use the requested local cwd

Remote runs use host-local defaults.

- remote run with no `cwd`: use the remote user's home directory
- remote run with `cwd`: attempt `cd <cwd>` on the remote host before launch
- remote run with missing `cwd`: return a structured error to the model

The local caller cwd must not be silently inherited into remote runs.

## Architecture

The intended split is:

1. `task` validates `engine`, `host`, `cwd`, and prompt
2. task execution chooses a CLI engine as it does today
3. the CLI runner builds the engine command as it does today
4. a launcher/backend decides whether that command runs locally or via SSH
5. stdout JSONL is streamed back through the existing event pipeline

The engine-specific modules should stay focused on engine command lines and
event translation. The local vs remote concern belongs lower in the stack.

## Remote Launch Behavior

Phase 1 should use SSH.

The SSH path should:

- connect to a configured host alias
- set the working directory explicitly
- launch `codex` or `claude` without a TTY
- stream stdout back to Lemon unchanged
- keep stderr separate enough to classify transport failures vs engine failures

When `cwd` is omitted, the remote wrapper should explicitly `cd "$HOME"` before
launching the engine instead of relying on shell defaults.

## Error Model

Remote execution should distinguish these failures:

- SSH connection failure
- remote authentication failure
- remote `cwd` does not exist
- remote engine binary not found
- remote engine exited with an error after start
- local timeout or cancellation while waiting on the remote process

These should be returned in structured form so the model can retry with a
different host or directory.

## Resume And Host Affinity

Remote CLI runs are host-affine.

Any resume token, async followup, or task result metadata for a remote
`codex`/`claude` run must also persist the remote host identity. A token without
host information is not enough once the same engine can run on multiple
machines.

## Security Posture

Phase 1 should assume:

- remote hosts are explicitly configured and trusted
- remote hosts own their own Codex/Claude credentials
- Lemon does not forward arbitrary local environment variables by default

The remote launch layer should use a narrow allowlist for any environment
forwarding that is eventually required.

## Incremental Plan

1. Extend `task` params with a remote target field.
2. Keep support limited to `engine: "codex"` and `engine: "claude"` for remote
   runs.
3. Refactor CLI runner launch so local process spawning is one backend and SSH
   spawning is another.
4. Implement explicit remote-home and remote-`cwd` behavior.
5. Persist host metadata with task results and async bookkeeping.
6. Add tests for local behavior, remote home default, remote missing `cwd`,
   remote missing binary, timeout, and cancellation.

## Deferred Work

These are intentionally out of scope for this plan:

- host scheduling or capacity-aware placement
- workspace provisioning or repo sync
- remote execution for `kimi`, `opencode`, or `pi`
- remote internal sessions
- long-lived remote worker daemons
- distributed BEAM node membership

## Recommendation

Build phase 1 as a generic remote CLI runner backend over SSH for `codex` and
`claude` only.

That is the smallest design that preserves the current architecture, matches the
actual execution seam in Lemon, and keeps the door open for a more structured
remote worker protocol later if remote execution becomes important.
