I’d grade the attempt like this:

| Phase                                                      |                                                         Result |  Grade |
| ---------------------------------------------------------- | -------------------------------------------------------------: | -----: |
| Phase 1: AI boundary extraction                            |                                           Essentially achieved | **A-** |
| Phase 2: Execution DTO moved to core/contracts             |          Mostly achieved, with one important leftover coupling | **B+** |
| Phase 3: Events / async delivery / reasoning normalization | Good functional progress, incomplete architectural convergence | **B-** |
| Phase 4: Gateway/channels ownership cleanup                |                 Channel side improved; gateway still too broad | **C+** |

Overall: **you made real architectural progress, especially in phases 1 and 2.** This is not cosmetic. The new snapshot is materially cleaner. But phases 3 and 4 are still in “implemented useful fixes” territory rather than “finished the architectural migration” territory.

I could not run `mix test` or `mix lemon.quality` because `mix` is not installed in this environment, so this is a static code review of the uploaded snapshot.

---

## Phase 1 — AI boundary extraction

This is the strongest part of the work.

The original goal was:

```bash
rg "\bLemonCore\b" apps/ai/lib
# should return nothing
```

In the new snapshot, that appears to be true. `apps/ai/lib` no longer references `LemonCore`, and `apps/ai/mix.exs` no longer depends on `:lemon_core`.

The current `apps/ai/mix.exs` dependency shape is much healthier:

```elixir
defp deps do
  [
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:nimble_options, "~> 1.1"},
    {:plug, "~> 1.16", only: :test}
  ]
end
```

That is exactly the kind of shape I wanted: `ai` is now plausibly a reusable provider/client library instead of a Lemon-specific integration app.

You also moved Lemon-owned behavior into `lemon_ai_runtime`, which is the right home. I saw `LemonAiRuntime.Credentials`, `LemonAiRuntime.StreamOptions`, and Lemon-specific OAuth facades handling things like secrets, provider config resolution, and local callback listeners. That is the right inversion:

```text
Before:

ai -> lemon_core secrets/config/oauth

After:

lemon_ai_runtime -> lemon_core
lemon_ai_runtime -> ai
ai -> no Lemon dependency
```

That is a major improvement.

One detail I liked: the provider OAuth modules in `apps/ai` still exist, but they appear to be dependency-inverted. Instead of reaching into `LemonCore.Secrets`, they accept persistence/listener callbacks or options. Then `LemonAiRuntime.Auth.*` provides the Lemon-specific facade. That is much better than deleting useful provider logic just to satisfy a grep rule.

The main remaining issue here is documentation drift. The AI boundary extraction plan still reads as though `apps/ai` currently depends on Lemon and still lists “remove `LemonCore.*` calls from `apps/ai`” as the next major step. That was probably true before this implementation, but it is now stale. Update that doc aggressively, because stale migration docs are dangerous in this codebase.

My verdict: **Phase 1 is done enough to count as complete.** The only caveat is that you should update the docs and add CI assertions that prevent regression.

Recommended guardrail:

```bash
rg "\bLemonCore\b" apps/ai/lib && exit 1
rg "ProviderConfigResolver|Secrets|Onboarding" apps/ai/lib && exit 1
```

And at the architecture-policy level:

```elixir
@allowed_direct_deps %{
  ai: []
}
```

You already have `ai: []`, which is excellent.

---

## Phase 2 — execution boundary DTO moved to core/contracts

This is also a real improvement.

You added:

```text
apps/lemon_core/lib/lemon_core/execution_command.ex
apps/lemon_core/lib/lemon_core/engine_runtime.ex
```

`LemonCore.ExecutionCommand` is conceptually right:

```elixir
defmodule LemonCore.ExecutionCommand do
  @moduledoc """
  Queue-semantic-free execution command shared across router/runtime boundaries.
  """

  @enforce_keys [:run_id, :session_key, :prompt, :engine_id]

  defstruct [
    :run_id,
    :session_key,
    :prompt,
    :engine_id,
    :cwd,
    :resume,
    :lane,
    :tool_policy,
    :conversation_key,
    meta: %{}
  ]
end
```

And `LemonCore.EngineRuntime` is also directionally right:

```elixir
defmodule LemonCore.EngineRuntime do
  alias LemonCore.ExecutionCommand

  @callback submit_execution(ExecutionCommand.t()) :: :ok | {:error, term()}
  @callback cancel_by_run_id(binary(), term()) :: :ok
  @callback run_pid(binary()) :: pid() | nil
  @callback available?() :: boolean()
end
```

`LemonGateway.Runtime` now implements that behavior and converts from `ExecutionCommand` into `LemonGateway.ExecutionRequest` internally:

```elixir
def submit_execution(%ExecutionCommand{} = command) do
  command
  |> ExecutionCommand.ensure_conversation_key()
  |> ExecutionRequest.from_command()
  |> LemonGateway.Scheduler.submit_execution()
end
```

That is exactly the right pattern. Gateway can keep a private shape if it wants, but router should hand it the neutral command.

The best evidence that this phase worked: I found no `LemonGateway.ExecutionRequest` references in `apps/lemon_router/lib`. That was one of the major acceptance checks.

However, this phase is not fully complete because router still has direct gateway coupling through `LemonGateway.ChatState`.

I found references like:

```elixir
%LemonGateway.ChatState{last_engine: engine, last_resume_token: token}
```

inside:

```text
apps/lemon_router/lib/lemon_router/resume_resolver.ex
apps/lemon_router/lib/lemon_router/session_coordinator.ex
```

And `apps/lemon_router/mix.exs` still directly depends on `:lemon_gateway`:

```elixir
defp deps do
  [
    {:lemon_core, in_umbrella: true},
    {:lemon_gateway, in_umbrella: true},
    {:lemon_channels, in_umbrella: true},
    {:coding_agent, in_umbrella: true},
    {:agent_core, in_umbrella: true},
    ...
  ]
end
```

So the DTO problem was fixed, but the app-level dependency was not.

The next step should be very concrete: move `ChatState` out of gateway.

For example:

```elixir
defmodule LemonCore.ChatState do
  @moduledoc """
  Router-readable sticky execution state for a session.
  """

  @enforce_keys []
  defstruct [
    :last_engine,
    :last_resume_token,
    :updated_at_ms,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          last_engine: binary() | nil,
          last_resume_token: LemonCore.ResumeToken.t() | binary() | nil,
          updated_at_ms: non_neg_integer() | nil,
          meta: map()
        }
end
```

Then make the store return `%LemonCore.ChatState{}` rather than `%LemonGateway.ChatState{}`.

The target check should be:

```bash
rg "\bLemonGateway\b" apps/lemon_router/lib
# zero results
```

Then remove `:lemon_gateway` from `apps/lemon_router/mix.exs`.

Until that happens, Phase 2 is architecturally improved but not fully finished.

---

## Phase 3 — events, async delivery, and reasoning

This phase improved a lot functionally, but the architecture is still not fully canonical.

### What improved

You added validated constructors to `LemonCore.Event`:

```elixir
def engine_action(payload, meta) when is_map(payload) and is_map(meta) do
  validate_action_payload!(payload)
  new(:engine_action, payload, meta)
end

def reasoning_status(reasoning, meta) when is_map(reasoning) and is_map(meta) do
  ...
  new(:reasoning_status, normalize_reasoning(reasoning), meta)
end
```

You also stopped treating all `:note` events as disposable noise. `ToolStatusCoalescer` now recognizes notes that are actually reasoning and normalizes them into a reasoning action:

```elixir
kind in ["note", :note] ->
  case normalize_note_reasoning(action, ev) do
    {:ok, data} -> {:ok, data.id, data}
    :skip -> {:skip, :note}
  end
```

That is a meaningful fix. Previously, reasoning/status information could simply disappear.

The task runner and task result code also improved. Instead of embedding internal thinking as magic text like:

```text
[thinking] ...
```

you now use structured metadata such as:

```elixir
details: %{
  reasoning: %{
    text: "...",
    source: "assistant_thinking",
    phase: "updated"
  }
}
```

That is a much better design.

The task projection also appears to convert child-task reasoning into parent-surface `engine_action` payloads with:

```elixir
kind: "reasoning",
detail: %{reasoning: %{text: text, source: source, phase: phase}}
```

That is exactly the direction I wanted: reasoning becomes a structured operator-facing status signal, not hidden string convention.

You also made strong async followup improvements:

```text
CustomMessage{custom_type: "async_followup"}
```

is preserved better, projected into LLM context with a provenance wrapper, and preserved through compaction via `extract_async_followup_messages/1`.

The provenance wrapper is a good move:

```elixir
"[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
```

with fields like:

```text
source
task_id
run_id
agent_id
session_key
delivery
delivery_receipt
```

That is materially safer than letting async task output look like a normal user message.

I also like that router delivery stamping now exists in `LemonRouter.SessionTransitions`:

```elixir
receipt =
  %{
    mode: disposition,
    status: status
  }
  |> maybe_put_receipt(:fallback_mode, Keyword.get(opts, :fallback_mode))
  |> maybe_put_receipt(:active_run_id, Keyword.get(opts, :active_run_id))
```

and async followup entries get stamped with:

```elixir
entry
|> Map.put(:delivery, disposition)
|> Map.put(:delivery_receipt, receipt)
```

This addresses a real correctness issue from the previous review: `details.delivery` could drift from actual router behavior.

### What is still incomplete

The big issue: there still is not a truly canonical run event model.

`LemonCore.Event` is still:

```elixir
defstruct [:type, :ts_ms, :payload, :meta]
```

That is better than nothing, but most semantics still live inside payload conventions. There is still no mandatory:

```elixir
:id
:run_id
:session_key
:source
:visibility
:provenance
```

So event consumers still need to know implicit shapes like:

```elixir
event.type == :engine_action
event.payload.action.kind == "reasoning"
event.payload.action.detail.reasoning.text
```

That works, but it is not yet a stable event contract.

The second issue: `reasoning_status/2` exists, but it appears mostly aspirational. Most actual reasoning flow seems to use:

```elixir
:engine_action
kind: "reasoning"
```

That is not necessarily wrong, but the codebase should choose one model.

Either commit to:

```elixir
%LemonCore.Event{
  type: :engine_action,
  payload: %{
    action: %{
      kind: "reasoning",
      detail: %{reasoning: ...}
    }
  }
}
```

or commit to:

```elixir
%LemonCore.Event{
  type: :reasoning_status,
  payload: %{
    text: "...",
    source: "...",
    phase: "..."
  }
}
```

Right now you have both concepts, but only one seems meaningfully wired.

My recommendation: keep `:engine_action` for surface status if that is already integrated, but formalize it. Do not leave `reasoning_status/2` as a dead constructor.

Something like this would be clearer:

```elixir
defmodule LemonCore.RunEvents.EngineAction do
  @kinds ~w(tool command file_change web_search subagent reasoning)a

  def reasoning(run_id, session_key, text, opts \\ []) do
    LemonCore.Event.new(
      :engine_action,
      %{
        action: %{
          id: Keyword.get(opts, :id) || stable_reasoning_id(run_id, text),
          kind: "reasoning",
          title: text,
          detail: %{
            reasoning: %{
              text: text,
              source: Keyword.get(opts, :source, "unknown"),
              phase: Keyword.get(opts, :phase, "updated"),
              truncated: Keyword.get(opts, :truncated, false)
            }
          }
        },
        phase: Keyword.get(opts, :phase, "updated")
      },
      %{
        run_id: run_id,
        session_key: session_key,
        visibility: Keyword.get(opts, :visibility, :operator)
      }
    )
  end
end
```

The third issue: delivery receipt semantics are useful but ambiguous.

Right now the receipt has:

```elixir
%{
  mode: disposition,
  status: status
}
```

But for async followups, what we really need is:

```elixir
%{
  requested_mode: requested_mode,
  actual_mode: actual_mode,
  status: status,
  fallback_mode: fallback_mode,
  active_run_id: active_run_id,
  decided_at_ms: now_ms
}
```

The distinction matters. Example:

```text
requested_mode: :followup
actual_mode: :steer_backlog
status: :dispatched_to_active
```

That tells you what the tool asked for and what the router actually did. The current `mode: disposition` only tells part of the story and can be misread as the requested mode.

I would change this before too many clients depend on the current receipt shape.

Recommended shape:

```elixir
receipt =
  %{
    requested_mode: submission.queue_mode,
    actual_mode: disposition,
    status: status,
    decided_at_ms: LemonCore.Event.now_ms()
  }
  |> maybe_put_receipt(:fallback_mode, Keyword.get(opts, :fallback_mode))
  |> maybe_put_receipt(:active_run_id, Keyword.get(opts, :active_run_id))
```

Then set:

```elixir
entry
|> Map.put(:delivery, disposition)
|> Map.put(:delivery_receipt, receipt)
```

Keeping `delivery` as the actual mode is fine, but the receipt should preserve both.

My verdict: **Phase 3 is a strong functional improvement but not a completed event architecture.** You fixed several symptoms, but the event schema itself remains a bit too informal.

---

## Phase 4 — gateway/channels ownership cleanup

This is the weakest phase, although not a failure.

### What improved

`lemon_channels` is cleaner.

Adapter startup is now config-driven:

```elixir
config :lemon_channels,
  adapters: [
    LemonChannels.Adapters.Telegram,
    LemonChannels.Adapters.Discord,
    LemonChannels.Adapters.Xmtp,
    LemonChannels.Adapters.WhatsApp,
    LemonChannels.Adapters.XAPI
  ]
```

and test config disables default adapters:

```elixir
config :lemon_channels, adapters: []
```

That is much better than hardcoded adapter registration in application startup.

The new `LemonChannels.RunRequestBuilder` is also a good addition. It cleanly converts an inbound channel message into a core run request:

```elixir
RunRequest.new(%{
  origin: :channel,
  session_key: session_key,
  agent_id: agent_id,
  prompt: message_text(msg),
  queue_mode: meta_value(meta, :queue_mode),
  engine_id: meta_value(meta, :engine_id),
  model: meta_value(meta, :model),
  resume: normalize_resume_token(meta_value(meta, :resume)),
  cwd: meta_value(meta, :cwd),
  meta: ...
})
```

And `LemonChannels.Runtime.submit_inbound/1` now does the right high-level thing:

```elixir
inbound
|> LemonChannels.RunRequestBuilder.from_inbound()
|> LemonCore.RouterBridge.submit_run()
```

That is exactly the boundary I wanted:

```text
channel inbound
  -> LemonCore.RunRequest
  -> router bridge
  -> router
```

Not:

```text
channel inbound
  -> gateway execution request
```

So the channel side improved meaningfully.

### What remains wrong

`lemon_gateway` is still too broad.

`LemonGateway.Application` still starts:

```elixir
LemonGateway.TransportRegistry
LemonGateway.TransportSupervisor
LemonGateway.CommandRegistry
LemonGateway.Sms.Inbox
LemonGateway.Sms.WebhookServer
LemonGateway.Voice.CallRegistry
LemonGateway.Voice.DeepgramRegistry
LemonGateway.Voice.CallSessionSupervisor
LemonGateway.Voice.DeepgramSupervisor
LemonGateway.Voice.Server
```

And gateway still contains:

```text
lemon_gateway/sms/*
lemon_gateway/voice/*
lemon_gateway/transports/email*
lemon_gateway/transports/farcaster*
lemon_gateway/transports/webhook*
lemon_gateway/transport_registry.ex
lemon_gateway/transport_supervisor.ex
```

That means gateway is still partly:

```text
execution runtime
+
transport registry
+
SMS app
+
voice app
+
email transport
+
Farcaster transport
+
webhook ingress
```

That is still too much.

The goal was not just “channels submit RunRequest.” The bigger goal was:

```text
lemon_gateway owns engine execution lifecycle only.
lemon_channels owns external user transports and rendering.
```

You improved the `lemon_channels` side, but gateway still has substantial external transport responsibilities.

The next move should be structural.

Recommended target:

```text
lemon_gateway
  EngineRegistry
  EngineLock
  RunRegistry
  RunSupervisor
  ThreadRegistry
  ThreadWorkerSupervisor
  Scheduler
  Runtime
  ExecutionRequest
  Health

lemon_channels
  Telegram
  Discord
  Xmtp
  WhatsApp
  XAPI
  Email, if email is a user transport
  Farcaster, if Farcaster is a user transport
  Webhook, if webhook is user/application ingress

lemon_voice
  Twilio voice
  Deepgram
  Call sessions
  Recording downloads

lemon_sms
  Twilio SMS inbox
  SMS tools
```

A minimal first cleanup would be to remove these from `LemonGateway.Application`:

```elixir
LemonGateway.TransportRegistry
LemonGateway.TransportSupervisor
LemonGateway.CommandRegistry
LemonGateway.Sms.Inbox
LemonGateway.Sms.WebhookServer
LemonGateway.Voice.*
```

and keep only execution-runtime supervision.

If extracting separate apps is too much right now, at least create a transitional app such as:

```text
lemon_gateway_legacy_transports
```

or:

```text
lemon_ingress
```

That would let `lemon_gateway` become execution-only without forcing every transport migration in one PR.

My verdict: **Phase 4 is partially done.** The channel-side design is much better, but gateway still has the old product-front-door shape.

---

## Architecture policy improved, but not enough

You updated `ArchitecturePolicy` so that:

```elixir
ai: []
```

That is good.

But the policy still allows some dependencies that should probably now be treated as transitional drift:

```elixir
lemon_router: [
  :agent_core,
  :ai,
  :coding_agent,
  :lemon_channels,
  :lemon_core,
  :lemon_gateway
]
```

and:

```elixir
lemon_gateway: [
  :agent_core,
  :ai,
  :coding_agent,
  :lemon_automation,
  :lemon_channels,
  :lemon_core
]
```

That means the architecture checker may now bless some relationships that the desired architecture should eventually reject.

This is where I would still add the two-policy model:

```elixir
defmodule LemonCore.Quality.ArchitecturePolicy do
  def current_allowed_direct_deps do
    %{
      lemon_router: [:agent_core, :ai, :coding_agent, :lemon_channels, :lemon_core, :lemon_gateway],
      lemon_gateway: [:agent_core, :ai, :coding_agent, :lemon_automation, :lemon_channels, :lemon_core],
      ai: []
    }
  end

  def target_allowed_direct_deps do
    %{
      lemon_router: [:agent_core, :ai, :coding_agent, :lemon_core],
      lemon_gateway: [:agent_core, :coding_agent, :lemon_core],
      ai: []
    }
  end
end
```

Then CI can do:

```text
current policy: fail on violation
target policy: report drift
```

This matters because otherwise the checker becomes a snapshot of today’s compromises instead of a guide toward the desired architecture.

---

## The most important remaining work

If I were taking over the next pass, I would do these in order.

### 1. Remove router’s last gateway dependency

Move `LemonGateway.ChatState` into core.

Target check:

```bash
rg "\bLemonGateway\b" apps/lemon_router/lib
# no results
```

Then remove this from `apps/lemon_router/mix.exs`:

```elixir
{:lemon_gateway, in_umbrella: true}
```

This is the highest-leverage remaining cleanup from Phase 2.

---

### 2. Make async delivery receipt semantics explicit

Replace:

```elixir
%{
  mode: disposition,
  status: status
}
```

with:

```elixir
%{
  requested_mode: submission.queue_mode,
  actual_mode: disposition,
  status: status,
  fallback_mode: fallback_mode,
  active_run_id: active_run_id,
  decided_at_ms: LemonCore.Event.now_ms()
}
```

Then update LLM provenance formatting to show both:

```text
requested_delivery: followup
actual_delivery: steer_backlog
delivery_status: dispatched_to_active
```

This will prevent future confusion.

---

### 3. Decide whether reasoning is an event type or an engine action kind

Right now you have both:

```elixir
:reasoning_status
```

and:

```elixir
:engine_action, kind: "reasoning"
```

Pick one canonical path.

My recommendation: use `:engine_action` for UI/status surfaces, but create typed constructors so callers do not hand-roll payloads.

Example:

```elixir
LemonCore.Event.engine_reasoning(%{
  run_id: run_id,
  session_key: session_key,
  text: text,
  source: "runner_note",
  phase: "updated",
  visibility: :operator
})
```

Do not leave `reasoning_status/2` unused unless it is part of a near-term migration.

---

### 4. Shrink gateway

Start with supervision ownership.

Current gateway startup still says “transport platform.” It should say “engine runtime.”

A clean `LemonGateway.Application` should look more like:

```elixir
children = [
  LemonGateway.Config,
  LemonGateway.EngineRegistry,
  LemonGateway.EngineLock,
  {Registry, keys: :unique, name: LemonGateway.RunRegistry},
  LemonGateway.ThreadRegistry,
  LemonGateway.RunSupervisor,
  LemonGateway.ThreadWorkerSupervisor,
  {Task.Supervisor, name: LemonGateway.TaskSupervisor},
  LemonGateway.Scheduler
] ++ maybe_health_server_child()
```

Everything else should move.

---

### 5. Update stale migration docs

Especially:

```text
docs/plans/2026-03-19-ai-boundary-extraction-plan.md
```

That doc still describes the AI boundary as if Phase 1 has not landed. It should now become a completion report or be updated with the new remaining work:

```text
Status: apps/ai is Lemon-free.
Remaining:
- keep CI guard
- optional external repo extraction
- preserve provider-neutral OAuth interfaces
- verify no production callers rely on Lemon-backed Ai.Auth storage
```

---

## Checks I would run locally

These are the exact checks I would expect to pass or fail in informative ways.

```bash
# Phase 1
rg "\bLemonCore\b" apps/ai/lib
rg "ProviderConfigResolver|Secrets|Onboarding" apps/ai/lib

# Phase 2
rg "LemonGateway.ExecutionRequest|ExecutionRequest" apps/lemon_router/lib
rg "\bLemonGateway\b" apps/lemon_router/lib

# Phase 3
rg "reasoning_status" apps
rg "kind: \"reasoning\"|\"reasoning\"" apps/lemon_router apps/coding_agent apps/lemon_core
rg "delivery_receipt|requested_mode|actual_mode" apps

# Phase 4
rg "TransportRegistry|TransportSupervisor|Sms|Voice|transports/" apps/lemon_gateway/lib
rg "RunRequestBuilder|submit_inbound" apps/lemon_channels/lib
```

Expected current results:

```text
apps/ai/lib LemonCore refs: good, zero
router ExecutionRequest refs: good, zero
router LemonGateway refs: still nonzero because of ChatState
reasoning_status: likely underused
delivery_receipt: present, but lacks requested/actual mode semantics
gateway transport ownership: still very nonzero
```

---

## Final assessment

You did **much better than a superficial patch pass**.

The AI boundary extraction is the biggest win. That is now genuinely cleaner. The execution command boundary is also a serious improvement. Those two changes reduce long-term architectural drag.

But the remaining problems are still important:

```text
router still depends on gateway through ChatState
events are improved but not truly canonical
delivery receipts need requested-vs-actual semantics
gateway still owns too much transport/product ingress
architecture policy still blesses some transitional coupling
```

So my take is:

```text
Phases 1-2: successful architectural work.
Phase 3: good implementation work, but not yet architectural closure.
Phase 4: started, with good channel-side changes, but gateway remains unresolved.
```

The next best milestone should be:

```text
“Router no longer depends on Gateway at compile time.”
```

That is the cleanest proof that the execution boundary work actually landed all the way.


