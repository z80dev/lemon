# Phase 3.1 — Typed Bus Events: Catalog and Design

Status: **partially implemented.** Catalog and design written 2026-08-10 against `2805c5b5`;
pre-work and stages S1–S11 landed the same day. See §8 for exactly what is done and what
remains. The catalog in §2 describes the tree *before* typing — it is the record of what was
found, and the migration table in §8 says which rows have since changed.

Scope: every `LemonCore.Bus.broadcast/2` call site in the umbrella (78 in `lib/`, 144 more in
`test/`), the topics they publish to, and every process that subscribes. The plan of record is
[`docs/platform-split.md`](../platform-split.md) §5 item **3.1**; its risk row predicts that
"catalog first will reveal undocumented consumer assumptions." It does — §6 lists thirteen, two
of which are live bugs.

> **Prior work check.** I grepped `docs/plans/` and `docs/platform/` for earlier bus/event design
> work. There is none: the bus is mentioned in passing by `lemon-stack-reshape-2026-07-02.md`,
> `gateway-channels-transport-migration.md` and `2026-04-12-subagent-reasoning-surfacing-plan.md`,
> but no document has ever catalogued the topics or proposed payload types. Unlike 2.4, this phase
> starts from scratch. `docs/platform/lemon_core.md` names the Bus in one sentence and documents
> nothing about it.

## 1. Headline recommendations

**R1 — Type the payload, keep the envelope.** `LemonCore.Event` stays exactly as it is; what
becomes a struct is `event.payload`. Consumers keep matching `%Event{type: :delta}` and gain the
option to match `%Event{type: :delta, payload: %Events.Delta{}}`. Replacing the envelope with
per-event structs would break the five deliberate *forwarders* (`run_process`, `acp`,
`session_live`, discord, telegram) that match `%Event{} = event` precisely because they must
relay types they do not know about.

**R2 — Implement `Access` on the Events structs for one deprecation cycle.** This is the
load-bearing decision. `LemonControlPlane.EventBridge` reads payloads through `payload[:key]` in
**114 places**; `Access` is not implemented for structs, so without a shim, typing a single
payload crashes the control plane's entire WS fanout. With the shim, each publisher can switch
independently and consumers migrate on their own schedule. Without it, `:run_completed` alone is a
twelve-subscriber flag day. See §4.3.

**R3 — The platform contract is 7 topics, not the 15 that exist.** `nodes`, `presence`,
`run_graph:*`, `parent_question:*`, `kanban*` and the sim/arena family have their publisher and
every subscriber inside a single app (or a single matched app pair). They should get documented
shapes in their owning app, not `LemonCore.Events.*` structs. Putting sim or kanban payload types
in `lemon_core` would re-domain the package that Phase 1 just spent ten items de-domaining. See §3.

**R4 — Two control-plane methods make typed payloads unenforceable until they are narrowed.**
`events.ingest` and `system-event` accept an arbitrary JSON object and broadcast it, under a
caller-chosen event type from a 20-atom allowlist, to a caller-chosen `run:<id>` / `session:<key>`
/ `system` / `cron` / `exec_approvals` / `goals` / `nodes` / `presence` topic. A remote client can
inject `%{"foo" => 1}` as a `:delta` into any live run. Restrict both to `:custom_event`, or
validate against the Events registry, *before* the first struct ships. See §6.8.

**R5 — Fix the three real bugs the catalog surfaced as their own commits, before typing.**
They are independent of this phase and each is a few lines: the raw-map `:run_failed` (§6.1), the
heartbeat completion extractor that always yields `nil` (§6.13), and the four
`Process.whereis(LemonCore.PubSub)` gates that silently drop events under the Registry backend
(§6.6).

## 2. Catalog

Envelope column: **E** = `%LemonCore.Event{}`; **raw** = a bare map or tuple sent with no envelope.

### 2.1 `run:<run_id>` — 12 subscribers, 6 apps

The busiest topic and the only one whose subscriber set spans the whole umbrella.

| Event type | Publisher | Payload (actual keys) | Env |
|---|---|---|---|
| `:run_started` | `lemon_gateway/run.ex:244` | `%{run_id, session_key, engine}` | E |
| `:delta` | `lemon_gateway/run.ex:443` | `%{run_id, ts_ms, seq, text, meta}` | E |
| `:run_completed` | `lemon_gateway/run.ex:136` (lock timeout), `:618` (normal) | `%{completed: %{engine, resume, ok, answer, error, usage, meta, run_id, session_key}, duration_ms}` | E |
| `:run_completed` (synthetic) | `lemon_router/run_process.ex:498,538,609`; `run_process/watchdog.ex:239` | same, `meta.synthetic == true` | E |
| `:run_failed` | `lemon_router/run_process.ex:691` (`terminate/2`) | `%{type: :run_failed, run_id, session_key, reason}` | **raw** |
| `:run_phase_changed` | `lemon_gateway/run.ex:773`; `lemon_router/phase_publisher.ex:86` | `LemonCore.RunPhaseEvent.build/1` → `%{type, run_id, session_key, conversation_key, phase, previous_phase, source, at}` | E |
| `:engine_started` | `lemon_gateway/run.ex:815` | `%{engine, resume, title, meta, run_id, session_key}` | E |
| `:engine_completed` | `lemon_gateway/run.ex:815` | same keys as `completed` above | E |
| `:engine_action` | `lemon_gateway/run.ex:815`; `LemonCore.Event.engine_reasoning/1` | `%{engine, phase, ok, message, level, action: %{id, kind, title, detail}}` | E |
| `:engine_event` | `lemon_gateway/run.ex:815` (fallback) | arbitrary engine map | E |
| `:checkpoint_created` / `_restored` / `_deleted` | `lemon_core/checkpoint.ex:321` | varies by kind; meta = checkpoint context | E |
| `:acp_client_request` | `coding_agent/tools/acp_file_bridge.ex:58` | `%{method, params, reply_to: pid(), ref: reference()}` | E |
| `:run_graph_changed` | `coding_agent/run_graph_server.ex:421,426` | `%{run_id, parent_run_id, session_key, status, event, timestamp_ms}` | E |
| `:task_started` / `_completed` / `_error` / `_timeout` / `_aborted` | `coding_agent/tools/task/async.ex:305,309` | `%{task_id, run_id, parent_run_id, session_key, agent_id, …}` | E |
| `:task_projected_child_action` | `coding_agent/tools/task/live_bridge.ex:71` | projected `engine_action` payload | E |
| `:parent_question_*` | `coding_agent/parent_questions.ex:343,347` | full question record (13 keys) | E |
| **anything** | `control_plane/methods/events_ingest.ex:147`, `system_event.ex:161` | **any map** | E |

Subscribers:

| # | Subscriber | Subscribes at | Matches |
|---|---|---|---|
| 1 | `LemonRouter.RunProcess` | `run_process.ex:133` | `:run_started`, `:run_completed`, `:delta`, `:engine_action`, `:task_projected_child_action`, **catch-all `%Event{}` → forwards to session topic** |
| 2 | `LemonRouter.AsyncTaskSurfaceSubscriber` | `async_task_surface_subscriber.ex:81` | `:engine_action` + terminal types |
| 3 | `CodingAgent.Tools.Task.LiveBridge` | `live_bridge.ex:53` | `:engine_action` + terminal types |
| 4 | `CodingAgent.Tools.Agent` | `tools/agent.ex:697` | `:delta`, `:run_completed` |
| 5 | `LemonControlPlane.EventBridge` | `event_bridge.ex:347` (ref-counted, dynamic) | everything, via `map_event/1` |
| 6 | `LemonControlPlane.ACP` | `acp.ex:360` | `:run_completed`, `:acp_client_request`, `:approval_requested`, catch-all |
| 7 | control-plane SSE (`/v1/chat/completions`) | `http/router.ex:137` | `:delta`, `:engine_action`, `:run_completed` |
| 8 | `Methods.AgentWait` | `agent_wait.ex:39` | `:run_completed` |
| 9 | `LemonAutomation.RunSubmitter` | `run_submitter.ex:22` (via `RunCompletionWaiter`) | `:run_completed`, `:run_failed` |
| 10 | `LemonAutomation.KanbanRunWorker` | `kanban_run_worker.ex:19` (via `RunCompletionWaiter`) | same |
| 11 | `LemonAutomation.HeartbeatManager` | `heartbeat_manager.ex:630` | `:run_completed`, `:run_failed` |
| 12 | webhook transport | `transports/webhook/response.ex:61,100,148` | `:run_completed` |
| 13 | telegram plugin | `telegram/transport.ex:737` | `:run_completed`, catch-all |

### 2.2 `session:<session_key>` — 4 subscribers

| Event type | Publisher | Payload | Env |
|---|---|---|---|
| *(forwarded from `run:*`)* | `lemon_router/run_process.ex:242,295,362,390,420` | unchanged from source | E |
| `:checkpoint_*` | `lemon_core/checkpoint.ex:325` | as §2.1 | E |
| `:goal_*` | `agent_core/workspace/goal_store.ex:523` | `%{goal_id, agent_id, status, objective_bytes, continuation_count, last_run_id, loop_verdict, loop_status, loop_auto_enabled}` | E |
| `:coalesced_output` | `lemon_router/stream_coalescer.ex:483` | `%{type: :coalesced_output, session_key, channel_id, run_id, text, seq}` | **raw** |
| `:cron_*` (base session) | `lemon_automation/cron_manager.ex:1110` | cron payload | E |
| **anything** | `events_ingest.ex:147`, `system_event.ex:161` | any map | E |

Subscribers: `lemon_web/live/session_live.ex:17`, `discord/transport.ex:3408`,
`telegram/transport.ex:729`, `LemonControlPlane.EventBridge` (dynamic).

### 2.3 `exec_approvals` — 6 subscribers

| Event type | Publisher | Payload | Env |
|---|---|---|---|
| `:approval_requested` | `lemon_core/exec_approvals.ex:117` | `%{approval_id, pending: %{id, run_id, session_id, session_key, agent_id, tool, action, rationale, requested_at_ms, expires_at_ms}}` | E |
| `:approval_resolved` | `lemon_core/exec_approvals.ex:174` (decision), `:378` (timeout) | `%{approval_id, decision, pending}` | E |
| `:approval_requested` | `control_plane/methods/exec_approval_request.ex:57` | same shape | E |

Subscribers: `exec_approvals.ex:77` (the requester itself, awaiting resolution),
`coding_agent/session.ex:1139`, `discord:3414`, `telegram:1354`, `control_plane/acp.ex:361`,
`EventBridge`.

### 2.4 `cron` — 2 subscribers

Nine types published from `lemon_automation/events.ex` (`:cron_tick`, `:cron_job_created`,
`:cron_job_updated`, `:cron_job_deleted`, `:cron_run_started`, `:cron_run_completed`,
`:cron_lifecycle_action`, `:heartbeat_suppressed`, `:heartbeat_alert`), all `Event`-wrapped with
documented payloads — this module is the closest thing the repo has to a typed-event precedent.

**Plus four hand-built `%LemonCore.Event{}` literals in `heartbeat_manager.ex:496,547,566,586`**
that publish `:cron_run_started` / `:cron_run_completed` with a *different* payload shape,
bypassing `Events` entirely (§6.10).

Subscribers: `heartbeat_manager.ex:149`, `EventBridge`. (`events.ex:29` is a moduledoc example,
not a subscription.)

### 2.5 `system` — 1 subscriber

| Event type | Publisher | Payload | Env |
|---|---|---|---|
| `:config_reloaded` | `lemon_core/config_reloader.ex:260` | `%{reload_id, reason, changed_sources, changed_paths, diff}` | E |
| `:config_reload_failed` | `lemon_core/config_reloader.ex:316` | `%{reload_id, reason, error}` | E |
| `:secret_changed` | `lemon_core/secrets.ex:432` | `%{owner, name, action}` | E |
| `:talk_mode_changed` | `control_plane/methods/talk_mode.ex:66` | `%{session_key, mode}` | E |
| `:voicewake_changed` | `control_plane/methods/voicewake_set.ex:40` | voicewake settings | E |
| `:device_pair_requested` / `_resolved` | `device_pair_request.ex:51`, `_approve.ex:82`, `_reject.ex:51` | pairing record | E |

Subscriber: `EventBridge` only — and it has **no mapping clause for the first three**, so
`:config_reloaded`, `:config_reload_failed` and `:secret_changed` are published into a topic where
the only listener silently discards them.

### 2.6 Single-app topics (recommend: no `LemonCore.Events.*` struct)

| Topic | Publisher | Subscriber | Notes |
|---|---|---|---|
| `nodes` | 6 × `control_plane/methods/node_*.ex` | `EventBridge` | both ends in `lemon_control_plane` |
| `presence` | `control_plane/presence.ex:231` | `EventBridge` | both ends in `lemon_control_plane` |
| `goals` | `agent_core/workspace/goal_store.ex:522` | `EventBridge` | **cross-app**, 1 consumer — cheap to type |
| `kanban`, `kanban:<board_id>` | `agent_core/workspace/kanban_store.ex:653,654` | **none** | zero subscribers repo-wide |
| `routing_feedback` | `lemon_memory/ingest.ex:175` | `lemon_router/routing_feedback_store.ex:217` | **cross-app**, already pattern-matched on exact keys |
| `run_graph:<run_id>` | `coding_agent/run_graph_server.ex:400` | `coding_agent/run_graph.ex:327` | payload is the bare tuple `{:run_graph, :state_changed, run_id}` — **raw** |
| `parent_question:<request_id>` | `coding_agent/parent_questions.ex:340` | `coding_agent/tools/ask_parent.ex:262` | matches on `meta.request_id` only, ignores payload |
| `sim:<id>`, `sim:<id>:decisions` | `lemon_sim/kernel/bus.ex:30,36` | `lemon_sim_ui/arena.ex:504,520`, LiveViews | payload embeds a whole `%LemonSim.State{}` |
| `sim:lobby` | `lemon_sim_ui/sim_manager.ex:1739` | 4 LiveViews + `arena.ex:179` | empty payload |
| `arena:<domain>:league` | `lemon_sim_ui/arena.ex:752` | `arena_leaderboard_live.ex:21` | `%{game_id}` |
| hosted-game topic | `hosted_game/room_server.ex:1676` | `hosted_werewolf_live.ex` (4 sites) | `%{room_id}` |
| philosopher-chat topic | `philosopher_chat/thread_server.ex:844` | `philosopher_chat_api_controller.ex:172` | `%{type, event_seq, …}` |
| `channels` | **none in `lib/`** | `EventBridge` | documented in the Bus contract; reachable only via the control-plane injectors (§6.8) |
| `logs` | **none** | **none** | documented in the Bus contract; dead |

### 2.7 Envelope discipline, summarised

Of 78 `lib/` publish sites, **75 use `%LemonCore.Event{}`**. The three that do not:

- `run_process.ex:691` — `%{type: :run_failed, run_id, session_key, reason}` (§6.1)
- `stream_coalescer.ex:483` — `%{type: :coalesced_output, …}`
- `run_graph_server.ex:400` — `{:run_graph, :state_changed, run_id}` (a signal, not an event; fine)

A fourth latent shape exists: `LemonGateway.DependencyManager.build_event/3` returns
`{event_type, payload}` when `LemonCore.Event` is not loadable (§6.9).

## 3. Contract vs app-internal

The plan says to type "every published topic." That over-reaches. The test is whether a payload
crosses an app boundary *and* has a consumer that is not its publisher's sibling.

**Platform contract — type these (7):**

| Topic | Subscribers | Why it is contract |
|---|---|---|
| `run:<id>` | 12 | Consumed by router, coding_agent, control plane (WS + SSE + ACP), automation, gateway, channels |
| `session:<key>` | 4 | Consumed by the web UI and two channel plugins |
| `exec_approvals` | 6 | Consumed by two channel plugins, the ACP server and coding_agent |
| `cron` | 2 | Crosses `lemon_automation` → `lemon_control_plane` → WS clients |
| `system` | 1 | Publishers in `lemon_core` and `lemon_control_plane`; reaches WS clients |
| `goals` | 1 | Crosses `agent_core` → `lemon_control_plane` → WS clients |
| `routing_feedback` | 1 | Crosses `lemon_memory` → `lemon_router`; the pilot (§5) |

**App-internal — document the shape in the owning app, do not add a core struct:** `nodes`,
`presence` (both ends in `lemon_control_plane`); `run_graph:*`, `parent_question:*` (both ends in
`coding_agent`); the five sim/arena topics (`lemon_sim` + `lemon_sim_ui`, a matched pair shipped
together).

**Delete rather than type:** `kanban` and `kanban:<board_id>` (zero subscribers — either the UI
that was going to consume them never landed, or it was removed); `channels` and `logs` (zero
publishers; remove from the Bus moduledoc's "must be stable" list, which is the only place they
are asserted to exist).

## 4. Design

### 4.1 Shape

```
%LemonCore.Event{
  type:    :run_completed,                  # unchanged — the dispatch key
  ts_ms:   1_754_800_000_000,               # unchanged
  meta:    %{run_id: …, session_key: …},    # unchanged — routing identity
  payload: %LemonCore.Events.RunCompleted{} # ← this is what 3.1 changes
}
```

`meta` deliberately stays a free map. Every subscriber reads `meta.run_id` / `meta.session_key` /
`meta.origin` / `meta.synthetic` / `meta.request_id` / `meta.task_id` / `meta.parent_run_id`, and
different publishers supply different subsets. Typing `meta` is a separate, larger change with no
consumer benefit; a documented `@type meta` in `LemonCore.Event` is enough.

### 4.2 Proposed structs

All live in `apps/lemon_core/lib/lemon_core/events/`, one module per file, each with
`@enforce_keys` for required fields, a `@type t`, `new/1` (keyword or map → struct, raising on
unknown keys), and `from_map/1` (lenient, for legacy maps arriving over the wire).

`run:<id>`:

```elixir
defmodule LemonCore.Events.RunStarted do
  @enforce_keys [:run_id]
  defstruct [:run_id, :session_key, :engine]
  # run_id: String.t(); session_key: String.t() | nil; engine: String.t() | nil
end

defmodule LemonCore.Events.Delta do
  @enforce_keys [:run_id, :seq, :text]
  defstruct [:run_id, :seq, :text, :ts_ms, meta: %{}]
  # seq: non_neg_integer(); text: String.t(); ts_ms: non_neg_integer() | nil
end

defmodule LemonCore.Events.RunCompleted do
  @enforce_keys [:completed]
  defstruct [:completed, :duration_ms]
  # completed: LemonCore.Events.Completion.t(); duration_ms: non_neg_integer() | nil
end

defmodule LemonCore.Events.Completion do
  @enforce_keys [:ok]
  defstruct [:ok, :answer, :error, :engine, :resume, :usage, :run_id, :session_key, meta: %{}]
  # ok: boolean(); answer: String.t() | nil; error: term() | nil
  # resume: LemonCore.ResumeToken.t() | %{engine: String.t(), value: term()} | nil
  # usage: map() | nil  ← left as map; LemonAi.Tokens owns its shape
end

defmodule LemonCore.Events.RunFailed do
  @enforce_keys [:run_id, :reason]
  defstruct [:run_id, :session_key, :reason]
end

defmodule LemonCore.Events.EngineAction do
  @enforce_keys [:action]
  defstruct [:action, :engine, :phase, :ok, :message, :level]
  # action: LemonCore.Events.Action.t()
  # phase: :started | :updated | :completed
  # ok: boolean() | nil; level: atom() | nil
end

defmodule LemonCore.Events.Action do
  @enforce_keys [:id, :kind, :title]
  defstruct [:id, :kind, :title, detail: %{}]
  # kind: :tool | :command | :file_change | :web_search | :subagent | :reasoning | :note
  #   ← today validated as *either* atom or string in Event.validate_action_payload!/1;
  #     the struct should normalise to atom and the legacy path accept both.
end

defmodule LemonCore.Events.RunPhaseChanged do
  @enforce_keys [:run_id, :phase, :source]
  defstruct [:run_id, :session_key, :conversation_key, :phase, :previous_phase, :source, :at]
  # phase/previous_phase validated by LemonCore.RunPhase.valid?/1 — this struct replaces
  # LemonCore.RunPhaseEvent.build/1, which is already 90% of the design.
end
```

`exec_approvals`:

```elixir
defmodule LemonCore.Events.ApprovalRequested do
  @enforce_keys [:approval_id, :pending]
  defstruct [:approval_id, :pending]
end

defmodule LemonCore.Events.ApprovalResolved do
  @enforce_keys [:approval_id, :decision]
  defstruct [:approval_id, :decision, :pending]
  # decision: :approve_once | :approve_session | :approve_agent | :approve_global | :deny | :timeout
end

defmodule LemonCore.Events.ApprovalPending do
  @enforce_keys [:id, :tool]
  defstruct [:id, :run_id, :session_id, :session_key, :agent_id, :tool, :action,
             :rationale, :requested_at_ms, :expires_at_ms]
  # This map is already stored in ExecApprovalStore and read by five consumers with
  # identical key expectations — it is a struct in all but name.
end
```

`cron` (in `lemon_core` because `EventBridge` in `lemon_control_plane` consumes them and neither
app may depend on the other):

```elixir
LemonCore.Events.CronRunStarted     # run_id, cron_run_id, job_id, job_name, agent_id,
                                    # session_key, triggered_by, started_at_ms
LemonCore.Events.CronRunCompleted   # run_id, cron_run_id, job_id, status, suppressed,
                                    # agent_id, session_key, duration_ms, error, output
LemonCore.Events.CronTick           # timestamp_ms
LemonCore.Events.CronJobChanged     # action (:created|:updated|:deleted), job_id, name, job
LemonCore.Events.CronLifecycleAction # audit record
LemonCore.Events.HeartbeatAlert     # agent_id, job_id, job_name, run_id, response, severity
LemonCore.Events.HeartbeatSuppressed # agent_id, job_id, job_name, run_id
```

Note `CronRunStarted`/`CronRunCompleted` drop the nested `run:`/`job:` sub-maps in favour of the
flat fields EventBridge actually reads. That flattening is the point: it forces the
`heartbeat_manager` divergence (§6.10) to be resolved rather than papered over with `||`.

`system`, `goals`, `routing_feedback`:

```elixir
LemonCore.Events.ConfigReloaded      # reload_id, reason, changed_sources, changed_paths, diff
LemonCore.Events.ConfigReloadFailed  # reload_id, reason, error
LemonCore.Events.SecretChanged       # owner, name, action
LemonCore.Events.TalkModeChanged     # session_key, mode
LemonCore.Events.GoalChanged         # action, goal_id, agent_id, session_key, status,
                                      # objective_bytes, continuation_count, last_run_id,
                                      # loop_verdict, loop_status, loop_auto_enabled
LemonCore.Events.RoutingFeedback     # fingerprint_key, outcome, duration_ms
```

**Deliberately not typed:** `:acp_client_request` (§6.7 — it carries a live pid and a ref; it is
an RPC, and a value type would legitimise that), `:engine_event` (an explicit "unrecognised engine
output" escape hatch), `:custom_event` (user-defined by construction), and everything on the
app-internal topics in §3.

### 4.3 Versioning and the compatibility cycle

Each struct module carries `@event_version 1` and appears in a `LemonCore.Events.registry/0`
mapping `event_type → module`. The registry is what the contract kit (§5.3), the control-plane
injectors (R4) and `EventBridge` all validate against.

Compatibility for one release cycle rests on two mechanisms:

1. **`from_map/1` on every struct.** A consumer that receives a legacy map coerces it:
   `payload = Events.RunCompleted.from_map(payload)`. This is how a *new* consumer tolerates an
   *old* publisher — needed because publishers migrate one at a time and because
   `events.ingest` can inject a bare map at any moment.

2. **`Access` implemented on every Events struct** (`fetch/2`, `get_and_update/3`, `pop/2`,
   delegating to `Map`). This is how an *old* consumer tolerates a *new* publisher, and it is what
   makes the migration incremental instead of a flag day. The concrete number: `EventBridge` alone
   reads payloads via `payload[:key]` 114 times across 26 `map_event_type/3` clauses. It also has a
   struct-safe `get_field/2` helper in the same file, used inconsistently — the clauses for
   `:engine_action`, `:approval_*`, `:goal_*`, `:checkpoint_*` use it; the clauses for
   `:run_started`, `:run_completed`, `:delta`, `:cron_*`, `:presence_changed`, `:heartbeat*`,
   `:node_*`, `:task_*` use `Access`. Without the shim, typing `:run_completed` breaks WS fanout
   for every client on the first publish.

   The shim is explicitly one cycle: each `Access` implementation gets `@deprecated "Pattern-match
   the struct or use Map.get/2; Access on Events structs is removed in the next major."` A
   contract-kit assertion (§5.3) fails if an Events module ships without a removal note.

Semver rule once a struct is published, to go in `docs/platform/lemon_core.md`:

| Change | Bump |
|---|---|
| Add an optional field (with a default) | minor |
| Add an event type to the registry | minor |
| Make an optional field required, or remove a field | **major** |
| Change a field's type or an enum's members | **major** |
| Rename an event type atom | **major** |
| Remove the `Access` shim | **major** |

### 4.4 Interaction with the bridges

**`LemonCore.Introspection`** — no change needed, and this is a genuinely pleasant finding.
`introspection.ex:151` already opens with `sanitize_value(%{__struct__: _} = struct, opts)` →
`Map.from_struct/1`, so struct payloads persist identically to today's maps. The ~20 call sites
that pass the same map to both `Introspection.record/3` and `Bus.broadcast/2` can pass the struct
to both unchanged. The kit should assert this rather than leave it to luck.

**`LemonControlPlane.EventBridge`** — the real work of this phase lives here. Recommended end
state: each `map_event_type/3` clause pattern-matches its struct
(`defp map_event_type(:run_completed, %Events.RunCompleted{} = p, meta)`), so a field rename
becomes a compile error in the exact place that publishes the JSON name to WS clients. Keep an
explicit field-by-field mapping — do *not* derive the wire JSON from struct keys, or an internal
rename silently becomes a public API break. Retain a legacy clause per type
(`defp map_event_type(:run_completed, p, meta) when is_map(p)` → `from_map/1` then delegate) for
the compatibility cycle. The catch-all `map_event_type(_, _, _), do: nil` at `event_bridge.ex:880`
should additionally log-once-per-type for any atom present in `Events.registry/0`, which is how
§6.5's silent drops become visible.

**`LemonCore.EventBridge`** (the dynamic-dispatch shim in core) — no interaction. Its surface is
`subscribe_run/1` and `unsubscribe_run/1`; it never touches a payload.

**`LemonCore.RouterBridge`** — no interaction. It contains zero references to `Bus` or `Event`; it
is a submit facade.

**`LemonCore.Bus`** — two changes worth bundling. Its moduledoc "Topic Contract (must be stable)"
list is wrong in both directions: it omits `goals`, `kanban*`, `presence`, `run_graph:*`,
`parent_question:*` and the sim/arena family, and it lists `channels` and `logs`, which have no
publishers. Replace it with a pointer to this document plus the `Events.registry/0` table. Second,
add `Bus.broadcast_event/3` (`topic, type, payload`) that asserts the payload's struct matches the
registry entry for the type in `:dev`/`:test` and is a pass-through in `:prod` — the enforcement
point that makes "consumers pattern-match on structs" actually hold.

## 5. Migration sequencing

Ordered by blast radius ascending, so the mechanism is proven on cheap topics before it reaches
`run:*`. Each numbered item is one commit unless noted.

**Pre-work (independent of typing; land first):**

- **P1.** Fix `:run_failed` to use the `Event` envelope (§6.1) — 1 publisher, 3 consumers.
- **P2.** Fix `extract_heartbeat_output/1` (§6.13) — 1 file.
- **P3.** Replace the four `Process.whereis(LemonCore.PubSub)` gates with `Bus.pubsub?/0`-agnostic
  publishing (§6.6) — `checkpoint.ex`, `goal_store.ex`, `kanban_store.ex`, `stream_coalescer.ex`.
- **P4.** Narrow `events.ingest` and `system-event` (R4/§6.8) — **blocks everything after S3.**
- **P5.** Fold `heartbeat_manager`'s four hand-built cron events into `LemonAutomation.Events`
  (§6.10) — **blocks S5.**
- **P6.** Delete the `kanban`/`kanban:<id>` publishes, and `channels`/`logs` from the Bus
  moduledoc (§3).

**Typing, in order:**

| # | Topic / type | Subscribers | Notes |
|---|---|---|---|
| S1 | `LemonCore.Events` scaffold + `registry/0` + `Access` shim + `from_map/1` contract | — | No behaviour change; the kit lands with it |
| S2 | `routing_feedback` | 1 | **The pilot.** The consumer already destructures exact keys; this proves the mechanism end-to-end in ~40 lines |
| S3 | `goals` | 1 | Cross-app, one `EventBridge` clause |
| S4 | `system` (`:config_reloaded`, `:config_reload_failed`, `:secret_changed`, `:talk_mode_changed`) | 1 | Decide drop-vs-map for the first three (§6.5) as part of it |
| S5 | `cron` (7 types) | 2 | After P5. Largest *publisher* count (13 sites), small consumer count |
| S6 | `exec_approvals` (3 types incl. `ApprovalPending`) | 6 | First multi-app consumer set; `pending` is shared with `ExecApprovalStore`, so the store's read path migrates with it |
| S7 | `run:*` — `:run_phase_changed` | **0** | Free: published twice per transition and consumed by nobody (§6.4). Retires `LemonCore.RunPhaseEvent` |
| S8 | `run:*` — `:run_started` | 3 | |
| S9 | `run:*` — `:delta` | 5 | Highest volume; check the `Access` shim's cost under load here |
| S10 | `run:*` — `:engine_action` + `Action` | 5 | Also covers `Event.engine_reasoning/1`, which already validates this payload by hand — replace that validation with the struct |
| S11 | `run:*` — `:run_completed` + `Completion` + `:run_failed` | **12** | The big one; do it last, alone, and expect to touch `RunCompletionWaiter`'s seven receive clauses (§6.2) |
| S12 | `session:*` | 4 | Mostly falls out of S8–S11, since `run_process` forwards the same events. `:coalesced_output` gets an envelope here |
| S13 | Remove the `Access` shim; `Bus.broadcast_event/3` enforcement moves from warn to raise in `:test` | — | Next major |

Test-side blast radius is larger than lib-side and is the real cost driver: **144
`Bus.broadcast` call sites in `test/`** hand-construct payloads —
`lemon_control_plane` 57, `lemon_router` 52, `coding_agent` 18, `lemon_core` 10, `lemon_sim_ui` 4,
`lemon_automation` 2, `lemon_gateway` 1. The `Access` shim (R2) does not help these, because they
*build* payloads. Mitigation: ship a `LemonPlatformTest.EventsFixtures` module in S1 with
`run_completed(overrides \\ [])`-style builders, and convert tests topic-by-topic alongside each S
step. Roughly 60% of those sites are `:run_completed` or `:delta`, so S9 and S11 carry most of it.

### 5.3 What the contract kit should assert

New `LemonPlatformTest.EventsCase`, `use`-able by any app (and by extension authors publishing
their own events):

1. **Registry completeness** — every module under `LemonCore.Events.*` appears in
   `registry/0`, and every registry value is a loadable module exporting `new/1` and `from_map/1`.
2. **Round-trip** — `x |> Map.from_struct() |> Mod.from_map()` equals `x`, for a generated
   example of each struct. This is what guarantees the legacy-map acceptance path is honest.
3. **Introspection compatibility** — `LemonCore.Introspection.build_event(type, struct, opts)`
   succeeds and yields the same sanitized payload as the equivalent map. Locks in §4.4.
4. **Envelope discipline** — publishing each registry type through `Bus.broadcast_event/3`
   delivers a `%LemonCore.Event{}` whose `payload` is the expected struct.
5. **Backend parity** — every assertion in (4) runs twice, once with
   `config :lemon_core, :bus_backend, :pubsub` and once with `:registry`. This is the assertion
   class that would have caught §6.6, and it costs one `for backend <- [:pubsub, :registry]`.
6. **Deprecation hygiene** — any module implementing `Access` carries a `@deprecated` with a
   removal note (guards R2's one-cycle promise against becoming permanent).
7. **Engine lifecycle ordering** — extend the existing `LemonPlatformTest.EngineCase` (which today
   asserts only the in-process `{:engine_event, run_ref, …}` protocol at
   `engine_case.ex:332,351`) with a bus-level assertion: a conforming engine's run produces
   `:run_started` → `:delta`\* → `:run_completed` on `run:<id>`, with typed payloads, in that
   order. That is the first time the *bus* contract is machine-checked for third-party engines.

## 6. Risks and the undocumented consumer assumptions

The plan predicted these; here they are, with the two live bugs first.

**6.1 `:run_failed` is published raw and consumed as an envelope — live bug.**
`run_process.ex:691` (`terminate/2`) publishes `%{type: :run_failed, run_id:, session_key:,
reason:}` with no `Event` wrapper and no `:payload` key. But
`heartbeat_manager.ex:643` waits on `%LemonCore.Event{type: :run_failed, payload: payload}` — a
clause that can never match. A timer heartbeat whose run dies abnormally blocks for the full 30 s
timeout instead of failing fast. `RunCompletionWaiter` gets this right by accident, via a separate
`%{type: :run_failed, reason: reason}` clause.

**6.2 `RunCompletionWaiter` has seven receive clauses for one published shape.**
`run_completion_waiter.ex` accepts `%Event{type: :run_completed}`, `{:run_completed, payload}`,
`%{type: :run_completed, payload: …}`, a bare `%{completed: %{answer:, ok: true}}`, a bare
`%{completed: %{ok: false, error:}}`, `%Event{type: :run_failed}` and
`%{type: :run_failed, reason:}`. Only two are reachable today. The bare-`%{completed:}` clauses
and the tuple clause are fossils — the tuple one is the `DependencyManager.build_event/3` fallback
(§6.9). `agent_wait.ex:71`, `acp.ex` and `webhook/response.ex:305` each carry their own subset of
the same defensive fan. Typing `:run_completed` is the opportunity to delete about 15 dead clauses
across four apps; not doing so preserves the ambiguity the structs are meant to remove.

**6.3 `EventBridge` reads payloads via `Access` in 114 places.** Detailed in R2/§4.3. This is the
single biggest mechanical risk in the phase and the reason the `Access` shim is not optional.

**6.4 `:run_phase_changed` has zero subscribers** but is published on every phase transition by
*both* `lemon_gateway/run.ex:773` and `lemon_router/phase_publisher.ex:86` — two publishers, one
topic, no consumers, and `EventBridge` has no mapping clause so it would not surface even if a WS
client asked. Either the router or the gateway publisher is redundant. Typing it (S7) is free; the
real question the lead should settle is whether it should be published at all.

**6.5 `EventBridge`'s catch-all silently drops eight published types.** `map_event_type(_, _, _),
do: nil` at `event_bridge.ex:880` swallows `:config_reloaded`, `:config_reload_failed`,
`:secret_changed`, `:engine_started`, `:engine_completed`, `:engine_event`, `:run_phase_changed`
and `:acp_client_request` — all published onto topics `EventBridge` subscribes to. Nothing logs.
Any future event type is dropped the same way, which means "add an event" currently has no failure
mode that anyone notices.

**6.6 Four publishers gate on `Process.whereis(LemonCore.PubSub)` — live bug.**
`checkpoint.ex:318`, `goal_store.ex:520`, `kanban_store.ex:651` and `stream_coalescer.ex:481`
check for the `Phoenix.PubSub` process before broadcasting. Under the Registry fallback backend —
which `bus.ex:118-123` documents as a supported configuration, and which tests select via
`config :lemon_core, :bus_backend, :registry` — that process does not exist, so checkpoints, goal
events, kanban events and coalesced output are silently never published. `Bus.broadcast/2` already
handles both backends; the gates are wrong, not merely redundant.

**6.7 `:acp_client_request` carries a pid and a ref over a cluster-wide broadcast.**
`acp_file_bridge.ex:58` publishes `%{method, params, reply_to: self(), ref: ref}` on `run:<id>`
and then blocks in `receive` for `{:acp_client_response, ^ref, response}`. This is
request/response RPC wearing an event's clothes: it is order-dependent, single-consumer, and its
payload cannot be serialised, persisted or replayed like every other event on that topic. Under
`Phoenix.PubSub` it is also delivered to every node. Recommend excluding it from the typed
registry and, separately from 3.1, converting it to a direct call against the ACP session process.

**6.8 The control plane can inject arbitrary payloads under real event types.**
`events.ingest` (scope `:write`) accepts any JSON object and broadcasts it to `system`, `channels`,
`cron`, `exec_approvals`, `goals`, `nodes`, `presence`, or **any** `run:<id>` / `session:<key>`
topic, typed as `:custom_event`, `:heartbeat`, `:metrics` or `:log`. `system-event` (scope
`:admin`) does the same across a **20-atom allowlist that includes `:delta`, `:run_completed`,
`:approval_requested`, `:approval_resolved`, `:cron_run_started` and `:cron_run_completed`**. A
client with admin scope can therefore inject a malformed `:run_completed` into any live run, and
`run_process` will forward it to the session topic and every channel subscriber. Typed payloads
are advisory until this is narrowed — `events.ingest` to `:custom_event` only, and `system-event`
either to `:custom_event` or to payloads validated through `Events.registry/0`. This is why P4
blocks the run-topic work.

**6.9 A second wire shape exists behind an optional-dependency check.**
`DependencyManager.build_event/3` (`dependency_manager.ex:84`) returns `{event_type, payload}` —
a bare tuple — when `LemonCore.Event` is not loadable, and `emit_to_bus/4` in
`lemon_gateway/run.ex:718` broadcasts whatever it returns. Inside the umbrella `lemon_core` is
always present, so this path is dead; it exists because the gateway was once meant to run without
core. It should be deleted, not typed. It is the origin of `RunCompletionWaiter`'s tuple clause.

**6.10 The `cron` topic carries two incompatible payload shapes for the same event type.**
`LemonAutomation.Events.emit_run_started/2` publishes
`%{run: CronRun.to_map(run), cron_run_id, router_run_id, job_id, job_name, agent_id, session_key,
triggered_by}`. `heartbeat_manager.ex:496` publishes the same `:cron_run_started` type as
`%{run: %{id, job_id, agent_id, session_key, prompt, status}, job: %{id, name, agent_id}}` — a
nested `job` map the other shape lacks, and no `job_name`. `EventBridge`'s clause reads
`job[:name] || payload[:job_name]`, `run[:run_id] || payload[:router_run_id] || run[:id]` and
`run[:job_id]`; those `||` chains are a direct fossil of this divergence, and there is no way to
tell from the WS payload which publisher produced an event. P5 must resolve this before `cron`
can be typed, and resolving it is a behaviour change (heartbeat cron events will gain a stable
`job_name` and `router_run_id`) that the lead should sign off.

**6.11 `kanban` and `kanban:<board_id>` have no subscribers; `channels` and `logs` have no
publishers.** The latter two are in the Bus moduledoc's "Standard topics (must be stable)" list,
and `EventBridge` subscribes to `channels` at startup although no module publishes to it — the
only way to put an event on `channels` is the control-plane injector of §6.8. The documented
contract and the real one have never matched.

**6.12 `parent_question:<id>`'s consumer ignores the payload entirely.**
`ask_parent.ex:283` matches `%LemonCore.Event{meta: %{request_id: ^request_id}}` and then re-reads
state from `ParentQuestions.get/1`. The 13-key payload that `parent_questions.ex:315` carefully
assembles is used only by the persisted event log and `Introspection`. Worth knowing before
anyone spends effort typing it: the bus event here is a doorbell, not a message.

**6.13 Timer heartbeats always record a `nil` result — live bug.**
`heartbeat_manager.ex:655` extracts output with `payload[:output] || payload[:answer] ||
payload[:result]` (plus string variants) from a `:run_completed` payload whose actual keys are
`:completed` and `:duration_ms`; the answer lives at `payload.completed.answer`. Every timer
heartbeat therefore reports `{:ok, nil}`, which the caller then broadcasts as
`:cron_run_completed` with `output: nil`. Independent of typing (P2), but a typed
`RunCompleted`/`Completion` pair makes this class of miss a compile-time question instead of a
silent nil.

## 7. What Phase A concludes

The plan's framing — "give each published topic a struct" — should be narrowed to *seven contract
topics and about 25 event types*, with the app-internal topics documented in their owning apps.
The mechanism should be a typed `payload` inside the existing envelope, with an `Access` shim for
one cycle, because that is what converts a twelve-subscriber flag day into thirteen independent
commits.

The catalog's most useful output is not the struct list; it is that the bus's real contract has
drifted far enough from its documented one that four publishers are silently disabled under a
supported backend, eight event types are published to a listener that discards them, two live bugs
sit in the run-completion path, and an admin-scoped RPC method can forge any of it. Typing the
payloads is worth doing, but P1–P6 are worth doing first and are independently valuable if 3.1 is
ever deprioritised.

## 8. Implementation status

Landed 2026-08-10, after the design above was reviewed.

**Pre-work (§5), all landed:**

| Item | What changed |
|---|---|
| P1 | `:run_failed` now publishes a `LemonCore.Event` envelope (`run_process.ex`), making `HeartbeatManager`'s previously unmatchable clause live. Its error extraction now reads `:reason` first, which is the key the publisher actually sends. |
| P2 | `extract_heartbeat_output/1` reads `payload.completed.answer`, so timer heartbeats record their real output instead of `nil`. |
| P3 | New `LemonCore.Bus.running?/0` asks the *active* backend whether it is up. The four publishers that checked `Process.whereis(LemonCore.PubSub)` (`checkpoint.ex`, `goal_store.ex`, `kanban_store.ex`, `stream_coalescer.ex`) now use it, so they are no longer silently inert under the Registry fallback. |
| P5 | `HeartbeatManager`'s four hand-built cron events are gone; it builds synthetic `CronJob`/`CronRun` structs and calls `LemonAutomation.Events`, so both emitters produce one payload shape. Timer heartbeats consequently gain `job_name`, `router_run_id`, `agent_id` and `session_key`, which they never carried before. |

**Typing (§5 stages):**

| Stage | Topic / type | Status |
|---|---|---|
| S1 | `LemonCore.Events` registry, `Events.Payload` macro, `Access` shim, `Bus.broadcast_event/4` | done |
| S2 | `routing_feedback` | done — publisher and consumer both typed, consumer keeps a legacy-map clause |
| S3 | `goals` | done |
| S4 | `system` (`:config_reloaded`, `:config_reload_failed`, `:secret_changed`, `:talk_mode_changed`) | done |
| S5 | `cron` (7 types) | done |
| S6 | `exec_approvals` (3 types incl. `ApprovalPending`) | done — also aligned the control-plane publisher, which used `created_at_ms` where core uses `requested_at_ms` and omitted the top-level `approval_id` |
| S7 | `:run_phase_changed` | done — `LemonCore.RunPhaseEvent` now delegates to `Events.RunPhaseChanged` and is deprecated |
| S8–S11 | `run:*` — `:run_started`, `:delta`, `:engine_action`, `:run_completed`, `:run_failed` | done |
| S12 | `session:*` | follows from S8–S11 (the router forwards the same events). `:coalesced_output` is still an unenveloped raw map |
| S13 | Remove the `Access` shim | next major |

**Contract kit:** `LemonPlatformTest.EventsCase` asserts registry completeness, `from_map/1`
round-trip and string-key acceptance, strict `new/1`, Introspection parity between struct and
map payloads, JSON encodability, `broadcast_event/4` envelope discipline **under both bus
backends**, and that the `Access` shim carries a deprecation note. It runs against the
platform's own registry at
`apps/lemon_platform_test/test/compliance/core_events_test.exs`.

**Two design decisions that changed during implementation:**

1. **Payloads derive `Jason.Encoder`.** Not in the original design. The JSONL store backend
   encodes with Jason and the approval `pending` record is persisted, so a bare struct would
   have raised `Protocol.UndefinedError` there. `jason` is a hard dependency of `lemon_core`,
   so deriving is free.
2. **`EventBridge`'s 26 `Access`-reading clauses were left alone.** The shim carries them
   unchanged — verified by 770 control-plane, 1072 gateway, 547 router, 3958 coding_agent and
   201 automation tests passing with no consumer edits. What *was* added is the diagnostic the
   design asked for: the catch-all now warns once per event type when a type in
   `Events.registry/0` reaches it unmapped, so a missing mapping stops being silent. Converting
   those clauses to struct patterns — the change that makes a field rename a compile error — is
   the remaining work in this area and is worth its own pass.

**Phase B — the remaining pre-work, landed after the design was accepted:**

| Item | What changed |
|---|---|
| P4 (§6.8) | **Validate, don't ban.** Both injectors keep their full allowlist, but a type registered in `LemonCore.Events` must now supply a payload that coerces into its struct or the call is refused with `{:invalid_request, ...}` naming the coercion failure. A well-formed injection still works and is indistinguishable from a real event — which is the point — while a malformed `run_completed` never reaches a subscriber. Unregistered types (`shutdown`, `tick`, node/device pairing, `custom_*`) have no declared shape and keep their pass-through behaviour. Implemented with a new `LemonCore.Events.cast/2`, the strict counterpart to `coerce/2`. |
| P6 (§6.11) | The `kanban` and `kanban:<board_id>` broadcasts are deleted — zero subscribers repo-wide, and the durable record was always the `Introspection.record/3` call beside them, which stays. The `LemonCore.Bus` moduledoc's topic contract is rewritten: it now separates the seven typed contract topics from the app-internal ones, and says plainly that `channels` and `logs` never had a publisher. |
| §6.4 | The gateway no longer publishes `:run_phase_changed`; `LemonRouter.PhasePublisher` is the single publisher, since the router owns the phase graph. The gateway keeps tracking and validating its own transitions (`maybe_track_phase/2`) because that is what surfaces an out-of-order phase in its logs — it just no longer broadcasts a duplicate. |
| §6.2 | `LemonGateway.DependencyManager.build_event/3`'s unreachable `{event_type, payload}` tuple fallback is gone, and with it the tuple receive clauses in `RunCompletionWaiter` and `webhook/response.ex` that existed only to catch it. `RunCompletionWaiter` also loses its two envelope-less `%{completed: ...}` clauses and its two pre-P1 `:run_failed` shapes, going from seven receive clauses to four. The remaining bare-map clauses (`%{type: ..., payload: ...}`) are kept deliberately: an envelope-less map is the documented legacy shape and stays accepted for one cycle, whereas a tuple never was. |
| §6.7 | `:acp_client_request` stays out of the registry. Converting it from a broadcast to a direct call is filed as its own task. |

**Two bugs the validate-or-reject work surfaced in the Phase A code, both now fixed:**

1. **Overridden `from_map/1` never ran.** `LemonCore.Events.Payload` defines a generic
   `from_map/1` that matches any map, so the custom clauses in `RunCompleted`,
   `EngineAction`, `Action` and the two approval payloads — the ones that coerce a *nested*
   payload — were shadowed and dead. A `run_completed` arriving as JSON kept its `completed`
   field as a raw map, and `EngineAction` never normalised `phase`/`kind` to atoms. The kit's
   round-trip assertion missed it because `Map.from_struct/1` on a well-formed struct already
   contains the nested struct, so the generic clause happened to produce an equal result. Fixed
   with `defoverridable from_map: 1, new: 1`; the kit gained a nested-coercion assertion that
   feeds each payload a fully flattened map, which does catch it.
2. **`false` collapsed to `nil`.** The `get_field/2` helper in `Action` and `EngineAction` used
   `Map.get(attrs, :key) || Map.get(attrs, "key")`, which reads atom-or-string keys correctly
   for everything except `false` — so an engine action's `ok: false`, the flag that says the
   action *failed*, silently became `nil`. Caught by `LemonGateway.RunTest`. Fixed with
   `Map.fetch/2`, plus a kit assertion that round-trips every payload with its booleans
   falsified.

Bug 3's fix gained the regression test the design asked for:
`bus_registry_fallback_test.exs` now asserts `running?/0` follows the *active* backend rather
than `LemonCore.PubSub`, and that a typed struct payload survives `broadcast_event/4` intact
under the Registry fallback.

**Still open:**

- **Test-side fixtures.** The 144 `Bus.broadcast` sites in `test/` still build raw maps. They
  all pass, because consumers accept both, but `LemonPlatformTest.EventsFixtures` was not
  written and tests were not converted.
- **`EventBridge`'s 26 `Access`-reading clauses.** Still map-based; the shim carries them. The
  conversion to struct patterns — which is what turns a field rename into a compile error — is
  the last substantive piece before the shim can be removed in S13.
- **`:coalesced_output`** is still published as an unenveloped raw map on `session:<key>`.

**Known in-flight at time of writing:** the Farcaster transport deletion (task #29) has landed —
`apps/lemon_gateway/lib/lemon_gateway/transports/` now holds only `email` and `webhook`, and
neither Farcaster nor the email port appears anywhere in this catalog (Farcaster never used the
Bus; the email adapter at `apps/lemon_channels/lib/lemon_channels/adapters/email/` has no Bus
call sites). The email port (task #27) is therefore not expected to change any row above. The one
row that would move is webhook's `run:<id>` subscription (`transports/webhook/response.ex`), if
webhook is ever relocated — per `transport-unification.md` §1 it stays in the gateway, so it
should not be.
