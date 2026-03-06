
# Concrete Architecture Refactor Plan

## 1. Purpose

This plan turns the architectural review into an implementation roadmap that is safe to execute incrementally.

The main theme is **canonical ownership**:

- `lemon_channels` should own **channel-specific UX and rendering**
- `lemon_router` should own **request normalization and conversation queue semantics**
- `lemon_gateway` should own **execution slots, engine lifecycle, and low-level execution safety**
- `lemon_core` should own **shared contracts and backend abstractions**, not arbitrary product-domain storage
- `coding_agent` should own **agent runtime behavior**, but not hide multiple unrelated runtimes inside single giant modules

This plan is intentionally explicit. It assumes the implementer will follow instructions literally.

---

## 2. Non-negotiable implementation rules

These rules are part of the plan.

1. **Do not combine phases in one PR.**
   - Each phase should land independently.
   - Each phase must preserve runtime behavior unless the phase explicitly says otherwise.

2. **Do not delete old code until the replacement is proven by tests.**
   - First add the new contract or module.
   - Then migrate call sites.
   - Then delete compatibility code.

3. **Do not introduce new cross-app leaks while fixing old ones.**
   - No new `LemonChannels.OutboundPayload` construction outside `lemon_channels`.
   - No new gateway queue-mode logic once router migration starts.
   - No new generic `LemonCore.Store.put/get/delete/list` calls in shared domains after typed wrappers exist.

4. **Prefer move + delegate over rewrite.**
   - Move functions into a new module.
   - Leave the old entrypoint as a thin delegator.
   - Delete the delegator only after all call sites are migrated and tests are green.

5. **Keep public APIs stable where possible.**
   - `CodingAgent.Session` should remain the public module even if its internals are split.
   - `CodingAgent.Tools.Task` should remain the public tool entry module even if internals are split.
   - `LemonGateway.Runtime.submit/1` may remain temporarily as a compatibility wrapper.

6. **Every phase must update docs and tests in the same PR.**
   - If the architecture changed, the corresponding docs and AGENTS files must change too.
   - If a boundary moved, the architecture quality rules must change too.

---

## 3. Target architecture

## 3.1 Current high-level flow

```text
Channel transport
  -> Router.handle_inbound
  -> RunOrchestrator
  -> RunProcess
  -> Gateway.Scheduler
  -> Gateway.ThreadWorker
  -> Gateway.Run
  -> bus events
  -> Router.OutputTracker / StreamCoalescer / ToolStatusCoalescer
  -> Router.ChannelAdapter.Telegram
  -> Channels outbox / Telegram delivery
```

Problems in the current flow:

- router owns Telegram rendering details
- gateway owns conversation queue semantics that are really router/product semantics
- both router and gateway partially enforce “only one active thing at a time”
- storage ownership is blurred through generic `Store` tables

## 3.2 Target high-level flow

```text
Channel transport
  -> Router.handle_inbound
  -> Router.SessionCoordinator
  -> Router.RunOrchestrator
  -> Router.ActiveRun (formerly RunProcess)
  -> Gateway.Scheduler / Gateway.Run
  -> bus events
  -> Router semantic output tracking
  -> LemonCore.DeliveryIntent
  -> Channels.Dispatcher
  -> channel-specific renderer/presenter
  -> Channels.Outbox
```

Important target properties:

- Router emits **semantic delivery intents**, not Telegram payload details.
- Channels owns **all platform presentation decisions**.
- Router owns **queue semantics** (`collect`, `followup`, `steer`, `interrupt`, etc.).
- Gateway owns **execution slots**, **engine lifecycle**, and **engine lock safety** only.
- Shared storage is wrapped by typed domain modules.

---

## 4. Ownership matrix

| Concern | Target owner | Must not own it after refactor |
|---|---|---|
| Inbound channel command parsing (`/resume`, `/model`, `/new`, topic logic, auth, buffering) | `lemon_channels` | `lemon_router`, `lemon_gateway` |
| Resume string parsing / formatting for channel UX | `lemon_channels` | `lemon_router` |
| Run request normalization, policy/model resolution, default engine selection | `lemon_router` | `lemon_gateway`, `lemon_channels` |
| Queue semantics (`collect`, `followup`, `steer`, `steer_backlog`, `interrupt`) | `lemon_router` | `lemon_gateway` |
| Execution concurrency slots, engine start/stop, run process lifecycle | `lemon_gateway` | `lemon_router`, `lemon_channels` |
| Channel rendering (truncate, edit-vs-send, reply markup, media groups, message-id tracking, progress message strategy) | `lemon_channels` | `lemon_router` |
| Chat state persistence backend | `lemon_core` backend + typed store wrapper | every app directly via raw generic store API |
| Telegram-specific delivery state | `lemon_channels` | `lemon_router`, `lemon_gateway` |
| Pending compaction application to inbound prompts | `lemon_router` | `lemon_channels` |
| Agent session runtime internals | `coding_agent` | unrelated apps |

---

## 5. Phase order

Execute phases in this exact order:

1. **Phase 0** — restore trust in architecture metadata and quality gates
2. **Phase 1** — introduce future contracts without behavior changes
3. **Phase 2** — move channel rendering ownership fully into `lemon_channels`
4. **Phase 3** — move queue semantics ownership fully into `lemon_router`
5. **Phase 4** — split typed stores from `LemonCore.Store`
6. **Phase 5** — reduce monolith modules (`CodingAgent.Session`, `CodingAgent.Tools.Task`, Telegram transport, webhook transport)
7. **Phase 6** — delete compatibility code and codify new boundaries

Do not skip Phase 0. Later phases will be much harder to validate if the architecture checker is lying.

---

## 6. Phase 0 — Restore trust in architecture metadata and quality gates

## 6.1 Why this phase exists

Right now the architecture checker is out of sync with the repo:

- it misses `in_umbrella: true` deps that also include extra options
- it does not know about `lemon_mcp`
- it cannot correctly reason about `coding_agent_ui` because some UI modules are under `CodingAgent.UI.*`
- docs and mix files are drifting from the actual repo

If this is not fixed first, later refactors will either:
- fail the wrong checks, or
- pass while still violating the intended architecture

That makes every later phase noisier and less trustworthy.

## 6.2 Scope

Files to change:

- `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`
- `apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs`
- `apps/lemon_core/test/mix/tasks/lemon.quality_test.exs`
- `docs/architecture_boundaries.md`
- `README.md` (only if app list / version policy is stale)
- `apps/lemon_control_plane/mix.exs`
- `apps/lemon_web/mix.exs`
- every `apps/*/mix.exs` that still declares an older Elixir version
- optionally `apps/lemon_gateway/lib/lemon_gateway/transports/discord.ex` if converted into an explicit legacy shim

## 6.3 Exact required changes

### 6.3.1 Replace regex dep parsing with AST parsing

Current problem:
- `ArchitectureCheck.parse_umbrella_deps/1` uses regex
- it misses tuples like `{:lemon_channels, in_umbrella: true, runtime: false}`

Required implementation:
- parse each `mix.exs` file into AST
- find the `deps/0` or `defp deps` function body
- extract umbrella deps by reading tuple elements, not by regex matching text

Required behavior:
- the parser must detect all of the following as umbrella deps:
  - `{:foo, in_umbrella: true}`
  - `{:foo, in_umbrella: true, runtime: false}`
  - `{:foo, "~> 1.0"}` -> **not** umbrella
  - `{:foo, path: "../foo"}` -> **not** umbrella unless `in_umbrella: true`

Pseudo-implementation:

```elixir
defp parse_umbrella_deps(mix_file) do
  with {:ok, source} <- File.read(mix_file),
       {:ok, ast} <- Code.string_to_quoted(source) do
    ast
    |> find_deps_ast()
    |> extract_umbrella_dep_atoms()
    |> Enum.uniq()
    |> Enum.sort()
  else
    _ -> []
  end
end
```

Do not use `Code.eval_string/1`. This is a static analysis tool, not a runtime evaluator.

### 6.3.2 Replace “first alias segment” ownership with exact-module + longest-prefix ownership

Current problem:
- the checker only tracks the first alias segment (`CodingAgent`, `LemonRouter`, etc.)
- that is too coarse
- it cannot distinguish `CodingAgent.Session` from `CodingAgent.UI.RPC`

Required implementation:
- parse and keep the **full module name**
- resolve ownership using:
  1. exact-module overrides
  2. then longest matching namespace prefix

Required data structures:

```elixir
@exact_module_owners %{
  "CodingAgent.UI" => :coding_agent,
  "CodingAgent.UI.Context" => :coding_agent,
  "CodingAgent.UI.RPC" => :coding_agent_ui,
  "CodingAgent.UI.Headless" => :coding_agent_ui,
  "CodingAgent.UI.DebugRPC" => :coding_agent_ui
}

@app_namespaces %{
  coding_agent: ["CodingAgent"],
  coding_agent_ui: ["CodingAgentUi"],
  ...
}
```

Required owner resolution:

```elixir
defp owner_for_module(full_name) do
  case Map.get(@exact_module_owners, full_name) do
    nil ->
      namespace_prefix_owners()
      |> Enum.filter(fn {prefix, _owner} ->
        full_name == prefix or String.starts_with?(full_name, prefix <> ".")
      end)
      |> Enum.max_by(fn {prefix, _owner} -> String.length(prefix) end, fn -> nil end)
      |> case do
        nil -> nil
        {_prefix, owner} -> owner
      end

    owner ->
      owner
  end
end
```

This is the minimum correct behavior. Do not keep the current prefix-only logic.

### 6.3.3 Add missing app policy for `lemon_mcp`

Required updates:
- add `:lemon_mcp` to `@allowed_direct_deps`
- add `:lemon_mcp` to namespace ownership maps
- update `docs/architecture_boundaries.md` so the documented list matches the repo

Do not leave “unknown app” false positives in the checker.

### 6.3.4 Clean duplicate deps and version drift

Required cleanup:
- remove duplicate `{:lemon_games, in_umbrella: true}` entries from:
  - `apps/lemon_control_plane/mix.exs`
  - `apps/lemon_web/mix.exs`

Required decision:
- standardize all umbrella apps on one Elixir version declaration.
- because the top-level README says Elixir `1.19+`, the recommended change is:
  - set every umbrella app `mix.exs` to `elixir: "~> 1.19"`

If CI/runtime does **not** actually support 1.19 yet, then stop and make the docs truthful first. Do not leave code and docs contradicting each other.

### 6.3.5 Make the legacy Discord gateway module unmistakably legacy

File:
- `apps/lemon_gateway/lib/lemon_gateway/transports/discord.ex`

Required outcome:
- either delete it if unused, or
- mark it as a compatibility shim with an explicit comment:
  - “Discord transport ownership lives in `lemon_channels`; do not add behavior here.”

The goal is to prevent future accidental feature work in the wrong layer.

## 6.4 Tests for Phase 0

Run all of these:

```bash
mix test apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs
mix test apps/lemon_core/test/mix/tasks/lemon.quality_test.exs
mix lemon.quality
```

Add/adjust tests for:

1. umbrella dep parsing with extra tuple options
2. exact-module owner resolution for `CodingAgent.UI.RPC`
3. prefix owner resolution for normal namespaces
4. `lemon_mcp` no longer flagged as unknown
5. duplicate dependency cleanup does not alter compile behavior

Recommended extra validation:

```bash
mix compile --warnings-as-errors
```

## 6.5 Acceptance criteria

Phase 0 is complete only when all are true:

- `mix lemon.quality` passes
- the checker sees all real umbrella deps
- the checker correctly attributes `CodingAgent.UI.RPC` to `coding_agent_ui`
- docs list the real app set
- duplicate deps are removed
- version policy is consistent

---

## 7. Phase 1 — Introduce future contracts without behavior changes

## 7.1 Why this phase exists

Before moving ownership, add the contracts that later phases will migrate toward.

This phase creates **new seams** without immediately deleting the old seams. That reduces risk and makes the next phases mechanical instead of conceptual.

## 7.2 Scope

Add these new modules:

- `apps/lemon_core/lib/lemon_core/delivery_route.ex`
- `apps/lemon_core/lib/lemon_core/delivery_intent.ex`
- `apps/lemon_gateway/lib/lemon_gateway/execution_request.ex`
- `apps/lemon_channels/lib/lemon_channels/dispatcher.ex`

Modify:

- `apps/lemon_core/lib/lemon_core/run_request.ex`
- `apps/lemon_gateway/lib/lemon_gateway/runtime.ex`
- `apps/lemon_gateway/lib/lemon_gateway/types.ex` (compatibility only)
- small targeted tests in `lemon_core`, `lemon_gateway`, `lemon_channels`

## 7.3 Exact required changes

### 7.3.1 Extend `LemonCore.RunRequest` to carry structured resume information

Current problem:
- router parses free-form prompt text to discover resume tokens
- it does that by calling `LemonChannels.EngineRegistry.extract_resume/1`
- that is a channel-layer leak into the router

Required change:
- add `:resume` to `%LemonCore.RunRequest{}`

Required struct shape:

```elixir
defstruct origin: :unknown,
          session_key: nil,
          agent_id: "default",
          prompt: nil,
          queue_mode: :collect,
          engine_id: nil,
          model: nil,
          resume: nil,
          meta: %{},
          cwd: nil,
          tool_policy: nil,
          run_id: nil
```

Required normalization:
- accept `resume` if already a `%LemonCore.ResumeToken{}`
- otherwise normalize to `nil`

Rule after this change:
- transports and control-plane callers may supply structured `resume`
- router must stop parsing channel-specific resume syntax in later phases

### 7.3.2 Add semantic route and delivery contracts in `lemon_core`

Add:

```elixir
defmodule LemonCore.DeliveryRoute do
  @enforce_keys [:channel_id, :account_id, :peer_kind, :peer_id]
  defstruct [:channel_id, :account_id, :peer_kind, :peer_id, :thread_id]
end
```

Add:

```elixir
defmodule LemonCore.DeliveryIntent do
  @type kind ::
          :stream_snapshot
          | :stream_finalize
          | :tool_status_snapshot
          | :tool_status_finalize
          | :final_text
          | :file_batch
          | :reaction

  @enforce_keys [:intent_id, :run_id, :session_key, :route, :kind]
  defstruct [
    :intent_id,
    :run_id,
    :session_key,
    :route,
    :kind,
    body: %{},
    attachments: [],
    controls: %{},
    meta: %{}
  ]
end
```

Rules for this contract:
- `body`, `attachments`, and `controls` are **semantic**
- do **not** put Telegram message ids into `body`
- do **not** put `reply_markup` maps into `controls`
- do **not** encode transport payloads here
- this contract is for router → channels communication only

### 7.3.3 Add execution contract to gateway

Add:

```elixir
defmodule LemonGateway.ExecutionRequest do
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
    :meta
  ]
end
```

Why `lane` stays:
- `lane` is execution context, not queue semantics
- queue semantics will move out
- execution lanes can remain gateway input

Why `queue_mode` must **not** be present:
- queue mode is product/conversation behavior
- gateway should not own it after the migration

### 7.3.4 Add temporary compatibility wrappers

Add in `LemonGateway.Runtime`:

```elixir
@spec submit_execution(LemonGateway.ExecutionRequest.t()) :: :ok
def submit_execution(%ExecutionRequest{} = request) do
  LemonGateway.Scheduler.submit_execution(request)
end

@spec submit(LemonGateway.Types.Job.t()) :: :ok
def submit(%Job{} = job) do
  job
  |> ExecutionRequest.from_job()
  |> submit_execution()
end
```

Add compatibility constructor:

```elixir
defmodule LemonGateway.ExecutionRequest do
  def from_job(%LemonGateway.Types.Job{} = job) do
    %__MODULE__{
      run_id: job.run_id,
      session_key: job.session_key,
      prompt: job.prompt,
      engine_id: job.engine_id,
      cwd: job.cwd,
      resume: job.resume,
      lane: job.lane,
      tool_policy: job.tool_policy,
      meta: job.meta
    }
  end
end
```

Keep the compatibility wrapper only until Phase 6.

### 7.3.5 Add channels dispatcher entrypoint

Add:

```elixir
defmodule LemonChannels.Dispatcher do
  @spec dispatch(LemonCore.DeliveryIntent.t()) :: :ok | {:error, term()}
  def dispatch(%LemonCore.DeliveryIntent{} = intent) do
    # temporary implementation can be small and incomplete,
    # but the module and public API must exist now
  end
end
```

Important rule:
- `Dispatcher` is the future **single** router-facing delivery API
- router should stop touching `OutboundPayload` directly in Phase 2

## 7.4 Tests for Phase 1

Add and run:

```bash
mix test apps/lemon_core/test/lemon_core/run_request_test.exs
mix test apps/lemon_gateway/test/lemon_gateway_test.exs
mix test apps/lemon_channels/test/lemon_channels/application_test.exs
```

Add new tests for:

1. `RunRequest` normalizes `resume`
2. `ExecutionRequest.from_job/1` preserves fields except `queue_mode`
3. `DeliveryIntent` validates required fields
4. `Dispatcher.dispatch/1` returns a sane result for at least a simple text intent

Recommended extra validation:

```bash
mix compile --warnings-as-errors
```

## 7.5 Acceptance criteria

- new contracts exist and compile
- existing behavior still works
- old call paths still function through compatibility wrappers
- no production logic is yet moved; this phase is scaffolding only

---

## 8. Phase 2 — Move channel rendering and platform UX fully into `lemon_channels`

## 8.1 Why this phase exists

This is the highest-value architectural fix.

Right now a Telegram UX change can require editing both:

- `lemon_router`
- `lemon_channels`

That is the wrong ownership model.

After this phase:
- router emits semantic intents
- channels decides how those intents become Telegram messages, edits, buttons, truncation, media groups, etc.

## 8.2 Scope

Files that will shrink or disappear:

- `apps/lemon_router/lib/lemon_router/channel_adapter.ex`
- `apps/lemon_router/lib/lemon_router/channel_adapter/generic.ex`
- `apps/lemon_router/lib/lemon_router/channel_adapter/telegram.ex`
- `apps/lemon_router/lib/lemon_router/channels_delivery.ex`
- `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
- `apps/lemon_router/lib/lemon_router/stream_coalescer.ex`
- `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex`
- `apps/lemon_router/lib/lemon_router/run_orchestrator.ex` (resume parsing leak removal)

New channels-side modules to add:

- `apps/lemon_channels/lib/lemon_channels/dispatcher.ex`
- `apps/lemon_channels/lib/lemon_channels/presentation_state.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/generic/renderer.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/renderer.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/status_renderer.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/file_batcher.ex`
- optionally `apps/lemon_channels/lib/lemon_channels/adapters/telegram/resume_index_store.ex`

The exact split can vary slightly, but the ownership outcome may not.

## 8.3 Exact required changes

### 8.3.1 Router must stop constructing `OutboundPayload`

This is the core rule of the phase.

After this phase, these router modules must not construct `%LemonChannels.OutboundPayload{}`:
- `RunProcess.OutputTracker`
- `ChannelAdapter.Generic`
- `ChannelAdapter.Telegram`
- anything else in `apps/lemon_router/lib`

Instead, router must emit `%LemonCore.DeliveryIntent{}` and call:

```elixir
LemonChannels.Dispatcher.dispatch(intent)
```

### 8.3.2 Router must stop using Telegram helpers directly

Remove these router-layer dependencies:

- `LemonChannels.OutboundPayload`
- `LemonChannels.Telegram.Truncate`
- `LemonChannels.GatewayConfig`
- `LemonChannels.EngineRegistry`

Replace them with:
- `LemonCore.DeliveryIntent`
- `LemonChannels.Dispatcher`
- `LemonCore.RunRequest.resume` supplied by the caller

### 8.3.3 Move resume parsing to channel transports

Current bad pattern:
- `RunOrchestrator` parses raw prompt text for resume tokens by calling `LemonChannels.EngineRegistry.extract_resume/1`

Required new pattern:
- channel transport parses explicit resume syntax before handing the request to router
- structured `%ResumeToken{}` moves through `InboundMessage.meta[:resume]` and/or directly into `RunRequest.resume`
- router consumes structured data, not free-form channel syntax

Required router change:
- delete router-side “extract resume from prompt text” logic
- `RunOrchestrator` should only look at:
  - `request.resume`
  - router-owned auto-resume resolution (Phase 3)

### 8.3.4 Simplify router coalescers to semantic output only

Router coalescers may remain temporarily, but only as semantic coalescers.

Remove platform-specific state from router coalescer state:
- `answer_msg_id`
- `status_msg_id`
- `answer_create_ref`
- `status_create_ref`
- deferred platform-specific text bookkeeping
- reply markup knowledge
- pending resume indexing lists
- Telegram-specific limit ordering

Keep only:
- accumulated text
- sequence number
- run id
- session key
- semantic action list / status text
- flush timing

Router output after this change should look like:

```elixir
%LemonCore.DeliveryIntent{
  intent_id: "...",
  run_id: run_id,
  session_key: session_key,
  route: route,
  kind: :stream_snapshot,
  body: %{text: full_text, seq: seq},
  meta: %{surface: :answer}
}
```

or

```elixir
%LemonCore.DeliveryIntent{
  intent_id: "...",
  run_id: run_id,
  session_key: session_key,
  route: route,
  kind: :tool_status_snapshot,
  body: %{text: rendered_status, seq: seq},
  controls: %{allow_cancel?: true},
  meta: %{surface: :status}
}
```

### 8.3.5 Channels must own message-id mapping and delivery ack handling

Current problem:
- router tracks delivery refs and message ids so it can later decide edit vs create
- that means router owns platform presentation state

Required new pattern:
- channels stores this state internally
- key it by route + run + surface

Recommended state key:

```elixir
%{
  route: %DeliveryRoute{},
  run_id: run_id,
  surface: :answer | :status
}
```

Recommended state fields:

```elixir
%{
  platform_message_id: "123",
  pending_create_ref: ref,
  last_seq: 42,
  last_text_hash: "..."
}
```

That state belongs in `lemon_channels`, not `lemon_router`.

### 8.3.6 Use `CapabilityQuery` in channels, not `ChannelAdapter` in router

Current pattern:
- router asks a channel adapter what the channel supports

Target pattern:
- channels dispatcher/renderer decides using:
  - `LemonChannels.CapabilityQuery`
  - renderer-specific logic
  - adapter-specific state

Examples:
- whether edits are supported
- how large file batches can be
- whether reactions are supported
- whether tool-status buttons should render

### 8.3.7 Move delivery-related Telegram indices into channels-owned modules

Move ownership of message-based Telegram indices:
- `:telegram_msg_resume`
- `:telegram_msg_session`

into a channels-owned module, for example:

- `LemonChannels.Telegram.ResumeIndexStore`

Rule:
- only the channels layer should index platform message ids to resume/session metadata
- router must not write message-id-based Telegram tables

### 8.3.8 Unify pending compaction application in router

There is currently duplicate “apply pending compaction to next user message” logic in:
- router
- Telegram transport

That duplication must end.

Required outcome:
- **router** is the single owner of “rewrite next inbound prompt with pending compaction transcript”
- Telegram transport must stop mutating inbound text for this purpose

If Telegram transport still needs UI-only state for compaction prompts, keep that state separate from prompt mutation.

## 8.4 Recommended migration sequence inside Phase 2

Follow this exact sequence:

1. add `LemonChannels.Dispatcher`
2. add `LemonChannels.PresentationState`
3. add generic renderer in channels
4. migrate non-Telegram router output path to `Dispatcher`
5. add Telegram renderer in channels
6. migrate Telegram stream output path
7. migrate Telegram tool-status output path
8. migrate file batching / auto-send behavior
9. migrate delivery-ack state to channels
10. delete router `ChannelAdapter.*`
11. remove router imports of `OutboundPayload`
12. remove router-side resume parsing leak

Do not start by deleting `ChannelAdapter.Telegram`. Replace it first.

## 8.5 Tests for Phase 2

Must run all of these:

```bash
mix test apps/lemon_router/test/lemon_router/stream_coalescer_test.exs
mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/lemon_channels/test/lemon_channels/telegram/delivery_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/inbound_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_authorization_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_cancel_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_parallel_sessions_test.exs
mix test apps/lemon_channels/test/lemon_channels/outbox_architecture_test.exs
mix test apps/lemon_channels/test/lemon_channels/outbox_retry_behavior_test.exs
```

Add new tests:
- `apps/lemon_channels/test/lemon_channels/dispatcher_test.exs`
- `apps/lemon_channels/test/lemon_channels/adapters/telegram/renderer_test.exs`
- `apps/lemon_channels/test/lemon_channels/adapters/generic/renderer_test.exs`

New assertions to add:
1. router output path emits intents, not payload structs
2. telegram renderer truncates long text correctly
3. telegram renderer switches between send and edit correctly
4. tool status buttons are rendered only by channels
5. file batches are chunked only by channels
6. delivery ack updates channels-owned presentation state
7. router no longer writes Telegram message-index tables

## 8.6 Acceptance criteria

Phase 2 is complete only when all are true:

- router does not construct `OutboundPayload`
- router does not import `LemonChannels.Telegram.Truncate`
- router does not import `LemonChannels.EngineRegistry`
- `ChannelAdapter.*` is removed or reduced to dead compatibility stubs with no callers
- Telegram rendering behavior is fully owned by channels
- pending compaction prompt mutation is no longer duplicated

---

## 9. Phase 3 — Make router the sole owner of queue semantics

## 9.1 Why this phase exists

This is the second major fix.

Queue modes such as:
- `collect`
- `followup`
- `steer`
- `steer_backlog`
- `interrupt`

are not engine runtime details. They are **conversation/product semantics**.

That means they belong in the router, which owns:
- session identity
- inbound origin
- user intent
- conversation continuity policy

Gateway should be the execution substrate, not the conversation traffic cop.

## 9.2 Important nuance: queue key is not always the raw session key

Today gateway sometimes serializes by resume token / thread key, not only by session key.

Do **not** lose that behavior.

Target rule:
- router owns the queue, but the queue key is:
  - explicit resume token if present
  - otherwise auto-resume token if resolved
  - otherwise raw session key

This preserves single-flight behavior across resumed threads that may span multiple session entrypoints.

Recommended term:
- `conversation_key`

Recommended type:
- `{:resume, engine, token}` or `{:session, session_key}`

## 9.3 Scope

New router modules to add:

- `apps/lemon_router/lib/lemon_router/session_coordinator.ex`
- `apps/lemon_router/lib/lemon_router/session_coordinator_supervisor.ex`
- `apps/lemon_router/lib/lemon_router/conversation_key.ex`
- `apps/lemon_router/lib/lemon_router/resume_resolver.ex`

Router modules to shrink:

- `apps/lemon_router/lib/lemon_router/run_orchestrator.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/lemon_router/lib/lemon_router/router.ex`

Gateway modules to simplify:

- `apps/lemon_gateway/lib/lemon_gateway/types.ex`
- `apps/lemon_gateway/lib/lemon_gateway/runtime.ex`
- `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex`
- `apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex`

## 9.4 Exact required changes

### 9.4.1 Add a router-owned coordinator process

Add a router process that is the single owner of queue semantics per conversation key.

Recommended public API:

```elixir
defmodule LemonRouter.SessionCoordinator do
  @spec submit(LemonCore.RunRequest.t()) :: :ok
  @spec cancel(binary(), term()) :: :ok
  @spec active_run(term()) :: {:ok, binary()} | :none
end
```

Core responsibilities:
- own active run pointer
- own pending queue/backlog
- apply queue-mode rules
- resolve conversation key
- decide when to submit execution to gateway
- decide when to steer vs queue vs interrupt

Do **not** make gateway responsible for any of those after this phase.

### 9.4.2 Keep `RunProcess` only as an active-run observer/executor wrapper

`RunProcess` may stay as a per-run process, but it must lose session-queue ownership.

Rename internally or conceptually to `ActiveRun` if helpful.

It may continue to own:
- bus subscription
- watchdog
- zero-answer retry
- compaction trigger
- semantic output tracking
- one execution submission to gateway
- completion notification back to the coordinator

It must stop owning:
- session single-flight registration
- queue-mode behavior
- “should this run start now?” decisions

### 9.4.3 Move auto-resume resolution out of gateway and into router

Current problem:
- gateway scheduler mutates incoming jobs by consulting chat state

Target:
- router resolves auto-resume before submission

Add:
- `LemonRouter.ResumeResolver`

Responsibilities:
- if `RunRequest.resume` is present, use it
- else consult chat state for auto-resume
- produce final structured resume to pass into `ExecutionRequest`

Gateway may continue writing chat state on completion for now. That is acceptable. The problem is gateway mutating request semantics, not gateway persisting execution results.

### 9.4.4 Replace `Job` as the semantic queue contract

After this phase the public gateway input should be `ExecutionRequest`, not `Types.Job`.

Required gateway rule:
- `queue_mode` is no longer part of the public gateway contract

Transitional compatibility:
- keep `Job` only as an adapter until Phase 6
- do not add new logic to `Job`

### 9.4.5 Remove queue semantics from `ThreadWorker`

Current `ThreadWorker` responsibilities that must move out:
- collect coalescing
- followup debounce
- steer fallback behavior
- interrupt insertion logic
- auto-followup promotion

Possible end states:

**Preferred end state**
- remove `ThreadWorker` entirely
- `Scheduler` only manages global execution slots
- on slot grant, router-owned active run starts the gateway run directly

**Acceptable intermediate end state**
- keep `ThreadWorker`, but it becomes a trivial single-request launcher with no queue semantics

Do not leave queue-mode branches in gateway after the migration.

### 9.4.6 Keep `EngineLock` as a safety rail, not the primary owner of semantics

`EngineLock` can remain as a low-level “do not double-drive one engine thread” safety mechanism.

It must not be the primary source of correctness for queue semantics.

Correctness should come from router-owned coordination.
`EngineLock` should be treated as defense-in-depth.

## 9.5 Recommended migration sequence inside Phase 3

Follow this order:

1. add `ConversationKey`
2. add `ResumeResolver`
3. add `SessionCoordinator` with no behavior change yet
4. route all new run submissions through `SessionCoordinator`
5. move `collect` behavior into coordinator
6. move `followup` behavior into coordinator
7. move `steer` / `steer_backlog` behavior into coordinator
8. move `interrupt` behavior into coordinator
9. change gateway submission to `ExecutionRequest`
10. simplify scheduler
11. simplify or remove thread worker
12. repurpose `SessionRegistry` as coordinator registry or delete it

Do not remove gateway queue logic until the router tests prove the behavior is preserved.

## 9.6 Tests for Phase 3

Run all of these:

```bash
mix test apps/lemon_router/test/lemon_router/router_test.exs
mix test apps/lemon_router/test/lemon_router/run_orchestrator_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/lemon_gateway/test/scheduler_test.exs
mix test apps/lemon_gateway/test/thread_worker_test.exs
mix test apps/lemon_gateway/test/queue_mode_test.exs
mix test apps/lemon_gateway/test/run_test.exs
mix test apps/lemon_gateway/test/run_transport_agnostic_test.exs
mix test apps/lemon_gateway/test/engine_lock_test.exs
mix test apps/lemon_gateway/test/lemon_gateway/scheduler_monitor_lifecycle_test.exs
```

Add new tests:

- `apps/lemon_router/test/lemon_router/session_coordinator_test.exs`
- `apps/lemon_router/test/lemon_router/resume_resolver_test.exs`
- `apps/lemon_router/test/lemon_router/conversation_key_test.exs`

Behavior that must be explicitly tested in router now:
1. consecutive `collect` requests queue correctly
2. rapid `followup` requests debounce/merge correctly if that behavior remains
3. `steer` injects into active run when supported
4. `steer_backlog` falls back correctly when steering is rejected
5. `interrupt` cancels active run and runs the new request next
6. same resume token across different session entries maps to the same coordinator key
7. different sessions still run concurrently subject to gateway slot limits

After router tests exist, gateway queue-mode tests should eventually shrink or disappear.

## 9.7 Acceptance criteria

- queue-mode decisions are made in router, not gateway
- gateway public input is `ExecutionRequest`
- gateway no longer auto-resolves resume state
- router owns conversation-key selection
- one active conversation per conversation key is enforced by router
- `ThreadWorker` either disappears or becomes dumb enough that queue semantics are no longer there

---

## 10. Phase 4 — Split typed stores from `LemonCore.Store`

## 10.1 Why this phase exists

`LemonCore.Store` currently mixes:
- backend abstraction
- typed domain operations
- generic arbitrary tables
- Telegram-specific indices
- policy storage
- run history
- chat state
- introspection storage

That makes ownership unclear and encourages more arbitrary storage sprawl.

The goal of this phase is **not** to rewrite persistence internals first.
The goal is to make data ownership explicit at the API level first.

## 10.2 Scope

Add typed wrappers first. Do **not** split backend internals in the same PR.

Recommended new shared wrappers:

- `apps/lemon_core/lib/lemon_core/chat_state_store.ex`
- `apps/lemon_core/lib/lemon_core/run_store.ex`
- `apps/lemon_core/lib/lemon_core/progress_store.ex`
- `apps/lemon_core/lib/lemon_core/policy_store.ex`
- `apps/lemon_core/lib/lemon_core/introspection_store.ex`
- `apps/lemon_core/lib/lemon_core/project_binding_store.ex`

Recommended app-owned wrappers:

- `apps/lemon_router/lib/lemon_router/pending_compaction_store.ex`
- `apps/lemon_channels/lib/lemon_channels/telegram/state_store.ex`
- `apps/lemon_channels/lib/lemon_channels/telegram/resume_index_store.ex`

## 10.3 Store domain mapping

Use this mapping. Do not improvise.

| Current table / concern | Target wrapper owner |
|---|---|
| chat state | `LemonCore.ChatStateStore` |
| runs / run history / finalize run / sessions index | `LemonCore.RunStore` |
| progress message ↔ run mapping | `LemonCore.ProgressStore` |
| agent/channel/session/runtime policy | `LemonCore.PolicyStore` |
| introspection events | `LemonCore.IntrospectionStore` |
| `pending_compaction` | `LemonRouter.PendingCompactionStore` |
| `telegram_pending_compaction` | remove if possible; otherwise route through `LemonRouter.PendingCompactionStore` or a temporary compatibility wrapper |
| `telegram_msg_resume`, `telegram_msg_session` | `LemonChannels.Telegram.ResumeIndexStore` |
| `telegram_session_model`, `telegram_default_model`, `telegram_default_thinking`, `telegram_selected_resume`, `telegram_thread_generation` | `LemonChannels.Telegram.StateStore` |
| `project_overrides`, `projects_dynamic` | `LemonCore.ProjectBindingStore` |

Important note:
- app-specific business tables that are not cross-app shared should eventually get app-local wrappers too
- do **not** try to eliminate every generic `Store` call in the entire repo in one step
- shared domains come first

## 10.4 Exact required changes

### 10.4.1 Create wrappers as pass-through modules first

Example:

```elixir
defmodule LemonCore.ChatStateStore do
  def get(session_key), do: LemonCore.Store.get_chat_state(session_key)
  def put(session_key, state), do: LemonCore.Store.put_chat_state(session_key, state)
  def delete(session_key), do: LemonCore.Store.delete_chat_state(session_key)
end
```

Do this first for every target wrapper.

Do not change backend internals yet.

### 10.4.2 Migrate call sites by domain

Recommended order:

1. gateway chat-state call sites
2. router run-history / pending-compaction call sites
3. progress mapping call sites
4. policy call sites
5. Telegram state call sites in channels
6. Telegram message-index call sites
7. project binding call sites

### 10.4.3 Freeze the generic API for new shared-domain work

After wrappers exist, add a quality rule:

- shared-domain modules must not call:
  - `LemonCore.Store.put/3`
  - `LemonCore.Store.get/2`
  - `LemonCore.Store.delete/2`
  - `LemonCore.Store.list/1`

except from:
- `LemonCore.Store` itself
- the typed wrapper modules
- explicitly allowlisted legacy modules during migration

This is the minimum enforcement needed to stop backsliding.

### 10.4.4 Delete duplicate pending-compaction implementation

As part of wrapper migration:
- router becomes sole owner of pending-compaction storage and prompt application
- Telegram transport must stop directly consulting `:telegram_pending_compaction`
- if needed, keep a compatibility delegator for one PR only

## 10.5 Tests for Phase 4

Run all of these:

```bash
mix test apps/lemon_core/test/lemon_core/store_test.exs
mix test apps/lemon_core/test/lemon_core/store/backend_test.exs
mix test apps/lemon_core/test/lemon_core/store/read_cache_test.exs
mix test apps/lemon_gateway/test/chat_state_test.exs
mix test apps/lemon_router/test/lemon_router/router_pending_compaction_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/inbound_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_topic_test.exs
```

Add new tests:
- `apps/lemon_core/test/lemon_core/chat_state_store_test.exs`
- `apps/lemon_core/test/lemon_core/run_store_test.exs`
- `apps/lemon_core/test/lemon_core/progress_store_test.exs`
- `apps/lemon_core/test/lemon_core/policy_store_test.exs`
- `apps/lemon_router/test/lemon_router/pending_compaction_store_test.exs`
- `apps/lemon_channels/test/lemon_channels/telegram/state_store_test.exs`
- `apps/lemon_channels/test/lemon_channels/telegram/resume_index_store_test.exs`

Add a quality/enforcement test that fails on new raw generic store call sites outside an allowlist.

## 10.6 Acceptance criteria

- shared domains use typed wrappers
- router no longer reads/writes Telegram-specific tables directly
- channels owns Telegram-specific state wrappers
- pending-compaction logic has one owner
- new raw generic store call sites are blocked by tests/quality rules

---

## 11. Phase 5 — Reduce monolith modules without changing public APIs

## 11.1 Why this phase exists

After the major ownership seams are fixed, there are still oversized modules that are hard to reason about:

- `CodingAgent.Session`
- `CodingAgent.Tools.Task`
- `LemonChannels.Adapters.Telegram.Transport`
- `LemonGateway.Transports.Webhook`

These are now much safer to decompose because the cross-app contracts are clearer.

## 11.2 `CodingAgent.Session` plan

### Goal
Keep `CodingAgent.Session` as the public API and GenServer shell, but move unrelated concern clusters into internal modules.

### Existing extracted helpers already present
Do not fight the existing direction. Continue it.

Existing helpers include:
- `CodingAgent.Session.CompactionManager`
- `CodingAgent.Session.EventHandler`
- `CodingAgent.Session.MessageSerialization`
- `CodingAgent.Session.ModelResolver`
- `CodingAgent.Session.PromptComposer`
- `CodingAgent.Session.WasmBridge`

### Required next extractions

Add or continue toward:

- `CodingAgent.Session.State`
- `CodingAgent.Session.CompactionLifecycle`
- `CodingAgent.Session.OverflowRecovery`
- `CodingAgent.Session.BackgroundTasks`
- `CodingAgent.Session.Notifier`
- `CodingAgent.Session.Persistence`

Recommended state grouping:

```elixir
defmodule CodingAgent.Session.State do
  defstruct [
    :core,
    :queues,
    :extensions,
    :notifications,
    :compaction,
    :recovery,
    :wasm
  ]
end
```

Do not move everything at once.
Move one concern cluster at a time.

### Mechanical extraction order

1. pure serialization helpers
2. background task helpers
3. event broadcasting / notifier logic
4. compaction lifecycle
5. overflow recovery
6. wasm lifecycle
7. remaining state-building helpers

### Rule
No public `CodingAgent.Session` function signature changes in this phase.

## 11.3 `CodingAgent.Tools.Task` plan

### Goal
Keep the public tool entry module, but split orchestration concerns.

Required internal modules:

- `CodingAgent.Tools.Task.Params`
- `CodingAgent.Tools.Task.Async`
- `CodingAgent.Tools.Task.Runner`
- `CodingAgent.Tools.Task.Followup`
- `CodingAgent.Tools.Task.Result`

Suggested responsibility mapping:

| Current concern | New module |
|---|---|
| option parsing / validation / budget gating | `Task.Params` |
| async lifecycle (`execute`, `poll`, `join`) | `Task.Async` |
| engine/subagent run path | `Task.Runner` |
| router followup / async submission | `Task.Followup` |
| result shaping / reduction | `Task.Result` |

Do not let `Task` continue to be both:
- a tool spec
- a subagent scheduler
- an async task store adapter
- a followup router bridge
- a result reducer

## 11.4 `LemonChannels.Adapters.Telegram.Transport` plan

This file is still too large even after ownership is corrected.

Continue extracting transport-only submodules.

Add/continue toward:

- `Transport.Poller`
- `Transport.CommandRouter`
- `Transport.SessionRouting`
- `Transport.ResumeSelection`
- `Transport.ModelPreferences`
- `Transport.MemoryReflection`
- `Transport.PerChatState`

Retain `Transport` as the shell that coordinates:
- polling loop
- update dispatch
- command routing
- forwarding to router bridge

Do not let this file keep both:
- network transport mechanics
- command UX rules
- state persistence
- prompt rewriting
- delivery callbacks
- authorization policy
- buffer management

The existing helper directory already shows the right direction:
- `commands.ex`
- `file_operations.ex`
- `media_groups.ex`
- `message_buffer.ex`
- `update_processor.ex`

Keep pushing in that direction.

## 11.5 `LemonGateway.Transports.Webhook` plan

This is lower priority than the other three, but still worth doing after the seam fixes.

Split into:

- `Webhook.SignatureValidation`
- `Webhook.RequestNormalization`
- `Webhook.InvocationDispatch`
- `Webhook.ResponseBuilder`

Do not mix HTTP parsing, auth, dispatch, and output shaping in one file.

## 11.6 Tests for Phase 5

Run all of these:

```bash
mix test apps/coding_agent/test/coding_agent/session_test.exs
mix test apps/coding_agent/test/coding_agent/session_auto_compaction_async_test.exs
mix test apps/coding_agent/test/coding_agent/session_overflow_recovery_test.exs
mix test apps/coding_agent/test/coding_agent/session_extensions_test.exs
mix test apps/coding_agent/test/coding_agent/tools/task_test.exs
mix test apps/coding_agent/test/coding_agent/tools/task_async_test.exs
mix test apps/coding_agent/test/coding_agent/subagent_comprehensive_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_authorization_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_cancel_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_offset_test.exs
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_topic_test.exs
mix test apps/lemon_gateway/test/webhook_transport_test.exs
```

Also add focused unit tests for each newly extracted helper module.

## 11.7 Acceptance criteria

- large modules are smaller because responsibilities moved out, not because code was merely rearranged
- public entry modules remain stable
- new internal modules have narrow responsibility and direct tests
- total behavior remains unchanged

---

## 12. Phase 6 — Delete compatibility code and codify the new boundaries

## 12.1 Why this phase exists

Until compatibility code is removed, the old architecture still exists in practice.

This final phase makes the new design real and enforceable.

## 12.2 Required deletions / simplifications

Delete or fully deprecate after call sites are gone:

- `LemonRouter.ChannelAdapter`
- `LemonRouter.ChannelAdapter.Generic`
- `LemonRouter.ChannelAdapter.Telegram`
- `LemonRouter.ChannelsDelivery` (if replaced by `LemonChannels.Dispatcher`)
- router-side Telegram delivery state handling
- gateway-side queue-mode logic
- `LemonGateway.Types.Job.queue_mode`
- `LemonGateway.Runtime.submit/1` old compatibility path (if all callers use `submit_execution/1`)
- `ThreadWorker` if it becomes unnecessary
- duplicate pending-compaction implementation in Telegram transport

## 12.3 Add hard architecture rules

Extend quality checks so the following are explicitly forbidden:

### Router forbiddens
Router may not reference:
- `LemonChannels.OutboundPayload`
- `LemonChannels.Telegram.Truncate`
- `LemonChannels.GatewayConfig`
- `LemonChannels.EngineRegistry`

### Gateway forbiddens
Gateway may not implement:
- queue-mode branching
- auto-resume request mutation
- conversation-key selection

### Shared-store forbiddens
Shared-domain modules may not call raw generic store APIs outside wrappers.

### Channels forbiddens
Channels may not mutate conversation prompts for pending compaction.
That belongs to router.

## 12.4 Final docs to update

Update these to the final architecture:

- `README.md`
- `docs/architecture_boundaries.md`
- `apps/lemon_gateway/AGENTS.md`
- `apps/lemon_channels/AGENTS.md`
- `apps/coding_agent/AGENTS.md`
- `apps/lemon_router/README.md` or `AGENTS.md` if present
- any planning docs that still describe gateway-owned queue semantics

## 12.5 Tests for Phase 6

Run the full target validation suite:

```bash
mix lemon.quality
mix test apps/lemon_core
mix test apps/lemon_router
mix test apps/lemon_channels
mix test apps/lemon_gateway
mix test apps/coding_agent
```

If that is too expensive for every intermediate PR, still run it for the final cleanup PR of this phase.

## 12.6 Acceptance criteria

- no compatibility code is still carrying the old architecture
- quality rules enforce the intended ownership
- docs describe the actual architecture, not the former one
- final integration behavior matches the pre-refactor system

---

## 13. Appendix A — Exact move map

This appendix is intentionally mechanical.

## 13.1 Router → channels move map

| Current location | Move target |
|---|---|
| `LemonRouter.ChannelAdapter.Telegram.truncate/1` | `LemonChannels.Adapters.Telegram.Renderer` internal helper |
| `LemonRouter.ChannelAdapter.Telegram.batch_files/1` | `LemonChannels.Adapters.Telegram.FileBatcher` |
| `LemonRouter.ChannelAdapter.Telegram.tool_status_reply_markup/1` | `LemonChannels.Adapters.Telegram.StatusRenderer` |
| `LemonRouter.ChannelAdapter.Telegram.handle_delivery_ack/3` | `LemonChannels.PresentationState` |
| `LemonRouter.ChannelAdapter.Generic.emit_stream_output/1` | `LemonChannels.Adapters.Generic.Renderer` |
| `LemonRouter.ChannelAdapter.Generic.emit_tool_status/2` | `LemonChannels.Adapters.Generic.Renderer` |
| `LemonRouter.RunProcess.OutputTracker` payload construction | `LemonChannels.Dispatcher` + renderers |
| Telegram message-id ↔ resume/session indexing | `LemonChannels.Telegram.ResumeIndexStore` |

## 13.2 Gateway queue logic → router move map

| Current gateway logic | New router owner |
|---|---|
| `ThreadWorker.enqueue_by_mode/2` logic | `SessionCoordinator` |
| followup debounce | `SessionCoordinator` |
| steer fallback / backlog promotion | `SessionCoordinator` |
| interrupt insertion | `SessionCoordinator` |
| `Scheduler.maybe_apply_auto_resume/1` | `ResumeResolver` |
| `Scheduler.thread_key(job)` semantics | `ConversationKey` |

## 13.3 Store move map

| Current raw store usage | New wrapper |
|---|---|
| `Store.get_chat_state/1`, `put_chat_state/2` | `ChatStateStore` |
| `Store.get_run/1`, `append_run_event/2`, `finalize_run/2`, `get_run_history/1` | `RunStore` |
| `Store.put_progress_mapping/3`, `get_run_by_progress/2` | `ProgressStore` |
| policy helpers / policy tables | `PolicyStore` |
| `pending_compaction` | `PendingCompactionStore` |
| Telegram session/model/default tables | `Telegram.StateStore` |
| Telegram message resume/session index tables | `Telegram.ResumeIndexStore` |

---

## 14. Appendix B — Search commands for the implementer

Use these before and after each phase.

### Find router leaks into channels rendering

```bash
rg -n 'LemonChannels\.(OutboundPayload|Telegram\.Truncate|GatewayConfig|EngineRegistry)' apps/lemon_router
```

### Find gateway queue semantics

```bash
rg -n 'queue_mode|followup|steer|interrupt|thread_key|auto_resume' apps/lemon_gateway/lib
```

### Find raw generic store use

```bash
rg -n 'LemonCore\.Store\.(put|get|delete|list)\(' apps
```

### Find Telegram-specific table coupling outside channels

```bash
rg -n 'telegram_(msg_resume|msg_session|selected_resume|default_model|default_thinking|thread_generation|pending_compaction)' apps
```

### Find router payload construction

```bash
rg -n 'OutboundPayload|ChannelsDelivery|reply_markup|message_id' apps/lemon_router/lib
```

---

## 15. Appendix C — Do-not-do list

These mistakes will recreate the current problems.

1. Do not add another router-side adapter abstraction for Telegram after moving rendering to channels.
2. Do not let gateway keep “temporary” queue-mode logic after router coordinator exists.
3. Do not add new generic store tables directly from feature code in shared domains.
4. Do not parse channel-specific resume syntax in router once `RunRequest.resume` exists.
5. Do not leave duplicate pending-compaction logic in both router and Telegram transport.
6. Do not rename giant public modules just to make the diff look cleaner. Keep public APIs stable; split internals instead.
7. Do not land untested compatibility shims.

---

## 16. Recommended PR breakdown

Use this PR sequence:

1. **PR 1** — Phase 0 quality and governance fixes
2. **PR 2** — Phase 1 contracts (`RunRequest.resume`, `DeliveryIntent`, `ExecutionRequest`, `Dispatcher`)
3. **PR 3** — generic/non-Telegram delivery migration to `Dispatcher`
4. **PR 4** — Telegram renderer migration and router adapter deletion
5. **PR 5** — router `SessionCoordinator` introduction with compatibility mode
6. **PR 6** — move queue semantics from gateway to router
7. **PR 7** — typed store wrappers + shared-domain call-site migration
8. **PR 8** — pending-compaction unification + Telegram store ownership cleanup
9. **PR 9** — `CodingAgent.Session` internal decomposition
10. **PR 10** — `CodingAgent.Tools.Task` internal decomposition
11. **PR 11** — Telegram transport decomposition continuation
12. **PR 12** — delete compatibility code + final architecture rule enforcement

If one PR gets too large, split it again. Do not merge “mega PRs”.

---

## 17. Final definition of done

This refactor is done when all of the following are true:

- a Telegram UI change can be implemented entirely inside `lemon_channels`
- a queue-mode behavior change can be implemented entirely inside `lemon_router`
- gateway no longer decides conversation semantics
- shared domains use typed store APIs
- raw generic store calls are controlled
- `CodingAgent.Session` and `CodingAgent.Tools.Task` are smaller because responsibilities are split
- architecture quality checks enforce the intended ownership
- README/docs/AGENTS all describe the same architecture
