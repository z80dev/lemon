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

The supervised manager owns both session snapshots and the volatile version
cache in ETS. Status callers never create tables: their exit cannot discard
the cache, and a manager restart clears it. Versions are validated against the
executable's mtime; upgrades replace that executable's cached row. A missing
owner is a cache miss, not a reason to create a caller-owned table.

The control plane exposes it as `omp.*` methods and the `omp.session` event.
See [Delegating to omp](../../docs/user-guide/omp.md) and the
[tool reference](../../docs/tools/omp.md).
