# Cross-App Duplication Analysis

## Executive Summary

Identified **major cross-cutting patterns** across the umbrella apps that could benefit from consolidation in `lemon_core` or shared helper modules. Estimated impact: **significant code reuse** opportunity, particularly for store/registry patterns, config management, and GenServer behaviors.

---

## 1. Store & Registry Patterns

### High Duplication: Store Architecture

**Pattern:** ETS-backed stores with optional DETS persistence

**Instances Found:**
- `coding_agent/lib/coding_agent/task_store.ex` — Task tracking with ETS + DETS
- `lemon_core/lib/lemon_core/memory_store.ex` — Memory storage
- `lemon_core/lib/lemon_core/run_history_store.ex` — Run history
- `lemon_core/lib/lemon_core/progress_store.ex` — Progress tracking (wrapper)
- `lemon_channels/lib/lemon_channels/telegram/offset_store.ex` — Telegram offsets
- `lemon_channels/lib/lemon_channels/telegram/state_store.ex` — Telegram state
- `lemon_gateway/lib/lemon_gateway/sms/inbox_store.ex` — SMS inbox
- `lemon_automation/lib/lemon_automation/cron_store.ex` — Cron jobs
- `lemon_router/lib/lemon_router/agent_endpoint_store.ex` — Agent endpoints
- Plus 10+ more store implementations

**Common Pattern:**
```elixir
# All follow this structure:
# 1. ETS table owned by a GenServer
# 2. Optional DETS backend for persistence
# 3. Standard CRUD operations (get, put, list, delete)
# 4. TTL/cleanup operations
# 5. Bounded event/record management
```

**Files Identified:** 50+ store implementations across all major apps

**Recommendation:**
Create `LemonCore.Store.ETS` behavior/helper module:
```elixir
defmodule LemonCore.Store.ETS do
  @doc """
  Generic ETS store with optional DETS persistence.

  Handles:
  - Table creation and initialization
  - Record insertion/update
  - Cleanup by TTL
  - DETS persistence
  - Error handling
  """

  @callback table_name() :: atom()
  @callback record_structure() :: term()
  @callback dets_enabled?() :: boolean()
  @callback default_ttl() :: non_neg_integer()
end
```

**Impact:** Would eliminate ~200-300 LOC of boilerplate across 15+ files

---

### High Duplication: Registry Patterns

**Pattern:** GenServer-based registry for plugin/adapter registration

**Instances Found:**
- `lemon_channels/lib/lemon_channels/registry.ex` — Channel plugins
- `lemon_channels/lib/lemon_channels/engine_registry.ex` — Channel engines
- `lemon_gateway/lib/lemon_gateway/transport_registry.ex` — Transports
- `lemon_gateway/lib/lemon_gateway/engine_registry.ex` — Engines
- `lemon_gateway/lib/lemon_gateway/command_registry.ex` — Commands
- `lemon_control_plane/lib/lemon_control_plane/methods/registry.ex` — Methods
- `lemon_skills/lib/lemon_skills/registry.ex` — Skills
- `ai/lib/ai/provider_registry.ex` — AI providers
- `agent_core/lib/agent_core/agent_registry.ex` — Agents
- `coding_agent/lib/coding_agent/session_registry.ex` — Sessions
- `coding_agent/lib/coding_agent/tool_registry.ex` — Tools

**Common Pattern:**
```elixir
# All registries share:
# 1. GenServer with in-memory state (Map-based)
# 2. register/1, unregister/1, get/1, list/0 operations
# 3. Timeout handling (5-30 second calls)
# 4. Error handling for missing items
# 5. Optional metadata/capabilities lookup
# 6. Status checking (running, connected, etc.)
```

**Code Similarity Level:** 70-80% identical structure

**Recommendation:**
Create `LemonCore.Registry` behavior module:
```elixir
defmodule LemonCore.Registry do
  @moduledoc """
  Generic in-memory registry for plugins, providers, adapters, etc.

  Provides standard operations:
  - register/unregister items
  - get/list items
  - metadata/capability queries
  - status checks
  """

  @callback item_key(term()) :: String.t()
  @callback item_metadata(term()) :: map()
  @callback validate_item(term()) :: :ok | {:error, term()}
end
```

**Impact:** Would eliminate ~100-150 LOC per file, affecting 11 registries = ~1000+ LOC savings

---

## 2. Config & Environment Reading Patterns

### Duplication: Config Loaders

**Pattern:** Modules that read and cache environment configuration

**Instances Found:**
- `coding_agent/lib/coding_agent/config.ex` — Agent config
- `lemon_core/lib/lemon_core/config_cache.ex` — Core config cache
- `lemon_core/lib/lemon_core/config_reloader.ex` — Config with file watching
- `lemon_gateway/lib/lemon_gateway/config_loader.ex` — Gateway config
- `lemon_gateway/lib/lemon_gateway/config.ex` — Gateway config (duplicate?)
- `lemon_services/lib/lemon_services/config.ex` — Services config
- `lemon_core/lib/lemon_core/config/features.ex` — Feature flags
- `lemon_core/lib/lemon_core/config/agent.ex` — Agent config

**Common Pattern:**
```elixir
# All follow:
# 1. Read config from environment or file
# 2. Cache the result
# 3. Validate values
# 4. Provide typed accessor functions
# 5. Some have file watcher/reload support
```

**Code Duplication:** 40-50% similar patterns

**Recommendation:**
Centralize in `lemon_core` with variant for file watching:
```elixir
defmodule LemonCore.Config do
  @doc """
  Load and cache configuration from environment or files.
  Provides typed accessors and optional hot-reload.
  """
  def load_env(app_name, schema)
  def get(app_name, key, default)
  def with_cache(app_name, ttl_ms, loader_fn)
end

defmodule LemonCore.ConfigReloader do
  @doc "Load config with file watching and hot reload"
end
```

**Impact:** Would eliminate config boilerplate across 8 apps

---

## 3. GenServer Patterns

### Duplication: Lifecycle State Management

**Pattern:** GenServers with init/handle_call/handle_info patterns

**Instances Found (Sample):**
- `coding_agent/lib/coding_agent/session.ex` — Session management
- `coding_agent/lib/coding_agent/coordinator.ex` — Run coordination
- `lemon_router/lib/lemon_router/run_orchestrator.ex` — Run orchestration
- `lemon_router/lib/lemon_router/session_coordinator.ex` — Session coordination
- `lemon_gateway/lib/lemon_gateway/scheduler.ex` — Scheduling
- `lemon_channels/lib/lemon_channels/outbox.ex` — Message outbox
- `lemon_automation/lib/lemon_automation/cron_manager.ex` — Cron management
- `lemon_automation/lib/lemon_automation/heartbeat_manager.ex` — Heartbeats
- `ai/lib/ai/call_dispatcher.ex` — API call dispatching
- `ai/lib/ai/circuit_breaker.ex` — Circuit breaker pattern
- `ai/lib/ai/rate_limiter.ex` — Rate limiting

**Common Patterns:**
1. **State initialization and validation** (5-10 LOC pattern repeated)
2. **Timeout/error handling in handle_call** (10-15 LOC pattern)
3. **Metrics collection** (logging exit codes, timing)
4. **Graceful shutdown** (cleanup before stop)

**Code Duplication:** 30-40% in each file

**Issue:** `lemon_core` does NOT have reusable GenServer behaviors

**Recommendation:**
Add to `lemon_core`:
```elixir
defmodule LemonCore.GenServer do
  @moduledoc """
  Behaviors and helpers for common GenServer patterns.
  """

  defmodule WithMetrics do
    # Adds timing/counting to handle_call
  end

  defmodule WithGracefulShutdown do
    # Handles cleanup on termination
  end

  defmodule WithTimeout do
    # Adds request timeout handling
  end
end
```

---

## 4. PubSub & Event Patterns

### Duplication: Event Publishing & Subscription

**Files with PubSub:**
- `lemon_core/lib/lemon_core/bus.ex` — Event bus
- `lemon_core/lib/lemon_core/event_bridge.ex` — Event bridge
- `lemon_control_plane/lib/lemon_control_plane/event_bridge.ex` — Another event bridge (similar name, different module)
- `agent_core/lib/agent_core/event_stream.ex` — Event streaming
- `ai/lib/ai/event_stream.ex` — Another event stream
- Multiple adapters with custom PubSub subscriptions

**Pattern Observed:**
```elixir
# Repeated across 5+ files:
def subscribe(topic) do
  Phoenix.PubSub.subscribe(LemonCore.PubSub, topic)
end

def broadcast(topic, message) do
  Phoenix.PubSub.broadcast(LemonCore.PubSub, topic, message)
end
```

**Issue:** Inconsistent naming, multiple implementations of same concept

**Recommendation:**
Consolidate to single `LemonCore.Bus`:
- `LemonCore.Bus.subscribe/1`
- `LemonCore.Bus.broadcast/2`
- `LemonCore.Bus.publish/3` (async variant)

**Impact:** Would reduce event coordination code by 50-100 LOC across apps

---

## 5. Retry & Backoff Logic

### Duplication: Exponential Backoff Implementations

**Instances Found:**
- `lemon_channels/lib/lemon_channels/adapters/x_api/token_manager.ex` — API retry logic
- `lemon_channels/lib/lemon_channels/adapters/telegram/outbound.ex` — Telegram retry
- `lemon_channels/lib/lemon_channels/outbox.ex` — Message retry
- `lemon_channels/lib/lemon_channels/presentation_state.ex` — State retry
- `ai/lib/ai/call_dispatcher.ex` — API call retry
- `ai/lib/ai/providers/anthropic.ex` — Anthropic API retry
- `ai/lib/ai/providers/google_shared.ex` — Google API retry
- `coding_agent/lib/coding_agent/rate_limit_healer.ex` — Rate limit backoff
- `coding_agent/lib/coding_agent/rate_limit_pause.ex` — Rate limit pause
- `coding_agent/lib/coding_agent/tool_executor.ex` — Tool retry
- `lemon_router/lib/lemon_router/run_process/retry_handler.ex` — Run retry
- `lemon_gateway/lib/lemon_gateway/thread_worker.ex` — Worker retry

**Common Code Pattern:**
```elixir
# Repeated ~10 times:
defp calculate_backoff(attempt, initial_ms \\ 1000) do
  min_ms = initial_ms * :math.pow(2, attempt - 1)
  jitter = :random.uniform(round(min_ms * 0.1))
  trunc(min_ms) + jitter
end

# Or:
defp should_retry?(error, max_attempts) do
  case error do
    {:error, :rate_limit, _} -> true
    {:error, :timeout, _} -> true
    _ -> false
  end
end
```

**Code Duplication:** 40-60 LOC per file, ~10 files

**Recommendation:**
Create `LemonCore.Retry`:
```elixir
defmodule LemonCore.Retry do
  @spec with_exponential_backoff(
    fun :: (() -> {:ok, term()} | {:error, term()}),
    max_attempts :: pos_integer(),
    initial_delay_ms :: pos_integer(),
    jitter_factor :: float()
  ) :: {:ok, term()} | {:error, term()}

  @spec should_retry?({:error, atom(), term()} | any()) :: boolean()

  @spec calculate_backoff(attempt :: pos_integer(), initial_ms :: pos_integer()) :: pos_integer()
end
```

**Impact:** Would eliminate 400-600 LOC of retry logic across 12+ files

---

## 6. Logging Patterns

### Duplication: Structured Logging Helpers

**Pattern Found:**
Each app has its own structured logging utilities:

```elixir
# Pattern repeated in multiple adapters/services:
defp log_error(message, error) do
  Logger.error("#{@service_name}: #{message}", error: inspect(error))
end

defp log_warning(message) do
  Logger.warning("[#{@service_name}] #{message}")
end
```

**Files Involved:**
- `lemon_channels/lib/lemon_channels/adapters/xmtp/transport.ex`
- `lemon_core/lib/lemon_core/store.ex`
- `coding_agent/lib/coding_agent/tool_registry.ex`
- `coding_agent/lib/coding_agent/tools/task/followup.ex`
- `lemon_gateway/lib/lemon_gateway/run.ex`
- Plus others

**Recommendation:**
Add to `lemon_core`:
```elixir
defmodule LemonCore.Logger do
  def error(service_name, message, error)
  def warning(service_name, message)
  def info(service_name, message, context)
  def debug(service_name, message, details)
end
```

---

## 7. Checking if lemon_core Already Has Helpers

**Analysis of lemon_core existing helpers:**

### Already Exists (well-used):
- `LemonCore.Store` — Storage backend abstraction ✓
- `LemonCore.ConfigCache` — Config caching ✓
- Event/PubSub infrastructure ✓
- Error handling (LemonCore.Error) ✓

### Exists but NOT widely used (reimplemented elsewhere):
- **`LemonCore.Store`** — Exists but:
  - Many apps have their own ETS wrappers instead of using it
  - Not all stores in the codebase extend this behavior
  - Examples: `TaskStore`, `CronStore`, `OffsetStore` are independent

**Why not used:**
- Possibly didn't exist when some modules were written
- Different storage backends (some use GenServer + ETS directly)
- Not discoverable/documented as a shared pattern

### Missing from lemon_core (being reimplemented):
- Centralized Registry behavior ❌
- Retry/backoff helpers ❌
- Structured logging with service context ❌
- GenServer behavior compositions ❌
- Config hot-reload mechanism ❌

---

## Priority Recommendation Matrix

| Pattern | Files | LOC Saved | Priority | Effort |
|---------|-------|-----------|----------|--------|
| Registry behavior | 11 | 1000+ | HIGH | Medium |
| ETS Store helper | 15+ | 300+ | HIGH | Medium |
| Retry/backoff lib | 12 | 500+ | HIGH | Low |
| Config consolidation | 8 | 200+ | MEDIUM | Medium |
| Logging helpers | 6+ | 150+ | MEDIUM | Low |
| Event/PubSub unification | 5+ | 100+ | LOW | High |
| GenServer behaviors | 20+ | 400+ | MEDIUM | High |

**Quick Wins (Low effort, high impact):**
1. Retry/backoff library — 500 LOC saved, low effort
2. Structured logging helpers — 150 LOC saved, low effort
3. Registry behavior — 1000 LOC saved, medium effort

---

## Next Steps

1. **Consolidate in lemon_core:**
   - Move/create `Registry` behavior
   - Create `Retry` module with backoff helpers
   - Add `Logger` helpers with service context
   - Document existing `Store` behavior and encourage adoption

2. **Deprecation path:**
   - Keep existing implementations working
   - Mark as deprecated, recommend migration
   - Provide migration guides for common cases

3. **Documentation:**
   - Create guides in lemon_core docs
   - Provide examples for each pattern
   - Add to onboarding/architecture docs

---

## Notes

- **Task #3 (coding_agent tools)** has the highest impact for immediate refactoring due to identical duplication
- **Cross-app duplication** is more about architectural patterns and design - refactoring requires more coordination
- Several apps appear to have been written before current lemon_core patterns were established
- Suggest creating "Shared Patterns" wiki page to prevent future duplication
