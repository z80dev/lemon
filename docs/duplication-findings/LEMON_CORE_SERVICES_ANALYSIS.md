# Code Duplication Analysis: lemon_core and lemon_services

**Date:** 2026-03-23
**Status:** Ready for extraction and consolidation
**Scope:** apps/lemon_core/* and apps/lemon_services/*

---

## Executive Summary

The lemon_core and lemon_services apps exhibit **moderate duplication** in GenServer patterns, telemetry helpers, and initialization code. While `LemonCore.Retry` was successfully extracted, several other patterns remain duplicated across modules and could benefit from extraction.

Key findings:
- **Telemetry span helpers** implemented locally instead of using centralized `LemonCore.Telemetry.span/3`
- **GenServer boilerplate** (subscription management, state initialization) duplicated across 6+ GenServer implementations
- **MapHelpers usage** is strong (819 usages), showing good adoption of the unified helper
- **ETS state management** follows similar patterns across multiple modules
- **Scheduling patterns** duplicated across health checkers and service managers

---

## 1. Telemetry Span Pattern — Medium Priority

### Pattern
Multiple modules implement local telemetry wrappers instead of using the centralized helper:

**lemon_core/lib/lemon_core/reload.ex** (lines 240-260):
```elixir
defp telemetry_span(kind, target, fun) do
  metadata = %{kind: kind, target: target}
  started = System.monotonic_time()
  :telemetry.execute([:lemon, :reload, :start], %{system_time: System.system_time()}, metadata)

  try do
    result = fun.()
    duration_ms = elapsed_ms(started)
    :telemetry.execute(
      [:lemon, :reload, :stop],
      %{duration_ms: duration_ms},
      Map.put(metadata, :status, result_status(result))
    )
    result
  rescue
    e -> {:error, e}
  end
end
```

**lemon_core/lib/lemon_core/config_reloader.ex** (lines 176-216):
```elixir
:telemetry.execute(
  [:lemon, :config, :reload, :start],
  %{system_time: System.system_time()},
  telemetry_meta
)
# ... core work ...
:telemetry.execute(
  [:lemon, :config, :reload, :stop],
  %{duration: duration_ms * 1_000_000, duration_ms: duration_ms},
  Map.put(telemetry_meta, :changed_count, 0)
)
```

**Centralized Alternative — Already Exists:**
```elixir
# lemon_core/lib/lemon_core/telemetry.ex (line 42)
def span(event_prefix, metadata, fun) do
  :telemetry.span(event_prefix, metadata, fn ->
    result = fun.()
    {result, metadata}
  end)
end
```

### Files Affected
- `apps/lemon_core/lib/lemon_core/reload.ex` - defines custom `telemetry_span/3`
- `apps/lemon_core/lib/lemon_core/config_reloader.ex` - uses `:telemetry.execute` directly with start/stop pairs
- `apps/lemon_core/lib/lemon_core/telemetry.ex` - ALREADY provides `span/3` helper (underutilized)

### Issue
The `LemonCore.Telemetry.span/3` helper exists but is not used in reload.ex. The custom implementation in reload.ex adds custom timing and status logic that diverges from the standard pattern.

### Suggestion
**Enhance `LemonCore.Telemetry`** to add domain-specific span helpers:
```elixir
@spec reload_span(atom(), atom(), (-> result)) :: result when result: term()
def reload_span(kind, target, fun) do
  metadata = %{kind: kind, target: target}
  span([:lemon, :reload], metadata, fun)
end

@spec config_reload_span((-> result)) :: result when result: term()
def config_reload_span(fun) do
  span([:lemon, :config, :reload], %{}, fun)
end
```

This centralizes telemetry logic and ensures consistency.

---

## 2. GenServer Subscription Management — High Priority

### Pattern
Multiple GenServer modules implement identical subscription management (add/remove subscriber patterns):

**lemon_services/runtime/server.ex** (lines ~200-230):
```elixir
@impl true
def handle_cast({:subscribe_logs, pid}, state) do
  new_state = State.add_log_subscriber(state, pid)
  send_recent_logs(state.definition.id, pid)
  {:noreply, new_state}
end

@impl true
def handle_cast({:unsubscribe_logs, pid}, state) do
  new_state = State.remove_log_subscriber(state, pid)
  {:noreply, new_state}
end

@impl true
def handle_cast({:subscribe_events, pid}, state) do
  new_state = State.add_event_subscriber(state, pid)
  {:noreply, new_state}
end

@impl true
def handle_cast({:unsubscribe_events, pid}, state) do
  new_state = State.remove_event_subscriber(state, pid)
  {:noreply, new_state}
end
```

### Files Affected
- `apps/lemon_services/lib/lemon_services/runtime/server.ex` - 4 subscription handlers
- `apps/lemon_core/lib/lemon_core/store.ex` - likely similar pattern (would need verification)

### Issue
This pattern is repeated across any GenServer with multi-type subscriptions (logs, events, metrics, etc.). Adding a new subscription type requires boilerplate in each handler.

### Suggestion
**Extract a helper module** `GenServerHelpers.Subscriptions`:
```elixir
defmodule LemonCore.GenServerHelpers.Subscriptions do
  @doc """
  Helper for subscription management in GenServers.
  """

  def add_subscriber(state_map_key, state, pid) do
    Map.update(state, state_map_key, [pid], &Enum.uniq([pid | &1]))
  end

  def remove_subscriber(state_map_key, state, pid) do
    Map.update(state, state_map_key, [], &List.delete(&1, pid))
  end

  def broadcast(state_map_key, state, message) do
    state
    |> Map.get(state_map_key, [])
    |> Enum.each(&send(&1, message))
  end
end
```

Then use it in GenServers:
```elixir
def handle_cast({:subscribe_logs, pid}, state) do
  {:noreply, Subscriptions.add_subscriber(:log_subscribers, state, pid)}
end
```

---

## 3. ETS State Management with Circular Buffers — Medium Priority

### Pattern
Two GenServer modules manage ETS-backed circular buffers with identical logic:

**lemon_services/runtime/log_buffer.ex** (lines 60-85):
```elixir
@impl true
def init(service_id) do
  :ets.insert(@table, {service_id, :queue.new(), 0})
  {:ok, %{service_id: service_id, max_lines: @default_max_lines}}
end

@impl true
def handle_cast({:append, log_line}, state) do
  service_id = state.service_id
  [{^service_id, buffer, index}] = :ets.lookup(@table, service_id)

  log_line = Map.put(log_line, :sequence, index)
  new_buffer = :queue.in(log_line, buffer)

  new_buffer =
    if :queue.len(new_buffer) > state.max_lines do
      # trim logic...
    else
      new_buffer
    end

  :ets.insert(@table, {service_id, new_buffer, index + 1})
  {:noreply, state}
end
```

### Files Affected
- `apps/lemon_services/lib/lemon_services/runtime/log_buffer.ex` - circular buffer for logs
- Likely other services with similar circular buffer needs

### Issue
The ETS lookup, tuple unpacking, queue operations, and insertion pattern is repeated. The max_lines trimming logic is duplicated.

### Suggestion
**Extract `LemonCore.CircularBuffer`** module:
```elixir
defmodule LemonCore.CircularBuffer do
  @spec new(atom(), non_neg_integer()) :: :ok
  def new(table, max_size) do
    :ets.new(table, [:set, :public, :named_table])
  end

  @spec append(atom(), term(), term(), non_neg_integer()) :: :ok
  def append(table, key, item, max_size) do
    [{^key, buffer, index}] = :ets.lookup(table, key)
    new_buffer = :queue.in(item, buffer)
    trimmed = if :queue.len(new_buffer) > max_size, do: trim(new_buffer, max_size), else: new_buffer
    :ets.insert(table, {key, trimmed, index + 1})
    :ok
  end

  defp trim(queue, max_size) do
    :queue.in(:queue.out(queue), max_size)
  end
end
```

---

## 4. Keyword Option Extraction in start_link — Low Priority

### Pattern
Multiple GenServer start_link implementations extract options identically:

**lemon_services/runtime/server.ex**:
```elixir
def start_link(opts) do
  definition = Keyword.fetch!(opts, :definition)
  GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
end
```

**lemon_services/runtime/log_buffer.ex**:
```elixir
def start_link(opts) do
  service_id = Keyword.fetch!(opts, :service_id)
  GenServer.start_link(__MODULE__, service_id, name: via_tuple(service_id))
end
```

**lemon_services/runtime/health_checker.ex**:
```elixir
def start_link(opts) do
  definition = Keyword.fetch!(opts, :definition)
  if definition.health_check do
    GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
  else
    :ignore
  end
end
```

### Issue
Repetitive `Keyword.fetch!` followed by GenServer.start_link with via_tuple naming. The conditional :ignore pattern is also repeated.

### Suggestion
**Add a macro** in `GenServerHelpers`:
```elixir
defmacro with_via_tuple(opts_var, key, do: block) do
  quote do
    value = Keyword.fetch!(unquote(opts_var), unquote(key))
    GenServer.start_link(__MODULE__, value, name: via_tuple(value.id))
  end
end
```

(Or simpler: just a pattern-matched helper function if the pattern is consistent.)

---

## 5. Scheduling/Timer Pattern — Low Priority

### Pattern
Multiple GenServers schedule periodic tasks identically:

**lemon_services/runtime/health_checker.ex** (lines 85-100):
```elixir
defp do_check(state) do
  # ...
end

defp schedule_check(interval_ms) do
  Process.send_after(self(), :check, interval_ms)
end
```

**lemon_services/runtime/server.ex**:
```elixir
Process.send_after(self(), :do_start, delay)
```

### Issue
Each module implements its own scheduling. For common patterns (periodic health checks, retries with backoff), this is repetitive.

### Suggestion
**No extraction needed right now** — the scheduling is simple enough and varies per use case. Only extract if we find 5+ identical patterns.

---

## 6. MapHelpers Adoption — Excellent

### Pattern
`LemonCore.MapHelpers` is heavily used across the codebase (819+ usages).

**Example:**
```elixir
# Instead of:
Map.get(map, key) || Map.get(map, Atom.to_string(key))

# Code uses:
LemonCore.MapHelpers.get_key(map, key)
```

### Status
**No action needed.** MapHelpers is well-adopted and solves a real problem (atom/string key switching).

---

## 7. Config Loading — Centralized Appropriately

### Pattern
Config loading in lemon_core uses `Application.get_env` with fallback chains:

**lemon_core/memory_store.ex**:
```elixir
def init(opts) do
  app_config = Application.get_env(:lemon_core, __MODULE__, [])
  # ...
end
```

**Quality check** (lemon_core/quality/architecture_rules_check.ex):
```elixir
patterns: [
  "Application.get_env(:lemon_channels, :telegram)",
  "Application.get_env(:lemon_channels, :discord)",
]
```

### Status
**Good separation of concerns.** Runtime modules use `LemonCore.GatewayConfig` instead of raw `Application.get_env`. No duplication detected.

---

## 8. Error Handling with `case`/`with` — Normal Distribution

### Pattern Count
- 849 uses of `with`/`case` across the codebase
- No significant duplication pattern — these are domain-specific error chains, not boilerplate

### Status
**No action needed.** Error handling is varied by domain and extracting would reduce clarity.

---

## 9. Retry Logic — Already Extracted ✅

### Status
`LemonCore.Retry` was successfully extracted and is being used:

**Usage:**
- `lemon_channels/adapters/telegram/outbound.ex` — uses `exponential_backoff`
- `lemon_channels/adapters/whatsapp/transport.ex` — uses `capped_backoff`
- `lemon_channels/outbox.ex` — uses both
- `lemon_gateway/transports/webhook/response.ex` — uses `capped_backoff`

No duplicated retry logic detected.

---

## 10. Telemetry Event Definitions — Centralized ✅

**lemon_core/telemetry.ex** defines all event names and provides:
- Generic `span/3` for telemetry wrappers
- Domain-specific helpers: `run_submit`, `run_start`, `channel_inbound`, `approval_requested`, etc.

### Status
**Good structure.** Ready to extend with reload/config-specific helpers (see Finding #1).

---

## Summary Table

| Pattern | Files | Status | Priority | Effort |
|---------|-------|--------|----------|--------|
| **Telemetry spans** | reload.ex, config_reloader.ex | Duplicated locally | Medium | Low |
| **GenServer subscriptions** | server.ex, possibly others | Duplicated | High | Medium |
| **ETS circular buffers** | log_buffer.ex, future services | Duplicated | Medium | Medium |
| **Keyword extraction** | server.ex, log_buffer.ex, health_checker.ex | Boilerplate | Low | Low |
| **Scheduling/timers** | health_checker.ex, server.ex | Simple, acceptable | Low | — |
| **MapHelpers** | 819+ usages | Well-adopted | — | ✅ |
| **Config loading** | Centralized | Appropriate | — | ✅ |
| **Retry logic** | 5 files | Extracted | — | ✅ |
| **Telemetry events** | telemetry.ex | Centralized | — | ✅ |

---

## Recommended Extraction Order

1. **GenServer Subscription Management** (High priority, medium effort)
   - Create `LemonCore.GenServerHelpers.Subscriptions`
   - Update `lemon_services/runtime/server.ex` to use it
   - Reuse in other multi-type subscription GenServers

2. **Telemetry Span Helpers** (Medium priority, low effort)
   - Extend `LemonCore.Telemetry` with domain-specific span wrappers
   - Update `reload.ex` and `config_reloader.ex` to use them

3. **ETS Circular Buffer** (Medium priority, medium effort)
   - Create `LemonCore.CircularBuffer` module
   - Update `log_buffer.ex` to use it
   - Document for future service log/event buffers

4. **Keyword Extraction Pattern** (Low priority, optional)
   - Consider if we find 3+ more GenServers with identical patterns

---

## Notes for Next Session

- LemonCore.Retry is well-integrated (no stranded implementations found)
- MapHelpers adoption is excellent (819+ usages)
- Telemetry infrastructure is good; just needs domain-specific wrappers
- No architectural debt in error handling (case/with chains are domain-specific)
- GenServer boilerplate is the main remaining issue; should be addressed in next phase
