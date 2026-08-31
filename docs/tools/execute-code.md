# Execute Code (`execute_code`)

`execute_code` is programmatic tool calling: the model submits a python3 script, the
script calls agent tools through pre-imported helper functions, and the script's result
comes back through an explicit channel: `text()` blocks are the result, while everything
printed to stdout/stderr lands in a clearly labeled diagnostics tail. A script can read
fifty files, grep a whole tree, or fetch a page and then emit a three-line summary via
`text()`; intermediate tool results travel over a file-based RPC bridge and never enter
the model transcript.

The tool is **disabled by default** and **bash-equivalent**: scripts run as ordinary host
code with the user's permissions. This is not a sandbox — see [Security](#security).

## Configuration

`execute_code` is configured under `[runtime.tools.execute_code]`
(`LemonCore.Config.Tools.resolve_execute_code/1` owns TOML/env resolution):

```toml
[runtime.tools.execute_code]
enabled = false                        # default: tool is not registered at all
python_path = ""                       # explicit interpreter; empty = find python3 on PATH
timeout_ms = 120000                    # end-to-end wall-time cap per run, including session queue wait
max_rpc_calls = 100                    # helper calls one run may make
max_rpc_result_bytes = 5242880         # total helper-result bytes one run may consume (5 MiB)
max_output_bytes = 50000               # script stdout/stderr bytes returned as diagnostics
max_text_bytes = 65536                 # total JSON-encoded text() frame bytes one run may emit
max_parallel_rpc = 4                   # helper calls the pump dispatches concurrently
tools = []                             # helper subset; empty = full fixed allowlist
kernel_mode = "per_call"               # "per_call" (default) | "session"
kernel_idle_timeout_ms = 1800000       # idle kernels reaped after 30 minutes
max_live_kernels = 16                  # strict live-kernel cap (idle-only LRU eviction)
max_queued_cells_per_kernel = 8        # FIFO queue depth behind the one active cell
```

Environment overrides (env wins over TOML):

- `LEMON_EXECUTE_CODE_ENABLED`
- `LEMON_EXECUTE_CODE_PYTHON_PATH`
- `LEMON_EXECUTE_CODE_TIMEOUT_MS`
- `LEMON_EXECUTE_CODE_MAX_RPC_CALLS`
- `LEMON_EXECUTE_CODE_MAX_RPC_RESULT_BYTES`
- `LEMON_EXECUTE_CODE_MAX_OUTPUT_BYTES`
- `LEMON_EXECUTE_CODE_MAX_TEXT_BYTES`
- `LEMON_EXECUTE_CODE_MAX_PARALLEL_RPC`
- `LEMON_EXECUTE_CODE_TOOLS` (comma-separated subset of the allowlist)
- `LEMON_EXECUTE_CODE_KERNEL_MODE`
- `LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS`
- `LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS`
- `LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL`

Only an explicit `"session"` selects session mode. Any other `kernel_mode` value — typos,
booleans, anything — resolves to `"per_call"`, so a config mistake can never silently
enable persistence. The numeric bounds are clamped to positive integers.

## Kernel modes

### `per_call` (default)

Every run executes in a fresh python3 process in a fresh private workspace, through the
same `BashExecutor` machinery as the `bash` tool. Imports, globals, and objects do not
survive the run. `reset: true` is accepted and validated but redundant
(`reset_performed: false` in details).

### `session` (opt-in)

Runs execute as **cells** on a persistent python3 interpreter (a *kernel*) supervised by
`CodingAgent.PythonRepl` (a registry plus a `DynamicSupervisor` of temporary workers under
`CodingAgent.PythonRepl.Supervisor`, started after `CodingAgent.TaskSupervisor`). Imports,
globals, objects, the module cache, and `os.environ` survive across calls — see
[State](#state-retention-and-loss).

**State is live process memory only.** It is never written to disk, never added to the
session transcript, and there is no checkpoint or restore. An application or node restart
loses every kernel; the next call simply starts a new one.

#### Keying and subagents

A kernel is keyed by:

- the persisted session ID (stable across turns, compaction, and resume — never `run_id`,
  tool-call ID, or the caller-overridable `session_key`),
- the agent/profile ID,
- the canonical (symlink-resolved) working directory,
- the canonical (symlink-resolved) interpreter path,
- the enabled helper set, and
- the runner protocol version.

The owning `CodingAgent.Session` process is monitored separately. Subagents isolate
naturally because they have distinct persisted session IDs; a subagent never shares its
parent's kernel. Changing cwd, interpreter, agent, or helper set selects a *different*
kernel — state is never migrated between keys. If two live actors resume the same persisted
session they become co-owners of one kernel; a `reset` from one co-owner forks only the
requester onto a fresh kernel and leaves siblings on the shared one.

#### Cells, queueing, and timeouts

Each kernel runs **one active cell at a time**; further calls wait in a FIFO queue bounded
by `max_queued_cells_per_kernel` (default 8). A full queue returns a busy error — it never
silently falls back, because a fresh process would not see the expected namespace. A queued
call whose external abort fires or whose deadline expires simply leaves the queue; the active
cell is undisturbed.

## State retention and loss

| Event | Result | Kernel state |
|---|---|---|
| Success | printed output | retained, including all mutations |
| Ordinary Python exception | filtered traceback (line numbers offset by 1) | retained, including completed and partial mutations |
| `SystemExit` | cell error | retained |
| `input()` / stdin read | explicit unsupported-input error | retained |
| Helper denial / error / budget limit | catchable `ToolError` in the script | retained |
| Timeout (including queued wait) / abort / caller death | partial output may return, `state_retained: false` | **discarded** when active; a queued caller simply leaves the queue |
| Interpreter crash, `os._exit`, protocol fault | error, `state_retained: false` | **discarded** |

Cancellation escalates SIGINT → SIGTERM → SIGKILL against the interpreter process group
with bounded grace periods; the user-visible contract is **state loss**, not
`KeyboardInterrupt` recovery. A script cannot rely on catching the interrupt to keep its
namespace. Code that has started executing is never retried and never replayed into a
replacement kernel, because side effects may already exist.

### `reset`

`reset: true` discards retained state **before** the submitted script runs
(`reset_performed: true` in details). If the old kernel cannot be confirmed gone
(`:registry_unavailable` or `:stop_failed`), the call runs isolated per-call instead and
details report the fallback; other reset failures are returned as errors and nothing runs.

### Session lifecycle

- **Session reset** (`/new`, identity rotation): the session synchronously detaches from
  its kernels while idle, before the new identity is installed.
- **Session close/termination**: the session requests detach during shutdown; the registry
  monitor on the session PID is the crash fallback.
- **Owner death**: detaching an owner removes its queued cells; if it owned the active
  cell the kernel is discarded (its state is unsafe). A kernel with no owners stops
  immediately.
- **Config switch** back to `per_call` or `enabled = false` takes effect on the next call;
  kernels retained earlier are detached on session reset/close and otherwise reaped when
  idle.

### Pre-start fallback only

Session mode may fall back to the isolated per-call path **only before submitted code
starts**. Details report `persistent: false` and a `fallback_reason`:

| `fallback_reason` | Meaning |
|---|---|
| `missing_session_scope` | no stable session identity (e.g. a context without a persisted session ID/PID/agent ID) |
| `registry_unavailable` | the kernel registry is not running |
| `capacity_exhausted` | `max_live_kernels` reached and no idle kernel is evictable |
| `startup_failed` | the kernel failed to start |
| `stop_failed` | a requested reset could not confirm the old kernel stopped |

Fallback text says the call ran isolated and will not persist. A full queue
(`:queue_full`), a dead worker, or any failure after code started is **never** retried or
fallen back.

## Helpers and the tool bridge

Scripts call agent tools through pre-imported helpers from a fixed, compile-time
allowlist: `read`, `grep`, `find`, `ls`, `webfetch`. The `tools` setting (or
`LEMON_EXECUTE_CODE_TOOLS`) may only **narrow** this list — no configuration can add
Every helper call goes through the same `ToolPolicy` and approval handling as a direct
tool call, in both kernel modes. Each cell gets a **fresh bridge**: a new owner-only
(`0700`) RPC directory and a new random 256-bit token, validated in constant time; stale
or cross-cell requests cannot call helpers. Helper failures raise a catchable
`ToolError`. Per-run budgets: `max_rpc_calls` calls (dispatched `max_parallel_rpc` at a
time), `max_rpc_result_bytes` total result bytes, and `max_text_bytes` total `text()`
block bytes; exceeding any of them raises `ToolError`.

`webfetch` results mark the tool result untrusted and wrap printed output as external
content, exactly like the direct tool.

## Result channels: `text()`, `notify()`, `batch()`

Besides the per-tool helpers, every shim (both kernel modes) defines three
module-level functions:

- **`text(s)`** — the explicit result channel. Each call atomically flushes a
  numbered `text-<n>.json` block into the per-run rpc directory (write-through,
  never deferred to exit), so everything written before a timeout or abort kill
  still reaches the tool result. Blocks are lock-guarded, so they are safe from
  `batch()` worker threads, and the total emitted bytes are capped at
`max_text_bytes` (default 64 KiB). The cap charges the **JSON-encoded frame**
— exactly the bytes `json.dump` writes to disk, escaping included — on both
sides of the bridge: the shim charges what it is about to write and the host
charges the file body it actually reads, so a NUL-heavy string that six-folds
under `\u0000` escaping is refused by the same budget on both sides, and an
in-budget block is always delivered. The payload is normalized first (lone
surrogates become U+FFFD), so every frame the shim writes is valid JSON the
host can decode. An over-budget call raises `ToolError` while the blocks
already flushed stay in the result. Non-strings are `str()`-coerced.
- **`notify(msg)`** — a fire-and-forget streaming side channel. The pump
  consumes `notify-<n>.json` frames on every sweep and forwards each message
  to the tool's streaming update callback as a partial update
  (`notify: <msg>`), capped at 4 KiB per message and 64 forwarded messages per
  run — the counter rides the run's stats, so it spans sweeps and the final
  drain. Anything beyond is silently dropped, malformed frames are consumed
  without being forwarded or counted, and a run with no callback consumes and
  discards them so they never accumulate. A `notify()` issued immediately
  before exit is still forwarded: the per-call pump and the persistent stop
  path each run one notification-only final drain, and in session mode that
  drain runs as part of the teardown stats read (`RpcServer.drain_and_stats`)
  so its count is included in the stats the cell's result reports.
  Tool requests are never drained after the run — a posthumous request would
  be tool work nobody is waiting for.
- **`batch([(tool, params), ...])`** — parallel helper calls. Each element runs
  the plain blocking call inside a bounded stdlib thread pool (16 workers max);
  the Elixir pump dispatches claimed requests as supervised tasks in waves of
  `max_parallel_rpc` (default 4), so independent reads genuinely overlap.
  Results return in input order; if any call fails, every call is still waited
  out and then the first failure (in input order) is re-raised as the same
  `ToolError` a plain call raises.

When a run emitted at least one `text()` block, the tool result is assembled
as: the headline (if any) → `Script result (text()):` with the blocks verbatim
in flush order → a `Diagnostics (stdout/stderr, not the result):` tail carrying
the captured stdout/stderr (still capped at `max_output_bytes`, with the
spill-to-file marker when truncated). On a timeout or abort the flushed blocks
are still included — that is the point of write-through. A script that never
calls `text()` keeps the historic stdout-only result byte-for-byte.

Stderr remains merged into stdout on purpose: the port has no separate stderr
capture, so un-merging would silently *discard* stderr (python tracebacks
included) instead of surfacing it in the labeled diagnostics tail.

Accounting under parallel dispatch stays exact because claiming —
authentication, replay detection, and call-budget reservation — happens
serially in the pump before any task starts, and the result-byte budget is
spent by the pump as each task returns. A claimed request always ends
answered: when it becomes dispatch-bound its `req-<id>.json` is renamed to an
in-flight `req-<id>.claim` marker, and **publication is the dispatch gate** —
the rename must succeed and the published marker must be a regular file (a
planted object at the marker name, or a symlinked request, is answered with a
publication-failure error and its tool never runs). But the rpc directory is
script-writable, so a marker alone is evidence only against crashes, never
against a hostile script that deletes or replaces it after the gate. In
session mode the claim therefore has a **second, host-side half**: the
`RpcServer` records one ledger entry per **spent call slot** in its own
process memory — via the pump's `:on_claim` hook, first a `:reserved` entry
the moment a request passes the replay and call-budget gates, fed before
the sweep-local spend itself so no kill can spend a call the ledger cannot
prove, then the entry's disposition (`:invalid`/`:unknown_tool`/`:denied`
for requests answered inside the claim without dispatching, `:claimed` for
a dispatch-bound request, fed *before* the marker is published, making the
ledger a superset of the published claims) — where the script cannot reach
it. A sweep that dies mid-wave is recovered from **both halves** by the
next sweep (or the server's cancel/abnormal-exit path, where no successor
runs): its claimed ids are answered in writing and never re-dispatched,
the replay memory is reconstructed so a replayed id is refused even when
its marker was destroyed, and real accounting (ok status, result bytes,
tool usage) is restored from a surviving response file plus the claim's
tool identity — the ledger's name whenever the ledger recorded the id
(host-owned beats script-writable, so overwriting the marker body cannot
forge the recorded tool), and the marker's own body only for ids the
ledger never saw. Reservation entries settle exactly — one call, one error
or denial, the replay memory — and a disposition entry (`:invalid`,
`:unknown_tool`, `:denied`) is answered in the settle: recovery writes the
kind's error via `ensure_answered` whenever no response survives (a
sweep-written answer is never overwritten), so a contained fault after an
answered-but-never-dispatched request (invalid, unknown tool,
policy-denied) can no longer erase that spend and let later sweeps exceed
`max_calls`; an entry still bare `:reserved` (death between the feed,
which precedes the spend, and the fate branch) charges the call exactly
and counts one error, the conservative split of a branch that never ran —
and writes no response, leaving the request file to the successor sweep's
replay refusal. A `:claimed` entry with
neither marker nor response surviving stamps `rpc_accounting_loss: true`:
the accounting is then a lower bound and the
cell's result is forced to `trust: :untrusted`. The same flag is stamped
whenever a sweep is brutally killed, dies abnormally, or is caught
raising/throwing mid-sweep — a contained fault is contained only in the
process sense: its result settles through the same recovery-plus-lower-bound
path, because work it dispatched and answered without returning its stats
is unknowable. A successful cancel also settles the sweep's still-queued
claim-ledger messages through the same deduplicating recovery, so no stale
ledger entry outlives its sweep. Recovery trusts only regular-file markers
(planted directories and symlinks at marker names are ignored outright) and
charges each dead claim **exactly once**; a marker whose deletion fails
(bounded retries) can never re-charge the budget on a later sweep.

Approvals stay on the existing `ToolExecutor` path inside each task; each
approval-requiring claim pre-allocates its approval id, and a tiny unlinked
watcher cancels the pending prompt after the death of the sweep **and** again
after the death of the dispatch task (it exits once both are gone), so a
prompt registered in the window between the first cancel and the task's own
death is still cancelled, and a cancelled prompt can never install policy
(cancel, resolve, and a waiter's timeout are one atomic single-winner
transition; the loser is `{:error, :not_pending}` — or a timeout with no
side effects — and installs nothing). The exact lifetime guarantee: **prompts
are cancelled when the dispatch task dies.** Dispatch tasks have trap_exit
forced off at entry so they die with their sweep; the boundary is that tool
code on the approval path can re-enable trap_exit afterwards and block past
its task's death — such a task keeps its (cancelled-once) watcher parked
until some other kill ends it, and until then the prompt outlives the
script. This is adversarial tool behavior, not a supported mode; the
boundary is demonstrated by the "a prompt registered after the sweep died
cannot be orphaned" test in
`apps/coding_agent/test/coding_agent/tools/execute_code_rpc_test.exs`.

In session mode the kernel stages `lemon_tools.py` once and `_configure`
installs a fresh bridge for every cell: new rpc dir and token, a full fresh
`text()` budget (the per-call `max_text_bytes` rides the bridge), and reset
sequence counters. Threads **inherit the cell generation of the thread that
created them, captured at construction time** (an untagged creator — the main
thread — falls back to the currently open cell), and the shim refuses bridge
calls from threads tagged with an earlier cell, so a thread a finished cell
left behind — and every thread it later spawns — can neither spend a later
cell's budget nor write into its rpc directory (its `ToolError` is
harmless). This is isolation hygiene, not a sandbox.

## Output

Only what the script writes to stdout/stderr is captured — there is no implicit
final-expression repr. Output is sanitized, capped at `max_output_bytes` keeping the first
40% plus a rolling last 60% with a truncation marker, and the full combined output spills
to a `0600` file whose path appears in the result as `full_output_path` and in
`[Full output saved to: ...]` text. The path remains readable after the cell completes. A
finished spill becomes eligible for best-effort reaping after 24 hours; an active capture
owned by a live BEAM process is never reaped.

For a run that used `text()`, this captured output is the **diagnostics tail**
of the result, not the result itself — see
[Result channels](#result-channels-text-notify-batch).

## Bounds and reaping

- `max_live_kernels` (default 16) is a strict cap: admission evicts the least-recently-used
  **idle** kernel, and never evicts starting/running/cancelling/queued work. If nothing is
  evictable the call falls back per-call (`capacity_exhausted`).
- `kernel_idle_timeout_ms` (default 30 minutes) reaps idle kernels; running work is never
  reaped. Ownerless kernels stop immediately.
- Per-kernel queue: `max_queued_cells_per_kernel` (default 8).
- Fixed internal constants (not configurable): 10 s startup timeout, 1 s INT/TERM/KILL
  grace periods, 256 KiB protocol-frame cap, 64 KiB stream chunks.
- Python memory and child processes inside a kernel are **not** OS-sandboxed; a runaway
  script can consume host resources until its cell timeout fires.

- Python REPL full-output spill files remain available after cell completion. A node
  processes one batch of at most 1,000 direct entries per 24-hour reaper window across
  its current and stale private staging roots, retaining continuations for later windows.
  The current root is always processed first; one stale root may use its remaining budget.
  Only expired regular `pi-python-repl-*` files that are no longer live are eligible.
- Workspace and bridge teardown is bounded: removal visits at most 10,000 entries per
  tree (no symlink following), so a script that planted a huge tree cannot stall the
  owning process in `rm_rf`. Any remainder stays owner-only under the private staging
  root and is eligible for the boot-time stale-root sweep on a later node.
- Once at node boot, the reaper discovers sibling private staging roots left by prior
  nodes (or a prior first-root race), but only when their `0600` owner marker identifies a
  dead OS process. Empty stale roots are removed best-effort; non-empty roots are never
  removed or traversed recursively.

## Security

`execute_code` runs **local host code with bash-equivalent authority**. It is classified
with `bash` in `CodingAgent.ToolPolicy`, is default-off, and is approval-wrappable through
the normal registry path. The helper allowlist bounds the *Lemon tool* surface, not the
OS: Python can still read files, inspect the environment and network, and spawn processes.
The per-cell bridge token prevents stale/cross-cell helper requests; it is not secret from
code running in the same interpreter and is not a sandbox.

**Host requirement (GNU/Linux):** private workspaces are created through GNU `mktemp`
(coreutils, found on `PATH`) under `TMPDIR` (default `/tmp`) on a **local** filesystem —
NFS is unsupported. A per-node staging root and every workspace/bridge/spill object
beneath it are created atomically at exactly `0700` (directories) / `0600` (files) and
validated; there is no chmod-after-create and no fallback to loosely-permissioned temp
directories. Finished Python REPL spills become eligible for best-effort reaping after
24 hours; active captures are excluded. At boot, a node considers a sibling staging root
only when its validated owner marker names a dead OS PID; missing, malformed, and
live-owner markers are skipped. OS PID reuse can therefore conservatively defer stale-root
cleanup until a later boot. The reaper checks only direct regular `pi-python-repl-*` entries
with `lstat` and never follows symlinks. On platforms without a suitable GNU `mktemp`, or if
validation fails, the run fails closed **before any script executes** (per-call: a
workspace-creation error; session mode: `startup_failed` fallback).

## Telemetry and introspection

`execute_code` and the kernel subsystem emit only bounded categorical metadata and
count/duration measurements — never code, output, tracebacks, tokens, bridge paths, cwd,
interpreter paths, PIDs, key digests, or raw errors. See
[`docs/telemetry.md`](../telemetry.md#execute-code-and-persistent-python-kernels) for the
event catalog (`[:coding_agent, :execute_code, :stop]` and the
`[:coding_agent, :python_repl, ...]` families).

Operators can read an **aggregate** kernel snapshot via
`CodingAgent.PythonRepl.snapshot/0` — live/capacity counts, per-phase counts, owner and
fork counts, and reap settings; it contains no identities or payload. Lifecycle events are
also recorded through `LemonCore.Introspection` as redacted
`:python_repl_lifecycle_observed` summaries. There is intentionally **no control-plane
API** for kernel management.
