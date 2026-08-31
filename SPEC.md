# SPEC: execute_code result channel — `text()` / `notify()` + parallel RPC pump

Repo: lemon (Elixir umbrella). Worktree: `/home/z80/dev/lemon/.worktrees/execute-code-result-channel` (branch `feat/execute-code-result-channel`). Do all work here.

## Problem

Today `CodingAgent.Tools.ExecuteCode` returns **stdout** as the tool result that enters the model transcript (assembled in `result_text/2` around `execute_code.ex:921`, from `BashExecutor.Result.output`). Two defects follow:

1. `BashExecutor` runs Port with `:stderr_to_stdout` (`bash_executor.ex:84`), so library warnings and other incidental output are indistinguishable from deliberate results and pollute the transcript.
2. On timeout/abort the partially-captured stdout is delivered mid-line and garbled; deliberate results don't survive a kill.

Also: the RPC pump (`CodingAgent.Tools.ExecuteCode.Rpc`) executes tool requests **serially** inside `process_pending/2` sweeps, and the Python shim `_call/2` is synchronous with a non-thread-safe global `_SEQ` counter — so a script cannot issue parallel tool calls.

## Required changes

### R1 — `text()` result channel (Python shim + Elixir result assembly)

- Python side (generated `lemon_tools.py` in `CodingAgent.Tools.ExecuteCode.PythonShim`):
  - Add `text(s)` (accept `str`; `str()`-coerce non-strings): appends the string as a numbered text block by **write-through flush** — write `text-<n>.json` into the existing per-cell RPC dir using the same atomic tmp+`os.replace` pattern as `_call`, `0600` perms, fsync not required. Write per call (NOT atexit) so blocks survive timeout/kill.
  - Thread-safe: guard block numbering with a `threading.Lock` (required for R3's `batch()`).
  - Enforce a byte budget: total accumulated text-block bytes capped at a new config knob `max_text_bytes` (default 64 KiB; put alongside `max_output_bytes` in `Config`, wire through `runtime.toml`/config example if such an example file exists). Over-budget calls raise `ToolError` like other limit violations.
- Elixir side:
  - New `Config` field `max_text_bytes` with default; parsed from settings like `max_output_bytes`.
  - After the run (both per-call and session kernels), read all `text-*.json` blocks from the RPC dir **in id order**, then delete them with the rpc dir as today.
  - `result_text` assembly becomes: headline (existing) → text blocks verbatim in order (labeled as the script's result) → **diagnostics tail**: stdout/stderr capped at `max_output_bytes` (existing knob) and clearly labeled "diagnostics, not the result". Empty stdout → keep existing "(script produced no output)" behavior for the diagnostics section only.
  - Preserve existing behaviors: truncation spill-to-file marker, cancelled/timeout headlines, `state_retained` reporting. On cancelled/timeout runs, still include any `text-*.json` blocks that were flushed — that is the point of write-through.
  - `notify()` plumbing in R2 must not break when the pump never sees a text block (text blocks are file-only; no RPC round-trip).

### R2 — `notify()` streaming side channel (optional use of existing seam)

- Shim: `notify(msg)` writes `notify-<n>.json` (atomic, 0600, thread-safe counter) and does **not** block for a response.
- Elixir: the RPC pump sweeps already walk `req-*.json`; extend the sweep to also collect `notify-*.json` files (consume + delete after read, same hygiene as requests). Each collected notification is forwarded through the tool's `on_update` callback (`execute/6` currently ignores it — see `execute_code.ex:196/212`) as a partial `AgentToolResult` whose text is `notify: <msg>`. Cap forwarded message bytes (reuse a small constant, e.g. 4 KiB per message, 64 messages per run; silently drop beyond that).
- If `on_update` is nil, still consume+drop the files (never let them accumulate).

### R3 — Parallel nested tool calls

- Python shim: add `batch([(tool, params), ...]) -> [str results]` implemented with `concurrent.futures.ThreadPoolExecutor`; each worker calls the existing `_call`. Fix `_SEQ` increment to be under the existing/new lock so ids are unique under threads. No change to blocking semantics of plain `_call`.
- Elixir RPC pump: dispatch each authenticated, policy-allowed request as its own `Task` (supervised by a dedicated `Task.Supervisor` under the ExecuteCode supervision tree or the existing tool task supervisor — pick and justify) instead of running it inline in `process_pending/2`. Requirements:
  - Per-request ids remain answered exactly once; replay detection (`seen?/2`) must stay correct under concurrency (serialize stats updates or move to an owning process; justify the design in a comment).
  - Call-limit accounting (`stats.calls` vs `max_calls`) must remain exact: never dispatch beyond the remaining budget. Over-budget requests still get the existing limit-exceeded error response.
  - Approval-gated tools (`approval_required?/2`) keep working: either serialize approvals through the existing `ToolExecutor.execute_with_approval` path in the task, or document precisely why the current path is concurrency-safe. Do not allow an approval prompt to be duplicated or lost under parallel dispatch.
  - Responses still written atomically to `res-<id>.json`; ordering between requests must not matter.
  - Sweep pacing unchanged: `max_requests_per_sweep` still bounds requests *claimed* per sweep; concurrency bound = new config knob `max_parallel_rpc` (default 4, `Config` field, must be ≥1).

## Constraints

- **Scope**: only the `execute_code` feature surface (`apps/coding_agent/lib/coding_agent/tools/execute_code*`, `python_repl/` if a protocol version bump is needed, `bash_executor.ex` only if you stop merging stderr — see below). Nothing else in the repo.
- Do NOT touch the bot runtime, gateway, or `~/.lemon` config. Feature stays default-off (`enabled: false`).
- Keep `render_prelude`/one-shot compatibility path working (existing tests cover it).
- If protocol version constants exist (PythonRepl.Protocol), bump/handle per existing conventions.
- Stderr: it is acceptable (preferred) to stop passing `:stderr_to_stdout` for execute_code runs only if the diagnostics tail still shows stderr content; otherwise leave BashExecutor untouched. Either way, document the choice.
- Docs contract (repo rule): update the `@moduledoc` of `ExecuteCode` (+ `Rpc`/`PythonShim` docs where behavior changed) and any affected `AGENTS.md`/docs file that describes execute_code. Search `docs/` for `execute_code` and update what's stale.
- Style: run `mix format` on changed files. No stray `IO.inspect`.

## Verification (must run and report output)

```
cd /home/z80/dev/lemon/.worktrees/execute-code-result-channel
mix compile apps/coding_agent
mix test apps/coding_agent/test/coding_agent/tools/execute_code_test.exs
mix test apps/coding_agent/test/coding_agent/tools/execute_code_rpc_test.exs
mix test apps/coding_agent/test/coding_agent/tools/execute_code_rpc_server_test.exs
mix test apps/coding_agent/test/coding_agent/tools/execute_code_persistent_test.exs
mix test apps/coding_agent/test/coding_agent/tools/execute_code_adversarial_test.exs
mix test apps/coding_agent/test/coding_agent/tools/execute_code_config_test.exs
mix test apps/coding_agent/test/coding_agent/tool_registry_execute_code_test.exs
```

### New tests required (add to the existing test files, match their style)

1. `text()`: blocks returned in order; stdout noise lands in diagnostics tail, not the result; over-budget raises ToolError and reports partial blocks per your design (state the behavior in the test).
2. `text()` survival: script killed by timeout after flushing text blocks → blocks still present in result.
3. `notify()`: on_update receives forwarded notifications in order; nil on_update doesn't crash; files consumed.
4. `batch()`/parallel pump: N slow-but-safe tool calls (e.g. `ls` on large dirs or a stubbed slow tool if the test support provides one) complete with all results correct; call-limit still enforced exactly when batch size exceeds remaining budget; replay (duplicate id) still errors under parallel load.
5. Adversarial: planted `text-<id>.json` **symlink** (not regular file) must be rejected/skipped like the existing `res-<id>.json` symlink defense; oversized text block file (>budget) handled without crashing.
6. Config: `max_text_bytes` and `max_parallel_rpc` parse from settings with correct defaults.

Note: python3 must be on PATH for these tests (they spawn real interpreters). If the environment lacks python3, report that as a blocker instead of skipping silently.

## Deliverable

Commit(s) on `feat/execute-code-result-channel` in the worktree with clear messages. Final report: what changed per requirement (R1/R2/R3), design decisions (concurrency approach for the pump, stderr decision, budget enforcement points), verification output, and anything deferred. Do NOT push, do NOT open a PR.
