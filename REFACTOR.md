Static review only: I unpacked the umbrella, traced the main execution paths, and read the boundary docs/checkers, but I did **not** boot the system or run the test suite.

## Verdict

Yes — the overall architecture basically makes sense.

This is a **BEAM/OTP subsystem architecture**, not a classic CRUD layered app, and within that model it is more coherent than most umbrella repos. The big split is understandable and mostly consistent in code:

* `ai` / `agent_core` / `coding_agent` form the agent stack.
* `lemon_router` owns conversation semantics and policy/orchestration.
* `lemon_gateway` owns execution lifecycle and slot scheduling.
* `lemon_channels` owns rendering/delivery.
* `lemon_control_plane` owns RPC/API surface.
* `lemon_core` owns shared primitives.

That split is documented in `README.md:1141-1215` and is also reflected in the umbrella deps in `apps/lemon_router/mix.exs:26-32`, `apps/lemon_gateway/mix.exs:28-46`, `apps/lemon_channels/mix.exs:26-28`, `apps/lemon_control_plane/mix.exs:26-36`, and `apps/lemon_core/mix.exs:26-28`.

The strongest sign that the architecture is real, not aspirational, is that the repo has explicit guardrails:

* dependency policy in `docs/architecture_boundaries.md:7-25`
* runtime ownership rules in `docs/architecture_boundaries.md:41-53`
* enforcement in `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex:25-60`
* source-pattern guardrails in `apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex:23-205`
* CI-style quality task in `apps/lemon_core/lib/mix/tasks/lemon.quality.ex:44-48`

That is all good architecture hygiene.

## What is working well

### 1. Router / gateway / channels is a good split

This is the cleanest part of the design.

`LemonGateway.ExecutionRequest` is explicitly a **queue-semantic-free execution contract** (`apps/lemon_gateway/lib/lemon_gateway/execution_request.ex:1-4`), and it refuses to proceed without a router-owned `conversation_key` (`execution_request.ex:68-77`). The scheduler also refuses to invent that key (`apps/lemon_gateway/lib/lemon_gateway/scheduler.ex:488-495`), and `ThreadWorker` explicitly says queue semantics live in `lemon_router` (`apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex:3-7`).

On the router side, `RunOrchestrator` resolves the `conversation_key` and builds the `ExecutionRequest` before handing it to `SessionCoordinator` (`apps/lemon_router/lib/lemon_router/run_orchestrator.ex:289-329`). That is a strong, coherent ownership boundary.

### 2. Delivery semantics are separated from channel rendering

`LemonRouter.StreamCoalescer` produces semantic `LemonCore.DeliveryIntent` values and hands them to `LemonChannels.Dispatcher` (`apps/lemon_router/lib/lemon_router/stream_coalescer.ex:14-16`, `335-340`). `LemonChannels.Dispatcher` then picks the renderer (`apps/lemon_channels/lib/lemon_channels/dispatcher.ex:1-23`).

That is exactly the kind of split you want: router emits intent, channels decide presentation.

### 3. Compile-time decoupling is handled thoughtfully

`LemonCore.RouterBridge` and `LemonCore.EventBridge` are good patterns for an umbrella repo where you want runtime collaboration without turning everything into a compile-time hairball (`apps/lemon_core/lib/lemon_core/router_bridge.ex:1-60`, `apps/lemon_core/lib/lemon_core/event_bridge.ex:1-24`).

This is one of the best decisions in the codebase.

### 4. The repo is designed like a BEAM system

You are using registries, dynamic supervisors, per-session/per-run/per-conversation processes, bounded orchestration, and explicit invariants. `docs/beam_agents.md:20-75` is especially good because it states the architectural invariants instead of leaving them as tribal knowledge.

## Where the architecture is getting strained

The main issue is **not wrong boundaries**. The main issue is **too much orchestration spread across too many handoff layers**, plus a few modules that have become local monoliths.

### 1. The run pipeline has too many lifecycle hops

The intended flow is spelled out in `README.md:1159-1161`:

`SessionCoordinator/RunOrchestrator -> ExecutionRequest -> Scheduler -> ThreadWorker -> Run -> Engine -> Events`

In practice there is even more around it:

* router ingress in `LemonRouter.Router`
* orchestration in `RunOrchestrator`
* queue semantics in `SessionCoordinator`
* per-run lifecycle in `RunProcess`
* slot scheduling in `Scheduler`
* per-conversation FIFO in `ThreadWorker`
* execution in `Gateway.Run`
* event fanout/coalescing back through router/channels

`RunProcess` alone is already acting as a lifecycle integration shell (`apps/lemon_router/lib/lemon_router/run_process.ex:1-17`, `93-184`), and `SessionCoordinator` is a 700+ line queueing state machine (`apps/lemon_router/lib/lemon_router/session_coordinator.ex:250-335` plus the rest of the file).

That architecture still makes sense, but it is cognitively expensive. The danger is that future features get added by inserting one more queue, one more wrapper state machine, or one more “temporary” event layer.

What I would do is make the run lifecycle explicit as a single shared phase model, even if the processes stay separate:

```elixir
defmodule LemonCore.RunPhase do
  @type t ::
          :accepted
          | :queued_in_session
          | :waiting_for_slot
          | :starting_engine
          | :streaming
          | :finalizing
          | :completed
          | :failed
          | :aborted
end
```

Then every handoff emits the same phase transition event instead of each subsystem inventing its own local notion of progress.

I would also look hard at whether the **pre-execution transit** responsibilities can be simplified. Right now both router-side and gateway-side layers represent “not running yet, but in motion.” Even if you keep the process split, the state model should feel like one pipeline.

### 2. `lemon_core` is becoming a platform app, not a primitives app

`LemonCore.Application` starts:

* PubSub
* config cache
* the store
* config reloader
* config watcher
* browser local server

See `apps/lemon_core/lib/lemon_core/application.ex:8-14`, `44-50`.

That means `lemon_core` is no longer just “shared primitives.” It is edging toward “shared runtime platform.” That is not inherently wrong, but it changes how you should treat it.

The bigger issue is `LemonCore.Store`: it is a 1.4k LOC generic store with chat state, run events, progress mappings, generic tables, policy tables, introspection, and more (`apps/lemon_core/lib/lemon_core/store.ex:1-40`, `46-220`, and beyond). You already introduced typed wrappers like `RunStore`, `ChatStateStore`, `PolicyStore`, etc., which is good, but the split is incomplete. For example, `RunStore.delete_history/1` still scans raw `:run_history` table entries directly (`apps/lemon_core/lib/lemon_core/run_store.ex:26-38`).

I would move toward domain-owned storage behaviours:

```elixir
defmodule LemonCore.RunStorage do
  @callback get(binary()) :: term()
  @callback append_event(binary(), map()) :: :ok | {:error, term()}
  @callback finalize(binary(), map()) :: :ok | {:error, term()}
  @callback history(binary(), keyword()) :: list()
  @callback delete_session(binary()) :: :ok | {:error, term()}
end
```

Then implement `RunStorage.Ets`, `RunStorage.Sqlite`, etc., and let `RunStore` depend on that behaviour, not on a giant multi-domain store.

I would **not** split `lemon_core` into multiple umbrella apps immediately. First I would split it internally into hard subdomains and narrow the public APIs. If that works, then app-splitting becomes obvious instead of speculative.

### 3. The boundary governance has already started to drift

The docs and the checker disagree.

Examples:

* `docs/architecture_boundaries.md:15` says `lemon_control_plane` may depend on `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core`, `lemon_router`, `lemon_skills`
* but `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex:32-41` also allows `:lemon_gateway`

Similarly:

* docs say `lemon_gateway` allows only `agent_core`, `coding_agent`, `lemon_channels`, `lemon_core` (`docs/architecture_boundaries.md:19`)
* checker also allows `:ai` and `:lemon_automation` (`architecture_check.ex:45-52`)

And:

* docs say `lemon_router` allows `agent_core`, `coding_agent`, `lemon_channels`, `lemon_core`, `lemon_gateway` (`docs/architecture_boundaries.md:20`)
* checker also allows `:ai` (`architecture_check.ex:54`)

This is a small thing technically, but a big thing architecturally. Once the policy and the enforcement diverge, people stop trusting both.

I would make one source of truth and generate the other from it.

```elixir
defmodule LemonCore.Quality.ArchitecturePolicy do
  @allowed_direct_deps %{...}
  def allowed_direct_deps, do: @allowed_direct_deps
end
```

Then generate `docs/architecture_boundaries.md` from `allowed_direct_deps/0`.

### 4. A few modules are obvious hotspot monoliths

The biggest ones I found statically:

* `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex` — ~3871 LOC
* `apps/lemon_core/lib/lemon_core/store.ex` — ~1434 LOC
* `apps/lemon_gateway/lib/lemon_gateway/run.ex` — ~892 LOC
* `apps/lemon_control_plane/lib/lemon_control_plane/protocol/schemas.ex` — ~880 LOC
* `apps/lemon_router/lib/lemon_router/session_coordinator.ex` — ~732 LOC
* `apps/lemon_channels/lib/lemon_channels/outbox.ex` — ~726 LOC

The Telegram transport is the clearest refactor target. At the top of the file you can already see it handling polling, offsets, delivery, trigger modes, commands, file ops, memory reflection, buffering, model policy, per-chat state, resume selection, session routing, voice transcription, etc. (`apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex:10-33`, `57-139`).

That is too much for one GenServer, even though some concerns are already split into helper modules.

I would make the transport a supervisor and break the live concerns apart:

```elixir
children = [
  LemonChannels.Adapters.Telegram.Poller,
  LemonChannels.Adapters.Telegram.UpdateNormalizer,
  LemonChannels.Adapters.Telegram.CallbackRouter,
  LemonChannels.Adapters.Telegram.MediaGroupAggregator,
  LemonChannels.Adapters.Telegram.ApprovalNotifier,
  LemonChannels.Adapters.Telegram.PerChatState
]
```

The same general advice applies to `Store`, `Gateway.Run`, and `SessionCoordinator`: each one should either be a smaller state machine or a thin façade over submodules with much narrower responsibilities.

### 5. `lemon_control_plane` is drifting toward an RPC monolith

`LemonControlPlane.Methods.Registry` hardcodes a very long builtin method list (`apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex:26-169`), and `Protocol.Schemas` is a giant central schema map (`apps/lemon_control_plane/lib/lemon_control_plane/protocol/schemas.ex:1-180` and much more).

That works for a while, but it scales poorly because:

* adding a method means touching multiple centralized files
* ownership becomes fuzzy
* validation and implementation drift apart

I would colocate schema with the method implementation:

```elixir
defmodule LemonControlPlane.Methods.Sessions.Delete do
  use LemonControlPlane.Method

  def name, do: "sessions.delete"

  def schema do
    %{
      required: %{"sessionKey" => :string}
    }
  end

  def scopes, do: [:sessions_write]

  def handle(%{"sessionKey" => session_key}, _ctx) do
    :ok = LemonCore.RunStore.delete_session(session_key)
    {:ok, %{"deleted" => true}}
  end
end
```

Then the registry can discover modules, and `Schemas.validate/2` can call `module.schema/0` instead of maintaining a giant global map.

### 6. There are a couple of smaller layering leaks

The biggest small one I noticed: `lemon_gateway` depends on `lemon_channels` in `apps/lemon_gateway/mix.exs:43-46`, but actual code usage appears very thin. One concrete reference is `LemonGateway.Health.xmtp_transport_check/0` reaching into `LemonChannels.Adapters.Xmtp.Transport` (`apps/lemon_gateway/lib/lemon_gateway/health.ex:149-176`).

That kind of health-check-driven compile-time dependency is how clean boundaries slowly get muddy. I would move cross-subsystem health aggregation up to the control plane or a top-level runtime app.

Another smaller one: router-owned pending compaction is architecturally consistent with your rules, but `LemonRouter.Router.handle_inbound/1` still does a hidden prompt rewrite via `maybe_apply_pending_compaction/3` (`apps/lemon_router/lib/lemon_router/router.ex:38-40`, `247-334`). That should probably be an explicit submission stage, not a hidden mutation inside ingress handling.

## What I would change first

In order:

1. **Fix policy drift immediately.**
   Make architecture policy single-source-of-truth and generate docs from it.

2. **Refactor the hotspot modules before changing app boundaries.**
   Start with:

   * Telegram transport
   * `LemonCore.Store`
   * `SessionCoordinator`
   * control-plane schemas

3. **Introduce a canonical end-to-end run phase model.**
   Not a rewrite; just make the handoff pipeline explicit and uniformly observable.

4. **Turn typed store wrappers into real domain storage APIs.**
   Right now they are useful wrappers, but not yet strong enough to prevent the giant-store pattern from reappearing.

## Bottom line

The architecture is **good enough and directionally right**. I would not rewrite it. I would not collapse the umbrella into fewer apps. I would not replace the BEAM process architecture with a simpler synchronous service layer.

The improvements are mostly about:

* reducing orchestration complexity
* shrinking hotspot modules
* making boundary enforcement trustworthy
* finishing the move from “generic shared utilities” to “domain-owned APIs”

Below is an **agent-facing implementation spec** for the first 3 PRs:

1. **PR 1 — architecture policy source of truth**
2. **PR 2 — canonical run phase model**
3. **PR 3 — `SessionCoordinator` pure-state extraction**

This is written so a weaker implementation agent can follow it mechanically.

---

# Overall constraints

## Hard constraints

Do **not** change these architecture decisions:

* `lemon_router` owns conversation/session/queue semantics.
* `lemon_gateway` owns execution lifecycle and slot scheduling.
* `lemon_channels` owns rendering/transport/presentation.
* `lemon_control_plane` owns RPC/API surface.
* `lemon_core` owns shared primitives and narrow shared services.

Do **not** do a broad rewrite.

Do **not** change public behavior unless the spec explicitly says to.

Do **not** delete existing checks/tests first and “rebuild later.”

Prefer:

* additive changes
* compatibility shims where needed
* characterization tests before invasive edits

## Required validation commands

At minimum, after each PR, run:

```bash
mix test apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs
mix test apps/lemon_core/test/lemon_core/quality/architecture_rules_check_test.exs
mix test apps/lemon_core/test/mix/tasks/lemon.quality_test.exs
mix lemon.quality
```

For PR 2 and PR 3 also run targeted router/gateway tests if they exist.

If the repo has broad CI and time permits, also run:

```bash
mix test
```

---

# PR 1 — Architecture policy source of truth

## Purpose

Eliminate drift between:

* `docs/architecture_boundaries.md`
* `LemonCore.Quality.ArchitectureCheck`
* any other hardcoded architecture policy

The repository currently duplicates app dependency policy in multiple places. This must be reduced to one canonical source.

---

## Required end state

There must be exactly one canonical module that defines the direct umbrella dependency policy.

All of the following must derive from it:

* `ArchitectureCheck.allowed_direct_deps/0`
* the dependency-checking logic used by `ArchitectureCheck.run/1`
* the generated policy section in `docs/architecture_boundaries.md`

The checker and the docs must no longer be maintained independently.

---

## Files to create

Create:

* `apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex`
* `apps/lemon_core/lib/mix/tasks/lemon.architecture.docs.ex`

Optional helper module if needed:

* `apps/lemon_core/lib/lemon_core/quality/architecture_docs.ex`

---

## Files to modify

Modify:

* `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`
* `docs/architecture_boundaries.md`
* `apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs`
* `apps/lemon_core/test/mix/tasks/lemon.quality_test.exs`

Potentially also:

* `apps/lemon_core/lib/mix/tasks/lemon.quality.ex`
* `apps/lemon_core/test/lemon_core/quality/docs_check_test.exs`

Only if needed to integrate doc generation / stale-doc detection cleanly.

---

## Implementation details

## Step 1 — add `ArchitecturePolicy`

Create:

`apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex`

Required shape:

```elixir
defmodule LemonCore.Quality.ArchitecturePolicy do
  @moduledoc """
  Canonical source of truth for architecture dependency policy.

  This module defines which umbrella apps may directly depend on which other
  umbrella apps. Human-readable docs and machine checks must derive from this
  module rather than duplicating policy in multiple places.
  """

  @type app :: atom()
  @type dependency_map :: %{optional(app()) => [app()]}

  @allowed_direct_deps %{
    # exact current intended policy goes here
  }

  @spec allowed_direct_deps() :: dependency_map()
  def allowed_direct_deps do
    @allowed_direct_deps
    |> Enum.into(%{}, fn {app, deps} -> {app, Enum.sort(deps)} end)
  end
end
```

### Rules for this module

* Preserve the **currently intended** policy, not necessarily the stale docs.
* Choose the policy to match the current **actual enforced checker**, unless you have a strong reason not to.
* Return values must be sorted deterministically.
* Do not include runtime ownership prose here; this module is for structured policy data.

## Step 2 — migrate `ArchitectureCheck`

Edit:

`apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`

Required changes:

1. Add alias:

```elixir
alias LemonCore.Quality.ArchitecturePolicy
```

2. Delete the local `@allowed_direct_deps` map.
3. Update `allowed_direct_deps/0` to delegate:

```elixir
@spec allowed_direct_deps() :: %{optional(atom()) => [atom()]}
def allowed_direct_deps, do: ArchitecturePolicy.allowed_direct_deps()
```

4. Update any logic that references `@allowed_direct_deps` to call `allowed_direct_deps/0` or `ArchitecturePolicy.allowed_direct_deps/0`.

### Important

Do not accidentally leave a stale copy of the old map in comments or tests. The point is single-source-of-truth.

## Step 3 — add deterministic docs renderer

Create either:

* `LemonCore.Quality.ArchitectureDocs`
* or generate directly in mix task

Recommended helper shape:

```elixir
defmodule LemonCore.Quality.ArchitectureDocs do
  alias LemonCore.Quality.ArchitecturePolicy

  @doc """
  Renders the canonical architecture dependency policy as markdown table rows.
  """
  @spec render_dependency_policy_markdown() :: String.t()
  def render_dependency_policy_markdown do
    deps = ArchitecturePolicy.allowed_direct_deps()

    header = """
    | App | Allowed direct umbrella deps |
    | --- | --- |
    """

    rows =
      deps
      |> Enum.sort_by(fn {app, _} -> Atom.to_string(app) end)
      |> Enum.map(fn {app, allowed} ->
        app_cell = "`#{app}`"

        deps_cell =
          case allowed do
            [] -> "*(none)*"
            list -> Enum.map_join(list, ", ", &"`#{&1}`")
          end

        "| #{app_cell} | #{deps_cell} |"
      end)

    Enum.join([header | rows], "\n")
  end
end
```

## Step 4 — add docs generation mix task

Create:

`apps/lemon_core/lib/mix/tasks/lemon.architecture.docs.ex`

Required behavior:

* updates only the generated dependency policy section in `docs/architecture_boundaries.md`
* must be deterministic
* must not overwrite the rest of the doc unpredictably

Recommended approach:

* define marker comments in the doc
* replace only content between them

Add markers to the doc like:

```md
<!-- architecture_policy:start -->
...generated section...
<!-- architecture_policy:end -->
```

Then the mix task replaces only the section between those markers.

### Mix task behavior

Usage:

```bash
mix lemon.architecture.docs
mix lemon.architecture.docs --check
mix lemon.architecture.docs --root /path/to/repo
```

Recommended semantics:

* default mode: rewrite file in place
* `--check`: fail if file contents differ from generated output
* `--root`: optional repository root

Recommended task structure:

```elixir
defmodule Mix.Tasks.Lemon.Architecture.Docs do
  use Mix.Task

  alias LemonCore.Quality.ArchitectureDocs

  @shortdoc "Generate architecture boundary docs from policy"

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [check: :boolean, root: :string]
      )

    root = opts[:root] || File.cwd!()
    path = Path.join(root, "docs/architecture_boundaries.md")

    existing = File.read!(path)
    generated = replace_generated_section(existing, ArchitectureDocs.render_dependency_policy_markdown())

    cond do
      opts[:check] and existing != generated ->
        Mix.raise("docs/architecture_boundaries.md is stale. Run mix lemon.architecture.docs")

      opts[:check] ->
        Mix.shell().info("[ok] architecture docs are up to date")

      true ->
        File.write!(path, generated)
        Mix.shell().info("Updated docs/architecture_boundaries.md")
    end
  end
end
```

## Step 5 — update `docs/architecture_boundaries.md`

Edit the doc to insert the generation markers around the “Direct Dependency Policy” table.

Required outcome:

* the table content matches the canonical policy
* the remainder of the doc stays human-authored

Do not generate the whole file. Generate only the policy table section.

## Step 6 — optionally wire docs freshness into `mix lemon.quality`

Preferred outcome:

* `mix lemon.quality` fails if architecture docs are stale

There are two acceptable implementations:

### Option A

Extend existing docs freshness checks if such infrastructure already exists.

### Option B

Add an explicit architecture-doc freshness check inside `Mix.Tasks.Lemon.Quality`.

Example:

```elixir
{:architecture_docs, fn -> run_architecture_docs_check(root) end}
```

Where `run_architecture_docs_check/1` shells into the same underlying logic used by `mix lemon.architecture.docs --check`.

Do not duplicate comparison logic in multiple places if avoidable.

---

## PR 1 acceptance criteria

All must be true.

### Functional

* `LemonCore.Quality.ArchitecturePolicy.allowed_direct_deps/0` exists and is the only canonical source of direct umbrella dependency policy.
* `ArchitectureCheck` no longer contains its own local dependency policy map.
* `docs/architecture_boundaries.md` dependency table is generated from canonical policy data.
* There is a deterministic way to check doc freshness.
* `mix lemon.quality` catches architecture policy drift and/or stale architecture docs.

### Behavioral

* Running the docs generator twice in a row yields no diff on the second run.
* The generated table is sorted deterministically.
* Existing architecture checks continue to work.

### Code quality

* no duplicate policy map remains in `ArchitectureCheck`
* no hardcoded table rows remain in the doc’s generated section
* naming is clear: “policy” for data, “docs” for rendering, “check” for validation

---

## PR 1 required tests

### 1. `ArchitecturePolicy` test

Add tests asserting:

* it returns a map
* keys include known apps
* lists are sorted
* `:lemon_core` maps to `[]`

You can add to:

* `apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs`
  or create:
* `architecture_policy_test.exs`

### 2. `ArchitectureCheck` delegation test

Add/modify tests so they confirm that `ArchitectureCheck.allowed_direct_deps/0` returns the same value as `ArchitecturePolicy.allowed_direct_deps/0`.

### 3. docs generation idempotence test

Add test coverage for the markdown renderer and/or section replacement logic.

Cases:

* generating rows from policy returns expected format
* replacing generated section is idempotent
* running with `--check` on fresh content passes
* running with `--check` on stale content fails

### 4. quality task regression test

Add or modify `apps/lemon_core/test/mix/tasks/lemon.quality_test.exs` so stale architecture docs are reported as failure, if you wire this into `mix lemon.quality`.

---

## PR 1 suggested test cases

### Case A — policy sync

```elixir
test "architecture check delegates to architecture policy" do
  assert ArchitectureCheck.allowed_direct_deps() ==
           ArchitecturePolicy.allowed_direct_deps()
end
```

### Case B — renderer formats empty deps

Expected row:

```md
| `lemon_core` | *(none)* |
```

### Case C — renderer formats sorted deps

Expected order:

* app rows sorted alphabetically
* dependency names sorted alphabetically within row

### Case D — stale doc detection

Given doc content with altered generated section,
`mix lemon.architecture.docs --check` must fail.

---

## PR 1 non-goals

Do not:

* redesign the runtime ownership rule prose
* move `ArchitectureRulesCheck` patterns into the policy module unless strictly necessary
* change actual dependency policy beyond reconciling current checker-vs-doc drift

---

# PR 2 — Canonical run phase model

## Purpose

Introduce one shared vocabulary for run lifecycle across router and gateway without rewriting the whole execution pipeline yet.

This PR is primarily about:

* types
* valid transitions
* canonical naming
* events/tests

It is **not** a full migration of every existing event or state field.

---

## Required end state

There must be a shared run lifecycle model in `lemon_core`.

At minimum it must define:

* canonical run phases
* legal transitions between phases
* a safe API to validate transitions

Optional but strongly preferred:

* a canonical event payload builder for phase-change events

---

## Files to create

Create:

* `apps/lemon_core/lib/lemon_core/run_phase.ex`
* `apps/lemon_core/lib/lemon_core/run_phase_graph.ex`

Optional:

* `apps/lemon_core/lib/lemon_core/run_phase_event.ex`

Create tests:

* `apps/lemon_core/test/lemon_core/run_phase_test.exs`
* `apps/lemon_core/test/lemon_core/run_phase_graph_test.exs`

Potential optional integration tests in router/gateway if appropriate.

---

## Files to modify

Likely modify:

* selected router/gateway modules that can emit canonical phase transitions cheaply
* potentially `RunProcess`, `RunOrchestrator`, `SessionCoordinator`, `Scheduler`, or related event publication points

This PR should stay incremental. Do not migrate everything.

---

## Canonical phase set

Use this exact initial set unless code inspection reveals a strong incompatibility:

```elixir
:accepted
:queued_in_session
:waiting_for_slot
:dispatched_to_gateway
:starting_engine
:streaming
:finalizing
:completed
:failed
:aborted
```

These names are intentionally cross-subsystem and end-to-end.

---

## Implementation details

## Step 1 — add `RunPhase`

Create:

`apps/lemon_core/lib/lemon_core/run_phase.ex`

Required contents:

```elixir
defmodule LemonCore.RunPhase do
  @moduledoc """
  Canonical end-to-end lifecycle phases for a run across router and gateway.

  These phases provide a shared vocabulary for observability, debugging, and
  boundary clarity. Subsystems may maintain additional local state, but any
  externally observable lifecycle should map onto this phase model.
  """

  @type t ::
          :accepted
          | :queued_in_session
          | :waiting_for_slot
          | :dispatched_to_gateway
          | :starting_engine
          | :streaming
          | :finalizing
          | :completed
          | :failed
          | :aborted

  @ordered [
    :accepted,
    :queued_in_session,
    :waiting_for_slot,
    :dispatched_to_gateway,
    :starting_engine,
    :streaming,
    :finalizing,
    :completed,
    :failed,
    :aborted
  ]

  @spec all() :: [t()]
  def all, do: @ordered

  @spec terminal?(t()) :: boolean()
  def terminal?(phase), do: phase in [:completed, :failed, :aborted]
end
```

## Step 2 — add `RunPhaseGraph`

Create:

`apps/lemon_core/lib/lemon_core/run_phase_graph.ex`

Required API:

```elixir
defmodule LemonCore.RunPhaseGraph do
  alias LemonCore.RunPhase

  @transitions %{
    accepted: [:queued_in_session, :waiting_for_slot, :aborted],
    queued_in_session: [:waiting_for_slot, :aborted],
    waiting_for_slot: [:dispatched_to_gateway, :aborted, :failed],
    dispatched_to_gateway: [:starting_engine, :failed, :aborted],
    starting_engine: [:streaming, :finalizing, :failed, :aborted],
    streaming: [:finalizing, :failed, :aborted],
    finalizing: [:completed, :failed],
    completed: [],
    failed: [],
    aborted: []
  }

  @spec allowed_next(RunPhase.t()) :: [RunPhase.t()]
  def allowed_next(phase), do: Map.get(@transitions, phase, [])

  @spec valid_transition?(RunPhase.t(), RunPhase.t()) :: boolean()
  def valid_transition?(from, to), do: to in allowed_next(from)

  @spec transition(RunPhase.t(), RunPhase.t()) ::
          :ok | {:error, {:invalid_transition, RunPhase.t(), RunPhase.t()}}
  def transition(from, to) do
    if valid_transition?(from, to) do
      :ok
    else
      {:error, {:invalid_transition, from, to}}
    end
  end
end
```

### Important

Do not overcomplicate this with graph libraries or persistence.

This PR is about shared semantics, not graph infrastructure.

## Step 3 — define canonical event shape

Preferred, though not mandatory, for this PR:

Create helper:

`apps/lemon_core/lib/lemon_core/run_phase_event.ex`

Example:

```elixir
defmodule LemonCore.RunPhaseEvent do
  alias LemonCore.RunPhase

  @spec build(keyword()) :: map()
  def build(opts) do
    %{
      type: :run_phase_changed,
      run_id: Keyword.fetch!(opts, :run_id),
      session_key: Keyword.get(opts, :session_key),
      conversation_key: Keyword.get(opts, :conversation_key),
      phase: Keyword.fetch!(opts, :phase),
      previous_phase: Keyword.get(opts, :previous_phase),
      source: Keyword.fetch!(opts, :source),
      at: Keyword.get(opts, :at, DateTime.utc_now())
    }
  end
end
```

If this helper is added, validate that `phase` and `previous_phase` are members of `RunPhase.all/0`.

## Step 4 — add at least a minimal mapping point in real code

This PR should not remain purely theoretical. Add at least one or two concrete emission points where canonical phases are attached or published.

Recommended low-risk mapping points:

### Router ingress / queue

When a run is accepted/submitted:

* emit or annotate `:accepted`
* if enqueued behind another run, emit or annotate `:queued_in_session`

### Gateway execution start

When execution is actually handed off:

* emit or annotate `:dispatched_to_gateway`
* when engine starts, emit or annotate `:starting_engine`

### Completion

At successful end:

* `:finalizing`
* then `:completed`

### Failure / abort

Map to:

* `:failed`
* `:aborted`

You do **not** need to fully unify every legacy event in this PR. But there must be at least one real code path using the canonical phase system.

## Step 5 — document mapping from existing lifecycle points

Add a short doc section, probably to `docs/architecture_boundaries.md` or a new lifecycle doc if appropriate, explaining the intended mapping:

| Existing subsystem point            | Canonical phase          |
| ----------------------------------- | ------------------------ |
| submission accepted                 | `:accepted`              |
| queued in `SessionCoordinator`      | `:queued_in_session`     |
| awaiting scheduler slot             | `:waiting_for_slot`      |
| handed to gateway runtime/run       | `:dispatched_to_gateway` |
| engine/session boot begins          | `:starting_engine`       |
| first streamed output/tool progress | `:streaming`             |
| persistence and output flush        | `:finalizing`            |
| success                             | `:completed`             |
| execution failure                   | `:failed`                |
| user/system abort                   | `:aborted`               |

This can be brief but must exist.

---

## PR 2 acceptance criteria

### Functional

* `LemonCore.RunPhase` exists with the canonical phase set.
* `LemonCore.RunPhaseGraph` exists with valid transition logic.
* There is a programmatic API to check legal/illegal transitions.
* At least one real router or gateway path now emits, stores, or annotates canonical phase transitions.

### Behavioral

* illegal transitions are rejected by `RunPhaseGraph.transition/2`
* terminal states are terminal
* phase order is deterministic
* no broad behavior regressions in run execution flow

### Design

* the phase names are cross-subsystem and not router- or gateway-local jargon
* this PR does not force a mass rewrite of all lifecycle code
* the code makes future migration straightforward

---

## PR 2 required tests

## Unit tests for `RunPhase`

Add:

`apps/lemon_core/test/lemon_core/run_phase_test.exs`

Test cases:

1. `all/0` returns the expected list in order
2. `terminal?/1` is true for `:completed`, `:failed`, `:aborted`
3. `terminal?/1` is false for non-terminal phases

## Unit tests for `RunPhaseGraph`

Add:

`apps/lemon_core/test/lemon_core/run_phase_graph_test.exs`

Minimum test cases:

1. `accepted -> queued_in_session` is valid
2. `queued_in_session -> waiting_for_slot` is valid
3. `waiting_for_slot -> dispatched_to_gateway` is valid
4. `starting_engine -> streaming` is valid
5. `streaming -> finalizing` is valid
6. `finalizing -> completed` is valid
7. `completed -> streaming` is invalid
8. `failed -> completed` is invalid
9. `aborted -> starting_engine` is invalid

Example:

```elixir
test "completed cannot transition back to streaming" do
  assert {:error, {:invalid_transition, :completed, :streaming}} =
           LemonCore.RunPhaseGraph.transition(:completed, :streaming)
end
```

## Optional integration tests

If there is an event bus or event publication path already easy to assert, add a minimal integration test showing that a successful run path emits canonical phase transitions in monotonic order.

If that is too expensive in this PR, add a smaller test around whichever module now maps a local event to a canonical phase.

---

## PR 2 non-goals

Do not:

* replace all existing lifecycle fields with canonical phases
* rewrite every run event payload shape
* redesign the entire run orchestration pipeline
* persist phase history globally unless already natural in current code

---

# PR 3 — `SessionCoordinator` pure-state extraction

## Purpose

Reduce one of the highest-complexity hotspots without changing ownership boundaries.

Current target:

* keep `SessionCoordinator` as the router-owned process boundary
* move queue semantics and state transitions into pure modules
* make queue behavior directly unit-testable without spinning up the GenServer

This is the highest-risk of the 3 PRs. Proceed incrementally.

---

## Required end state

`SessionCoordinator` remains the public GenServer interface, but it no longer contains most of the queueing business logic inline.

Instead, queue mutation rules must live in pure modules, ideally:

* `LemonRouter.SessionState`
* `LemonRouter.SessionTransitions`
* optionally `LemonRouter.SessionEffects`
* optionally `LemonRouter.SessionPolicies`

At minimum, `submit`, active completion, cancellation, and session-abort queue manipulation must route through pure transition functions.

---

## Files to create

Create:

* `apps/lemon_router/lib/lemon_router/session_state.ex`
* `apps/lemon_router/lib/lemon_router/session_transitions.ex`

Strongly recommended:

* `apps/lemon_router/lib/lemon_router/session_effects.ex`
* `apps/lemon_router/lib/lemon_router/session_policies.ex`

Tests:

* `apps/lemon_router/test/lemon_router/session_transitions_test.exs`
* `apps/lemon_router/test/lemon_router/session_state_test.exs` if needed

Potentially modify/add integration tests for `SessionCoordinator`.

---

## Files to modify

Modify:

* `apps/lemon_router/lib/lemon_router/session_coordinator.ex`

Possibly related tests under `apps/lemon_router/test/...`

---

## High-level design

## `SessionCoordinator` after refactor

It should become primarily:

* process registration/lifecycle
* API boundary (`submit`, `cancel`, `abort_session`, etc.)
* IO/effect execution
* translating incoming messages into commands
* calling pure transitions
* applying returned effects

It should **not** be the main home of queue mutation rules.

## `SessionState`

This should define the core coordinator state shape as a typed struct, even if the underlying GenServer still stores a plain map temporarily during migration.

Recommended minimum struct:

```elixir
defmodule LemonRouter.SessionState do
  alias LemonGateway.ExecutionRequest

  @type active_run :: %{
          run_id: binary(),
          session_key: binary(),
          pid: pid() | nil,
          mon_ref: reference() | nil,
          submission: map()
        }

  @type queued_submission :: %{
          run_id: binary(),
          session_key: binary(),
          queue_mode: atom(),
          execution_request: ExecutionRequest.t(),
          meta: map()
        }

  defstruct conversation_key: nil,
            active: nil,
            queue: [],
            last_followup_at_ms: nil,
            pending_steers: %{}
end
```

Do not over-model every field immediately. Start with the existing state shape and make it explicit.

## `SessionTransitions`

This module should be pure.

No:

* `GenServer.call`
* `send/2`
* `Registry`
* logging side effects
* gateway submission
* timers

It may return **effects** to be executed by `SessionCoordinator`.

Recommended return shape:

```elixir
{:ok, new_state, effects}
```

Where `effects` is a list of tagged tuples, for example:

```elixir
[
  {:maybe_start_next},
  {:emit_metric, :run_queued, %{run_id: "r2"}},
  {:clear_pending_steer, "r2"}
]
```

You do not need to design a huge effect DSL. Keep it small and local.

---

## Transition surface that must be extracted in this PR

At minimum, extract pure logic for:

1. submission normalization result application to state
2. enqueue behavior by queue mode
3. active-run teardown after DOWN
4. queue clearing on cancel
5. session-specific queue drop on abort
6. pending-steer clearing/fallback if they are truly state-only and not IO-bound

Do not try to extract every single helper in one pass. Extract the queue/state logic first.

---

## Implementation details

## Step 1 — create `SessionState`

Create:

`apps/lemon_router/lib/lemon_router/session_state.ex`

Required features:

* struct matching the existing coordinator state fields
* `new/1` constructor from init opts
* helper predicates if useful, such as `idle?/1`, `active?/1`

Example:

```elixir
defmodule LemonRouter.SessionState do
  @moduledoc """
  Pure state container for router-owned per-conversation queue semantics.
  """

  defstruct conversation_key: nil,
            active: nil,
            queue: [],
            last_followup_at_ms: nil,
            pending_steers: %{}

  @type t :: %__MODULE__{
          conversation_key: term(),
          active: map() | nil,
          queue: [map()],
          last_followup_at_ms: integer() | nil,
          pending_steers: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      conversation_key: Keyword.fetch!(opts, :conversation_key),
      active: nil,
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }
  end

  @spec idle?(t()) :: boolean()
  def idle?(%__MODULE__{active: nil}), do: true
  def idle?(_), do: false
end
```

## Step 2 — create `SessionTransitions`

Create:

`apps/lemon_router/lib/lemon_router/session_transitions.ex`

Required initial API:

```elixir
defmodule LemonRouter.SessionTransitions do
  alias LemonRouter.SessionState

  @type effect ::
          {:maybe_start_next}
          | {:clear_queue}
          | {:clear_pending_steers}
          | {:drop_session_queue, binary()}
          | {:drop_session_pending_steers, binary()}
          | {:mark_active_cleared}
          | {:start_submission, map()}
          | {:noop}

  @spec submit(SessionState.t(), map()) :: {:ok, SessionState.t(), [effect()]}
  def submit(state, submission) do
    ...
  end

  @spec cancel(SessionState.t(), term()) :: {:ok, SessionState.t(), [effect()]}
  def cancel(state, reason) do
    ...
  end

  @spec abort_session(SessionState.t(), binary(), term()) ::
          {:ok, SessionState.t(), [effect()]}
  def abort_session(state, session_key, reason) do
    ...
  end

  @spec active_down(SessionState.t(), pid(), reference()) ::
          {:ok, SessionState.t(), [effect()]}
  def active_down(state, pid, mon_ref) do
    ...
  end
end
```

The exact effect type can differ, but it must be explicit and testable.

## Step 3 — move init to `SessionState.new/1`

In `SessionCoordinator.init/1`, replace inline map construction with:

```elixir
{:ok, SessionState.new(opts)}
```

This is a good first compatibility seam.

## Step 4 — migrate `handle_call({:submit, submission}, ...)`

Current flow appears approximately:

* normalize submission
* normalize queue mode
* maybe promote auto followup
* enqueue by mode
* maybe start next

Refactor so that:

1. normalization still happens where necessary
2. state mutation happens via `SessionTransitions.submit/2`
3. coordinator interprets returned effects

Pseudo-shape:

```elixir
def handle_call({:submit, submission}, _from, state) do
  submission = normalize_submission(submission)

  with {:ok, state, effects} <- SessionTransitions.submit(state, submission),
       {state, reply} <- apply_effects_and_compute_reply(state, effects) do
    {:reply, reply, state}
  end
end
```

If this is too invasive, do a smaller step:

* `SessionTransitions.submit/2` returns only new state
* `SessionCoordinator` still calls `maybe_start_next/2`

But the preferred result is explicit effects.

## Step 5 — migrate cancel paths

Migrate these handlers to use pure transitions:

* `handle_cast({:cancel, reason}, state)`
* `handle_cast({:cancel_session, session_key, reason}, state)`
* `handle_cast({:abort_session, session_key, reason}, state)`

The transition layer should decide:

* which queue entries to drop
* whether state is affected
* whether active run matching that session should be marked for cancellation

The coordinator layer should still perform actual cancellation IO if needed.

### Key separation

Pure transition modules may decide **that** active run cancellation should happen.
They must not perform the cancellation themselves.

For example, transition returns an effect:

```elixir
{:cancel_active_run, session_key, reason}
```

Then the coordinator executes it by calling existing IO helpers.

## Step 6 — migrate active-run `:DOWN` handling

Current path:

* clear active registry
* flush pending steers for active
* clear `active`
* `send(self(), :maybe_start_next)`

Extract the state mutation into `SessionTransitions.active_down/3` or similar.

The coordinator should remain responsible for:

* registry cleanup if it is IO-bound
* actually sending itself `:maybe_start_next`

But state mutation should be pure.

## Step 7 — add a small effect interpreter in `SessionCoordinator`

Do not let effect handling sprawl everywhere.

Add a local helper:

```elixir
defp apply_effects(state, effects) do
  Enum.reduce(effects, {state, :ok}, fn effect, {state_acc, reply_acc} ->
    ...
  end)
end
```

Or split into:

* state-only effect handling
* IO effect handling

Keep this minimal.

### Important

Do not accidentally reintroduce business logic into the effect interpreter. It should execute simple commands, not decide policy.

## Step 8 — keep old helper names only if still useful

During migration, it is acceptable to keep existing helper functions like:

* `drop_session_queue/2`
* `clear_queue/1`
* `clear_pending_steers/1`

But if they remain, decide explicitly whether they are:

* pure transition helpers and belong in `SessionTransitions`
* or coordinator IO helpers and belong in `SessionCoordinator`

Do not leave duplicates with the same semantics in both places.

---

## Required behavior to preserve

The following existing semantics must remain intact unless tests prove current code differs:

1. queue semantics are conversation-owned / router-owned
2. only one active run per conversation coordinator
3. queued submissions are preserved in order unless queue policy explicitly changes them
4. cancel vs abort behavior remains distinct
5. aborting a session clears queued work for that session and cancels active work for that session
6. active run completion / DOWN triggers next queued work if any
7. pending steer behavior is not silently lost

If you discover current behavior is inconsistent, do not “fix” it silently in this PR. Preserve behavior and leave a targeted TODO.

---

## PR 3 acceptance criteria

### Structural

* `SessionState` exists and is used by `SessionCoordinator.init/1`
* `SessionTransitions` exists and contains pure queue/state transition logic
* `SessionCoordinator` no longer directly owns most state mutation rules for submit/cancel/abort/active-down paths
* there is a clear boundary between pure transitions and effect execution

### Behavioral

* queue behavior is unchanged from the caller perspective
* active-run teardown still triggers next run scheduling
* cancel and abort semantics still work
* no regression in pending-steer handling for covered scenarios

### Testability

* queue transition behavior can be tested directly via pure unit tests without starting the GenServer
* `SessionCoordinator` still has at least one integration test covering a real submit/start/complete flow

---

## PR 3 required tests

You need **both** pure-state tests and at least minimal coordinator integration coverage.

---

## A. Pure transition tests

Create:

`apps/lemon_router/test/lemon_router/session_transitions_test.exs`

Minimum required test cases:

### 1. submit while idle

Initial:

* `active: nil`
* `queue: []`

Action:

* submit one run

Expected:

* state updated appropriately
* effect list includes starting or maybe-start-next behavior
* no duplicate queue entry

### 2. submit while busy

Initial:

* active run exists
* queue empty

Action:

* submit second run

Expected:

* second run enters queue
* active run unchanged
* no immediate active replacement

### 3. cancel clears queue and requests active cancellation

Initial:

* active exists
* queue has items

Action:

* cancel conversation

Expected:

* queue emptied
* pending steers cleared if appropriate
* effect requests active cancellation

### 4. abort session only affects matching session

Initial:

* active belongs to session A
* queue contains runs for A and B

Action:

* abort session A

Expected:

* A’s queued entries removed
* B’s entries preserved
* active cancellation requested only if active belongs to A

### 5. active DOWN clears active and requests next start

Initial:

* active exists
* queue contains next run

Action:

* `active_down`

Expected:

* active cleared
* next-start effect present

### 6. active DOWN for non-matching pid/ref is no-op

Initial:

* active exists with different pid/ref

Expected:

* unchanged state
* no effects or only `:noop`

### 7. pending steer fallback/clear behavior

Cover whichever pending-steer paths are extracted in this PR.

---

## Example pure test shape

```elixir
defmodule LemonRouter.SessionTransitionsTest do
  use ExUnit.Case, async: true

  alias LemonRouter.{SessionState, SessionTransitions}

  test "submit while busy queues the submission" do
    state = %SessionState{
      conversation_key: {"conv", "key"},
      active: %{run_id: "r1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    submission = %{
      run_id: "r2",
      session_key: "s1",
      queue_mode: :enqueue,
      execution_request: %LemonGateway.ExecutionRequest{run_id: "r2"}
    }

    assert {:ok, new_state, effects} = SessionTransitions.submit(state, submission)

    assert new_state.active.run_id == "r1"
    assert Enum.map(new_state.queue, & &1.run_id) == ["r2"]
    refute {:start_submission, submission} in effects
  end
end
```

---

## B. `SessionCoordinator` integration tests

If the repo already has tests for this module, update them. If not, add a focused test module.

Minimum integration scenarios:

### 1. first submission becomes active

* start coordinator
* submit one run
* assert active run eventually set or `maybe_start_next` flow occurs

### 2. second submission queues behind active

* submit run 1
* submit run 2
* assert run 2 does not become active immediately

### 3. active `:DOWN` starts next queued run

* simulate the monitored process going down if practical
* assert next run gets started

### 4. abort session removes only matching queue entries

* set up mixed queue
* abort one session
* inspect state if there is a safe test seam, or assert downstream effects

If direct state inspection is hard, use `:sys.get_state/1` in tests if the codebase already tolerates it. Do not add public production APIs solely for test inspection if avoidable.

---

## Suggested migration strategy for PR 3

This PR is risky enough that sequence matters.

### Pass 1

* add `SessionState`
* change only `init/1`
* add pure tests for `SessionState`

### Pass 2

* extract submission enqueue logic into `SessionTransitions.submit/2`
* keep `maybe_start_next` in coordinator if needed
* add pure tests

### Pass 3

* extract cancel/abort queue mutation
* keep actual cancellation IO in coordinator
* add pure tests

### Pass 4

* extract active-down state mutation
* add pure tests + one integration test

Do not attempt to extract every helper in a single commit if that obscures correctness.

---

## PR 3 explicit non-goals

Do not:

* move queue ownership out of router
* collapse `SessionCoordinator` into gateway
* redesign queue modes
* redesign pending steer semantics
* replace GenServer with a different process model
* rewrite the whole run orchestration stack

---

# Final deliverable checklist by PR

## PR 1 checklist

* [ ] add `ArchitecturePolicy`
* [ ] remove duplicated direct-deps policy from `ArchitectureCheck`
* [ ] add deterministic docs renderer / generator
* [ ] add marker-based generated section to `docs/architecture_boundaries.md`
* [ ] add stale-doc check
* [ ] update tests
* [ ] `mix lemon.quality` passes

## PR 2 checklist

* [ ] add `RunPhase`
* [ ] add `RunPhaseGraph`
* [ ] add unit tests for legal/illegal transitions
* [ ] wire at least one real router/gateway code path to canonical phases
* [ ] add brief lifecycle mapping doc note
* [ ] targeted tests pass

## PR 3 checklist

* [ ] add `SessionState`
* [ ] migrate `SessionCoordinator.init/1`
* [ ] add `SessionTransitions`
* [ ] extract submit logic
* [ ] extract cancel/abort queue mutation
* [ ] extract active-down state mutation
* [ ] add pure transition tests
* [ ] add/update minimal integration tests
* [ ] preserve observable behavior

---

# Exact validation commands to run after all 3 PRs

```bash
mix format
mix compile

mix test apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs
mix test apps/lemon_core/test/lemon_core/quality/architecture_rules_check_test.exs
mix test apps/lemon_core/test/mix/tasks/lemon.quality_test.exs

mix test apps/lemon_core/test/lemon_core/run_phase_test.exs
mix test apps/lemon_core/test/lemon_core/run_phase_graph_test.exs

mix test apps/lemon_router/test/lemon_router/session_transitions_test.exs

mix lemon.architecture.docs --check
mix lemon.quality
```

If there are coordinator-specific tests:

```bash
mix test apps/lemon_router/test/lemon_router/session_coordinator_test.exs
```

And if feasible:

```bash
mix test
```

---

# What to do if behavior differs from expectations

If an extracted pure transition test reveals current production behavior differs from the expected semantics:

1. verify current behavior with an integration test against existing code
2. preserve current behavior in this PR unless the bug is obvious and low-risk
3. add a comment/TODO referencing the discrepancy
4. do not silently “clean up” semantics while doing structural refactoring

The primary goal of these 3 PRs is to improve **clarity, policy integrity, and testability** without destabilizing the system.

If you want, I can turn this into an even more mechanical **file-by-file patch plan** with proposed function signatures and exact test module skeletons.
