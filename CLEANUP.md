# Cleaning up Lemon
## Current codebase map

### Umbrella layout (apps + dependency edges)

```text
apps/
  lemon_core
  ai                -> lemon_core
  agent_core        -> ai, lemon_core
  lemon_channels    -> lemon_core
  lemon_skills      -> lemon_core, agent_core, ai, lemon_channels
  coding_agent      -> agent_core, ai, lemon_skills, lemon_core
  lemon_gateway     -> agent_core, coding_agent, lemon_channels, lemon_core
  lemon_router      -> lemon_core, lemon_gateway, lemon_channels, coding_agent, agent_core
  lemon_automation  -> lemon_core, lemon_router
  lemon_control_plane -> lemon_core, lemon_router, lemon_channels, lemon_skills, lemon_automation, coding_agent, ai
  lemon_web         -> lemon_core, lemon_router
  coding_agent_ui   -> coding_agent
  market_intel      -> lemon_core, agent_core, lemon_channels
  lemon_services    -> (no umbrella deps; also no references from other apps)
```

A useful way to read that graph:

```text
            ┌──────────┐
            │lemon_core│  (config/store/bus/secrets/ids/quality)
            └────┬─────┘
                 │
     ┌───────────┼─────────────────────────────┐
     │           │                             │
   ┌─▼─┐       ┌─▼────────┐                  ┌─▼──────────┐
   │ai │       │lemon_channels│              │lemon_router │
   └─┬─┘       └─────┬────┘                  └─────┬──────┘
     │               │                              │
┌────▼────┐      ┌──▼────────┐                 ┌───▼────────┐
│agent_core│     │lemon_skills│                 │lemon_gateway│
└────┬────┘      └────┬──────┘                 └────┬───────┘
     │                 │                             │
┌────▼──────┐          │                             │
│coding_agent│─────────┘                             │
└────┬──────┘                                        │
     │                                                 │
┌────▼──────────────┐                       ┌──────────▼──────────┐
│lemon_control_plane │                       │lemon_web (Phoenix UI)│
└────────────────────┘                       └──────────────────────┘
```

---

### App-by-app “what lives where” map

#### `lemon_core` (foundation layer)

**Role:** shared primitives + runtime infrastructure every other app leans on.

**Core modules / subdomains**

```text
lemon_core/
  bus.ex                   # PubSub wrapper + topics conventions
  config.ex                # TOML-based config load + modularization
  config_cache.ex          # ETS cache for config, used across apps
  config_reloader/*        # filesystem watcher + reload pipeline
  secrets/*                # secret lookup + resolution strategy
  store.ex + store/*       # pluggable KV store + sqlite/jsonl/ets backends
  event.ex                 # Event envelope type for PubSub
  event_bridge.ex          # dynamic dispatch for event subscribers (configured by control_plane)
  router_bridge.ex         # dynamic dispatch for router calls (configured by lemon_router)
  exec_approvals.ex        # exec approval persistence & checks
  idempotency/*, dedupe/*  # generic dedupe/idempotency helpers
  quality/*                # architecture boundary check, etc.
```

**Supervision (from `LemonCore.Application`)**

* `Phoenix.PubSub` (named `LemonCore.PubSub`)
* `LemonCore.ConfigCache`
* `LemonCore.Store`
* `LemonCore.ConfigReloader`
* `LemonCore.ConfigWatcher`
* `LemonCore.LocalServer` (lightweight local coordination)

---

#### `ai` (LLM provider abstraction)

**Role:** provider adapters, request/response normalization, model registry.

**Core modules / subdomains**

```text
ai/
  models/*                 # provider-specific model registries (already decomposed)
  providers/*              # HTTP adapters (OpenAI, Anthropic, Bedrock, etc.)
  auth/*                   # key resolution helpers
  lib/*                    # shared types + high-level APIs
```

---

#### `agent_core` (agent runtime + CLI runners)

**Role:** agent loop primitives, abort signal, CLI-runner abstraction and event types.

**Core modules / subdomains**

```text
agent_core/
  agent.ex                 # primary agent orchestration
  loop/*                   # agent loop helpers
  abort_signal/*           # cooperative cancellation
  cli_runners/*            # jsonl runner, parsers, types (ResumeToken, events, etc.)
  tool-related helpers     # (varies)
```

---

#### `coding_agent` (the “native lemon” engine implementation)

**Role:** interactive coding agent session state machine + tools + compaction + WASM.

**Core modules / subdomains**

```text
coding_agent/
  session.ex               # big GenServer (streaming, compaction, wasm lifecycle, serialization)
  session_manager.ex       # supervises sessions, routing, etc.
  compaction.ex            # summarization/compaction logic
  tools/*                  # large tool surface (websearch, task, fuzzy, etc.)
  wasm/*                   # wasm sidecar + tool building
  cli_runners/*            # LemonRunner etc used by lemon_gateway engines
  security/*               # execution safety helpers
```

---

#### `lemon_skills` (tools/skills that span agents)

**Role:** reusable “skills” exposed to agents; some overlap with `coding_agent/tools`.

**Core modules / subdomains**

```text
lemon_skills/
  tools/*                  # PostToX, GetXMentions, etc.
  http_client/*            # http client wrappers (currently duplicative with lemon_core/httpc)
  discovery/*              # skill discovery/registry
```

---

#### `lemon_channels` (inbound/outbound IO)

**Role:** transport adapters + outbox delivery, rate-limit, dedupe, formatting helpers.

**Core modules / subdomains**

```text
lemon_channels/
  adapters/
    telegram/transport.ex  # very large; poller + commands + files + voice + routing
    discord/transport.ex
    xmtp/*                 # PortServer + bridge
    x_api/*                # X/Twitter client helpers
  outbox/*                 # enqueue, delivery, dedupe, rate limiter
  telegram/*               # API/markdown/truncate helpers used by telegram adapter
  registry.ex              # capabilities lookup (e.g., supports_edit?)
  gateway_config.ex        # reads LemonCore.Config + runtime overrides
  binding_resolver.ex      # maps ChatScope -> agent_id/cwd/engine/etc
  types.ex                 # ChatScope, ResumeToken
```

---

#### `lemon_gateway` (execution gateway + engines)

**Role:** job scheduler + run runner + engine abstraction; also contains legacy/optional “transport” code.

**Core modules / subdomains**

```text
lemon_gateway/
  scheduler.ex             # concurrency + queue/lane execution
  run.ex                   # run lifecycle, emits events to LemonCore.Bus
  engines/*                # lemon/codex/claude/opencode/pi/... via AgentCore.CliRunners
  engine_registry.ex       # engine module registry + resume helpers
  config.ex + config_loader.ex # gateway-local config wrapper (overlaps lemon_core config)
  binding_resolver.ex      # maps ChatScope/bindings/projects (overlaps channels)
  types.ex                 # Job, ChatScope, ResumeToken (overlaps channels/agent_core)
  telegram/*               # legacy Telegram API/outbox/startup notifier (duplicates channels)
  transports/*             # webhook/email/voice/xmtp/etc (some unused by default)
  sms/*, voice/*           # Twilio/webhooks, voice call session, etc.
  store/*                  # duplicate store backends (largely unused; lemon_gateway/store.ex delegates to lemon_core)
```

---

#### `lemon_router` (orchestration + session/run lifecycle)

**Role:** central “brain” that accepts inbound requests, resolves agent profile/tool policy, schedules a run, and shapes output.

**Core modules / subdomains**

```text
lemon_router/
  router.ex                # entrypoints: submit/abort/etc
  run_orchestrator.ex      # chooses engine/model/policy; starts RunProcess
  run_process.ex           # long-lived process per run (state machine)
  run_supervisor.ex        # dynamic supervisor for runs
  stream_coalescer.ex      # subscribes to run events; turns into channel-friendly output
  tool_status_coalescer.ex # tool-call UI shaping
  channels_delivery.ex     # bridges to lemon_channels outbox + telegram fallback behavior
  agent_profiles.ex        # loads per-agent config from lemon_core config
  sticky_engine.ex         # keeps engine consistent per session
  policy.ex                # tool policy merge logic
```

---

#### `lemon_control_plane` (HTTP/WebSocket API)

**Role:** external control surface (WS protocol + “methods”) + event streaming.

**Core modules / subdomains**

```text
lemon_control_plane/
  http/*                   # Plug/Bandit router
  ws/*                     # WebSock adapter
  protocol/*               # request/response encode/decode
  methods/*                # one-file-per-method (large surface area)
  event_bridge.ex          # attaches LemonCore.EventBridge to WS subscribers
  auth/*                   # token checks
  presence.ex              # presence tracking
```

---

#### `lemon_web` (Phoenix LiveView UI)

**Role:** web UI that subscribes to bus events and submits prompts to router.

**Key integration points**

* subscribes to `LemonCore.Bus.session_topic(session_key)`
* calls `LemonRouter.submit/1` on user submit
* renders tool calls using `:engine_action` payloads

---

#### `lemon_automation` (cron + automation)

**Role:** scheduled triggers that call router runs.

---

#### `market_intel` (data ingestion + AI commentary)

**Role:** ingestion workers + commentary generation + optional X posting via lemon_channels.

---

#### `lemon_services` (service/agent runner management)

**Status in this repo:** appears *unreferenced* by other apps (no imports/uses found), and not mentioned in root docs/configs. Strong candidate for removal or reintegration.

---

### Runtime “happy path” flow map

#### 1) Inbound message -> run -> outbound message

```text
Telegram/Discord/XMTP inbound
  -> lemon_channels.adapters.*.transport
     - parse inbound message
     - build ChatScope
     - BindingResolver.resolve_* (agent_id/cwd/engine/queue_mode)
     - LemonCore.RouterBridge.submit_run/handle_inbound (dynamic dispatch)
  -> lemon_router.Router / RunOrchestrator
     - AgentProfiles (config)
     - Policy merge
     - engine selection + sticky engine
     - starts RunProcess
  -> lemon_gateway.Scheduler
     - schedules Job in lane/queue_mode
     - starts LemonGateway.Run
  -> lemon_gateway.Engines.*
     - usually a CliRunner (AgentCore or CodingAgent runner)
     - emits streaming events
  -> LemonGateway.Run broadcasts to LemonCore.Bus:
     - run_topic(run_id)
     - session_topic(session_key)
  -> lemon_router.StreamCoalescer subscribes to run_topic(run_id)
     - coalesces deltas/tool events
     - builds LemonChannels.OutboundPayload
     - LemonChannels.Outbox.enqueue(...)
  -> lemon_channels.outbox.delivery -> adapter delivery -> transport APIs
```

#### 2) Control plane streaming

```text
WS client connects
  -> lemon_control_plane.ws.Connection
  -> method calls to query/submit runs
  -> subscribes to run events via LemonCore.EventBridge
  -> pushes serialized events back over WS
```

---

## Where complexity has grown (redundancies + overengineering)

I’m going to call out the highest-leverage “untangling” points: places where you’re paying ongoing complexity tax (duplication, type conversions, legacy fallbacks) rather than “large file but coherent domain”.

### 1) Telegram stack exists twice (`lemon_gateway/telegram/*` vs `lemon_channels/telegram/*`)

You have parallel implementations of:

```text
telegram/api.ex
telegram/formatter.ex
telegram/markdown.ex
telegram/offset_store.ex
telegram/poller_lock.ex
telegram/transport_shared.ex
telegram/trigger_mode.ex
telegram/truncate.ex
```

…under **both** `LemonGateway.Telegram.*` and `LemonChannels.Telegram.*`.

**What this costs:**

* drift risk (features fixed in one copy don’t land in the other)
* duplicated tests
* more complicated startup (gateway still has telegram-only supervision special cases)

**What I found in-code:**

* `LemonGateway.Telegram.*` is referenced only by gateway’s own application/supervisor and by a couple of lemon_channels tests asserting legacy processes *don’t* start.
* The “new path” for telegram IO is clearly `LemonChannels.Adapters.Telegram.Transport`.

**Simplify:**

* make **`lemon_channels`** the single owner of telegram code.
* delete `apps/lemon_gateway/lib/lemon_gateway/telegram/` + remove `StartupNotifier` + remove telegram special-case in `TransportSupervisor`.

If you still need “startup notification”, re-implement it in channels as an outbox send (so you don’t need a separate telegram API copy).

---

### 2) XMTP bridge exists twice (gateway transport vs channels adapter)

You have near-identical modules:

```text
LemonGateway.Transports.Xmtp.{PortServer, Bridge}
LemonChannels.Adapters.Xmtp.{PortServer, Bridge}
```

Plus the node script currently lives in `lemon_gateway/priv/xmtp_bridge.mjs`, while channels has fallback logic to find that script.

**Simplify:**

* move `xmtp_bridge.mjs` (and its package metadata if still needed) to `apps/lemon_channels/priv/`
* delete gateway’s `transports/xmtp/*`
* channels becomes canonical XMTP owner (matching the overall “channels own IO” direction)

---

### 3) “Gateway config” is implemented 3 different ways

* `LemonCore.Config` and `LemonCore.Config.Gateway` already define a typed gateway struct.
* `LemonChannels.GatewayConfig` wraps `LemonCore.Config.cached/1` + store overrides.
* `LemonGateway.Config` + `ConfigLoader` re-parses + layers on top again (and then gateway code uses that).

This is a classic source of “why does it behave differently here?” incidents.

**Simplify:**
Make **one** public API for “gateway-ish config view” and use it everywhere.

Concretely: add a single module in `lemon_core`, then delete both per-app wrappers.

Example:

```elixir
defmodule LemonCore.GatewayConfig do
  @moduledoc """
  Single source of truth for gateway+channels config view.
  Combines:
    - LemonCore.Config.cached(cwd).gateway (typed struct)
    - runtime overrides from LemonCore.Store
  """

  alias LemonCore.{Config, Store}
  alias LemonCore.Config.Gateway

  @overrides_table :gateway_config_overrides

  @spec load(String.t() | nil) :: Gateway.t()
  def load(cwd \\ nil) do
    base = Config.cached(cwd).gateway || %Gateway{}
    overrides = Store.get(@overrides_table, cwd || :global) || %{}
    merge_gateway(base, overrides)
  end

  defp merge_gateway(%Gateway{} = base, overrides) when is_map(overrides) do
    # keep this boring and explicit; avoid deep magic merges
    %Gateway{
      base
      | enable_telegram: Map.get(overrides, :enable_telegram, base.enable_telegram),
        enable_discord: Map.get(overrides, :enable_discord, base.enable_discord),
        default_engine: Map.get(overrides, :default_engine, base.default_engine),
        bindings: Map.get(overrides, :bindings, base.bindings),
        projects: Map.get(overrides, :projects, base.projects)
    }
  end
end
```

Then:

* `LemonChannels.GatewayConfig.get/2` becomes `LemonCore.GatewayConfig.load/1` call(s)
* `LemonGateway.Config.*` becomes either deleted or reduced to a tiny compatibility shim that calls core

---

### 4) Binding resolution is duplicated + you’re carrying dual store tables for back-compat

You currently have:

* `LemonGateway.BindingResolver` with tables `:gateway_project_overrides`, `:gateway_projects_dynamic`
* `LemonChannels.BindingResolver` with tables `:channels_project_overrides`, `:channels_projects_dynamic`
* telegram adapter writes to **both** sets of tables to keep legacy readers alive

That’s *pure complexity tax*.

**Simplify:**

* create a single binding resolver in **lemon_core**, and a single set of tables.
* update both router + channels to call the same resolver.
* delete the dual-write back-compat code.

Example direction:

```elixir
defmodule LemonCore.ChatScope do
  defstruct [:transport, :chat_id, :topic_id]
  @type t :: %__MODULE__{transport: atom(), chat_id: integer(), topic_id: integer() | nil}
end

defmodule LemonCore.Binding do
  defstruct [:transport, :chat_id, :topic_id, :project, :agent_id, :default_engine, :queue_mode]
  @type t :: %__MODULE__{...}
end

defmodule LemonCore.BindingResolver do
  alias LemonCore.{Binding, ChatScope, GatewayConfig, Store}

  @project_overrides :project_overrides
  @dynamic_projects  :projects_dynamic

  def resolve_binding(%ChatScope{} = scope) do
    GatewayConfig.load().bindings
    |> List.wrap()
    |> pick_most_specific(scope)
    |> normalize()
  end

  def get_project_override(%ChatScope{} = scope),
    do: Store.get(@project_overrides, scope)

  def put_project_override(%ChatScope{} = scope, project_id),
    do: Store.put(@project_overrides, scope, project_id)

  def put_dynamic_project(id, attrs),
    do: Store.put(@dynamic_projects, id, attrs)

  # etc...
end
```

Then:

* delete `LemonGateway.BindingResolver` and `LemonChannels.BindingResolver`
* remove telegram transport dual writes
* router/orchestrator and channels adapters call core resolver uniformly

---

### 5) Resume token / engine-id parsing exists in at least 3 shapes (plus conversions)

You have:

* `LemonChannels.Types.ResumeToken` + `LemonChannels.EngineRegistry.extract_resume/1`
* `LemonGateway.Types.ResumeToken` + engine callback expectations
* `AgentCore.CliRunners.Types.ResumeToken` (most complete parsing/formatting)

And `LemonRouter.RunOrchestrator` currently imports both channels resume token types **and** agent_core resume token types.

That’s a red flag: *single concept, multiple structs, glue code everywhere*.

**Simplify:**
Pick one canonical resume token type (best home: `lemon_core`) and make everyone use it.

```elixir
defmodule LemonCore.ResumeToken do
  defstruct [:engine, :value]
  @type t :: %__MODULE__{engine: String.t(), value: String.t()}
end
```

Then:

* `AgentCore.CliRunners.Types` can `alias LemonCore.ResumeToken` (or wrap it)
* `LemonChannels.EngineRegistry` becomes a thin facade over the canonical parser
* `LemonGateway.Engine` callback types use `LemonCore.ResumeToken.t()`

Bonus: you can move “engine known IDs” to core too, and stop duplicating default engine lists in multiple places.

---

### 6) Engine event types are translated unnecessarily

Gateway converts CLI runner events into `LemonGateway.Event.*` structs, then immediately converts them to maps for PubSub payloads.

That’s extra moving pieces:

* `AgentCore.CliRunners.Types.*Event`
* `LemonGateway.Event.*`
* map payloads on the bus

**Simplify options (choose one):**

**Option A (fast):** drop `LemonGateway.Event` structs entirely; use CLI runner event structs as “internal” events; keep only map emission to bus.

* removes a whole translation layer (`CliAdapter` gets much smaller)

**Option B (best):** define `LemonCore.EngineEvent` types (or a single `%EngineEvent{kind, payload}`) and have both CLI runners and gateway engines emit that.

Either way, eliminate “struct A -> struct B -> map”.

---

### 7) Router is doing channel-specific rendering/shaping (coupling router ↔ channels)

`lemon_router/stream_coalescer.ex` and `channels_delivery.ex` have deep knowledge of telegram truncation, edit support, payload shaping, etc.

This makes it hard to:

* add a channel without touching router
* change delivery behavior without re-testing orchestration logic

**Desired simplification direction:**

* router produces *generic run events* + a stable “output intent” stream
* channels owns formatting + delivery decisions per adapter

To do that, bus events need enough routing metadata (session_key + chat scope / channel binding) so channels can deliver without router hand-holding. Right now, gateway bus meta contains `origin` + `session_key`, but not necessarily a complete “where to deliver” identity.

---

### 8) Several “big files” are monoliths that are begging to be split by concern

These are not inherently “bad”, but they’re where iteration slows down:

* `lemon_channels/adapters/telegram/transport.ex` (~5.5k LOC)
* `coding_agent/session.ex` (~3.3k LOC)
* `lemon_router/run_process.ex` (~2.4k LOC)
* `lemon_router/stream_coalescer.ex` (~1.3k LOC)
* `lemon_gateway/transports/webhook.ex` (~1.5k LOC)

Splitting these into ~5–10 “boring” modules each will reduce incidental complexity a lot (compile time, diff review, mental load), without changing architecture.

---

### 9) `lemon_services` looks dead (or at least unintegrated)

No other app depends on or references it; it’s not in configs/docs.

**Simplify:**

* either remove it from umbrella (and delete)
  **or**
* wire it into control plane methods and make it real.

Right now it’s “extra surface area” without payoff.

---

## A concrete “untangling” plan (high leverage first)

Here’s the ordering I’d do to remove complexity without destabilizing runtime:

### Phase 1: delete obvious dead duplication (low risk)

1. Remove gateway store backend duplicates:

* delete `apps/lemon_gateway/lib/lemon_gateway/store/*` backends (keep `lemon_gateway/store.ex` shim or delete it too and use `LemonCore.Store` directly)
* confirm no references (they appear unused)

2. Remove gateway XMTP transport duplicate:

* delete `apps/lemon_gateway/lib/lemon_gateway/transports/xmtp/*`

3. Remove gateway telegram stack (after re-homing startup notifier if desired):

* delete `apps/lemon_gateway/lib/lemon_gateway/telegram/*`
* remove `StartupNotifier` child + `TransportSupervisor` telegram outbox special case
* keep telegram only in `lemon_channels`

### Phase 2: unify shared primitives in `lemon_core` (medium risk, big payoff)

4. Introduce canonical types in core:

* `LemonCore.ChatScope`
* `LemonCore.ResumeToken`
* (optional) `LemonCore.EngineId` utilities

5. Move binding resolution into core (and unify store tables):

* `LemonCore.BindingResolver`
* unify tables: `:project_overrides`, `:projects_dynamic`
* update channels + router + gateway to stop writing to legacy tables

6. Unify gateway/channels config view:

* `LemonCore.GatewayConfig.load/1`
* delete `LemonChannels.GatewayConfig` and `LemonGateway.Config`/`ConfigLoader`

### Phase 3: reduce glue layers (higher leverage, needs more testing)

7. Standardize engine event types:

* eliminate `LemonGateway.Event` translation layer or replace with core `EngineEvent`

8. Decouple router from channel formatting:

* move StreamCoalescer + ToolStatusCoalescer responsibilities into channels (or a dedicated “delivery” app)
* ensure bus meta includes routable identity (session_key + chat scope / channel binding)

### Phase 4: “monolith file” decomposition (safe refactors)

9. Break up:

* `telegram/transport.ex` into `transport/poller.ex`, `transport/commands.ex`, `transport/files.ex`, `transport/messages.ex`, `transport/routing.ex`, etc.
* `coding_agent/session.ex` into `session/{serialization,wasm_lifecycle,compaction_lifecycle,model_resolver,background_tasks}.ex`
* `run_process.ex` into `run_process/{state,transitions,io,telemetry}.ex`

---

## Desired end-state map

### End-state dependency graph (cleaner boundaries, fewer cross-layer leaks)

```text
lemon_core
  ├─ provides: config/cache/store/bus/secrets + shared domain primitives:
  │    - GatewayConfig
  │    - ChatScope / Binding / ResumeToken / EngineId helpers
  │    - ToolPolicy (optional, shared)
  │    - BindingResolver (single implementation + single tables)

ai -> lemon_core
agent_core -> ai, lemon_core
coding_agent -> agent_core, ai, lemon_core (+ lemon_skills if you keep it separate)
lemon_skills -> lemon_core, agent_core, ai, lemon_channels   (or merged into coding_agent)

lemon_channels -> lemon_core
  └─ owns ALL IO adapters (telegram/discord/xmtp/x_api/…)
     - includes xmtp_bridge.mjs in its own priv/
     - owns telegram API/markdown/truncate (single copy)
     - consumes LemonCore.{GatewayConfig, BindingResolver, ResumeToken}

lemon_gateway -> lemon_core, agent_core, coding_agent
  └─ pure “execution gateway”
     - scheduler/run/engines/tools/voice/sms
     - NO telegram/*, NO xmtp transport duplicate, NO config loader duplicate
     - uses LemonCore.ResumeToken + shared engine-id parsing
     - emits LemonCore.Event with routable meta

lemon_router -> lemon_core (and optionally lemon_gateway)
  └─ pure orchestration + session/run lifecycle
     - minimal/no channel-format knowledge
     - does NOT depend on lemon_channels for types/formatting
     - bus events carry enough meta so channels can deliver

lemon_control_plane -> lemon_core, lemon_router, lemon_gateway (+ ai/skills/automation as needed)
lemon_web -> lemon_core, lemon_router  (or uses control_plane API only)
lemon_automation -> lemon_core, lemon_router
market_intel -> lemon_core, agent_core, lemon_channels

(remove or integrate lemon_services)
```

### End-state module placement (what moves where)

```text
apps/lemon_core/lib/lemon_core/
  gateway_config.ex           # NEW: unified config accessor for gateway+channels
  chat_scope.ex               # NEW: canonical ChatScope type
  resume_token.ex             # NEW: canonical ResumeToken type + parsing/formatting
  binding.ex                  # NEW: canonical Binding struct
  binding_resolver.ex         # NEW: single resolver + single store tables
  tool_policy.ex              # NEW (optional): canonical tool policy + merge/eval helpers
  httpc.ex                    # canonical HTTP client (others deleted)
  config/*, store/*, bus.ex   # existing

apps/lemon_channels/
  lib/lemon_channels/
    adapters/*                # telegram/discord/xmtp/x_api…
    outbox/*                  # unchanged
    telegram/*                # single copy lives here
    (delete binding_resolver.ex, gateway_config.ex, types.ex)
  priv/xmtp_bridge.mjs        # moved from lemon_gateway

apps/lemon_gateway/
  lib/lemon_gateway/
    scheduler.ex, run.ex, engines/*, tools/*, voice/*, sms/*
    (delete telegram/*, transports/xmtp/*, store/* backends, config_loader/config)
    engine_event.ex?          # (optional) if you keep gateway-specific event types; ideally no
    types.ex                  # only Job-related types; shared types moved to lemon_core

apps/lemon_router/
  lib/lemon_router/
    router.ex, run_orchestrator.ex, run_process.ex
    (move stream_coalescer/tool_status_coalescer into lemon_channels delivery pipeline
     OR keep them but remove direct channel-format knowledge and rely on channels APIs)
```

### End-state runtime flow (clean separation)

```text
Inbound (channels)
  -> Adapter parses + builds LemonCore.ChatScope
  -> LemonCore.BindingResolver resolves agent_id/cwd/engine/queue_mode
  -> RouterBridge.submit_run (router)

Execution (router + gateway)
  -> router schedules job in gateway
  -> gateway runs engine, emits LemonCore.Event with meta:
       %{run_id, session_key, chat_scope, channel_id, peer_id, ...}

Outbound (channels)
  -> channels subscribes to run events (Bus) by run_id/session_key
  -> delivery pipeline coalesces + formats per adapter capabilities
  -> outbox delivers
```

That end-state removes the biggest sources of accidental complexity:

* no duplicate telegram/xmtp stacks
* no triple “gateway config” implementations
* one binding resolver, one set of override tables
* one resume token type
* router stops being a “telegram formatting module” and becomes orchestration-only

---

## Current Status (Manager Updates)

**Last updated:** 2026-02-25 (Phases 1+2+4 COMPLETE, 3a COMPLETE, 3b NOT STARTED)

### Overall Progress

| Phase | Description | Status | Progress |
|-------|-------------|--------|----------|
| **Phase 1** | Delete dead duplication | COMPLETE | 3/3 tasks |
| **Phase 2** | Unify shared primitives | COMPLETE | 3/3 tasks |
| **Phase 3** | Reduce glue layers | PARTIAL | 3a done, 3b not started |
| **Phase 4** | Monolith decomposition | COMPLETE | 3/3 tasks |

### Active Tasks

| Task | Assignee | Status | Notes |
|------|----------|--------|-------|
| 3b: Decouple router from channels | Opus senior dev | NOT STARTED | Unblocked by 3a completion |

### Completed Tasks

| Task | Assignee | Summary |
|------|----------|---------|
| 1a: Gateway store backends | Sonnet dev | Deleted 5 lib + 4 test files, updated 15+ refs to LemonCore.Store |
| 1b: Gateway XMTP transport | Sonnet dev | Deleted 3 stub files, copied xmtp_bridge.mjs to channels priv |
| 1c: Gateway telegram stack | Sonnet dev | Deleted 11 lib + 22 test files, cleaned supervisor tree |
| 2a: Canonical types | Opus dev | Created LemonCore.{ChatScope,ResumeToken,Binding}, updated 89 files |
| 2b: Unify BindingResolver | Opus dev | Created LemonCore.BindingResolver, unified 4 tables → 2, thin delegation wrappers |
| 2c: Unify GatewayConfig | Opus dev | Created LemonCore.GatewayConfig, simplified config_loader + channels gateway_config |
| 3a: Standardize engine events | Opus dev | Replaced 4 Event structs with plain map constructors + defguards |
| 4a: Decompose telegram transport | Opus dev | 5,550 -> 4,372 LOC, extracted 5 modules |
| 4b: Decompose session.ex | Opus dev | 3,398 -> 2,129 LOC, extracted 5 modules |
| 4c: Decompose run_process.ex | Opus dev | 2,438 -> 689 LOC, extracted 4 modules (Watchdog, CompactionTrigger, RetryHandler, OutputTracker) |

### Remaining Work

- **3b: Decouple router from channel formatting** — Move telegram-specific logic out of StreamCoalescer and ChannelsDelivery. Router produces generic output intents; channels owns formatting.

See [CLEANUP_WORKLOG.md](CLEANUP_WORKLOG.md) for detailed per-task logs.
