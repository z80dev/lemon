# Phase 3.1 — Typed Bus Events: Catalog and Design

Status: **implemented.** Platform contract topics carry typed payload structs from
`LemonCore.Events` inside the unchanged `LemonCore.Event` envelope. This page is the
canonical catalog of bus topics, registered event types, payload fields, the delivery and
recovery boundary, and the versioning rules. `apps/lemon_core/AGENTS.md` and
`apps/lemon_core/README.md` describe the higher-level core boundary; the authoritative
registry is `LemonCore.Events.registry/0`
(`apps/lemon_core/lib/lemon_core/events.ex`).

> **Top-level execution end state.** `engine` remains in run events, completion
> records, and `ResumeToken` as provenance, with the fixed value `"lemon"` for
> every top-level run. It is not a request field or a runtime selector. Subagent
> identities are task-only provenance on delegated task records; subagents run
> natively in-process.
> Top-level resume accepts only native tokens; non-native historical state is
> retained but quarantined from resumption.

## Current delivery and recovery boundary

This section describes how bounded delivery and recovery work today. The
numbered sections below catalog the typed event contract.

`LemonCore.Bus` still owns publication. Bounded subscribers opt into
`Bus.subscribe(topic, delivery: handle)` using one `Bus.Delivery` handle across
their topics. Admission happens **before** `send/2`, not after an unbounded
mailbox has already accepted the payload. A handle caps queue entries and
individual encoded Erlang-term size plus excess retained sub-binary backing,
serializes concurrent admission without waiting on a consumer, and permanently
fences itself on overflow. It emits one
small overflow marker. Contended concurrent admission is conservatively treated
as overflow rather than making authoritative producers wait. Closing/replacing
the handle or subscriber death releases the transient relationship; no token
log, second bus, or lifecycle store is created.
Browser panes additionally request `tagged: true`: every data/control message
carries a delivery-epoch reference. A recovered pane accepts only its replacement
handle's reference, so a producer delayed before `send/2` cannot apply an old
subscription's packet after reconciliation. The EventBridge uses the same tagged
ingress fencing so an old producer's delayed data or overflow marker cannot reach
or disconnect a freshly reauthenticated recipient.

These are local-receiver bounds, not a bound on an entire distributed node,
the socket implementation's OS buffers, or arbitrary messages sent outside the
handle. The maximum admitted encoded-plus-binary-backing budget is queue limit ×
per-message limit, plus the compact overflow/terminal controls; it is not a cumulative-byte
counter. Unrelated messages in the same mailbox conservatively consume capacity.

| Producer → consumer | Supported boundary / recovery |
| --- | --- |
| Native session → direct subscribers | Defaults to 256 queued entries and 1 MiB per event; overflow fences that subscription and explicitly signals recovery. At most one compact terminal notification is reserved in addition to the overflow marker, preserving a separate reconstructable completion path. |
| Native session → executor runner | Uses the bounded direct subscription rather than an unused duplicate stream; terminal recovery rereads the native owner instead of relying on every delta. Session subscription streams also bound mailbox ingress and the existing internal EventStream queue. |
| Bus → control-plane EventBridge → operator WebSocket | Defaults to 256 queued entries and 1 MiB per event at bridge ingress and each recipient; no task is created for every broadcast. Overflow sends `stream.resync` or disconnects the lagging socket; reconnect reauthenticates before reading snapshots. |
| Bus → browser chat pane | One shared 256-entry handle across session/approval/system topics, 65,536 bytes per message, and one overflow marker. Live answer segments cap at 65,536 bytes; transcript/tool caches cap at 400 items and terminal tombstones at 128 runs. |
| Router answer/status coalescers | Tagged pre-mailbox admission defaults to 256 entries / 65,536 bytes per event. Overflow fences transient rendering and signals session resync; answer finalization requires canonical `final_text` after overflow. Status finalization records an interruption hint instead of claiming a complete action stream. Finalized gates reject delayed old envelopes; 128 recent terminal run IDs fence late API calls. The existing distinct-action history is not a fixed-count buffer; the ingress bound is not a claim that a run with arbitrarily many distinct actions retains constant memory. |
| TUI / browser after dropped progress | Both consume `sessions.snapshot`; active recovered text is replaced from authority, never appended to an uncertain token prefix. No offline mutation is replayed. |

### Reliable truth and consistency

The selected native branch, persisted run completion, current approval owner,
task/run graph, and session-owned process receipts are the reconstruction
authorities. A terminal action lacking a receipt is **outcome unknown**, not
running or invented success. Terminal cancellation remains cancellation. A new
user turn cannot acquire its predecessor's answer; idle live sessions must match
the selected branch before reusing a retained invocation's terminal summary.
Unavailable owner reads stay unavailable; old cards are not evidence of a
currently actionable approval.

`sessions.snapshot` composes these reads and returns session/branch/revision and
fixed run-attempt identity, bounded/redacted messages and answer state, actions,
approvals, children, processes, todos, and plan state. It is explicitly **not**
an atomic transaction across owners and has no durable event cursor. The server
checks owner identity before/after composition and requests retry on drift.
Clients fence late responses by selection/request generation and discard a read
if relevant events or loss/reconnect indications arrived during it, with bounded retries. Untagged events for
an unrecognized run request reconciliation rather than acquiring branch
authority. Recovered active answers remain replacement-only until canonical
completion, avoiding duplication from delayed pre-snapshot deltas. See
[the control-plane contract](https://github.com/z80dev/lemon/blob/main/apps/lemon_control_plane/README.md#session-snapshot-and-reconciliation).

### Remaining best-effort paths

`Bus.subscribe/1` remains an unbounded raw subscription. In particular the
agent-loop → Agent → native Session owner notifications, Session task/approval
ingress, gateway executor sink, router run-owner ingress, channel adapter
session/run/approval subscriptions, webhook completion waiters, ACP/SSE streaming,
and voice/audio bridges do **not** acquire end-to-end mailbox bounds merely
because operator fanout is bounded. Generic `EventStream.push_async` users also
retain their existing raw-cast ingress; the bounded Session notifier path is
not evidence for every stream producer. Channel final-answer delivery and
native run completion have their existing owner paths; transient status replay
for those other adapters is not provided by `sessions.snapshot`. Named-node
live streaming is a separately owned platform contract and is not merged or
replaced here.
Process retained-output quotas and stable process receipts are owned by the
execution-node and process contracts, not by the Bus. Neither a quota nor
model-facing truncation is a substitute for pre-mailbox admission.
Likewise, the snapshot's JSON size limit is not a bound on its source-owner
read: native branch collection, owner replies and revision hashing remain
proportional to the retained authoritative transcript.

### Regression coverage

Run the focused bus/recovery suites once from the umbrella root, then the TUI client suites:

```bash
scripts/test path \
  apps/lemon_core/test/lemon_core/bus_delivery_test.exs \
  apps/lemon_core/test/lemon_core/bus_bounded_subscription_test.exs \
  apps/lemon_core/test/lemon_core/bus_test.exs \
  apps/lemon_core/test/lemon_core/bus_registry_fallback_test.exs \
  apps/lemon_agent/test/lemon_agent/event_stream_test.exs \
  apps/coding_agent/test/coding_agent/session_backpressure_test.exs \
  apps/coding_agent/test/coding_agent/session_recovery_test.exs \
  apps/coding_agent/test/coding_agent/session/notifier_backpressure_test.exs \
  apps/coding_agent/test/coding_agent/session/session_runner_recovery_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/event_bridge_backpressure_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/sessions_snapshot_test.exs \
  apps/lemon_router/test/lemon_router/coalescer_backpressure_test.exs \
  apps/lemon_router/test/lemon_router/stream_coalescer_test.exs \
  apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs \
  apps/lemon_web/test/lemon_web/chat_live_test.exs --seed 1

bun --cwd clients/tui test \
  test/ui/session-controller.test.ts \
  test/protocol/client.test.ts \
  test/ui/event-controller.test.ts \
  test/store/session-store.test.ts
```

They suspend a consumer before a bounded burst and assert the admission and byte bounds,
the resync marker, owner-answer recovery, tagged-epoch rejection of late producers, and
approval/terminal truth under pressure. The core small fixture admits eight events plus
one resync marker and at most one compact terminal notification (encoded retained terms
fit `8 × 256 + encoded_resync + 1024` bytes); the Web fixture publishes 1,000 small events
to a suspended pane and permits at most 270 queued messages. The byte-admission regression
retains a 256-byte slice of a 16,384-byte binary and rejects that backing: encoded size
alone would admit it and pin the larger binary.

For a configured runtime, the central interactive smoke entry points are:

```bash
./bin/lemon web --no-open
./bin/lemon tui --session agent:default:web:browser:unknown:stream-recovery-smoke
```

Open `/chat/agent%3Adefault%3Aweb%3Abrowser%3Aunknown%3Astream-recovery-smoke`
in the authenticated browser. With a small tool/child/process run active, close
and reopen the TUI or reload the browser while the runtime continues. Confirm
one terminal answer and no completed action left spinning; decide a pending
approval in the other client and confirm it does not return on reconnect.
Repeat after a confirmed rewind and check the selected branch's todo/plan
projection. Rotate/revoke access and verify reconnect refuses the old
credential. Do not treat an interactive smoke as a replacement for the
synchronized overflow/race fixtures above.

## 1. Design principles

- **Type the payload, keep the envelope.** `LemonCore.Event` (`type`, `ts_ms`, `meta`,
  `payload`) is the stable envelope; `event.payload` is a struct for registered types.
  Consumers match `%Event{type: :delta}` and, where they need fields,
  `%Event{type: :delta, payload: %Events.Delta{}}`. Forwarders (router `run_process`, ACP,
  `session_live`, Discord, Telegram) match `%Event{} = event` so they can relay types they
  do not know about.
- **The platform contract is the registered topics.** A topic is contract when its payload
  crosses an app boundary or reaches the control plane and its clients (§3). Topics whose
  publisher and every subscriber live in one app document their shape in the owning app and
  have no `LemonCore.Events.*` struct.
- **Validate at the publisher.** `Bus.broadcast_event/4` checks a registered type's payload
  against its struct: it raises in `:dev`/`:test` and coerces in `:prod`. The control plane
  does not expose arbitrary event injection.
- **No `Access` on payloads.** Consumers pattern-match or read fields; anything that may hold
  a legacy map coerces once at its entry point with `LemonCore.Events.coerce/2` (§4.3).

## 2. Catalog

Envelope is always `%LemonCore.Event{}` unless noted **raw**. "Typed" means the type is in
`LemonCore.Events.registry/0`. Subscribers are listed by module; call-site lines move, so
grep `Bus.subscribe` and `Bus.broadcast` for the exact sites.

### 2.1 `run:<run_id>`

The busiest topic and the only one whose subscribers span the umbrella.

| Event type | Publisher | Payload |
|---|---|---|
| `:run_started` (typed) | `LemonGateway.Run` | `Events.RunStarted` (`run_id`, `session_key`, `engine: "lemon"`, optional `model`, `provider`, `thinking_level`) |
| `:delta` (typed) | `LemonGateway.Run` | `Events.Delta` (`run_id`, `seq`, `text`, `ts_ms`, `meta`) |
| `:run_completed` (typed) | `LemonGateway.Run`; synthetic completions from `LemonRouter.RunProcess`, `RunProcess.Watchdog`, `SessionCoordinator`, `LemonGateway.Scheduler` and `ThreadWorker` (admission failures) | `Events.RunCompleted` wrapping `Events.Completion`; synthetic ones carry `meta.synthetic == true` |
| `:run_failed` (typed) | `LemonRouter.RunProcess` (abnormal termination) | `Events.RunFailed` (`run_id`, `session_key`, `reason`) |
| `:run_phase_changed` (typed) | `LemonRouter.PhasePublisher` (the only publisher; the gateway tracks phases but does not broadcast them) | `Events.RunPhaseChanged`, built with `RunPhaseChanged.build/1` |
| `:engine_action` (typed) | `LemonGateway.Run`; `CodingAgent.Tools.Task.LiveBridge` and `Task.Async` for projected child actions; `LemonCore.Event.engine_reasoning/1` | `Events.EngineAction` wrapping `Events.Action` |
| `:engine_started`, `:engine_completed`, `:engine_event` | `LemonGateway.Run` (native executor events) | plain maps; `:engine_event` is the escape hatch for unrecognised native events (not registered) |
| `:checkpoint_created` / `_restored` / `_deleted` | `LemonCore.Checkpoint`; remote ones relayed by `LemonGateway.Run` | map (checkpoint id/kind, tool, action, path counts) — also on `session:<key>` (not registered) |
| `:task_started` / `_completed` / `_error` / `_timeout` / `_aborted` | `CodingAgent.Tools.Task.Async` | map (`task_id`, `run_id`, `parent_run_id`, `session_key`, `agent_id`, …); published to the child run and the parent run |
| `:run_graph_changed` | `CodingAgent.RunGraphServer` | map (`run_id`, `parent_run_id`, `session_key`, `status`, …); child and parent run topics |
| `:parent_question_*` | `CodingAgent.ParentQuestions` | full question record; child and parent run topics (also `parent_question:<id>`, §2.9) |

`LemonCore.ACPClientBridge` (a node-local `Registry`) carries ACP client filesystem
requests as direct request/reply calls, not bus events (`:no_client`, `:client_down`,
`:timeout`).

Subscribers include `LemonRouter.RunProcess` (also forwards run events to the session
topic), `LemonRouter.AsyncTaskSurfaceSubscriber`, `CodingAgent.Tools.Task.LiveBridge`,
`CodingAgent.Tools.Agent` (completion waits), the execution-node worker
(`CodingAgent.ExecutionNode.Worker`), `LemonChannels.TypingIndicator`,
`LemonChannels.UserPromptSurface`, the Discord/Telegram transports,
`LemonComputerUse.Server`, control-plane `Methods.AgentWait`, `ACP`, the SSE route in
`LemonControlPlane.HTTP.Router` and the A2A runner/router, the gateway webhook transport
(`transports/webhook/response.ex`), `LemonAutomation.RunCompletionWaiter`,
`LemonWeb.ShellLive`, and `LemonControlPlane.EventBridge` (ref-counted, dynamic).

#### Named execution-node transport

Named-node `coding_agent.run` executions retain the same run/session Bus contract.
Workers forward sequenced, bounded JSON frames via the node-only
`node.invoke.event` method; `NodeRegistry` authorizes the invocation's live
connection/generation, rejects gaps and deduplicates accepted sequences.
`CodingAgent.Executor.RemoteSessionRunner` sends deltas and tool actions through
the usual gateway sink, so the gateway assigns normal delta sequence numbers and
the router forwards the unchanged typed events to the session topic. Checkpoints
use the same sink ordering and existing checkpoint event names. The controller
emits one started event and the terminal `node.invoke.result` still completes the run.

Remote approvals use `LemonCore.ExecApprovals` on the controller, including its
existing requested/resolved events and store. Controller IDs are separate from
worker IDs; only the invocation recipient can deliver a decision back to the
owning node. Pending requests are denied/cancelled on disconnect, timeout or owner
death. No live-event replay survives a disconnected invocation. Wire envelopes,
limits and decision shapes are documented in the
source file `apps/lemon_control_plane/README.md`, under “Live named-node runs”.

### 2.2 `session:<session_key>`

| Event type | Publisher | Payload |
|---|---|---|
| everything forwarded from `run:*` | `LemonRouter.RunProcess` | unchanged from source |
| `:checkpoint_*` | `LemonCore.Checkpoint` | as §2.1 |
| `:goal_*` | `LemonAgent.Workspace.GoalStore` | `Events.GoalChanged` (also on `goals`) |
| `:run_completed` (cron summary) | `LemonAutomation.CronManager` | `Events.RunCompleted`, `meta.origin == :cron` |
| `:stream_resync` | `LemonRouter.CoalescerIngress` after bounded-ingress overflow | `%{reason: :overflow}` (not registered) |
| `:coalesced_output` | `LemonRouter.StreamCoalescer` | **raw** `%{type: :coalesced_output, session_key, channel_id, run_id, text, seq}` — no envelope |

Subscribers: `LemonWeb.Chat.PaneLive` (bounded delivery handle), the Discord and Telegram
transports, and `LemonControlPlane.EventBridge` (dynamic).

### 2.3 `exec_approvals`

| Event type | Publisher | Payload |
|---|---|---|
| `:approval_requested` | `LemonCore.ExecApprovals` | `Events.ApprovalRequested` (`approval_id`, `pending: Events.ApprovalPending`) |
| `:approval_resolved` | `LemonCore.ExecApprovals` (decision, timeout, cancellation, owner-end expiry) | `Events.ApprovalResolved` (`approval_id`, `decision`, `pending`) |

`decision: :expired` means the run or native session that owned the approval ended
(`LemonCore.ExecApprovals.expire_owner/1`, driven by the `LemonCore.Store`
finalize-run hook and `CodingAgent.Session.terminate/2` through
`LemonCore.ExecApprovalExpiry`). It is immediate and grants nothing; `:timeout` stays
the clock deadline. Channel prompts and TUI records are edited to say the run ended.

Subscribers: `ExecApprovals` itself (the requester awaiting resolution),
`CodingAgent.Session`, `CodingAgent.ExecutionNode.Worker`, the Discord and Telegram
transports, `LemonChannels.ApprovalPromptTracker`, control-plane `ACP`, `EventBridge`, and `LemonWeb` (`ShellLive`,
`SkillsLive`, and `Chat.PaneLive` filtered to the pane's session).

### 2.4 `cron`

All published by `LemonAutomation.Events`, all typed: `:cron_tick`, `:cron_job_created` /
`_updated` / `_deleted` (`Events.CronJobChanged`), `:cron_run_started`,
`:cron_run_completed`, `:cron_lifecycle_action`, `:heartbeat_suppressed`,
`:heartbeat_alert`. Heartbeat suppression runs synchronously during `CronManager`
terminalization via `LemonAutomation.Heartbeat`; there is no separate heartbeat manager.
Subscribers: `EventBridge` and `LemonWeb.WorkManagementLive`.

### 2.5 `system`

Typed, all with `Events.*` payloads: `:config_reloaded` and `:config_reload_failed`
(`LemonCore.ConfigReloader`), `:secret_changed` (`LemonCore.Secrets`; owner, name and
action only, never the value), `:talk_mode_changed` (registered, no in-repo publisher
today). Subscribers: `EventBridge` and `LemonWeb.Chat.PaneLive`; `EventBridge` maps none of
the four to a WS event (§6).

### 2.6 `goals`

`:goal_set`, `_paused`, `_resumed`, `_completed`, `_cleared`, `_continuation_submitted`,
`_loop_verdict`, `_loop_status`, published by `LemonAgent.Workspace.GoalStore` as
`Events.GoalChanged` on `goals` and on the goal's `session:<key>`. All map to the WS
`goal` event. Subscribers: `EventBridge`, `LemonWeb.WorkManagementLive`.

### 2.7 `routing_feedback`

`:routing_feedback` (`Events.RoutingFeedback`: `fingerprint_key`, `outcome`, `duration_ms`),
published by `LemonMemory.Ingest`, consumed by `LemonRouter.RoutingFeedbackStore`.

### 2.8 `channels`

`:channel_delivery` (`Events.ChannelDelivery`) is the observation of every outbound
dispatch. `LemonChannels.Dispatcher.dispatch/1` emits it after the renderer's result is
known, from a helper that rescues and logs, so a crashed bus backend or serialization
issue never breaks a real send. It gates on `Bus.running?/0` and has a
`[:lemon, :channels, :dispatch]` telemetry twin (see [telemetry](../telemetry.md)).

| Field | Meaning |
|---|---|
| `intent_id`, `run_id`, `session_key` | copied from the `LemonCore.DeliveryIntent` |
| `channel_id`, `account_id`, `peer_kind`, `peer_id`, `thread_id` | the `DeliveryRoute` |
| `kind` | the intent kind (`:final_text`, `:stream_snapshot`, …) |
| `text_preview` | bounded excerpt of the outbound text, never the full body |
| `ok` / `error` | dispatch result; `error` is a bounded `inspect/2` of the reason |
| `duration_ms`, `ts_ms` | dispatch duration and wall-clock emit time |

`EventBridge` maps it to `channel.delivery` and all non-node clients receive it without
topic subscriptions.

### 2.9 App-internal and other topics (no `LemonCore.Events.*` struct)

| Topic | Publisher → subscriber | Notes |
|---|---|---|
| `nodes` | control-plane `node.*` methods → `EventBridge`, `LemonWeb.NodesLive` | `:node_pair_requested`, `:node_pair_resolved`, `:node_invoke_completed` |
| `presence` | `LemonControlPlane.Presence` → `EventBridge` | `:presence_changed` |
| `user_prompts` | `CodingAgent.Session.UserPrompt` → `LemonChannels.UserPromptSurface`, `EventBridge` | `:user_prompt_requested`, `:user_prompt_resolved` (public projection, string keys) |
| `omp` | `LemonOmp.Manager` → `EventBridge`, `LemonWeb.OmpLive` | `:omp_session` snapshots (`LemonOmp.bus_topic/0`) |
| `run_graph:<run_id>` | `CodingAgent.RunGraphServer` → `CodingAgent.RunGraph` | bare tuple `{:run_graph, :state_changed, run_id}` — a signal, not an event |
| `parent_question:<request_id>` | `CodingAgent.ParentQuestions` → `Tools.AskParent` | the event is a doorbell; the consumer re-reads state from `ParentQuestions.get/1` |
| `background_run:<id>` | `CodingAgent.BackgroundRun.Worker` | envelope events mirrored to the task store |
| `sessions:lifecycle` | `LemonCore.RunStore.delete_history/1` → `CodingAgent.ToolResources` | tuple `{:session_history_deleted, session_key, cutoff}` |
| `a2a:task:<id>` | `LemonControlPlane.A2A.Runner` → A2A runner/router | tuple `{:a2a_task_terminal, task_id}` |
| `lemon_web:runs` | `LemonWeb.ShellLive.RunEvents` → `ShellLive` | tuple `{:lemon_web_run, phase, info}` |
| `sim:*`, `arena:*`, hosted-game topics | `lemon_sim` / `lemon_sim_ui` | matched pair shipped together; payloads can embed a whole `%LemonSim.State{}` |

The `kanban*` broadcasts were deleted (zero subscribers; durable record is the
`Introspection.record/3` call), and `logs` has never had a publisher.

## 3. Contract vs app-internal

A topic is platform contract when its payload crosses an app boundary and has a consumer that
is not its publisher's sibling. Contract topics, all registered in `LemonCore.Events`:

| Topic | Why it is contract |
|---|---|
| `run:<id>` | consumed by router, coding_agent, control plane (WS, SSE, ACP, A2A), automation, gateway, channels, web |
| `session:<key>` | consumed by the web UI and channel plugins |
| `exec_approvals` | consumed by channel plugins, ACP, coding_agent, web |
| `cron` | crosses `lemon_automation` → `lemon_control_plane` → WS clients |
| `system` | publishers in `lemon_core`; reaches WS clients and the web pane |
| `goals` | crosses `lemon_agent` → `lemon_control_plane` → WS clients |
| `routing_feedback` | crosses `lemon_memory` → `lemon_router` |
| `channels` | outbound delivery observations from `lemon_channels` |

Everything in §2.9 is app-internal: document the shape in the owning app, and do not add a
core struct — it would push domain types back into `lemon_core`. A publisher on an
app-internal topic may still use `Bus.broadcast_event/4`: unregistered types pass through.

## 4. Design

### 4.1 Shape

```
%LemonCore.Event{
  type:    :run_completed,                  # the dispatch key
  ts_ms:   1_754_800_000_000,               # wall-clock milliseconds
  meta:    %{run_id: …, session_key: …},    # routing identity
  payload: %LemonCore.Events.RunCompleted{} # typed for registered types
}
```

`meta` deliberately stays a free map, read with `Access`. Subscribers read
`meta.run_id` / `session_key` / `origin` / `synthetic` / `request_id` / `task_id` /
`parent_run_id`, and different publishers supply different subsets. Typing `meta` has no
consumer benefit.

### 4.2 Registered payloads

All live in `apps/lemon_core/lib/lemon_core/events/`, one module per file, built with
`use LemonCore.Events.Payload` (struct, `@enforce_keys`, `@derive Jason.Encoder`,
`event_type/0`, `event_version/0`, `fields/0`, strict `new/1`, lenient `from_map/1`).
Bold fields are enforced.

| Topic | Event type → module | Fields |
|---|---|---|
| `run:*` | `run_started` → `RunStarted` | **run_id**, session_key, engine, model, provider, thinking_level |
| | `delta` → `Delta` | **run_id**, **seq**, **text**, ts_ms, meta |
| | `run_completed` → `RunCompleted` | **completed** (`Completion`), duration_ms |
| | `run_failed` → `RunFailed` | **run_id**, session_key, **reason** |
| | `run_phase_changed` → `RunPhaseChanged` | **run_id**, session_key, conversation_key, **phase**, previous_phase, **source**, at |
| | `engine_action` → `EngineAction` | **action** (`Action`), engine, phase (`:started \| :updated \| :completed`, default `:updated`), ok, message, level |
| `exec_approvals` | `approval_requested` → `ApprovalRequested` | **approval_id**, **pending** (`ApprovalPending`) |
| | `approval_resolved` → `ApprovalResolved` | **approval_id**, **decision** (`:approve_once`, `:approve_session`, `:approve_agent`, `:approve_global`, `:deny`, `:timeout`, `:cancelled`, `:expired`), pending |
| `cron` | `cron_tick` → `CronTick` | **timestamp_ms** |
| | `cron_run_started` → `CronRunStarted` | **cron_run_id**, router_run_id, **job_id**, job_name, agent_id, session_key, triggered_by, started_at_ms, run |
| | `cron_run_completed` → `CronRunCompleted` | **cron_run_id**, router_run_id, **job_id**, agent_id, session_key, status, duration_ms, output, error, suppressed, run |
| | `cron_job_created` / `_updated` / `_deleted` → `CronJobChanged` | **action**, **job_id**, name, agent_id, job |
| | `cron_lifecycle_action` → `CronLifecycleAction` | **audit** |
| | `heartbeat_alert` → `HeartbeatAlert` | **agent_id**, job_id, job_name, run_id, response, severity |
| | `heartbeat_suppressed` → `HeartbeatSuppressed` | **agent_id**, job_id, job_name, run_id |
| `system` | `config_reloaded` → `ConfigReloaded` | **reload_id**, reason, changed_sources, changed_paths, diff |
| | `config_reload_failed` → `ConfigReloadFailed` | **reload_id**, reason, **error** |
| | `secret_changed` → `SecretChanged` | **owner**, **name**, **action** |
| | `talk_mode_changed` → `TalkModeChanged` | **session_key**, **mode** |
| `goals` | `goal_set`, `_paused`, `_resumed`, `_completed`, `_cleared`, `_continuation_submitted`, `_loop_verdict`, `_loop_status` → `GoalChanged` | **goal_id**, agent_id, session_key, status, objective_bytes, continuation_count, last_run_id, loop_verdict, loop_status, loop_auto_enabled |
| `routing_feedback` | `routing_feedback` → `RoutingFeedback` | **fingerprint_key**, **outcome**, duration_ms |
| `channels` | `channel_delivery` → `ChannelDelivery` | **intent_id**, run_id, session_key, **channel_id**, account_id, peer_kind, peer_id, thread_id, **kind**, text_preview, **ok**, error, duration_ms, ts_ms |

Nested payloads, never published alone (`LemonCore.Events.nested_modules/0`):

| Module | Fields |
|---|---|
| `Completion` | **ok**, answer, error, engine, resume (`%{engine, value}`; top-level resumption accepts only `engine: "lemon"`), usage (a plain map owned by `LemonAi`), run_id, session_key, meta |
| `Action` | **id**, **kind** (`:tool`, `:command`, `:file_change`, `:web_search`, `:subagent`, `:reasoning`, `:note`, `:approval`, `:compaction`), **title**, detail |
| `ApprovalPending` | **id**, run_id, session_id, session_key, agent_id, invocation_context_key (private: excluded from JSON), **tool**, tool_call_id, action, rationale, requested_at_ms, expires_at_ms |

`Events.registry/0` maps type → module, `payload_module/1` and `registered?/1` look one up,
and `modules/0` includes the nested modules.

Not typed on purpose: `:engine_event` (native-executor escape hatch), `:engine_started` /
`:engine_completed`, `:checkpoint_*`, `:task_*`, `:run_graph_changed`, `:parent_question_*`,
`:stream_resync`, `:coalesced_output`, and the app-internal topics in §2.9.

### 4.3 Versioning and compatibility

Each payload module reports `event_version/0` (currently 1 for all), bumped only for a
breaking field change. `LemonCore` is a Hex package, so a registered struct follows semver:

| Change | Bump |
|---|---|
| Add an optional field (with a default) | minor |
| Add an event type to the registry | minor |
| Make an optional field required, or remove a field | **major** |
| Change a field's type or an enum's members | **major** |
| Rename an event type atom | **major** |

Compatibility mechanics:

1. **`from_map/1` on every struct** accepts string keys, drops unknown keys, coerces nested
   payloads and passes structs through. `Events.coerce/2` applies it by type; consumers that
   may receive a legacy map (hand-built test payloads, events relayed from another node)
   coerce once at their entry point and never carry key-probing downstream.
2. **`cast/2`** is the strict counterpart for trust boundaries: it returns
   `{:error, reason}` instead of relaying a malformed payload.
3. **`new/1`** is strict about keys, not nested types: `RunCompleted.new(%{completed: %{ok: true}})`
   builds a valid struct whose `completed` is a plain map, so nested reads in consumers use
   the struct-and-map-safe `get_field/2` rather than field access.
4. **No `Access`.** `payload[:key]` raises on a payload struct. The contract kit asserts that
   no payload module implements `Access`.
5. **JSON.** Payloads derive `Jason.Encoder` (JSONL store backend, control plane). Fields
   declared `private_fields` are excluded; wire projections use allowlists.

### 4.4 Interaction with the bridges

- **`LemonCore.Introspection`**: `sanitize_value/2` converts structs with `Map.from_struct/1`,
  so struct payloads persist the same as maps. Publishers pass the struct to both
  `Introspection.record/3` and `Bus.broadcast/2` unchanged.
- **`LemonControlPlane.EventBridge`**: `project/1` is the single projection to operator wire
  events (WS fanout; in-process operator clients such as the web UI call it too). It
  coerces once, then each `map_event_type/3` clause heads on its struct, so a field rename
  is a compile error at the place that publishes the JSON name to WS clients. The
  field-by-field mapping is explicit — wire JSON is never derived from struct keys. The
  bridge subscribes with a tagged bounded `Bus.Delivery`; see the delivery boundary above.
- **`LemonCore.EventBridge`** (the dynamic-dispatch shim in core) exposes `subscribe_run/1` /
  `unsubscribe_run/1` and never touches a payload. **`LemonCore.RouterBridge`** is a submit
  facade with no Bus references.
- **`Bus.broadcast_event/4`** (`topic, type, payload, meta \\ nil`) is the publishing path
  for contract topics. Unregistered types pass through as-is. The `:enforce_event_payloads`
  application env (default on in `:dev`/`:test`) selects raise vs coerce.
- **`Bus.running?/0`** asks the *active* backend (Phoenix.PubSub or the local-node Registry
  fallback, `Bus.backend/0`) whether it is up. Publishers that emit as a side effect of a
  durable write gate on it, never on `Process.whereis(LemonCore.PubSub)`, which is inert under
  the Registry fallback.

## 5. Contract kit

`LemonPlatformTest.EventsCase` is `use`-able by any app and by extension authors who publish
their own events:

```elixir
defmodule MyApp.EventsContractTest do
  use LemonPlatformTest.EventsCase, modules: [MyApp.Events.ThingHappened]
end
```

With no `:modules` it covers everything in `LemonCore.Events.modules/0`; the platform's own run
is `apps/lemon_platform_test/test/compliance/core_events_test.exs`. It asserts:

1. **Registry completeness** — every registered type resolves to a loaded module exporting
   `new/1`, `from_map/1` and `event_version/0`.
2. **Round-trip** — `from_map(Map.from_struct(x)) == x`, including fully flattened nested
   maps and payloads whose booleans are falsified (`ok: false` must stay `false`).
3. **String keys** — `from_map/1` accepts string-keyed maps from the control plane.
4. **Unknown keys** — `new/1` raises, `from_map/1` drops them.
5. **Introspection compatibility** — a struct sanitizes to the same map its untyped form did.
6. **JSON encodability** — `Jason.encode/1` succeeds.
7. **Envelope discipline and backend parity** — `Bus.broadcast_event/4` delivers the struct
   intact and rejects a mismatched payload, run under **both** `:pubsub` and `:registry`
   backends (`config :lemon_core, :bus_backend, ...`).
8. **No `Access`** on any payload module.

`LemonPlatformTest.EventsFixtures` builds valid payloads for tests (`run_started/1`,
`delta/1`, `run_completed/1`, `run_failed/1`, `approval_*`, `cron_*`, `channel_delivery/1`,
`completion/1`, `action/1`, each taking keyword overrides). Hand-built raw maps in tests
still work because consumers coerce at their entry points.

## 6. Known gaps and consumer assumptions

- **Registered types with no WS mapping.** `EventBridge` maps run started/completed, delta,
  engine action, goals, approvals, channel delivery, cron, heartbeat alert/suppressed and
  tick. It does **not** map `:run_failed`, `:run_phase_changed`, `:config_reloaded`,
  `:config_reload_failed`, `:secret_changed`, `:talk_mode_changed` or `:routing_feedback`.
  The catch-all logs one warning per such type — and a second distinct warning when a
  registered type arrives with a payload that is not (and cannot be coerced into) its
  struct — then drops the event. Unregistered types without a clause are dropped silently.
- **Untyped publishers on registered types.** `CodingAgent.Tools.Task.Projection` builds
  `:engine_action` through `LemonCore.Event.engine_action/2`, which validates a plain-map
  payload by hand (`validate_action_payload!/1`); consumers coerce, so it works, but it is
  the one typed event still published as a bare map.
- **Unenveloped session output.** `:coalesced_output` on `session:<key>` is a raw map with no
  `LemonCore.Event` wrapper.
- **Raw subscriptions are unbounded.** See "Remaining best-effort paths" above.
- **`parent_question:<id>` is a doorbell.** The consumer ignores the payload and re-reads
  `ParentQuestions.get/1`; do not rely on that payload for anything but the persisted event
  log and `Introspection`.

## 7. History

The typed-event migration landed in 2026-08 before the 0.2 release, in stages: a
`LemonCore.Events` registry and `Events.Payload` macro with a temporary `Access` shim, then
`routing_feedback`, `goals`, `system`, `cron`, `exec_approvals` and finally the `run:*`
types; the shim was removed on 2026-08-13 once `EventBridge` and the other consumers were
converted to struct patterns. Notable fixes along the way: `:run_failed` now uses the
`LemonCore.Event` envelope; timer-heartbeat completion output is read from
`completed.answer`; publishers gate on `Bus.running?/0` instead of `Process.whereis/1`;
the gateway no longer publishes a duplicate `:run_phase_changed`; the bare-tuple
`DependencyManager.build_event/3` fallback and its receive clauses were deleted;
`:acp_client_request` left the bus for `LemonCore.ACPClientBridge`; and the `kanban*`
broadcasts were deleted. `:channel_delivery` (2026-08-16) gave `channels` its first publisher.
`apps/lemon_core/CHANGELOG.md` carries the dated record.
