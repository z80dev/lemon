Below is the execution backlog I would hand to the team. It is ordered by **architectural leverage**, **blast radius**, and **dependency sequencing**.

One additional finding while turning this into tickets: **`apps/lemon_mcp` exists in the umbrella, but it is not present in `docs/architecture_boundaries.md` or `LemonCore.Quality.ArchitectureCheck`**. That means your boundary checker and docs are already out of sync with the actual app inventory. I would fix that before relying on the guardrails.

## Program-level exit criteria

When this backlog is complete, all of these should be true:

```bash
# router/channels boundary is real, not aspirational
grep -R "LemonChannels.OutboundPayload" -n apps/lemon_router/lib
grep -R "LemonChannels.Telegram" -n apps/lemon_router/lib
grep -R "LemonChannels.EngineRegistry\\|LemonChannels.GatewayConfig" -n apps/lemon_router/lib
grep -R ":telegram_pending_compaction\\|:telegram_msg_resume\\|:telegram_selected_resume\\|:telegram_msg_session" -n apps/lemon_router/lib

# concurrency hygiene
grep -R "Process.sleep" -n apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex
grep -R "Task.start(fun)" -n apps/coding_agent/lib apps/lemon_automation/lib apps/lemon_channels/lib

# architecture policy is synced to actual apps
# and quality check passes
mix lemon.quality
```

The first four grep blocks should return **no matches**.

---

## P0 — Guardrails and repo hygiene

### ARCH-001 — Sync architecture policy with the real app inventory

**Why first:** your enforcement layer is only useful if it matches reality.

**Files**

* `docs/architecture_boundaries.md`
* `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`
* `apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs`
* `apps/lemon_mcp/mix.exs`

**Work**

* Decide whether `lemon_mcp` is a first-class umbrella app.
* If yes, add it to:

  * `@allowed_direct_deps`
  * `@app_namespaces`
  * `docs/architecture_boundaries.md`
* If no, move it out of `apps/` so the checker does not treat it as a managed umbrella app.

**Acceptance criteria**

* `ArchitectureCheck.run/1` recognizes the actual app set.
* Docs and code enumerate the same app inventory.
* A regression test explicitly covers the `lemon_mcp` decision.

---

### ARCH-002 — Remove or quarantine the nested `games-platform/` repo copy

**Why first:** duplicate trees poison search results, refactors, CI, and developer trust.

**Files**

* `./games-platform/**`

**Work**

* Determine whether `games-platform/` is:

  * accidental duplicate,
  * fixture,
  * vendored subtree,
  * archived snapshot.
* If accidental, remove it.
* If intentional, move it under a clearly non-source location and exclude it from CI/search/tooling.

**Acceptance criteria**

* There is only one canonical umbrella source tree in the repo root.
* Repo-wide search no longer returns duplicate matches for app files.
* CI/docs/scripts do not scan the duplicate tree.

---

### ARCH-003 — Add explicit router/channels tripwire tests

**Why first:** the main refactor will regress unless the boundary is enforced mechanically.

**Files**

* New: `apps/lemon_router/test/lemon_router/architecture/boundary_test.exs`
* Possibly extend: `apps/lemon_core/lib/lemon_core/quality/architecture_check.ex`

**Work**
Add deny-list assertions for `lemon_router` source files:

* forbidden module refs:

  * `LemonChannels.OutboundPayload`
  * `LemonChannels.Telegram.*`
  * `LemonChannels.EngineRegistry`
  * `LemonChannels.GatewayConfig`
* forbidden state keys:

  * `:telegram_pending_compaction`
  * `:telegram_msg_resume`
  * `:telegram_selected_resume`
  * `:telegram_msg_session`

**Acceptance criteria**

* CI fails if router reaches into channel payload types or Telegram internals.
* The test reports the exact offending file and line.

---

## P1 — Fix the router/channels boundary

This is the highest-value work. Also: the docstring on `LemonRouter.ChannelAdapter` already describes the desired state, but the implementation still constructs `OutboundPayload`s. This wave is mostly about making the code match the stated architecture.

---

### ARCH-010 — Introduce a **core-owned** output intent contract

`lemon_channels` cannot depend on `lemon_router`, so the neutral contract should live in `lemon_core`, not router.

**Files**

* New: `apps/lemon_core/lib/lemon_core/channel_route.ex`
* New: `apps/lemon_core/lib/lemon_core/output_intent.ex`
* New: `apps/lemon_channels/lib/lemon_channels/dispatcher.ex`

**Target shape**

```elixir
defmodule LemonCore.ChannelRoute do
  @enforce_keys [:channel_id, :account_id, :peer_kind, :peer_id]
  defstruct [:channel_id, :account_id, :peer_kind, :peer_id, :thread_id]
end

defmodule LemonCore.OutputIntent do
  @enforce_keys [:route, :op]
  defstruct [:route, :op, body: %{}, meta: %{}]

  @type op ::
          :stream_append
          | :stream_replace
          | :tool_status
          | :keepalive_prompt
          | :final_text
          | :fanout_text
          | :send_files
end
```

**Work**

* Define channel-neutral route and output intent structs in `lemon_core`.
* Add `LemonChannels.Dispatcher.dispatch/1` that translates intents into channel-specific outbound work.

**Acceptance criteria**

* No module in `apps/lemon_router/lib` directly constructs `LemonChannels.OutboundPayload`.
* Router’s delivery boundary is one call: `LemonChannels.Dispatcher.dispatch(intent)`.
* `Dispatcher` is the only place where intent -> payload translation begins.

---

### ARCH-011 — Move stream/status/final/watchdog delivery semantics into `lemon_channels`

**Files**

* `apps/lemon_router/lib/lemon_router/channel_adapter.ex`
* `apps/lemon_router/lib/lemon_router/channel_adapter/generic.ex`
* `apps/lemon_router/lib/lemon_router/channel_adapter/telegram.ex`
* `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
* `apps/lemon_router/lib/lemon_router/run_process/watchdog.ex`
* `apps/lemon_channels/lib/lemon_channels/adapters/telegram/outbound.ex`
* `apps/lemon_channels/lib/lemon_channels/adapters/discord/outbound.ex`
* possibly new outbound helpers under `lemon_channels`

**Work**
Move ownership of these decisions from router to channels:

* truncate / chunk / edit-vs-send
* inline keyboard rendering
* status-message lifecycle
* reply markup
* callback payload generation
* channel-specific finalization behavior
* fanout payload shaping

**Specific hotspots to clean**

* `RunProcess.OutputTracker` should emit intents, not `OutboundPayload`.
* `RunProcess.Watchdog` should emit a generic prompt intent, not construct a Telegram message with inline keyboard JSON.
* `ChannelAdapter.Telegram` should stop being a 1,000+ line delivery/policy module inside router.

**Acceptance criteria**

* `apps/lemon_router/lib/lemon_router/run_process/watchdog.ex` no longer aliases `LemonChannels.OutboundPayload`.
* Router no longer contains `"inline_keyboard"` or Telegram callback-data prefix assembly.
* `LemonRouter.ChannelAdapter.Telegram` is either deleted or reduced to a thin capability/query layer with **zero** `LemonChannels.*` payload/delivery logic.
* Telegram-specific rendering tests live under `lemon_channels`, not router.

---

### ARCH-012 — Move Telegram-specific persisted state ownership out of router

**Files**

* `apps/lemon_router/lib/lemon_router/run_process/compaction_trigger.ex`
* `apps/lemon_router/lib/lemon_router/channel_adapter/telegram.ex`
* New: `apps/lemon_channels/lib/lemon_channels/channel_state.ex`

  * or `apps/lemon_channels/lib/lemon_channels/adapters/telegram/state.ex`

**Work**
Move all Telegram-owned persistent state APIs behind a channel-owned boundary:

* `:telegram_pending_compaction`
* `:telegram_msg_resume`
* `:telegram_selected_resume`
* `:telegram_msg_session`

**Concrete refactor**
Replace router-side direct key manipulation with an abstract API:

```elixir
LemonChannels.ChannelState.mark_pending_compaction(route, reason, details)
LemonChannels.ChannelState.reset_resume_state(route)
LemonChannels.ChannelState.put_resume(route, resume_token)
```

**Acceptance criteria**

* `RunProcess.CompactionTrigger` no longer defines:

  * `reset_telegram_resume_state/1`
  * `mark_telegram_pending_compaction/...`
* Router does not call `LemonCore.Store.put/delete` for Telegram-specific keys.
* All Telegram state reads/writes go through `lemon_channels`.

---

### ARCH-013 — Canonicalize resume-token ownership in `lemon_core`

**Files**

* `apps/lemon_core/lib/lemon_core/resume_token.ex`
* `apps/lemon_channels/lib/lemon_channels/engine_registry.ex`
* `apps/lemon_router/lib/lemon_router/run_orchestrator.ex`
* `apps/lemon_router/lib/lemon_router/channel_adapter/telegram.ex`

**Work**

* Make `LemonCore.ResumeToken` the only owner of:

  * resume extraction,
  * strict resume-line detection,
  * resume formatting.
* Remove router’s dependency on `LemonChannels.EngineRegistry.extract_resume/1` and `format_resume/1`.

**Acceptance criteria**

* `RunOrchestrator.extract_resume_and_strip_prompt/2` uses `LemonCore.ResumeToken.extract_resume/1`.
* Router no longer references `LemonChannels.EngineRegistry`.
* `LemonChannels.EngineRegistry` is either deleted or reduced to channel-local engine config only.

---

### ARCH-014 — Remove thin wrappers that no longer add policy

**Files**

* `apps/lemon_channels/lib/lemon_channels/gateway_config.ex`
* `apps/lemon_channels/lib/lemon_channels/binding_resolver.ex`
* `apps/lemon_gateway/lib/lemon_gateway/binding_resolver.ex`

**Work**
Choose a canonical access model for shared concepts:

* either call `LemonCore.*` directly,
* or preserve app façades only where they add real translation/policy.

**Acceptance criteria**

* Every remaining wrapper either:

  * transforms data,
  * enforces local policy,
  * or intentionally preserves a public façade.
* One-line pass-through wrapper modules are removed.

---

## P1 parallel lane — concurrency and runtime hygiene

This lane is worth doing in parallel with the boundary work because it is largely independent.

---

### PERF-010 — Make `XAPI.TokenManager` non-blocking during refresh

**Files**

* `apps/lemon_channels/lib/lemon_channels/adapters/x_api/token_manager.ex`

**Current problem**
`handle_call(:get_access_token, ...)` can synchronously refresh tokens, which means network I/O happens in the GenServer call path.

**Target pattern**

```elixir
# one refresh in flight, callers queued
# no network I/O directly in handle_call
```

**Work**

* Add `refreshing?`, `refresh_ref`, and `waiters` to state.
* Offload refresh work to a supervised task.
* Coalesce concurrent token requests while refresh is in flight.

**Acceptance criteria**

* No network refresh occurs directly from `handle_call`.
* At most one refresh runs concurrently.
* 10 parallel `get_access_token/1` callers during expiry produce one refresh and 10 replies.
* Telemetry exists for refresh start/stop/failure.

---

### PERF-011 — Remove `Process.sleep/1` retry behavior from `ThreadWorker`

**Files**

* `apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex`

**Work**

* Replace sleep-based retry with `Process.send_after/3` or `handle_continue/2`.
* Keep the worker mailbox responsive while retry is pending.

**Acceptance criteria**

* `grep -R "Process.sleep" apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex` returns no matches.
* Transient run-start failure schedules retry without blocking the GenServer.
* Tests cover retry success and retry exhaustion.

---

### PERF-012 — Stop normalizing enqueue failure into success

**Files**

* `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex`

**Current problem**
`normalize_enqueue/1` currently turns failures into `:ok`.

**Work**

* Remove silent normalization.
* Return or record structured failure.
* Emit telemetry and optionally dead-letter failed jobs.

**Acceptance criteria**

* `normalize_enqueue/1` is removed or replaced with explicit failure accounting.
* Enqueue failure emits telemetry with `thread_key`, `run_id`, and reason.
* Callers can distinguish “accepted” from “failed to enqueue”.

---

### PERF-013 — Replace eager task fanout in `CodingAgent.Parallel`

**Files**

* `apps/coding_agent/lib/coding_agent/parallel.ex`

**Work**

* Replace the custom semaphore/task-eager implementation with `Task.async_stream/3` for the common path.
* Preserve ordering and bounded concurrency.

**Acceptance criteria**

* `map_with_concurrency_limit/4` is demand-driven, not “spawn all then block on semaphore”.
* Results remain ordered.
* Existing timeout semantics are preserved or explicitly updated.
* Tests verify bounded concurrency.

---

### PERF-014 — Centralize background task spawning policy

**Files**

* `apps/coding_agent/lib/coding_agent/coordinator.ex`
* `apps/coding_agent/lib/coding_agent/session/compaction_manager.ex`
* `apps/lemon_automation/lib/lemon_automation/cron_manager.ex`
* `apps/lemon_automation/lib/lemon_automation/heartbeat_manager.ex`
* `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex`
* New: `apps/lemon_core/lib/lemon_core/background_task.ex`

**Work**
Replace duplicated `start_background_task/1` helpers with one shared policy.

**Target shape**

```elixir
defmodule LemonCore.BackgroundTask do
  @spec start((-> any()), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(fun, opts \\ []) do
    # explicit supervisor + explicit fallback policy
  end
end
```

**Acceptance criteria**

* Duplicated helper implementations are deleted.
* Missing-supervisor behavior is explicit and shared.
* Dev/test do not silently degrade to unsupervised `Task.start/1` unless the caller opts in.

---

## P2 — Store ownership split

Do **not** start this before `ARCH-012`. Otherwise you will just spread Telegram coupling into multiple new store modules.

---

### DATA-010 — Build a state-ownership map

**Files**

* New: `docs/state_ownership.md`
* `apps/lemon_core/lib/lemon_core/store.ex`

**Work**
Document every `LemonCore.Store` table/key family:

* owning app,
* owning module,
* hot vs cold path,
* durability expectation,
* migration target.

**Acceptance criteria**

* Every current `Store` key/table has a named owner.
* Channel-specific state is clearly marked as non-core-owned.

---

### DATA-011 — Extract channel state out of the generic store API

**Files**

* New: `apps/lemon_channels/lib/lemon_channels/channel_state.ex`
* router/gateway call sites that manipulate Telegram keys

**Acceptance criteria**

* Telegram channel state is accessed only through a channel-owned API.
* Router and gateway no longer call the generic store for Telegram-specific keys.

---

### DATA-012 — Introduce typed stores for core concepts

**Files**

* New:

  * `apps/lemon_core/lib/lemon_core/run_store.ex`
  * `apps/lemon_core/lib/lemon_core/session_store.ex`
  * `apps/lemon_core/lib/lemon_core/progress_store.ex`

**Work**
Move the highest-volume and highest-value call paths first.

**Acceptance criteria**

* New writes go to typed stores, not generic `Store`.
* `LemonCore.Store` remains only as a compatibility layer for legacy paths.
* Telemetry exists per store operation and logical table.

---

## P2 parallel lane — control-plane metadata consolidation

---

### CTRL-010 — Make control-plane methods self-describing

**Files**

* New/updated: `apps/lemon_control_plane/lib/lemon_control_plane/method.ex`
* `apps/lemon_control_plane/lib/lemon_control_plane/methods/*.ex`

**Target shape**

```elixir
defmodule LemonControlPlane.Methods.Health do
  use LemonControlPlane.Method,
    name: "health",
    scopes: [],
    schema: %{optional: %{}},
    capabilities: []

  @impl true
  def handle(_params, _ctx), do: {:ok, %{ok: true}}
end
```

**Acceptance criteria**

* Method name, scopes, schema, and capabilities are defined in the method module.
* Adding a new method does not require touching multiple registries/maps.

---

### CTRL-011 — Generate the registry and schema export from method metadata

**Files**

* `apps/lemon_control_plane/lib/lemon_control_plane/methods/registry.ex`
* `apps/lemon_control_plane/lib/lemon_control_plane/protocol/schemas.ex`

**Acceptance criteria**

* `@builtin_methods` is removed or generated.
* `@schemas` giant map is removed or generated.
* Capability grouping is derived from method metadata, not maintained separately.

---

## P3 — Large-module decomposition

Do this **after** the boundary cleanup, or you will move the same logic twice.

---

### MOD-010 — Split `Telegram.Transport` by responsibility

**Files**

* `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex`

**Suggested extractions**

* `poller.ex`
* `update_router.ex`
* `media_group_assembler.ex`
* `reaction_tracker.ex`
* `async_task_runner.ex`
* `delivery_callbacks.ex`

**Acceptance criteria**

* Transport owns only transport orchestration and process state.
* Polling, update normalization, media assembly, and async helpers live in separate modules.
* Each extracted module has direct unit tests.

---

### MOD-011 — Split `Webhook` transport by boundary

**Files**

* `apps/lemon_gateway/lib/lemon_gateway/transports/webhook.ex`

**Suggested extractions**

* request verification
* request normalization
* route/session-key derivation
* reply shaping
* provider-specific behavior

**Acceptance criteria**

* `Webhook` transport becomes a thin transport/orchestration module.
* Non-transport logic moves into separately testable modules.

---

### MOD-012 — Split `CodingAgent.Session` into state machine + subsystems

**Files**

* `apps/coding_agent/lib/coding_agent/session.ex`

**Suggested split**

* session state machine
* compaction policy/runtime
* branch management
* tool runtime
* event/UI projection

**Acceptance criteria**

* Public session API remains stable.
* Session module stops owning unrelated helper clusters.
* Extracted modules have subsystem-focused tests.

---

## P3 — Surface cleanup / dead code decisions

---

### CLEAN-010 — Decide the fate of `lemon_services`

**Files**

* `apps/lemon_services/**`

**Work**
Make an explicit decision:

* integrate,
* archive,
* or delete.

**Acceptance criteria**

* There is an ADR with one of those decisions.
* If kept, it has first-class callers and policy/docs coverage.
* If not kept, it is removed from the umbrella.

---

## Recommended sequencing

### Lane A — must happen first

1. `ARCH-001`
2. `ARCH-002`
3. `ARCH-003`

### Lane B — main architecture correction

4. `ARCH-010`
5. `ARCH-011`
6. `ARCH-012`
7. `ARCH-013`
8. `ARCH-014`

### Lane C — parallel performance lane

9. `PERF-010`
10. `PERF-011`
11. `PERF-012`
12. `PERF-013`
13. `PERF-014`

### Lane D — after channel-state ownership is fixed

14. `DATA-010`
15. `DATA-011`
16. `DATA-012`

### Lane E — independent but lower urgency

17. `CTRL-010`
18. `CTRL-011`

### Lane F — last

19. `MOD-010`
20. `MOD-011`
21. `MOD-012`
22. `CLEAN-010`

---

## Three sequencing mistakes to avoid

1. **Do not split `telegram/transport.ex` before fixing router/channels ownership.**
   You will just relocate boundary leakage.

2. **Do not split `LemonCore.Store` before moving Telegram-owned state out of router.**
   You will harden bad ownership into new APIs.

3. **Do not rewrite the control-plane registry in one shot.**
   Add metadata-first, generate the registry second, remove manual maps last.

---

## The first PR stack I would open

1. **Guardrails PR**

   * fix `lemon_mcp` policy mismatch
   * quarantine/remove `games-platform/`
   * add router/channels deny-list tests

2. **Output contract PR**

   * add `LemonCore.ChannelRoute`
   * add `LemonCore.OutputIntent`
   * add `LemonChannels.Dispatcher`
   * no behavior change yet

3. **Generic channel migration PR**

   * migrate `channel_adapter/generic.ex` path to intents
   * remove router-side `OutboundPayload` construction for generic channels

4. **Telegram migration PR**

   * move stream/status/final/watchdog rendering into `lemon_channels`
   * router emits intents only

5. **Telegram state ownership PR**

   * move `:telegram_*` state behind `LemonChannels.ChannelState`
   * remove direct router store access

6. **Resume/wrapper cleanup PR**

   * `ResumeToken` canonical
   * delete thin wrappers

That stack gets you the real architectural win without trying to boil the ocean.

Reply with `issues` and I’ll turn this into GitHub-ready issue bodies with titles, labels, and checklists.
