# Native session memory and hibernation

This opt-in measurement supports [#597](https://github.com/z80dev/lemon/issues/597)
and the live-root retention introduced by
[#564](https://github.com/z80dev/lemon/issues/564). It measures real
`CodingAgent.Session` processes and their owned `LemonAgent.Agent` processes,
not empty stand-in GenServers. It is outside the test suite and nightly latency
lane. Measured local evidence is recorded below.

## Run locally

Use Python 3.11+ and an already prepared **development** build, from the umbrella
root. The launcher neither compiles nor fetches dependencies. Supply the full
commit SHA that produced those BEAMs; a revision label does not check that the
build or working tree matches it.

```bash
python3 -B bench/session_memory.py \
  --revision FULL_40_CHARACTER_COMMIT_SHA \
  --samples 20 --turns 4 --hibernate-after-ms 50 \
  --output /tmp/session-memory.json
```

The 50 ms timeout is a **benchmark-only override** to shorten repeated waits.
Repeat with `--hibernate-after-ms 5000` for the production timeout before making
a production wake-latency claim. The unhibernated control uses
`hibernate_after: :infinity`. Both settings go through `Session.start_link/1`
and are forwarded to its owned agent; no `:sys` mutation, explicit `:hibernate`
message, or forced garbage collection is used.

The launcher starts one disposable VM using:

```text
mix run --no-start --no-compile --no-deps-check bench/session_memory.exs
```

Run the Python command, not that probe directly: the launcher creates a private
HOME, cwd, temporary directory and stores, filters the inherited environment,
fixes the VM to two schedulers, and disables tzdata updating before boot. Only
SDK paths (`MIX_HOME`/`HEX_HOME`) and PATH/locale settings survive from the parent.
It starts `:coding_agent` and its application dependencies, not the full router,
channels or control-plane runtime. Gateway health/ingress are disabled. The
fixture invokes no tools and uses a local injected provider callback; unexpected
Req HTTP requests raise rather than falling through to a provider. No provider
credentials or paid calls are needed. Subprocess groups and temporary state are
cleaned up on success, failure, interruption and timeout. Only the report is
retained; it contains no conversation content, credentials, paths or process IDs.

## Workload and observation

Four cohorts are measured: `child_idle`, `child_hibernated`, `root_idle`, and
`root_hibernated`. Each has one discarded warm-up session, followed by
`--samples` **fresh sessions measured sequentially**, not a concurrent-population
capacity test. A child uses the production subagent scope, task-child flag, depth
one and parent lineage. A root uses main scope and `executor_root: true`. Both
start under the real `SessionSupervisor`, remain registered, and retain the
normal native tool inventory. User extensions, MCP discovery, WASM, retries,
automatic compaction and personal/project memory capture are excluded from this
controlled fixture. The actual tool count is recorded per sample.

Each session completes `--turns` synthetic user/assistant pairs before its memory
snapshot. Each user prompt is 2,048 UTF-8 bytes; each assistant answer is 3,840
bytes. The report records these sizes and actual retained message counts, since
additional runtime bookkeeping is not assumed to be free. Standard prompt/tool
state and journal/event history are included in the measured processes. The
fixture uses zero token/cost usage, emits text events and no tool calls, and
holds its provider behind a message barrier until the observer receives the
request timestamp. Completion and idle-state barriers precede memory sampling;
no fixed sleep is treated as proof of completion.

Root turns use #564's real `RootLifecycle.checkout/2` and `retain/1` paths. The
benchmark requires the same registered Session and Agent PIDs after another
turn and refresh. The root idle TTL and cap remain active, but sequential
sampling avoids cap eviction. This exercises the retained session layer, **not**
router/gateway admission, the executor's completed-event barrier, or parked
journal restoration. Child sampling likewise measures the session/agent pair,
not task-worker, TaskStore or parent-follow-up overhead.

A hibernated sample is accepted only when **both** processes report
`current_function: {:erlang, :hibernate, 3}` or the OTP 29
`{:gen_server, :loop_hibernate, 4}` form, plus `status: :waiting` and an empty
mailbox. The idle control must be waiting with an empty mailbox and must not be
hibernated. These checks use `Process.info/2`, not a GenServer state call that
would wake the target. Memory reads are bracketed by the same checks. Missing
completion, dead owners, failed refreshes and hibernation deadlines fail the
measurement instead of emitting zeroes. Polling is confined to this opt-in
observer and uses a bounded deadline.

## Metric definitions

Each cohort reports sample count, mean, minimum, maximum and nearest-rank
p50/p99, plus raw per-session values. Memory units are **bytes**; latency units
are **microseconds** (`1,000 us = 1 ms`). With 20 observations the nearest-rank
p99 is the maximum: use larger samples and repeated same-machine runs to assess
noise. Percentiles of component metrics are not additive.

| Metric | Definition |
| --- | --- |
| `session_process_bytes` | `Process.info(session, :memory)`: the BEAM's bytes attributed to the Session process, including its heaps, stack and process bookkeeping |
| `agent_process_bytes` | The same process-memory reading for the owned Agent |
| `session_agent_process_bytes` | Sum of those two readings in the **same sample**; the primary idle/hibernated pair comparison |
| `budget_scope_process_bytes` | Process-memory reading for the session's owned BudgetScope (not assumed hibernated) |
| `session_agent_budget_process_bytes` | Same-sample sum of Session, Agent and BudgetScope process memory |
| `session_agent_unique_referenced_binary_bytes` | Total size of ref-counted binaries listed by `Process.info(pid, :binary)` for Session and Agent, deduplicated by binary identity across the pair; reported separately, not claimed as exclusively owned memory |
| `session_scalar_call_us` | Monotonic time immediately before `Session.streaming?/1` → its `false` reply; includes mailbox/scheduler/call overhead, plus wake cost in the hibernated cohort, without copying history |
| `agent_scalar_call_us` | Time immediately before `Agent.get_session_id/1` → its matching ID reply; the same scalar wake/call boundary for the Agent |
| `next_turn_to_provider_us` | Time before the next session prompt (or root checkout) → timestamp at entry to the injected provider callback. Roots include live invocation rebind/tool refresh; children do not. Excludes provider response generation and the release barrier |
| `reload_refresh_us` | Time before `CodingAgent.CodeReload.refresh_sessions([id])` → `%{refreshed: 1, busy: 0, failed: 0}`; includes wake and rebuilding the idle session's tool closures |

Before **each** latency operation the measured pair returns to its cohort's
observed waiting/hibernation state. The prompt probe adds one further fixture
turn **after** the memory snapshot. Reload refresh is measured last, and same
Session/Agent identities and idle responsiveness are required afterward. This
is the session-refresh hook used by code reload; it deliberately does **not**
compile, load or purge code, time the complete `LemonCore.CodeReload` operation,
or replace the hibernation/code-reload regression tests.

### What the memory figures cannot establish

Process memory is not OS RSS, allocator-reserved memory, VM-wide marginal memory
or total cost per concurrent task. It excludes shared application supervisors,
registries/ETS, caches, code/literals, Store, filesystem journal/cache pages,
external processes and tool kernels. BudgetScope is shown separately, not hidden
in the pair. Ref-counted binary payloads are outside process heaps and can be
shared with other sessions, the observer or code literals; the separate binary
metric must not be summed across sessions as if every reference owned a copy.
The observer receives state once for identity/count metadata before settling;
its own memory is not included. No target GC is forced in the idle control, so
its heap slack is intentionally part of the comparison with OTP hibernation's
collection. Transcript length, tools and configured integrations change the
result; these small synthetic transcripts are not a universal per-agent price.

## Measured local evidence

Measured 2026-11-16 at `abc566dcdb83f35d311fb9c2c66b889e3b6fcc9d` on
MacBook Pro Mac15,9 / Apple M3 Max / 128 GB RAM / macOS 15.6 /
OTP 29 (ERTS 17.1.1) / Elixir 1.20.5, two schedulers:

```bash
python3 -B bench/session_memory.py --revision $(git rev-parse HEAD) \
  --samples 20 --turns 4 --hibernate-after-ms 5000 \
  --output /tmp/session-memory.json
```

Twenty samples per cohort, four fixture turns, production five-second timeout.
CPU benchmarks were serialized, but bounded provider measurements ran during
this probe; other host activity was uncontrolled. The pre-epic `4d94b3c8e`
checkout has no session-memory probe or retained-root/hibernation implementation,
so there is no historical baseline; the idle arm is the same-revision control.

| Cohort | Session bytes p50 / p99 | Agent bytes p50 / p99 | Pair bytes p50 / p99 | Artifact / tested revision |
| --- | --- | --- | --- | --- |
| Child idle | 14,709,512 / 14,709,704 | 4,721,088 / 4,729,680 | 19,430,616 / 19,439,192 | Local report / revision above |
| Child hibernated | 94,744 / 94,744 | 1,808,128 / 1,808,128 | 1,902,872 / 1,902,872 | Local report / revision above |
| Live root idle (#564) | 58,313,296 / 58,313,296 | 28,656,024 / 28,656,560 | 86,969,320 / 86,969,856 | Local report / revision above |
| Live root hibernated (#564) | 97,592 / 97,592 | 11,458,952 / 11,458,952 | 11,556,544 / 11,556,544 | Local report / revision above |

| Latency evidence | Idle p50 / p99 | Hibernated p50 / p99 | Artifact / tested revision |
| --- | --- | --- | --- |
| Child Session scalar call (us) | 2 / 2 | 185 / 262 | Local report / revision above |
| Child Agent scalar call (us) | 2 / 14 | 2,641 / 2,873 | Local report / revision above |
| Live-root Session scalar call (us) | 4 / 8 | 116 / 158 | Local report / revision above |
| Live-root Agent scalar call (us) | 2 / 4 | 10,348 / 14,724 | Local report / revision above |
| Child next turn → fixture request (us) | 18,068 / 27,207 | 50,931 / 57,607 | Local report / revision above |
| Live-root checkout → fixture request (us) | 269,739 / 334,497 | 290,307 / 303,041 | Local report / revision above |
| Child session-refresh hook (us) | 191,252 / 214,415 | 227,996 / 245,042 | Local report / revision above |
| Root session-refresh hook (us) | 190,718 / 211,483 | 217,168 / 235,759 | Local report / revision above |

BudgetScope was 13,984 bytes p50/p99 in every cohort. Unique referenced binary
bytes p50/p99 were child idle 158,226 / 158,234, child hibernated
104,898 / 104,898, root idle 171,521 / 171,521 and root hibernated
107,612 / 107,612. The pair-process p50 reductions are approximately 90.2%
for children and 86.7% for roots; these are not RSS or concurrency-capacity gains.
All samples passed identity, hibernation and reload-refresh checks. Hibernation
increased the local p50 next-request boundary by 32.863 ms for children and
20.568 ms for roots; these are separate-distribution differences, not paired
per-session wake estimates.

The local wake probes are not the #546 end-to-end budget. Run the existing
[latency harness](latency-sla.md) before and after integration on the same
machine/build settings, retaining both reports:

```bash
mix lemon.eval.latency --boots 5 --turns 20 \
  --revision BEFORE_FULL_40_CHARACTER_COMMIT_SHA --output /tmp/latency-before.json
# After integrating and preparing the corresponding development build:
mix lemon.eval.latency --boots 5 --turns 20 \
  --revision AFTER_FULL_40_CHARACTER_COMMIT_SHA --output /tmp/latency-after.json \
  --baseline /tmp/latency-before.json
```

Those back-to-back turns generally do not reach the five-second hibernation
timeout; use the session-memory command with `--hibernate-after-ms 5000` to
supply the separate idle-wake evidence. Report both, not a microbenchmark as an
end-to-end SLA. #546 baseline/threshold status and first measured targets remain
owned by the latency page and the orchestrator; no new latency target is invented
here. Nanocode's vendor-reported waiting-agent memory is not a controlled Lemon
baseline.

## Defaults decision

Keep task depth **2**, task concurrency **8**, root idle TTL **300,000 ms** and
root idle cap **32** unchanged: sequential synthetic cohorts do not justify
raising concurrent capacity. Session and Agent `hibernate_after` default to
**5,000 ms** (or caller-supplied `:infinity` to disable). Five seconds leaves
short inter-message gaps warm; this run establishes savings at that setting,
not that it is optimal. Hibernation retains the
live PID and state; TTL parking saves and stops the owner and is a different
lifecycle transition. Before raising concurrency/depth or changing the timeout,
measure realistic transcript/tool workloads and concurrent-population memory,
then compare #546 before/after latency plus the explicit idle-wake figures.
