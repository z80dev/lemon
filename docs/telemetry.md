# Telemetry

Every catalog row below names the function that emits the event and links its module.
`scripts/check_docs_source_refs.mjs` (run by `scripts/test quality` and the docs-site
gate) fails when a linked function no longer makes the telemetry call for its row's event,
so a catalog entry here means the event actually fires.

`:telemetry ~> 1.0` is the required observability dependency. `lemon_agent`
also declares `opentelemetry_api` as **optional** for the default-off
[GenAI span exporter](#optional-genai-span-export). There is no required OTel SDK,
transport exporter, `telemetry_metrics`, `telemetry_poller`, or
`phoenix_live_dashboard`; the generic consumer example uses
`:telemetry.attach_many/4`.

Two layers coexist and are easy to confuse:

- **Telemetry** (this document) is fire-and-forget. Handlers run synchronously in the
  emitting process; nothing is stored.
- **Introspection** ([below](#introspection-the-persisted-layer)) is a separate, persisted,
  queryable envelope written through `LemonCore.Store`. It has its own event taxonomy and is
  *not* derived from the telemetry events here.

## Safe runtime diagnostics

Production diagnostics use owner-published snapshots and explicit summary APIs,
not `:sys.get_state`. Gateway health reads scheduler counters without waiting
for the scheduler mailbox. Async task surface bindings are immutable Registry
values: answer finalization never asks a subscriber for its private state.
Long-lived admission, stream, process-store, LSP, channel-registry and task-control
servers expose redacted `format_status/1` summaries. These hooks also remove
messages, reasons and debug logs that may contain private data; they do not make
arbitrary process inspection safe.

Prefer the documented telemetry events and bounded status summaries first.
On a trusted local node, `:sys.get_status(pid)` requests the redacted OTP status
but still requires a responsive owner; it is not a health probe.

For a problem that requires tracing, use OTP `:dbg` or an operator-installed
`recon_trace` only for a short, bounded capture of a specific PID and function.
Neither is enabled by Lemon, and `recon` is not a required dependency. Trace
arguments, return values, messages and exceptions can contain credentials,
prompts and tool output **before redaction**. Do not enable node-wide tracing
or attach to an untrusted remote node; keep captures private and never paste
raw output into issues. Set a small event limit (for example
`recon_trace:calls/3`'s limit argument), stop the trace immediately after capture,
and clear OTP tracing with `:dbg.stop_clear/0`. Tracing has runtime overhead;
do not use it as a permanent metrics collector.

## Control-plane method execution

`LemonControlPlane.Methods.Registry` emits these events for every dispatch,
including unknown methods and caught callback failures:

| Event | Measurements | Metadata | Emitter |
| --- | --- | --- | --- |
| `[:lemon, :control_plane, :method, :start]` | `system_time` (native) | `method` | [`emit_method/3`](../apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex) |
| `[:lemon, :control_plane, :method, :stop]` | `duration` (native) | `method`, `outcome: :ok \| :error \| :exception` | [`emit_method/3`](../apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex) |
| `[:lemon, :control_plane, :method, :exception]` | `count: 1` | `method`, `class` (exception module or catch kind) | [`LemonControlPlane.Methods.Registry.report_failure/2`](../apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex) |

Method labels are registered names of at most 128 bytes, or `:unknown`; arbitrary
request method strings are never reflected into telemetry. Parameters, auth
context, return values and raw failure terms are excluded. A caught exception
emits both the exception counter and a stop with `outcome: :exception`. A process
killed during dispatch may have a start without a stop.

## OS-process lifecycle

| Event | Measurements | Metadata | Emitter |
| --- | --- | --- | --- |
| `[:lemon, :process_group, :start]` | `count: 1` | `scope: :group \| :process` | [`LemonCore.ProcessGroup.terminate/2`](../apps/lemon_core/lib/lemon_core/process_group.ex) |
| `[:lemon, :process_group, :stop]` | `count: 1`, `duration` (native) | `scope`, `outcome: :terminated \| :signaled` | [`LemonCore.ProcessGroup.terminate/2`](../apps/lemon_core/lib/lemon_core/process_group.ex) |
| `[:lemon, :process_group, :failure]` | `count: 1`, `duration` (native) | `scope`, `outcome: :alive \| :unobservable` | [`LemonCore.ProcessGroup.terminate/2`](../apps/lemon_core/lib/lemon_core/process_group.ex) |
| `[:lemon, :process_session, :start]` | `count: 1`, `duration` (native) | `mode: :managed \| :oneshot`, `outcome: :running` | [`lifecycle_event/4`](../apps/coding_agent/lib/coding_agent/process_session.ex) in `CodingAgent.ProcessSession` |
| `[:lemon, :process_session, :failure]` | `count: 1`, `duration` (native) | `mode`, `outcome: :startup_failed` | [`lifecycle_event/4`](../apps/coding_agent/lib/coding_agent/process_session.ex) |
| `[:lemon, :process_session, :stop]` | `count: 1`, `duration` (native) | `mode`, `outcome: :stopped \| :owner_failed` | [`lifecycle_event/4`](../apps/coding_agent/lib/coding_agent/process_session.ex) |

Process-group events describe termination attempts, not workload launches.
Process-scoped `:signaled` means signal acknowledgement, not verified exit;
group termination distinguishes confirmed termination from an alive or
unobservable group. Process-session durations start before initialization, so
`:start` measures startup and `:stop` measures owner lifetime including startup.
An owner stop is not evidence that the workload completed successfully. Abrupt
BEAM process kills may prevent terminal events.

All metadata is bounded labels: no process/session identities, commands, paths,
environment values, output or raw failure reasons are included.

## Session-start latency stages

`[:coding_agent, :session, :start_stage]` is emitted synchronously by
`CodingAgent.Session.Lifecycle.initialize/2` after each measured initialization
stage. Measurements are `%{duration: native_time_units}`; convert with
`System.convert_time_unit(duration, :native, :microsecond)` before reporting.
Metadata contains only `session_id` and a code-authored `stage` atom:
`:journal_load`, `:tool_registry`, `:environment_capture`, or
`:prompt_composition`. No cwd, prompt, tool arguments, environment values or
credentials are included. Each stage uses two monotonic clock reads and one
telemetry dispatch, without a closure, task, write or persistent observation.

Journal timing includes load/create and header resolution. Tool timing includes
extension lifecycle initialization and planning-tool construction. Environment
timing includes the frozen-snapshot bypass; prompt timing includes sections,
joining and planning composition. These are completed-stage observations, not
start/stop spans: an interrupted stage emits nothing. They measure session
creation, not every prompt refresh when a session is reused. Settings/model
resolution, execution-context writes and later agent initialization remain
outside these four stage durations.

The [offline latency lane](benchmarks/latency-sla.md) consumes these events and
the existing gateway run `:start`, `:first_token` and `:stop` events. Consumers
must keep synchronous handlers cheap; the benchmark only sends bounded timing
messages to its owner and retains no session content.

## Prompt source loading

Instruction and rule loading runs on session start and on every turn's prompt
refresh. `CodingAgent.ResourceLoader.SourceReader` emits
`[:coding_agent, :prompt_sources, :read]` for every disk read of an instruction
file, `@` import or rule file (stat-validated cache hits emit nothing), with
`%{bytes: n}` and metadata `%{truncated: boolean}`, and
`[:coding_agent, :prompt_sources, :load]` once per loader pass with
`%{duration: native_time_units, reads: n, bytes: n}` and metadata
`%{source: :instructions | :rules}`. No paths or content are included. A turn
whose sources are unchanged reports `reads: 0`.

## Conventions

### Naming

Three prefix families coexist. This is descriptive, not a recommendation — see
[Known gaps](#known-gaps-and-inconsistencies).

| Prefix | Meaning | Emitted via |
|---|---|---|
| `[:lemon, ...]` | Cross-cutting platform concerns: runs, channels, approvals, memory, scheduler, reload, WASM | `LemonCore.Telemetry.emit/3` and its named helpers |
| `[:lemon_agent, ...]`, `[:coding_agent, ...]`, `[:lemon_ai, ...]` | App-local concerns, prefixed by OTP app | `LemonCore.Telemetry.emit/3` or `:telemetry.execute/3` directly |
| `[:lemon_skills, ...]` | App-local, full app name as prefix | app-local helper module |

`LemonCore.Telemetry.emit/3` is a direct pass-through to `:telemetry.execute/3`
([`telemetry.ex`](../apps/lemon_core/lib/lemon_core/telemetry.ex)); attaching does not
depend on which one an emitter used.

### Span shape

Events ending in `:start` / `:stop` / `:exception` follow the `:telemetry.span/3` convention
by hand — none of them actually call `:telemetry.span/3`. The practical consequence is that
`:stop` is **not** guaranteed to follow every `:start`: if the emitting process is killed
between them, no `:stop` or `:exception` arrives. Consumers that pair them need their own
timeout.

### Measurement units

Model-call and tool-call span events consistently use `duration` in **native
monotonic units**, never milliseconds or microseconds. Their terminal events
also carry `monotonic_time` (the native terminal timestamp); subtracting
`duration` reconstructs admission time even when a stream ends in another
process. Model `first_event_duration` uses the same unit. Both start events
carry native `system_time` and `monotonic_time`. Convert with
`System.convert_time_unit(value, :native, :millisecond)` for display.

Other, older telemetry families retain explicitly suffixed units. When writing
a consumer, check the table for the event you are attaching to:

| Unit | Used by |
|---|---|
| `duration` in **native** units | `[:lemon, :channels, :deliver, :stop]`, `[:lemon_agent, :loop, :end]`, `[:lemon_ai, :dispatcher, :rejected]`, `[:lemon_ai, :model_call, :stop \| :exception]` (also `first_event_duration`), `[:lemon_agent, :tool_call, :stop \| :exception]` |
| `duration_us` | `[:coding_agent, :extension, :tool, ...]`, `[:coding_agent, :wasm, :tool, ...]`, `[:lemon, :memory, :ingest, ...]` |
| `duration_ms` | `[:lemon, :reload, ...]`, `[:lemon, :run, :stop]`, `[:lemon, :wasm, :*, :stop]` |
| both `duration` (native) and `duration_ms` | `[:lemon, :config, :reload, :stop]` and `:exception` — `duration` is a real monotonic native reading and `duration_ms` is derived from it via `System.convert_time_unit/3` |

`LemonCore.Telemetry`'s moduledoc records the intended convention for **new** emitters:
`duration` in native units, with `duration_ms` derived only for logs. Existing `duration_us`
/ `duration_ms` events predate it and are not renamed, because renaming is a breaking change
for any attached consumer.

`system_time` measurements are `System.system_time()` in native units and are timestamps,
not durations.

## Optional GenAI span export

`LemonAgent.GenAISpans` is a supervised, optional telemetry attachment owned by
`lemon_agent` (which already depends on both event-owning apps). `lemon_ai` and
`lemon_core` acquire no umbrella dependency. Nothing attaches unless the host
configures this **before application startup**:

```elixir
config :lemon_agent, :gen_ai_spans,
  enabled: true,
  exporter: LemonAgent.GenAISpans.OpenTelemetry
```

The adapter is compiled only when the optional `opentelemetry_api` dependency
is available. The host must install/start an OpenTelemetry SDK and configure
its batch processor, sampling and transport exporter separately. The API alone
is non-recording; Lemon does not add a required SDK, endpoint, collector or
background network service. Packaged hosts must explicitly include the
optional apps. See [configuration](config.md#optional-genai-span-export).

| Source | Span name / kind | Allowlisted attributes |
| --- | --- | --- |
| `[:lemon_ai, :model_call, :stop \| :exception]` | `chat <model>` / client | `gen_ai.operation.name: "chat"`, `gen_ai.system` and `gen_ai.provider.name` (provider label), `gen_ai.request.model`, `gen_ai.request.stream: true` when known streaming, and nonnegative `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_write.input_tokens` |
| `[:lemon_agent, :tool_call, :stop \| :exception]` | `execute_tool <name>` / internal | `gen_ai.operation.name: "execute_tool"`, `gen_ai.tool.name`, `lemon.tool.timeout` |

`gen_ai.system` preserves the older GenAI spelling; `gen_ai.provider.name`
supplies its current counterpart. Missing model/provider/tool labels become
`"unknown"`; missing usage is omitted, not invented as zero. Errors, canceled
model calls and tool failures set error status and a bounded `error.type`
(`model_call_error` or `tool_call_error`); successful calls leave status unset.
The attribute map is built from an allowlist, never by copying event metadata.
There are **no prompts, responses, tool arguments/results, intent strings,
paths, credentials, raw exception messages or stacktraces**, and no option to
enable content capture.

The mappings follow the [GenAI inference](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/client-inference.md)
and [tool-execution](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/execute-tool.md)
conventions (currently development status). GenAI input-token totals include
cache reads and writes. Lemon's source `input_tokens` excludes those subsets,
so the exporter sums all three **only when all are reported**; otherwise the
aggregate attribute is omitted. Known zero counters are preserved. Cache
subsets and output counters remain independently exportable when known.

The attachment exports completed spans at terminal events, with exact native
monotonic `start_time = monotonic_time - duration` and `end_time =
monotonic_time`. These match the Erlang OTel API's timestamp units; the SDK
converts to Unix timestamps for transport. No pairing registry, timeout,
per-call allocation at `:start` or unfinished OTel span is needed. Parallel calls
and cross-process streaming completion cannot mismatch. A process killed
without a terminal event produces no span. Dispatcher rejections are not model
calls; older `tool_task`, extension and WASM wrapper events are not exported
again, avoiding duplicate tool spans.

Spans are **standalone roots**, not whole-request traces: this attachment does
not infer a parent from a stream tracker's process dictionary or change the
emitter's current OTel context. Request-level context propagation and
whole-request tail sampling are not provided by this attachment.

To use a custom/test exporter without OpenTelemetry, implement
`LemonAgent.GenAISpans.Exporter.export_span/2` and configure:

```elixir
config :lemon_agent, :gen_ai_spans,
  enabled: true,
  exporter: MyApp.SpanExporter,
  exporter_config: [queue: MyApp.ExportQueue]
```

The callback receives a completed span map (`name`, `kind`, `attributes`,
`status`, native `start_time`, `end_time`, `duration`) and `:exporter_config`
unchanged. It executes synchronously: enqueue quickly, never perform network
I/O in it. Exporter errors/raises/throws/exits are isolated and emit only a
content-free warning; they cannot fail a model/tool call or detach the handler.
The attachment is removed on supervised shutdown and reclaimed on restart.
Restart `:lemon_agent` to apply configuration changes.


## Run lifecycle

The sequence below is the common path for a message arriving on a channel and producing a
reply. Not every step fires for every run: engine execution varies, and the tool block
repeats once per tool-calling turn.

```mermaid
sequenceDiagram
    participant Ch as Channel adapter
    participant R as LemonRouter
    participant S as Gateway Run / Slots
    participant L as LemonAgent.Loop
    participant P as LemonAi.CallDispatcher
    participant M as LemonMemory.Ingest
    participant O as Channels Outbox

    Ch->>R: inbound message
    Note over Ch: [:lemon, :channels, :inbound]
    Note over R: [:lemon, :run, :submit]
    R->>S: start Run; claim engine session; request permit
    Note over S: Slots.stats exposes in_flight, waitq, max
    S->>L: permit granted; executor starts
    Note over L: [:lemon_agent, :loop, :start]<br/>[:lemon_agent, :tool_schema_snapshot, :created]

    loop each turn
        L->>P: provider call
        Note over P: [:lemon_ai, :dispatcher, :dispatch]<br/>[:lemon_ai, :model_call, :start] then :stop or :exception<br/>or [:lemon_ai, :dispatcher, :rejected]
        Note over L: [:lemon_agent, :tool_task, :start]<br/>[:lemon_agent, :tool_task, :end] or :error<br/>[:lemon_agent, :tool_result, :emit]
    end

    Note over L: [:lemon_agent, :loop, :end]
    L->>S: release slot
    L->>M: finalize run
    Note over M: [:lemon, :memory, :ingest, :ok] or :failure
    R->>O: enqueue reply
    Note over O: [:lemon, :channels, :outbox, :queue]<br/>[:lemon, :channels, :deliver, :start]<br/>[:lemon, :channels, :deliver, :stop]
    O->>Ch: delivered
```

**The end-to-end run span is emitted from the gateway run process.**
`[:lemon, :run, :start]`, `[:lemon, :run, :first_token]`, and `[:lemon, :run, :stop]` all
fire from `LemonGateway.Run` through the matching `LemonCore.Telemetry`
helpers. `[:lemon, :run, :stop]` carries
`duration_ms` and an `ok` boolean, so whole-run latency and success/failure are both readable
from telemetry alone. A run the router terminalizes before an executor owns it emits its
`:stop` from `LemonRouter.RunCompletion` instead. The introspection layer's
`:run_started` / `:run_completed` records remain available as a persisted, queryable
alternative.

## Event catalog

### Run lifecycle — `[:lemon, :run, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :run, :submit]` | `count: 1` | `session_key`, `origin`, `engine` | [`LemonCore.Telemetry.run_submit/3`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonRouter.RunOrchestrator`](../apps/lemon_router/lib/lemon_router/run_orchestrator.ex) when a submission is accepted |
| `[:lemon, :run, :start]` | `ts_ms` | `run_id`, `session_key`, `engine`, `origin` | [`LemonCore.Telemetry.run_start/2`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonGateway.Run`](../apps/lemon_gateway/lib/lemon_gateway/run.ex) when the gateway starts the engine run |
| `[:lemon, :run, :first_token]` | `latency_ms` | `run_id` | [`LemonCore.Telemetry.run_first_token/2`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonGateway.Run`](../apps/lemon_gateway/lib/lemon_gateway/run.ex) on the first engine delta of the run |
| `[:lemon, :run, :stop]` | `duration_ms`, `ok` (boolean) | `run_id`; plus `session_key` and `engine` from the router path | [`LemonCore.Telemetry.run_stop/3`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonGateway.Run`](../apps/lemon_gateway/lib/lemon_gateway/run.ex) at finalize; `ok` distinguishes success from `{:error, _}`. Not emitted if the run process crashes before finalize. Runs terminalized before an executor owns them emit it from [`LemonRouter.RunCompletion.publish/2`](../apps/lemon_router/lib/lemon_router/run_completion.ex) |
| `[:lemon, :router, :run_abort_tombstone, :registered]` | `count: 1` | bounded `reason` label | [`emit_abort_tombstone_telemetry/2`](../apps/lemon_router/lib/lemon_router/run_orchestrator.ex) in `LemonRouter.RunOrchestrator`, when a fixed run ID is marked aborted at the serialized submission boundary |
| `[:lemon, :router, :run_abort_tombstone, :submission_rejected]` | `count: 1` | bounded `reason` label | [`emit_abort_tombstone_telemetry/2`](../apps/lemon_router/lib/lemon_router/run_orchestrator.ex), when a later submission is rejected by that tombstone |

### Cron — `[:lemon, :cron, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :cron, :tick]` | `job_count` | `%{}` (empty) | [`LemonCore.Telemetry.cron_tick/1`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonAutomation.CronManager`](../apps/lemon_automation/lib/lemon_automation/cron_manager.ex) once per scheduler tick as a liveness heartbeat with the count of registered jobs |

Cron terminalization, retry reconstruction, and Kanban hard-stop lease reclaim
do not add telemetry events. Their restart-safe
evidence is durable state/audit plus Bus lifecycle events: CronManager writes
terminal runs and retry lineage before emitting `:cron_run_completed`, Kanban
guards terminal writes by lease ID, and GoalLoopManager stores the authoritative
router run ID in goal-loop status. Goal-loop hard stops additionally expose the
router tombstone counters above, but operators should use persisted goal state
for exact lifecycle counts; `[:lemon, :cron, :tick]` remains only a liveness signal.

### Tool calls — `[:lemon_agent, :tool_call, ...]`

The tool-loop collector emits one start and one terminal event per admitted call,
including validation/start failures, cancellation and loop-enforced deadlines.
Terminal events are emitted by the collector, so a killed tool worker still gets
an outcome as long as its owning loop survives.

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon_agent, :tool_call, :start]` | `system_time`, `monotonic_time` (native) | `tool_name`, `is_error: false`, `timeout: false` | [`tool_call_start/1`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) in `LemonAgent.Loop.ToolCalls`, before preparation/start |
| `[:lemon_agent, :tool_call, :stop]` | `duration`, `monotonic_time` (native monotonic units) | `tool_name`, `is_error`, `timeout` | [`tool_call_finish/4`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex): tool return, validation error, cancellation or skipped call |
| `[:lemon_agent, :tool_call, :exception]` | `duration`, `monotonic_time` (native monotonic units) | `tool_name`, `is_error: true`, `timeout` | [`tool_call_finish/4`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex): caught exception/throw/exit, worker crash, task-start failure or loop timeout |

`timeout` is true for a loop deadline or a tool result with `timed_out: true`
or `timedOut: true`. Returned error results use `:stop` with `is_error: true`.
Metadata contains **only** the tool name and those two booleans: no arguments,
results, exception reasons, stacktraces, prompts or intent strings. Duration
starts at admission (including argument preparation), not time spent queued
behind earlier calls. Existing `tool_task` and `tool_result` events are unchanged.

### Task action usage — `[:coding_agent, :task, :action]`

The native task tool emits `%{count: 1}` after dispatch returns or raises.
Metadata is an allowlist: `action`, `kind`, `outcome`, `model`, `depth`, and
`run_id`. No prompt, steps text, task descriptions, messages, tool arguments,
results, paths, credentials, exceptions or stacktraces are included.

| `kind` | `action` | Counting unit |
| --- | --- | --- |
| `:dispatch` | `"run"`, `"swarm"`, `"poll"`, `"join"`, `"wait"`, `"get"`, `"message"`, `"steer"`, `"cancel"`, `"unknown"` | Exactly one per executed `task` call, including validation/policy refusals and calls already aborted |
| `:feature` | `"batch"` | Once per `run` call containing `tasks[]`, even if invalid |
| `:feature` | `"steps"` | Once per `run` or `swarm` call containing `steps`, at top level or in any task item, even if invalid; not once per stage or child |
| `:launch` | `"speculative_launch"` | Once per early `Execution.run/6` attempt after read-only/policy/budget preflight; streaming fragments and adoption do not count again |

Feature counts overlap dispatch counts: a batch with several stepped children
counts one `run`, one `batch`, and one `steps`. They measure caller usage, not
child-session count. Speculative attempts count separately even when later
discarded; ineligible items that never attempt an early launch do not count.
The separately exposed `wait` tool is not a `task` action and is not counted.
Emit sites are [`Task`](../apps/coding_agent/lib/coding_agent/tools/task.ex)
and [`Speculation`](../apps/coding_agent/lib/coding_agent/tools/task/speculation.ex),
through the bounded task telemetry helper.

`outcome` is `:ok` for a normal return, `:error` for a returned error or an
`AgentToolResult` marked `is_error`, `:aborted` if the dispatch's signal is
aborted, or `:exception` for a raised/thrown/exited dispatch (propagated unchanged).
An async receipt means **launch accepted**, not eventual child success. A batch
receipt may contain sibling failures without being marked as an overall error;
these are not child-outcome counters. Hard-killed emitters cannot emit a terminal
observation. Tool calls blocked before task dispatch are not counted.

`model` is the **calling session's** model (`provider/id` for model structs),
not an inferred effective child model: one batch may use several child models.
`depth` is the caller's nonnegative task nesting depth (root `0`); unknown
subagent depth is `nil`. `run_id` is the caller's `parent_run_id`/`run_id` option,
not the new child's run. Missing identity/model stays `nil`.

#### Capturing and reporting eval/arena usage

Telemetry itself persists nothing. In the dedicated **source-development
runtime executing the tools**, install the optional eval recorder before
starting an eval or arena trial:

```elixir
{:ok, recorder} = LemonEvals.TaskActions.start_link("/tmp/task-actions.jsonl")
# Run the eval/trials against this runtime, then wait for their dispatches to settle.
:ok = LemonEvals.TaskActions.flush(recorder)
GenServer.stop(recorder)
```

The file must not already exist. The recorder makes it owner-only, writes only
the allowlisted event/measurement/metadata envelope, and detaches on stop.
Handlers only enqueue records; JSON encoding and file I/O run in the recorder.
`flush/1` waits for already queued records and syncs the file; it is not a barrier
for still-running emitters. Stop the recorder normally before its owning process
exits. `lemon_evals` is not shipped in runtime releases: a packaged arena runtime
must use its own telemetry attachment/exporter with this same JSONL envelope,
not expect a recorder on the separate host/client to observe remote events:

```json
{"event":["coding_agent","task","action"],"measurements":{"count":1},"metadata":{"action":"swarm","kind":"dispatch","outcome":"ok","model":"provider/model","depth":0,"run_id":"run-id"}}
```

Aggregate offline, without running a model or starting runtime apps:

```bash
mix lemon.eval.task_actions --input /tmp/task-actions.jsonl \
  --output /tmp/task-action-counts.json
```

The helper reports `total_dispatches`, `event_count`, `per_action`, `per_run`,
and a run/action/kind/outcome/model/depth `breakdown`. A `null` run bucket is
unattributed evidence, not proof of a single run. Unrelated event envelopes are
ignored; invalid JSON or malformed task-action records fail rather than silently
undercount. An empty file means zero **observations**, not verified non-use.
Use one recorder per emitting runtime and avoid duplicate ingestion. Include
zero-action runs, observation dates, exact runtime revisions, missing capture
intervals and trial identities separately in the experiment manifest; this
helper cannot infer them. Only explicit run/model/depth labels survive into its
report; raw extra fields are never copied.

This instrumentation does not change task defaults or remove/move actions.
Two weeks of production usage, arena evidence, the posted usage report, and
the per-action keep/move/delete decisions in #604 remain operator/user work.

### Channels — `[:lemon, :channels, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :channels, :inbound]` | `count: 1` | `channel_id`, `account_id`, `peer_kind`, `agent_id` | [`LemonCore.Telemetry.channel_inbound/2`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonChannels.Runtime`](../apps/lemon_channels/lib/lemon_channels/runtime.ex) on each normalized inbound message |
| `[:lemon, :channels, :dispatch]` | `count: 1`, `duration` (native) | `channel_id`, `account_id`, `kind`, `intent_id`, `run_id`, `session_key`, `ok` (boolean) | [`observe/3`](../apps/lemon_channels/lib/lemon_channels/dispatcher.ex), after every `LemonChannels.Dispatcher.dispatch/1` — fires for both success and `{:error, _}`, check `ok`. Its bus twin is the `:channel_delivery` event on the `channels` topic (see [bus events](platform/bus-events.md)) |
| `[:lemon, :channels, :outbox, :queue]` | `depth`, `max_queue_size`, `count: 1` | caller map plus `event` (`:enqueued`, and other queue transitions) | [`emit_queue_depth_telemetry/3`](../apps/lemon_channels/lib/lemon_channels/outbox.ex) in `LemonChannels.Outbox` |
| `[:lemon, :channels, :outbox, :rejected]` | `count: 1`, `queue_depth`, `max_queue_size` | `reason: :queue_full`, `channel_id`, `account_id`, `chunk_count` | [`LemonChannels.Outbox.handle_call/3`](../apps/lemon_channels/lib/lemon_channels/outbox.ex), when the bounded queue refuses work |
| `[:lemon, :channels, :deliver, :start]` | `system_time` | `channel_id`, `account_id`, `chunk_index` | [`do_deliver/1`](../apps/lemon_channels/lib/lemon_channels/outbox.ex) |
| `[:lemon, :channels, :deliver, :stop]` | `duration` (native) | delivery meta plus `ok` (boolean) | [`do_deliver/1`](../apps/lemon_channels/lib/lemon_channels/outbox.ex); fires for both success and `{:error, _}` — check `ok` |
| `[:lemon, :channels, :deliver, :exception]` | `duration` (native) | delivery meta plus `kind: :exception`, `reason`, `stacktrace` | [`do_deliver/1`](../apps/lemon_channels/lib/lemon_channels/outbox.ex), only when the plugin raises |

### Gateway execution permits

`LemonGateway.Slots.stats/0` reads an ETS snapshot containing `in_flight`,
`waitq`, and `max`, or returns `{:error, :not_running}`. Health and status can
read it without calling a busy permit server. `waitq > 0` indicates saturation.
The removed scheduler's `:slot_queued`, `:slot_granted`, and `:slot_released`
telemetry family is not emitted by Slots; do not attach consumers to it.
Aggregate snapshots do not provide per-run wait latency. See the
[admission measurement protocol](architecture/admission-gates.md#measurement-methodology).

### Agent loop — `[:lemon_agent, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon_agent, :loop, :start]` | `system_time` | `prompt_count`, `message_count`, `tool_count`, `model` | [`run_agent_loop/6`](../apps/lemon_agent/lib/lemon_agent/loop.ex) (fresh loop) and [`run_continue_loop/5`](../apps/lemon_agent/lib/lemon_agent/loop.ex) (continue loop; `prompt_count` is always 0 there) in `LemonAgent.Loop` |
| `[:lemon_agent, :loop, :end]` | `duration` (native, **may be `nil`**), `system_time` | `message_count`, `model`, `status` (`:completed` \| `:early_exit`) | [`emit_loop_end_telemetry/3`](../apps/lemon_agent/lib/lemon_agent/loop.ex) |
| `[:lemon_agent, :loop, :state_transition]` | `system_time` | caller map plus `from`, `to` | [`transition_loop_state/3`](../apps/lemon_agent/lib/lemon_agent/loop.ex) |
| `[:lemon_agent, :tool_schema_snapshot, :created]` | `system_time` | `snapshot_id`, `fingerprint`, `tool_count`, `tool_names` | [`emit_tool_schema_snapshot/2`](../apps/lemon_agent/lib/lemon_agent/loop.ex) |
| `[:lemon_agent, :tool_task, :start]` | `system_time` | `tool_name`, `tool_call_id` | [`start_tool_tasks/9`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) in `LemonAgent.Loop.ToolCalls` |
| `[:lemon_agent, :tool_task, :end]` | `system_time` | `tool_name`, `tool_call_id`, `is_error` | [`collect_parallel_tool_results/16`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex), including started tools stopped by an abort |
| `[:lemon_agent, :tool_task, :error]` | `system_time` | `tool_name`, `tool_call_id`, `reason` | [`collect_parallel_tool_results/16`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) (task crash, `:timeout`), [`start_tool_tasks/9`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) (`{:start_failed, reason}`, prepare failure) and [`emit_tool_errors/6`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) (unstarted calls: `:aborted` after an abort, `:skipped` when steering arrives) |
| `[:lemon_agent, :tool_result, :emit]` | `system_time` | `tool_name`, `tool_call_id`, `is_error`, `trust` | [`emit_tool_result/7`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex). `trust` is normalized: only `:untrusted` stays untrusted, everything else becomes `:trusted` |
| `[:lemon_agent, :tool_call, :name_normalized]` | `system_time` | `original_name`, `matched_tool_name` | [`find_tool/2`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex), when a model-supplied tool name needed fuzzy matching |

### Providers — `[:lemon_ai, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon_ai, :dispatcher, :dispatch]` | `system_time` | `provider` | [`LemonAi.CallDispatcher.dispatch/3`](../apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex), before breaker and rate-limit checks |
| `[:lemon_ai, :dispatcher, :rejected]` | `duration`, `system_time` | `provider`, `reason` (`:circuit_open` \| `:rate_limited` \| `:max_concurrency`), `retry_after_ms` (circuit-open only) | [`LemonAi.CallDispatcher.dispatch/3`](../apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex) |
| `[:lemon_ai, :model_call, :start]` | `system_time`, `monotonic_time` | `provider`, `telemetry_span_context`, and `model` (id), `api`, `call_kind` (`:stream` \| `:complete`) when the caller labelled the call | [`LemonAi.ModelCallTelemetry.start/2`](../apps/lemon_ai/lib/lemon_ai/model_call_telemetry.ex), called by `CallDispatcher.dispatch/3` after the breaker, concurrency slot and rate limiter admit the call. Rejected dispatches emit only `:rejected` — never a `:start` |
| `[:lemon_ai, :model_call, :stop]` | `duration`, `monotonic_time` (native); `first_event_duration` (native, first text/thinking/tool-call delta, only when observed); `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens` (only when the provider reported them) | start metadata plus `outcome` (`:ok` \| `:error` \| `:canceled` \| `:aborted`), `stop_reason` (when the final message has one), `error_category` (non-`:ok` outcomes; bounded atom — a `LemonAi.Error.classify/1` category, or `:canceled`/`:timeout`/`:idle_timeout`/`:owner_down`/`:shutdown`/`:aborted`/`:stream_exit`/`:stream_tracking_failed`/`:stream_tracking_exit`/`:unexpected_result`) | [`emit_stop/6`](../apps/lemon_ai/lib/lemon_ai/model_call_telemetry.ex), through `ModelCallTelemetry.stop_result/2`, `stop_stream/4` and `stop_failure/3`. For streams it fires when the stream reaches its terminal event (done, error, cancel, idle/hard timeout) or the producer dies, from the existing stream tracker — not when `dispatch/3` returns. Prompts, messages, credentials, URLs and raw error terms are never in the metadata |
| `[:lemon_ai, :model_call, :exception]` | `duration`, `monotonic_time` (native) | start metadata plus `kind` (`:error` \| `:throw` \| `:exit`), `reason` (exception module for `:error`, otherwise the kind) | [`LemonAi.ModelCallTelemetry.exception/3`](../apps/lemon_ai/lib/lemon_ai/model_call_telemetry.ex), when the dispatch callback raises, throws or exits. Exactly one `:stop` or `:exception` follows each `:start`, unless the stream tracker process is killed outright |
| `[:lemon_ai, :circuit_breaker, :opened]` | `system_time` | `provider`, `failure_count`, `failure_threshold`, `reason` | [`LemonAi.CircuitBreaker.handle_call/3`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex) |
| `[:lemon_ai, :circuit_breaker, :closed]` | `system_time` | `provider` | [`LemonAi.CircuitBreaker.handle_call/3`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex), recovery confirmed |
| `[:lemon_ai, :circuit_breaker, :half_opened]` | `system_time` | `provider`, `recovery_timeout` | [`maybe_transition_to_half_open/1`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex) |
| `[:lemon_ai, :circuit_breaker, :reopened]` | `system_time` | `provider`, `reason` | [`LemonAi.CircuitBreaker.handle_call/3`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex), probe failed during half-open |
| `[:lemon_ai, :prompt_diagnostics, :llm_call]` | `system_time` | `data`, `engine: "ai"`, `session_key`, `agent_id`, `run_id` | [`record_introspection/2`](../apps/lemon_ai/lib/lemon_ai/prompt_diagnostics.ex) in `LemonAi.PromptDiagnostics`. Correlation fields come from `x-lemon-*` request headers and are `nil` when absent |

#### Prompt cache-read share measurement (#562)

Define aggregate cache-read share as
`sum(cache_read) / sum(input + cache_read + cache_write)` across all calls in
the multi-turn workload. Lemon's normalized `input` excludes cache reads and
writes. Missing provider counters or a zero denominator make the share
**unavailable**, not zero. Preserve per-turn counters and include failed calls
when usage is reported.

Measured 2026-11-16 at pre-epic `4d94b3c8e` and candidate
`abc566dcdb83f35d311fb9c2c66b889e3b6fcc9d`, using the production
`LemonAi.complete/3` route, `:openai_codex` / `gpt-6.1-sol`.
Environment: MacBook Pro Mac15,9, Apple M3 Max, 128 GB RAM, macOS 15.6,
OTP 29 / ERTS 17.1.1, Elixir 1.20.5; `ERL_FLAGS='+S 2:2'`.

| Revision | Turn | Uncached input | Cache-read | Cache-write | Output | Cache-read share |
|---|---:|---:|---:|---:|---:|---:|
| Pre-epic | 1 | 10,617 | 0 | 0 | 5 | 0% |
| Pre-epic | 2 | 10,638 | 0 | 0 | 5 | 0% |
| Pre-epic | 3 | 10,659 | 0 | 0 | 5 | 0% |
| Candidate | 1 | 10,616 | 0 | 0 | 5 | 0% |
| Candidate | 2 | 10,682 | 0 | 0 | 5 | 0% |
| Candidate | 3 | 10,748 | 0 | 0 | 5 | 0% |
| **Pre-epic aggregate** | **3** | **31,914** | **0** | **0** | **15** | **0%** |
| **Candidate aggregate** | **3** | **32,046** | **0** | **0** | **15** | **0%** |

First-call and subsequent-call aggregate shares were also 0% in both variants.
This small live sample demonstrates **no observed cache-share improvement**.
System bytes were 53,569 on all baseline turns but their SHA-256 identities
changed every turn. Candidate system bytes were 53,393 and their SHA-256 identity
was identical across all three turns. Stable bytes alone do not guarantee a
provider cache hit.

The same bounded synthetic workload used an 800-item public reference prefix,
three user turns with prior assistant replies retained, no tools, a 64-token
output cap, `reasoning: :minimal`, and a 90-second per-call stream deadline.
Each turn changed the fixture branch, dirty-file content and supplied date.
Baseline re-captured the environment; candidate captured its stable block once
and appended `Environment.turn_section/2` to each user turn. Fixture paths were
replaced by `<workspace>` before provider transmission. No credentials, private
prompts or conversation content were published.

The disposable helper obtained the host-configured credential in-process with
`System.cmd("omp", ["token", "openai-codex"])` and passed the trimmed value as
`api_key` with `api_key_authoritative: true`. It started only `:lemon_ai` and
`:req`, avoiding runtime listeners. Because baseline prebuilt modules initially
showed candidate behavior, each final run explicitly loaded its checkout's
`apps/coding_agent/lib/coding_agent/system_prompt/environment.ex` with
`Code.compile_file/1`. This compiled one source module in-memory, not an umbrella
build. Exact invocation forms below substitute shell variables for private
checkout and fixture locations:

```bash
# From the pre-epic checkout root:
CACHE_FIXTURE="$FIXTURE" CACHE_MODE=before ERL_FLAGS='+S 2:2' \
  mix run --no-start --no-compile --no-deps-check "$CANDIDATE/cache_share_measure.exs" \
  2>&1 | grep -E '^CACHE_|^\*\*'
# From the candidate checkout root:
CACHE_FIXTURE="$PWD/.cache-share-fixture" CACHE_MODE=after ERL_FLAGS='+S 2:2' \
  mix run --no-start --no-compile --no-deps-check cache_share_measure.exs \
  2>&1 | grep -E '^CACHE_|^\*\*'
```

Earlier route exploration is excluded from this paired table: three ZAI
`glm-4.7-flash` completions reported cache-read counts 2, 2 and 11,100 but missing
input/cache-write counters and an unverified baseline module; two Kimi attempts
failed before completing; one direct ZAI request timed out at 60 seconds and
another returned HTTP 429. These seven invocations are not zero-spend evidence;
their full spend is unknown. The final six Codex calls supersede the initial
credential-preflight blocker.

Caveats: single three-turn pair, fixed baseline-then-candidate order, synthetic
environment-level workload rather than a full coding-session/arena run, and
uncontrolled provider cache regime. Fresh local state does not flush provider
caches. Concurrent local CPU benchmarks were running; no latency comparison is
claimed. The helper and fixture were removed after measurement. No tests or
umbrella builds were run.

A bounded 2026-11-16 follow-up on `openai_codex` / `gpt-6.1-sol` compared
omitting the session key with retaining the native coding session's persisted
identity. Both variants ran through `CodingAgent.Session` → `LemonAgent` and a
completion adapter calling production `LemonAi.complete/3` over HTTP/SSE. The
adapter removed only `StreamOptions.session_id` in the no-key variant. This is
an **existing-path control comparison**, not a before/after Codex code-change
claim: native sessions already supplied a stable key at revision `abc566dcd`.

Six successful requests were made, three turns per variant, retaining assistant
replies. The synthetic custom prefix was 53,393 bytes; the complete native system
prompt was 55,984 bytes with SHA-256
`2b7f5347798c17322647112d97c773a7664aed8e2e454e2391d78fd4de60dcc2`,
identical across all six requests. Disposable paths were replaced by `<fixture>`
before transmission. There were no tools, reasoning was minimal, and the stream
deadline was 90 seconds. Provider and agent retries were disabled. A host Codex
credential was obtained in-process with `omp token openai-codex` and never logged
or persisted. One earlier local startup failed on an occupied health-listener
port before any model request; the measurement disabled that listener.

| Variant / turn | Uncached input | Cache read | Cache write | Output | Read share |
|---|---:|---:|---:|---:|---:|
| No key / 1 | 9,767 | 0 | 0 | 5 | 0% |
| No key / 2 | 10,042 | 0 | 0 | 5 | 0% |
| No key / 3 | 10,317 | 0 | 0 | 5 | 0% |
| Native key / 1 | 9,767 | 0 | 0 | 5 | 0% |
| Native key / 2 | 442 | 9,600 | 0 | 5 | 95.60% |
| Native key / 3 | 461 | 9,856 | 0 | 5 | 95.53% |
| No-key aggregate | 30,126 | 0 | 0 | 15 | **0%** |
| Native-key aggregate | 10,670 | 19,456 | 0 | 15 | **64.58%** |

Share is `sum(cache_read) / sum(input + cache_read + cache_write)`, excluding
output. Native-key turns 2–3 aggregate to **95.56%**. Raw
`input_tokens_details.cached_tokens` agreed with Lemon's normalized cache-read
counters (0, 9,600, 9,856); raw cache-write counters were zero throughout.
The same prompt and input counts produced hits once the session key was retained,
so insufficient prefix length does not explain this sample. This small,
fixed-order pair does not establish that missing keys caused the earlier report:
provider routing, retention and warmup were not controlled, and no latency claim
is made. OpenAI's public [prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
also warns that keys do not guarantee hits; its public Responses behavior is not
a guarantee about the ChatGPT Codex endpoint.

Native-session wire tests cover persisted identity across turns and restart for
OpenAI Responses and Codex, matching Codex affinity headers, distinct new-session
keys, and Anthropic's shared-prefix/last-user breakpoints. Direct `LemonAi`
callers must pass `StreamOptions.session_id`; the library does not invent one.

### Memory — `[:lemon, :memory, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :memory, :ingest, :ok]` | `duration_us` | `run_id`, `session_key`, `agent_id` | [`LemonMemory.Ingest.handle_cast/2`](../apps/lemon_memory/lib/lemon_memory/ingest.ex) |
| `[:lemon, :memory, :ingest, :failure]` | `count: 1`, `duration_us` | `run_id`, `error` (message string) | [`LemonMemory.Ingest.handle_cast/2`](../apps/lemon_memory/lib/lemon_memory/ingest.ex) |

### Approvals — `[:lemon, :approvals, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :approvals, :requested]` | `count: 1` | `approval_id`, `tool`, `run_id`, `session_id`, `session_key`, `agent_id` | [`LemonCore.Telemetry.approval_requested/3`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonCore.ExecApprovals`](../apps/lemon_core/lib/lemon_core/exec_approvals.ex) when a request is created |
| `[:lemon, :approvals, :resolved]` | `count: 1` | `approval_id`, `decision`, `tool`, `run_id` | [`LemonCore.Telemetry.approval_resolved/3`](../apps/lemon_core/lib/lemon_core/telemetry.ex), called from [`LemonCore.ExecApprovals`](../apps/lemon_core/lib/lemon_core/exec_approvals.ex) for a user decision, `decision: :cancelled`, `decision: :timeout`, and `decision: :expired` (run or session ended) |

### Control plane fan-out — `[:lemon, :control_plane, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :control_plane, :event_bridge, :broadcast]` | `count: 1`, `recipients` | `event`, `recipients` | [`dispatch_event/3`](../apps/lemon_control_plane/lib/lemon_control_plane/event_bridge.ex) in `LemonControlPlane.EventBridge`, once per fanned-out event before delivery to its recipients |

### Configuration and hot reload — `[:lemon, :config | :reload, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:lemon, :config, :reload, :start]` | `system_time` | reload context | [`do_reload/2`](../apps/lemon_core/lib/lemon_core/config_reloader.ex) in `LemonCore.ConfigReloader` |
| `[:lemon, :config, :reload, :stop]` | `duration`, `duration_ms` | context plus `changed_count`, `actions_count` | [`do_reload/2`](../apps/lemon_core/lib/lemon_core/config_reloader.ex), including the no-change path (`changed_count: 0`) |
| `[:lemon, :config, :reload, :exception]` | `duration`, `duration_ms` | context plus `kind`, `reason`, `stacktrace` | [`do_reload/2`](../apps/lemon_core/lib/lemon_core/config_reloader.ex) |
| `[:lemon, :reload, :start]` | `system_time` | reload context | [`telemetry_span/3`](../apps/lemon_core/lib/lemon_core/reload.ex) in `LemonCore.Reload` |
| `[:lemon, :reload, :stop]` | `duration_ms` | context plus `status` | [`telemetry_span/3`](../apps/lemon_core/lib/lemon_core/reload.ex) |
| `[:lemon, :reload, :exception]` | `duration_ms` | context plus `error`, `stacktrace` | [`telemetry_span/3`](../apps/lemon_core/lib/lemon_core/reload.ex), for both raised exceptions and caught throws/exits |

### Extension and WASM tools — `[:coding_agent, ...]` and `[:lemon, :wasm, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:coding_agent, :extension, :tool, :start]` | `count: 1` | tool identity | [`run_extension_tool/4`](../apps/coding_agent/lib/coding_agent/tool_registry.ex) in `CodingAgent.ToolRegistry` |
| `[:coding_agent, :extension, :tool, :stop]` | `count: 1`, `duration_us` | tool identity plus `status` | [`run_extension_tool/4`](../apps/coding_agent/lib/coding_agent/tool_registry.ex) |
| `[:coding_agent, :extension, :tool, :exception]` | `count: 1`, `duration_us` | tool identity plus `kind`, `error_type` | [`run_extension_tool/4`](../apps/coding_agent/lib/coding_agent/tool_registry.ex), for raised exceptions and caught throws/exits; both re-raise |
| `[:coding_agent, :wasm, :tool, :start]` | `count: 1` | tool identity | [`build_execute_fun/3`](../apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex) in `CodingAgent.Wasm.ToolFactory` |
| `[:coding_agent, :wasm, :tool, :stop]` | `count: 1`, `duration_us` | tool identity plus `status` | [`emit_stop/3`](../apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex) |
| `[:coding_agent, :wasm, :tool, :exception]` | `count: 1`, `duration_us` | tool identity plus `kind`, `error_type` | [`emit_exception/4`](../apps/coding_agent/lib/coding_agent/wasm/tool_factory.ex) |
| `[:coding_agent, :tool_call, :name_normalized]` | `system_time` | `original_name`, `matched_tool_name` | [`CodingAgent.ToolRegistry.get_tool/3`](../apps/coding_agent/lib/coding_agent/tool_registry.ex). Shares its metadata keys with the `[:lemon_agent, ...]` event of the same leaf name |
| `[:lemon, :wasm, :discover, :start]` | `count: 1` | `host: :wasm`, `session_hash`, `cwd_hash` | [`CodingAgent.Wasm.SidecarSession.handle_call/3`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |
| `[:lemon, :wasm, :discover, :stop]` | `duration_ms`, `ok` | `host: :wasm`, `session_hash`, `cwd_hash` | [`CodingAgent.Wasm.SidecarSession.discover/2`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |
| `[:lemon, :wasm, :invoke, :start]` | `count: 1` | `host: :wasm`, `session_hash`, `cwd_hash`, `tool_hash` | [`CodingAgent.Wasm.SidecarSession.handle_call/3`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |
| `[:lemon, :wasm, :invoke, :stop]` | `duration_ms`, `ok` | `host: :wasm`, `session_hash`, `cwd_hash`, `tool_hash` | [`finish_invocation/2`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex) |

Session and cwd identifiers in the WASM events are hashed, not raw.

### Session lifecycle counters and tool intents — `[:coding_agent, ...]`

| Event | Measurements | Metadata | Emitter |
|---|---|---|---|
| `[:coding_agent, :session, :environment_capture]` | `count: 1` | `session_id` | [`lifecycle_observation/2`](../apps/coding_agent/lib/coding_agent/session_manager.ex) in `CodingAgent.SessionManager` |
| `[:coding_agent, :session, :journal_load]` | `count: 1` | `session_id` | [`lifecycle_observation/2`](../apps/coding_agent/lib/coding_agent/session_manager.ex) |
| `[:coding_agent, :tool_intent, :stop]` | `duration_us` (digest, owner queueing, append and sync; not tool execution) | `effect`, `status: :ok \| :error` | [`record_locally/6`](../apps/coding_agent/lib/coding_agent/tool_intent.ex) in `CodingAgent.ToolIntent` |

The session counters count actual captures/parses and carry no content.

### Session recovery — `[:coding_agent, :session, :overflow_recovery, ...]`

The last segment is built at runtime.

| Event | Suffix values | Measurements | Metadata | Emitter |
|---|---|---|---|---|
| `[:coding_agent, :session, :overflow_recovery, <stage>]` | `:attempt`, `:success`, `:failure` | `count: 1` | recovery context including `duration_ms` | [`CodingAgent.Session.CompactionManager.emit_overflow_recovery_telemetry/3`](../apps/coding_agent/lib/coding_agent/session/compaction_manager.ex) |

### Skills — `[:lemon_skills, :skill, ...]`

All three carry `count: 1` and `system_time` measurements and are emitted through
`LemonSkills.Telemetry`, which drops `nil` metadata values before emitting. Bodies of
skills and file contents are never included.

| Event | Fires when | Key metadata | Emitter |
|---|---|---|---|
| `[:lemon_skills, :skill, :load]` | `read_skill` returns a skill or a not-found result | `result` (`ok` \| `not_found`), `key`, `name`, `source`, `path`, `view`, `section`, `file_path`, `tool_call_id`, `run_id`, `session_key`, `session_id`, `agent_id`, `cwd` | [`LemonSkills.Telemetry.skill_load/1`](../apps/lemon_skills/lib/lemon_skills/telemetry.ex) |
| `[:lemon_skills, :skill, :write]` | `skill_manage` accepts or rejects a write | `result`, `action` (`create` \| `edit` \| `patch` \| `delete` \| `write_file` \| `remove_file`), `name`, `scope`, `path`, `audit_status`, `replacements`, `reason`, plus correlation fields | [`LemonSkills.Telemetry.skill_write/1`](../apps/lemon_skills/lib/lemon_skills/telemetry.ex) |
| `[:lemon_skills, :skill, :prompt_render]` | prompt composition renders a skills block | `surface` (`available` \| `relevant`), `skill_count`, `skill_keys`, `active_count`, `not_ready_count`, `missing_count`, plus correlation fields | [`LemonSkills.Telemetry.skill_prompt_render/1`](../apps/lemon_skills/lib/lemon_skills/telemetry.ex) |

`LemonSkills.Application` attaches an introspection bridge at boot that projects these three
into persisted `:skill_load_observed`, `:skill_write_observed`, and
`:skill_prompt_render_observed` records, and updates `LemonSkills.Usage` counters.

At session end, missed-skill introspection compares the exact relevance keys cached in the
session for that turn with successful `read_skill` load observations. It does not parse
turn-specific XML from the system prompt; no relevance block is added to that cacheable
prompt or to the persisted conversation.

## Attaching a consumer

This is the whole integration surface. Handlers run **synchronously in the emitting
process**, so they must be fast and must not raise — a raising handler is detached by
`:telemetry` and stops receiving events.

```elixir
defmodule MyApp.TelemetryLogger do
  @moduledoc "Logs the saturation and failure signals worth paging on."

  require Logger

  @events [
    [:lemon, :channels, :outbox, :rejected],
    [:lemon_ai, :dispatcher, :rejected],
    [:lemon_ai, :circuit_breaker, :opened],
    [:lemon_agent, :tool_task, :error],
    [:lemon, :memory, :ingest, :failure]
  ]

  def attach do
    :telemetry.attach_many(
      "my-app-telemetry-logger",
      @events,
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  def handle_event([:lemon, :channels, :outbox, :rejected], m, meta, _config) do
    Logger.warning(
      "outbox rejected channel=#{meta.channel_id} reason=#{meta.reason} " <>
        "depth=#{m.queue_depth}/#{m.max_queue_size}"
    )
  end

  def handle_event([:lemon_ai, :dispatcher, :rejected], _m, meta, _config) do
    Logger.warning("provider rejected provider=#{meta.provider} reason=#{meta.reason}")
  end

  def handle_event([:lemon_ai, :circuit_breaker, :opened], _m, meta, _config) do
    Logger.error(
      "circuit opened provider=#{meta.provider} " <>
        "failures=#{meta.failure_count}/#{meta.failure_threshold}"
    )
  end

  def handle_event([:lemon_agent, :tool_task, :error], _m, meta, _config) do
    Logger.error("tool failed tool=#{meta.tool_name} reason=#{inspect(meta.reason)}")
  end

  def handle_event([:lemon, :memory, :ingest, :failure], m, meta, _config) do
    Logger.error("memory ingest failed run=#{meta.run_id} after #{m.duration_us}us: #{meta.error}")
  end
end
```

Call `MyApp.TelemetryLogger.attach()` once at application start, after `:telemetry` is
running.

### Verifying an attachment without a full runtime

`mix run --no-start` does not start the `:telemetry` application, so `attach_many/4` will
exit with `no process`. Start it explicitly, attach, and emit a synthetic event:

```elixir
{:ok, _} = Application.ensure_all_started(:telemetry)

:telemetry.attach(
  "probe",
  [:lemon_agent, :tool_call, :name_normalized],
  fn event, measurements, metadata, _ ->
    IO.inspect({event, measurements, metadata})
  end,
  %{}
)

:telemetry.execute([:lemon_agent, :tool_call, :name_normalized], %{system_time: 0}, %{
  original_name: "Read",
  matched_tool_name: "read"
})
```

### Aggregating into metrics

**`telemetry_metrics` is not a dependency of this repo**, and neither is
`telemetry_metrics_prometheus` or `phoenix_live_dashboard`. Metrics aggregation
and transport remain the host application's choice; the optional GenAI span
attachment above is separate. This section shows what metrics wiring looks
like *if you add those deps to your own project*; it does not ship by default.

```elixir
# in your own app's mix.exs:
#   {:telemetry_metrics, "~> 1.0"},
#   {:telemetry_metrics_prometheus, "~> 1.1"}

import Telemetry.Metrics

def metrics do
  [
    # Outbox overload; gateway permit pressure is sampled separately via Slots.stats/0.
    counter("lemon.channels.outbox.rejected.count", tags: [:channel_id, :reason]),

    # Provider health.
    counter("lemon_ai.dispatcher.rejected.duration", tags: [:provider, :reason]),
    counter("lemon_ai.circuit_breaker.opened.system_time", tags: [:provider]),

    # Tool reliability.
    counter("lemon_agent.tool_task.error.system_time", tags: [:tool_name]),

    # Latency. Note the three different units — see "Measurement units".
    distribution("lemon.channels.deliver.stop.duration",
      unit: {:native, :millisecond},
      tags: [:channel_id, :ok]
    ),
    distribution("lemon.memory.ingest.ok.duration_us",
      unit: {:microsecond, :millisecond},
      tags: []
    ),
    distribution("coding_agent.extension.tool.stop.duration_us",
      unit: {:microsecond, :millisecond},
      tags: [:status]
    )
  ]
end
```

Two things bite when you do this:

- **Pick the unit per event, not per dashboard.** `duration` is native, `duration_us` is
  microseconds, `duration_ms` is milliseconds, and `[:lemon, :config, :reload, :stop]`
  reports both a native `duration` and its `duration_ms` conversion.
  A single `unit: {:native, :millisecond}` applied across the board silently produces
  numbers that are wrong by six orders of magnitude on the `_us` events.
- **Runtime-suffixed events cannot be declared with a wildcard.** `Telemetry.Metrics` needs
  a concrete event name, so each suffix of a runtime-built family (for example
  `overflow_recovery`) has to be listed individually; the known values are in the catalog
  above.

For an interactive view instead of a scrape endpoint, `phoenix_live_dashboard` consumes the
same `metrics/0` list through its `:metrics` option. Neither path requires changing any
emit site.

## Known gaps and inconsistencies

These are recorded, not fixed. Renaming events is a breaking change for any attached
consumer and belongs in its own change.

**Session recovery builds its final segment at runtime**, so literal event-name
searches cannot discover every `[:coding_agent, :session, :overflow_recovery, _]`
event. The known values are listed in the catalog above.

**Measurement gaps.** `[:lemon_agent, :loop, :end]`
reports `duration: nil` when the process-dictionary start time is missing.
Gateway slot statistics are aggregate snapshots, not per-run wait spans.

**Coverage gaps.** There is no telemetry on the store, the Bus, or the router's
session-coordinator queue transitions.

## Introspection: the persisted layer

Introspection is a higher-level layer built beside `:telemetry`, not on top of it. It
captures a canonical envelope for agent lifecycle transitions and persists it through
`LemonCore.Store` for later query. Unlike telemetry, these records are **stored** and
**queryable**.

### Envelope

| Field | Type | Description |
|---|---|---|
| `event_id` | string | Stable unique identifier (prefixed `evt_`) |
| `event_type` | atom or string | Taxonomy name (below) |
| `ts_ms` | integer | Wall-clock milliseconds since the Unix epoch |
| `run_id` | string or nil | Run identifier |
| `session_key` | string or nil | Session identifier |
| `agent_id` | string or nil | Agent identifier |
| `parent_run_id` | string or nil | Lineage link when available |
| `engine` | string or nil | Engine name, e.g. `"claude"`, `"codex"`, `"lemon"` |
| `provenance` | `:direct` \| `:inferred` \| `:unavailable` | How context fields were resolved |
| `payload` | map | Event-specific metadata, redacted |

`:direct` means the emitter supplied the context fields; `:inferred` means they were derived
from surrounding state; `:unavailable` means they could not be determined.

### Redaction

`api_key`, `apikey`, `authorization`, `password`, `private_key`, `prompt`, `response`,
`secret`, `secrets`, `stderr`, `stdout`, and `token` are always removed. Tool argument
fields (`arguments`, `input`, `tool_arguments`) are redacted unless
`capture_tool_args: true` is passed. Result previews are kept and truncated to 256 bytes
unless `capture_result_preview: false` is passed. All other string values are truncated to
4096 bytes. See [`introspection.ex`](../apps/lemon_core/lib/lemon_core/introspection.ex).

### Taxonomy

Every atom below appears in a live `LemonCore.Introspection.record/3` call.

| Emitter | Event types |
|---|---|
| `LemonRouter.RunProcess` | `:run_started`, `:run_completed`, `:run_failed` |
| `LemonRouter.RunOrchestrator` | `:orchestration_started`, `:orchestration_resolved`, `:orchestration_failed` |
| Router answer finalization | `:answer_finalize_started`, `:answer_finalize_dispatch`, `:answer_finalize_failed`, `:answer_finalize_completed`, `:answer_artifact_finalize_failed`, `:answer_media_jobs_record_failed` |
| `CodingAgent.Session` | `:session_started`, `:session_ended`, `:compaction_triggered` |
| `CodingAgent.Session.EventHandler` | `:tool_call_dispatched`, `:engine_event_ignored` |
| `LemonAgent.Agent` | `:agent_loop_started`, `:agent_turn_observed` (inferred), `:agent_loop_ended`, `:agent_progress_snapshot` |
| Skills bridge / session-end audit | `:skill_load_observed`, `:skill_write_observed`, `:skill_prompt_render_observed`, `:missed_skill_observed`, `:missed_learning_observed` |

### Querying

```elixir
LemonCore.Introspection.list([])
LemonCore.Introspection.list(run_id: "run_abc123", limit: 50)
LemonCore.Introspection.list(session_key: "agent:default:main", limit: 20)
LemonCore.Introspection.list(event_type: :run_completed, limit: 30)

now_ms = System.system_time(:millisecond)
LemonCore.Introspection.list(since_ms: now_ms - 60 * 60 * 1000, limit: 200)
```

Results are newest-first. The same filters are available from the shell through
[`mix lemon.introspection`](../apps/lemon_core/lib/mix/tasks/lemon.introspection.ex), which
prints a table of timestamp, event type, run ID, session key, agent ID, engine, and
provenance:

```bash
mix lemon.introspection --limit 100
mix lemon.introspection --run-id run_abc123 --event-type run_completed
mix lemon.introspection --since 1h
mix lemon.introspection --since 2026-08-01T00:00:00Z
```

### Recording, disabling, retention

```elixir
LemonCore.Introspection.record(:run_started, %{origin: "telegram"},
  run_id: run_id,
  session_key: session_key
)
```

Set `config :lemon_core, :introspection, enabled: false` to drop events silently;
`LemonCore.Introspection.enabled?/0` reflects the setting. The store sweeps
`:introspection_log` periodically, pruning records older than 7 days by default.

## Related

- [beam_agents.md](beam_agents.md) — supervision trees and the process-level invariants these
  events observe
- [why-beam-for-agents.md](why-beam-for-agents.md) — why the runtime makes this kind of
  per-process observability cheap
