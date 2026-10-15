# LemonOmp contributor guide

`lemon_omp` drives omp (oh-my-pi) as an external delegate. It is not an
executor or engine: Lemon's own runs stay native. See [README](README.md) and
the [operator guide](../../docs/user-guide/omp.md).

## Boundaries

- Dependencies are `lemon_core`, `lemon_agent`, `lemon_ai`. The `omp` tool
  registers through `LemonAgent.ToolRegistry`; `coding_agent` must not name this
  app. The control plane depends on it directly for `omp.*` methods; CLI and
  TUI reach it only through the control plane.
- Speak omp's documented RPC protocol (v1 JSONL over stdio). Do not scrape
  terminal output or parse omp's interactive UI. Session files are read-only:
  never write, lock or migrate omp state.

## Process lifecycle

- One `LemonOmp.Session` owns one OS process per invocation, `restart:
  :temporary`. Never relaunch automatically; a relaunch could replay a prompt
  omp already acted on. Resume is an explicit new invocation with a new id.
- omp exits on stdin EOF. Keep the port as the owner of omp's stdin so any
  death of the session process ends omp; `terminate/2` escalates TERM/KILL
  (descendants included) after a grace period.
- Strip `LEMON_*` variables from omp's environment. Reject caller-supplied
  paths other than the validated `cwd`; resume accepts session ids, not paths.

## Control and trust

- Acknowledge steer/follow-up/cancel only after omp's correlated success
  response. omp errors are rejections; silence is `:outcome_unknown` and must
  not be retried automatically. Closed/crashed invocations fail closed.
- Agent callers are scoped to their own session key; a foreign id reads as not
  found. Operator surfaces use `owner: :any`.
- Everything from omp is untrusted. Bound and sanitize it in `Projection`, mark
  tool results untrusted, and bridge tool approval selects through
  `LemonCore.ExecApprovals` without blocking the Session. Cancel pending approvals
  when omp abandons a dialog or the session ends; decline all other blocking UI
  requests. Reject host-tool/host-URI requests; Lemon registers none.

## Verification

From the umbrella root: `scripts/test path apps/lemon_omp/test`. By default,
tests use the fake omp script in `test/support` and exclude `:omp_live`.
They restore application env and confirm OS processes are gone.

Opt in to the real-binary lifecycle smoke with:

```bash
LEMON_OMP_LIVE=1 scripts/test path apps/lemon_omp/test/lemon_omp/live_smoke_test.exs
```

This uses the developer's real `~/.omp/agent` credentials despite the test
HOME sandbox, and writes session history there. Override with
`LEMON_OMP_LIVE_AGENT_DIR`; choose the binary with `LEMON_OMP_BIN`.
`LEMON_OMP_LIVE_MODEL` defaults to
`openrouter/nvidia/nemotron-3-super-120b-a12b:free`; only `:free` models are
accepted. It creates files only in a throwaway git workspace.
