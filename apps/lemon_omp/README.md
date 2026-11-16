# lemon_omp

omp delegate driver for Lemon. It starts `omp --mode rpc` processes on request,
follows their RPC event stream, keeps a bounded snapshot per session, discovers
omp's stored sessions read-only, and contributes the `omp` agent tool through
`LemonAgent.ToolRegistry`.

- `LemonOmp` — public API (status, list/get/summary, start/resume,
  send/cancel/close, wait, discover). Returns JSON-safe camelCase maps.
- `LemonOmp.Session` — one supervised omp OS process per invocation.
- `LemonOmp.Manager` — admission cap, snapshot table, `omp` bus topic.
- `LemonOmp.Projection` — event fold and untrusted-text bounding.
- `LemonOmp.SessionFiles` — read-only session-file discovery.
- `LemonOmp.Rpc` — omp RPC v1 codec.
- `LemonOmp.Tools.Omp` — the agent tool.

Sessions delegate request correlation, command/handshake deadlines and caller
monitoring to `LemonCore.Rpc.Client`, using its JSON-lines framing. The session
still owns omp's stdin port, process-group cleanup, bounded incoming decoder,
turn projection and message-driven approval/cancellation handling. Configuration
steps run sequentially in the calling process; losing that caller removes its
pending command and cannot launch the remaining steps.

Control acknowledgements remain correlated to omp's response and reach callers
only after the session publishes the acknowledged turn projection. The RPC client
still monitors the original caller, not the session's reply relay. A deadline is
reported as `:outcome_unknown`, never retried; a closed connection is
`:not_running`. Late replies cannot acknowledge a newer request or reopen a
completed turn. A redirect's later prompt failure still updates its turn after
the original command was accepted.

The supervised manager owns both session snapshots and the volatile version
cache in ETS. Status callers never create tables: their exit cannot discard
the cache, and a manager restart clears it. Versions are validated against the
executable's mtime; upgrades replace that executable's cached row. A missing
owner is a cache miss, not a reason to create a caller-owned table.

Hard-killed sessions schedule worktree cleanup under the capped
`LemonOmp.TaskSupervisor`. If it cannot admit cleanup, the terminal snapshot
marks the worktree as kept with the task-admission reason; no unsupervised
fallback can delete it later. The supervisor uses the shared configurable
1024-task caller-policy default, not a measured throughput limit.

The control plane exposes it as `omp.*` methods and the `omp.session` event.
See [Delegating to omp](../../docs/user-guide/omp.md) and the
[tool reference](../../docs/tools/omp.md).
