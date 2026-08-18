# Persistent Python REPL Plan

Status: implemented; feature verification complete. The repository fast lane was run on 2026-08-18 and remains red only on an unrelated pre-existing `lemon_core` architecture rule violation in `LemonCore.Testing.HermeticEnv`.

Date: 2026-08-17

Last reviewed: 2026-08-18

## Executive summary

Lemon should add process-local persistent Python state by **extending the existing `execute_code` tool**, not by adding a second model-facing tool. Keep `script` and `timeout_ms`; add optional `reset`. Persistence is selected by operator config, never by a model-supplied session or kernel ID.

Implement a dedicated OTP subsystem in `apps/coding_agent`: a registry owns key/owner mappings, generations, admission, and reaping; a `DynamicSupervisor` owns temporary `PythonRepl.Session` workers; each worker owns exactly one Python `Port`, serializes cells, and destroys the interpreter process group after active timeout, cancellation, protocol fault, or crash. Do not force this into `ProcessManager`/`ProcessSession`: their terminal line/log/restart/DETS contract does not provide correlated eval requests, mutable-namespace serialization, or safe replacement.

Key state by persisted CodingAgent session ID plus agent/profile ID, canonical cwd, canonical interpreter, enabled helper set, and runner protocol version. Track the `CodingAgent.Session` PID as a separate owner. This survives turns and compaction, naturally isolates subagents, permits monitor-driven teardown, and safely handles two actors resuming the same persisted session. A co-owner reset forks only the requester.

Serialize every cell. Cancelling a queued caller removes only that call. Timing out or cancelling an active cell sends SIGINT where supported, then TERM/KILL on bounded grace periods, and always discards the namespace. Ordinary Python exceptions preserve completed and partial mutations. Never retry or fall back after a runner acknowledges that code started.

Use typed, request-correlated frames over a private control descriptor so user stdout/stderr cannot corrupt protocol. Keep Lemon’s existing file-RPC helper bridge, but give each cell a fresh `0700` directory and 256-bit token. Every helper call continues through current `ToolPolicy` and `ToolExecutor` approval handling and per-cell call/result budgets.

For compatibility, `kernel_mode` defaults to `"per_call"`; operators explicitly select `"session"`. `execute_code` remains default-off and bash-equivalent. Session mode may fall back to the current fresh-process path only before submitted code starts, and reports that fallback. No control-plane CRUD is required.

## Problem

`CodingAgent.Tools.ExecuteCode` currently creates a temporary workspace, writes `script.py` and `lemon_tools.py`, runs one Python process through `CodingAgent.BashExecutor`, services file-RPC calls, returns bounded output, and removes everything. Each call loses imports, definitions, objects, and in-memory results.

The root problem is not merely process reuse. A live mutable interpreter needs stable identity, separate OTP ownership, exclusive mutation, unambiguous transport, cancellation that cannot leave unknown state, process-tree cleanup, and hard resource bounds.

## Goals

- Preserve globals, imports, module cache, objects, and process environment across calls in session mode.
- Retain the existing tool name, `script`, timeout clamp, helper allowlist, policy/approval path, and per-call mode.
- Specify reset, errors, timeout, cancellation, cwd/interpreter changes, concurrency, subagents, session close, node restart, and fallback precisely.
- Supervise and bound every interpreter, queue, cell output, helper calls, and helper-result bytes.
- Prevent user output and inherited descriptors from corrupting or holding the control channel.
- Preserve the boundary forbidding compile-time `lemon_control_plane -> coding_agent` dependencies.
- Add redacted telemetry and aggregate introspection without recording code or output.

## Non-goals

- A separate `eval`, `python`, notebook, or kernel-management tool.
- Languages other than Python; IPython/Jupyter; notebooks; rich MIME; generalized eval.
- Disk durability, transcript restoration, checkpointing, remote persistence, or node migration.
- Remote/Docker/SSH/WASM placement or a sandbox. This remains host code with bash authority.
- Concurrent execution inside one namespace.
- Model-supplied session/owner/key/cwd/interpreter/close parameters.
- Control-plane REPL CRUD.

## Evidence and comparison

### Lemon facts

- `apps/coding_agent/lib/coding_agent/tools/execute_code.ex` defines `tool/2` and `execute/6`, using a per-call workspace, `BashExecutor`, and `ExecuteCode.Rpc`.
- `apps/coding_agent/lib/coding_agent/tools/execute_code/config.ex` fixes the allowlist to `read`, `grep`, `find`, `ls`, and `webfetch`; defaults are disabled, 120 seconds, 100 RPC calls, 5 MiB RPC results, and 50,000 output bytes.
- `apps/coding_agent/lib/coding_agent/tool_registry.ex` config-gates the built-in and applies policy/approval wrappers. `tool_policy.ex` classifies it as bash-equivalent.
- `apps/coding_agent/lib/coding_agent/session/lifecycle.ex` supplies persisted `session_id`, `session_pid`, `run_id`, `session_key`, `agent_id`, cwd, settings, policy, and approval context. Its persisted `SessionManager.header.id` is stable across turns/resume; `run_id` is not.
- `ProcessSession` owns a generic terminal Port and logs. It is a cleanup reference, not an eval protocol.
- `LemonAgent.Loop.ToolCalls` may kill a tool task at an outer timeout. The interpreter must monitor its caller and cancel independently.
- `LemonCore.Config.Tools.resolve_execute_code/1` owns canonical TOML/env resolution.

### Imported lessons

Hermes contributes compression-stable scope, single-kernel locking, generation-safe startup/reset, idle/LRU bounds, per-cell authenticated bridging, typed frames, process-group cleanup, and unconditional discard after active timeout/interruption. OMP contributes separate owner refcounts, monitor-driven detach, co-owner reset forks, request-correlated private-fd framing, and bounded SIGINT escalation.

Adopt the hybrid: Hermes serialization/conservative invalidation/bounds; OMP ownership/fork semantics; Lemon’s public tool, config path, file-RPC helpers, policy, approval, and output contract. Reject OMP’s concurrent shared namespace and preserve-after-soft-interrupt behavior.

## Architecture decisions

### Extend `execute_code`

Add optional `reset`; do not add an overlapping tool. Do not expose mode, language, session ID, owner ID, cwd, interpreter, or close. The dynamic description explains the resolved mode and persistence/failure semantics.

Rejected: a new `eval` tool duplicates policy and forces model routing; hidden persistence without reset is unrecoverable; model-selected IDs permit cross-session sharing.

### Compatibility default

Add `kernel_mode = "per_call" | "session"`, default `"per_call"`. There is no later automatic default flip in this plan. `enabled` remains false by default.

### Dedicated supervision

Create:

```text
CodingAgent.Supervisor
└── CodingAgent.PythonRepl.Supervisor (:one_for_all)
    ├── CodingAgent.PythonRepl.SessionSupervisor (DynamicSupervisor)
    └── CodingAgent.PythonRepl.Registry (GenServer)

CodingAgent.TaskSupervisor
└── CodingAgent.Tools.ExecuteCode.RpcServer (temporary, one active cell)
```

`:one_for_all` ensures a registry crash tears down otherwise orphaned interpreters. Session workers use `restart: :temporary`; registry generations decide replacement. In `CodingAgent.Application`'s child list, `CodingAgent.PythonRepl.Supervisor` must be inserted only after the existing `CodingAgent.TaskSupervisor`, because per-cell `RpcServer` workers depend on that supervisor.

### Key and owner

`CodingAgent.PythonRepl.Key` contains:

- `scope_id`: persisted `SessionManager.header.id` (`:session_id` tool opt);
- `agent_id`;
- canonical real cwd;
- canonical real interpreter path;
- sorted helper set or stable digest;
- runner protocol version.

Do not include `run_id`, tool-call ID, or caller-overridable `session_key`. Do not include policy: helper authorization is reevaluated per cell and no policy capability is cached.

Owner is the stable `CodingAgent.Session` PID (`:session_pid`), monitored by registry. Redacted session/run labels are telemetry metadata only. Subagents isolate naturally through distinct persisted session IDs.

### Co-owner semantics

- Sole-owner reset: increment generation, stop old worker, start fresh base key.
- Co-owner reset: detach requester and assign `{:owner_fork, base_key, owner_pid}`; replace only that fork. Siblings retain shared state. Fork is sticky until detach.
- Owner detach: remove its queued calls. If it owns the active cell, cancel/discard that interpreter; shared siblings lose it because state is unsafe. If no owner remains, stop immediately.

### Serialization and queueing

One active cell per worker, FIFO queue, default maximum 8 queued cells. The facade starts one
absolute `timeout_ms` deadline when the session run begins; it includes queue wait, active-cell
execution, and ordinary helper/approval waits. The kernel receives the same timeout for active
execution, while the facade remains authoritative for the end-to-end bound. Outer abort/tool
timeout still cancels a queued caller. Queue full returns busy; it does not fall back to per-call
because that would silently leave the expected namespace.

### Failure semantics

- Syntax/ordinary exception: return filtered traceback; retain state, including completed mutations.
- `SystemExit`: cell error, process retained.
- `input()`: explicit unsupported-input error, process retained.
- Helper denial/error/limit: Python `ToolError`; catchable; state retained.
- Active timeout, abort, or caller death: partial output may return, but state is discarded.
- Port death, `os._exit`, native crash, malformed protocol: state discarded.
- A queued caller whose abort or deadline fires leaves the queue without affecting the active cell.
- Never replay after `started`; side effects may already exist.

Cancellation is SIGINT to the process group on POSIX, 1-second grace, SIGTERM, 1-second grace, then SIGKILL/Port close. Platforms without reliable soft interrupt go directly to tree termination. User-visible contract is state loss, not `KeyboardInterrupt` recovery.

### Cwd/interpreter/config changes

Different canonical cwd, interpreter, agent, helper set, or protocol version selects a different key; no state migration. Before each cell, runner restores keyed cwd and helper path. Globals/imports/module cache/objects/`os.environ` persist; an `os.chdir()` does not change the next cell’s starting cwd.

### Session/node lifecycle

- `CodingAgent.Session.reset`: detach old owner after agent is idle and before installing new `SessionManager`.
- Session termination: synchronously request detach/close; PID monitor is crash fallback.
- Node/application restart: all Python memory is lost; first later call is new.
- Config switch to per-call/disabled: dispose that owner’s retained workers rather than merely waiting for idle reap.

## Runner/control protocol

Bundle `apps/coding_agent/priv/python_repl/runner.py`, stage it and `lemon_tools.py` into a `0700` per-kernel workspace, and execute the resolved interpreter unbuffered. Runner calls `setsid()` early on POSIX. Windows uses tree termination and does not promise soft SIGINT.

Parent stdin requests are UTF-8 NDJSON:

```json
{"v":1,"type":"init","cwd":"/canonical/path"}
{"v":1,"type":"eval","id":"cell-id","code":"...","cwd":"/canonical/path","bridge":{"dir":"...","token":"..."}}
{"v":1,"type":"shutdown"}
```

Runner duplicates original stdout as a non-inheritable control descriptor, redirects fd 1/2 to captured pipes, and emits only framed protocol on the saved descriptor. Frames use record-separator + `lemon-python\t` + JSON + newline. Stream bytes are base64 and chunked. Required frames: `ready`, `started`, `stream` (`stdout`/`stderr`), `exception`, `done`, `fatal`, `bye`.

`CodingAgent.PythonRepl.Protocol` incrementally validates prefix, version, type, request ID, terminal-frame uniqueness, fields, and a 256 KiB frame maximum. Unknown/malformed/oversized/wrong-ID frames destroy the interpreter. Unprefixed bytes are never treated as user output. Descendants do not inherit the control descriptor.

Preserve current script semantics: only explicit stdout/stderr is returned; no implicit final-expression repr. Rich display and top-level await are deferred.

## Tool bridge and security boundary

Keep file-RPC. Each cell receives a fresh `0700` directory, owner-only files, and random 256-bit token. Runner calls private `lemon_tools._configure(dir, token)` before code. Each request carries the token; `ExecuteCode.Rpc` validates it in constant time before counting/dispatch.

Refactor shared validation/dispatch/accounting so per-call `Rpc.serve/2` and persistent `RpcServer` use exactly the same fixed allowlist, current cell tool closures, `ToolPolicy`, `ToolExecutor.execute_with_approval`, abort signal, atomic responses, call limit, and result-byte limit. `RpcServer` runs outside `PythonRepl.Session`, so an approval/tool wait cannot block Port frames or cancellation.

The token prevents stale/cross-cell requests; it is not secret from arbitrary code in the same interpreter and is not a sandbox. Python can still inspect files/env/network and spawn processes.

## Output contract

`CodingAgent.PythonRepl.Output` captures stdout/stderr in arrival order, sanitizes like `BashExecutor.sanitize_output/1`, retains a 40% head/60% rolling tail within `max_output_bytes`, and spills full combined output using `BashExecutor`'s existing temporary-file/`full_output_path` convention, with the spill file created at `0600` permissions. Preserve current success/error text and full-output path behavior.

Do not add a persistent-only heuristic secret redactor; per-call code output is not redacted and this is a host-code boundary. Telemetry/introspection must never include code, output, traceback text, token, bridge path, cwd, interpreter path, or PID.

## Public tool/config contract

Schema:

```json
{
  "type":"object",
  "properties":{
    "script":{"type":"string"},
    "timeout_ms":{"type":"integer"},
    "reset":{"type":"boolean","default":false}
  },
  "required":["script"]
}
```

`timeout_ms` retains minimum 1,000 ms and configured maximum. It is an end-to-end wall-clock
limit from session-run entry, including queue wait, active-cell execution, and ordinary
helper/approval waits.

Retain existing detail fields and add:

- `persistent`
- `kernel_reused`
- `reset_performed`
- `state_retained`
- `fallback_reason` (`nil`, `missing_scope`, `unsupported_platform`, `registry_unavailable`, `capacity_exhausted`, `startup_failed`)
- `duration_ms` (end-to-end wall-clock duration)

Never expose PIDs, raw keys, owners, tokens, bridge paths, or generations. Timeout/cancellation/crash text says state was discarded. Session-mode fallback text says this call ran isolated and will not persist.

`reset: true` invalidates the effective generation **before** executing `script`. If reset cannot be confirmed, error; never fall back while an old kernel may survive. In configured per-call mode reset is accepted but redundant (`reset_performed:false`).

Session-mode fallback is allowed only before `started`, including missing stable scope, unavailable registry/platform, strict-capacity exhaustion, or startup failure. Queue overflow does not fall back. A reset fallback is allowed only after old-generation invalidation is confirmed. No failure after `started` is retried/fallen back.

Configuration:

```toml
[runtime.tools.execute_code]
enabled = false
python_path = ""
timeout_ms = 120000
max_rpc_calls = 100
max_rpc_result_bytes = 5242880
max_output_bytes = 50000
tools = []
kernel_mode = "per_call"            # "per_call" | "session"
kernel_idle_timeout_ms = 1800000
max_live_kernels = 16
max_queued_cells_per_kernel = 8
```

Add env overrides:

- `LEMON_EXECUTE_CODE_KERNEL_MODE`
- `LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS`
- `LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS`
- `LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL`

`LemonCore.Config.Tools.resolve_execute_code/1` owns TOML/env precedence; app-local Config normalizes it. Invalid mode follows normal validation and never silently enables session mode. Keep internal tested constants non-configurable initially: 10-second startup timeout, 1-second INT/TERM graces, 256 KiB frame cap, 64 KiB stream chunks.

## OTP state and bounds

Registry state tracks entries by effective key/PID/generation/status/owners/last-use; reverse owner keys; owner monitors; owner forks; and base generations. It serializes attach/start/reset, ignores stale ready/down events, and starts at most one worker per effective key/generation.

Session state tracks key, generation, phase (`starting|idle|running|cancelling|stopping`), Port/OS PID/workspace, startup timer, queue, active cell, output, protocol buffer, and completed-cell count. Active cell holds request ID, `GenServer.from`, caller monitor, abort signal, timers, bridge process/dir/token, current authorization context, output, RPC stats, and `started?`.

Strict admission: at `max_live_kernels`, evict the LRU eligible idle worker. Never evict starting/running/cancelling/queued work and never exceed the cap. If none eligible, explicit pre-start per-call fallback. Reaper stops only idle expired workers; ownerless workers stop immediately. Python memory/child count inside a live bash-equivalent process is not OS-sandboxed; docs must say so.

Normal stop sends `shutdown`, briefly waits for `bye`, then escalates. `terminate/2` always stops bridge, closes Port, removes workspaces, and best-effort kills group/tree. Tests include a descendant holding stdout and one ignoring INT/TERM. Abrupt machine/BEAM SIGKILL cannot guarantee cleanup.

## Implementation checklist

### Phase 1 — Freeze public/config contracts

- [ ] Update `apps/lemon_core/lib/lemon_core/config/tools.ex` (`execute_code_config`, `resolve_execute_code/1`) with mode/bounds/envs and validation.
- [ ] Update `apps/coding_agent/lib/coding_agent/tools/execute_code/config.ex` (`t`, struct, `load/2`).
- [ ] Update `execute_code.ex` (`tool/2`, `description/1`, docs) with optional `reset`, without selecting session path yet.
- [ ] Extend `apps/lemon_core/test/lemon_core/config/tools_test.exs`, `execute_code_config_test.exs`, and `tool_registry_execute_code_test.exs` for defaults, env precedence, invalid mode, bounds, gating, and additive schema.

Acceptance: existing configs resolve per-call; existing params behave unchanged; invalid mode never enables persistence.

### Phase 2 — Runner/protocol/process boundary

- [ ] Add `priv/python_repl/runner.py` with persistent namespace, input rejection, cwd restoration, private fd, stream drainers, frames, tracebacks, and POSIX session/process group.
- [ ] Add `python_repl/key.ex`, `protocol.ex`, `output.ex`, `process.ex`, and `session.ex` under `apps/coding_agent/lib/coding_agent/`.
- [ ] Add `apps/coding_agent/test/coding_agent/python_repl/{protocol,output,session,runner_integration}_test.exs`.

Acceptance: cells share state; ordinary errors retain; fake protocol output cannot forge frames; invalid frames kill; timeout/active caller death kills; queued death does not; descendants die; started code is never replayed.

### Phase 3 — Registry/ownership/supervision

- [ ] Add `python_repl/session_supervisor.ex`, `registry.ex`, `supervisor.ex`, and facade `apps/coding_agent/lib/coding_agent/python_repl.ex`.
- [ ] Add `CodingAgent.PythonRepl.Supervisor` to `CodingAgent.Application` after `TaskSupervisor` availability.
- [ ] Add registry/supervisor tests for first-use coalescing, reset-during-start, stale generation messages, sole/co-owner reset, owner death, detach during queued/active work, worker crash, strict cap/LRU, idle reap, and subsystem restart.

Acceptance: one Port per effective generation; stale generations never publish; live cap never exceeds configured value; active/queued work never evicts; registry crash leaves no worker.

### Phase 4 — Authenticated shared bridge

- [ ] Update `python_shim.ex` for per-cell `_configure(dir, token)`.
- [ ] Refactor `rpc.ex` into shared authenticated parsing/dispatch/accounting.
- [ ] Add `execute_code/rpc_server.ex` as temporary supervised cell poller.
- [ ] Extend RPC/adversarial tests for missing/wrong/stale token, replay, atomic files, policy/approval denial, helper failure, limits, abort, and cleanup.

Acceptance: direct and persistent helper calls traverse identical policy/approval paths; stale credentials cannot call; token/path never leak.

### Phase 5 — Tool and session integration

- [ ] Refactor `ExecuteCode.execute/6` into selector plus explicit per-call/persistent paths, retaining one schema/formatter.
- [ ] Pass session/owner/key inputs and current policy/approval/abort context to `PythonRepl.execute/1`.
- [ ] Add persistence/reuse/reset/state/fallback details and enforce pre-start-only fallback/no replay.
- [ ] Update `Session.Lifecycle.reset/2` to detach old owner before replacing SessionManager.
- [ ] Update `Session.terminate/2` to detach/close owned REPL sessions.
- [ ] Extend `execute_code_test.exs`; add `execute_code_persistent_test.exs`; extend session lifecycle tests.

Acceptance: per-call tests remain compatible; session state reuses/resets; exception/cancel/crash/fallback semantics match; close leaves no process; subagents isolate; key changes do not migrate state.

### Phase 6 — Operability/docs/cleanup

- [ ] Emit `[:coding_agent,:python_repl,:session,:start|:stop|:crash|:reap]`, `...:cell,:start|:stop`, `...:cancel`, `...:fallback`, and `...:bridge,:deny` with counts/durations and bounded categorical metadata only.
- [ ] Provide `Registry.snapshot/0` aggregate counts by state/capacity; use `LemonCore.Introspection.record/3` only for redacted lifecycle summaries. Add no control-plane method.
- [ ] Add canonical `docs/tools/execute-code.md` covering config, live-not-durable semantics, reset/errors/cancel/crash, keying/subagents, bridge/security, output/bounds/reaping/fallback/teardown.
- [ ] Update `docs/config.md`, `docs/config-registry.md`, `docs/telemetry.md`, `examples/config.example.toml`, `apps/coding_agent/README.md`, `apps/coding_agent/AGENTS.md`, and affected module docs. Remove claims that execution is always one temporary process; leave no duplicate implementation or alias.
- [ ] Add telemetry privacy/event tests.

Acceptance: tracked docs/config alone explain operation; telemetry detects churn/capacity/cleanup without code/credentials; no control-plane dependency exists.

## Verification commands

Run only from umbrella root:

```bash
mix format --check-formatted
mix test apps/lemon_core/test/lemon_core/config/tools_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/tools/execute_code_config_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/tools/execute_code_rpc_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/tools/execute_code_adversarial_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/tools/execute_code_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/tools/execute_code_persistent_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/python_repl --seed 1
mix test apps/coding_agent/test/coding_agent/tool_registry_execute_code_test.exs --seed 1
mix test apps/coding_agent/test/coding_agent/session --seed 1
scripts/test path apps/coding_agent/test --seed 1
scripts/test fast
```

Before broader enablement, exercise the real runner on each supported CI OS: reuse state, recover from ordinary error, reset, spawn/terminate descendants, force timeout, confirm next call fresh, close session, and verify registry and OS child counts return to zero.

## Rollout and rollback

1. Merge default-off with default `per_call`.
2. Enable `session` in development; observe starts, reuse, cancellations, crashes, fallback, reap, capacity, and orphan checks.
3. Opt selected trusted local profiles in via TOML. No data migration exists.
4. Roll back by selecting `per_call` or disabling the tool; config transition disposes retained workers.
5. Code rollback/node restart merely loses live namespaces; there is no durable schema rollback.

## Risks and mitigations

1. **Partial state after cancellation:** always discard active interpreter; `state_retained:false`.
2. **Duplicate side effects:** `started` is the absolute no-retry/fallback boundary.
3. **Startup/reset race:** registry-serialized generations; stale PID/generation events ignored and worker stopped.
4. **Process leaks:** dedicated supervision, owner monitors, private non-inherited fd, process groups/tree kill, immediate ownerless cleanup, idle/LRU reap.
5. **Co-owner disruption:** fork resets; active departing-owner cancellation still invalidates shared interpreter because safety wins.
6. **Resource exhaustion:** strict live cap, idle-only LRU, queue/output/RPC bounds; acknowledge absence of OS memory sandbox.
7. **Protocol spoofing:** private fd, captured streams, prefix/version/request validation, frame cap; fault destroys worker.
8. **Stale bridge authority:** fresh token/directory, constant-time auth, current cell context, fixed allowlist, immediate teardown.
9. **Compatibility surprise:** default per-call, same name/required params/output baseline, explicit opt-in.
10. **Durability/sandbox misconception:** canonical docs and result text explicitly deny both.

## Rejected alternatives

- Reuse `ProcessManager`: terminal/DETS semantics do not satisfy eval generations/owners.
- Key by run ID: changes across turns.
- Key by session key: caller-overridable provenance, not canonical identity.
- Share parent/subagent kernel: unsafe globals/cwd concurrency and capability leakage.
- Concurrent cells: mutable process-global state is not transactional.
- Preserve after SIGINT: partial/caught interruption makes safety unknowable.
- Retry after crash: may duplicate external side effects.
- Persistent HTTP bridge: duplicates Lemon’s working policy-integrated file-RPC path and lengthens capability lifetime.
- Persist registry in DETS: mappings cannot restore process memory and would be stale.
- Control-plane CRUD: unnecessary; if later required, add optional `LemonControlPlane.AgentRuntime.Provider` callback, never direct dependency.

## Deferred enhancements

Top-level await/final-expression display; rich MIME/artifacts; live output streaming; OS CPU/memory/process sandboxing; remote/distributed/checkpointed kernels; broader/background/PTY helpers; generalized languages; optional provider-backed redacted operator status; stronger Windows soft-interrupt parity.

## Implementation closure

Implemented on 2026-08-18. Targeted feature verification passed. The CodingAgent lane completed 4,144 tests with one environment failure because the declared local `playwright-core` dependency was not installed; after `npm ci`, that exact browser case passed independently. A real runner smoke confirmed first allocation, state reuse (`x = 41` then `42`), owner detach/reset, fresh allocation, state loss, and interpreter-process cleanup.

The root fast lane was also run. All feature-owning CodingAgent tests passed; the only repository-wide failure was the unrelated `LemonCore.Quality.ArchitectureRulesCheckTest`, which reports existing `TELEGRAM`, `DISCORD`, and `XMTP` references in `apps/lemon_core/lib/lemon_core/testing/hermetic_env.ex`. That external repository gate is not resolved by this feature.

## Definition of done

- Only `execute_code` exposes additive `reset`; no duplicate tool/alias.
- Existing config remains per-call; per-call behavior is covered.
- Session mode reuses by persisted identity, isolates subagents/key changes, and handles co-owner forks.
- Every interpreter is supervised, serialized, bounded, reaped, detached on reset/close/death, and process-tree cleaned.
- Queued/active cancellation, timeout, crash, reset, fallback, no-replay, startup/reset races, and disposal races have deterministic tests.
- User output cannot forge protocol; stale bridge credentials cannot call; helper policy/approval/budgets remain authoritative.
- Results expose persistence/reuse/reset/state/fallback without internal IDs/secrets.
- Telemetry/introspection are redacted and diagnose capacity/churn/escalation/protocol/cleanup.
- Tool/config/telemetry docs, app README/AGENTS/module docs, and config example match implementation.
- Targeted tests, CodingAgent tests, formatter check, root fast lane, and real-runner lifecycle smoke pass.
- No control-plane dependency, durable/sandbox claim, placeholder, TODO implementation, or temporary migration mechanism remains.
