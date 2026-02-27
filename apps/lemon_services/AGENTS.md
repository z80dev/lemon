# LemonServices

External service management via port-based processes.

## Quick Orientation

LemonServices manages long-running external OS processes (dev servers, workers, databases, etc.) through an OTP supervision tree. Each service gets its own supervisor with four components: a PortManager (OS port), a Server (lifecycle coordinator), a LogBuffer (circular log storage), and a HealthChecker (periodic probes). Definitions can be loaded from YAML at boot or created at runtime. AI agents interact with services through 8 tool functions in `Agent.Tools`.

This app is self-contained with no umbrella dependencies.

## Key Files and Purposes

| File | Module(s) | What It Does |
|---|---|---|
| `lib/lemon_services.ex` | `LemonServices` | **Public API**. All external interaction goes through here: `start_service`, `stop_service`, `restart_service`, `kill_service`, `get_service`, `list_services`, `list_services_by_tag`, `subscribe_to_logs`, `subscribe_to_events`, `register_definition`, `define_service`, etc. |
| `lib/lemon_services/application.ex` | `LemonServices.Application` | OTP app callback. Starts Registry, PubSub, DynamicSupervisor, and the top-level Supervisor. |
| `lib/lemon_services/supervisor.ex` | `LemonServices.Supervisor` | Top-level supervisor. Children: LogBuffer.TableOwner, Service.Store, Config.Loader. |
| `lib/lemon_services/config.ex` | `LemonServices.Config`, `LemonServices.Config.Loader` | YAML loading from `config/services.yml` and `config/services.d/*.yml`. `Loader` is a nested GenServer that registers definitions and auto-starts services on boot. `save_definition/1` persists to `services.d/`. |
| `lib/lemon_services/service/definition.ex` | `LemonServices.Service.Definition` | Definition struct. `new/1`, `new!/1`, `validate/1`, `to_map/1`, `from_map/1`. Defines command types, health check types, restart policies. |
| `lib/lemon_services/service/state.ex` | `LemonServices.Service.State` | Runtime state struct. Tracks status, health, PID, port, timestamps, restart count, exit code, subscriber sets. Helper functions: `set_status/3`, `set_health/2`, `increment_restart_count/1`, subscriber management. |
| `lib/lemon_services/service/store.ex` | `LemonServices.Service.Store` | ETS-backed GenServer for definition storage. Table `:lemon_services_definitions`. CRUD for definitions. |
| `lib/lemon_services/runtime/supervisor.ex` | `LemonServices.Runtime.Supervisor` | Per-service supervisor (`:one_for_all`). Also the `DynamicSupervisor` name for the global instance. `start_service/1` starts a child under the DynamicSupervisor. Children per service: LogBuffer, PortManager, HealthChecker, Server. |
| `lib/lemon_services/runtime/server.ex` | `LemonServices.Runtime.Server` | **Core lifecycle coordinator**. Handles `:do_start`, port data/exit, health check messages, crash recovery, restart policy evaluation, PubSub broadcasting, subscriber management. Restart backoff: `[1000, 2000, 5000, 10000, 30000]` ms. |
| `lib/lemon_services/runtime/port_manager.ex` | `LemonServices.Runtime.PortManager` | OS port lifecycle. Opens port with `Port.open/2` using `:spawn` mode. Graceful shutdown: SIGTERM then SIGKILL. Forwards port data/exit to owner (Server). `send_input/2` for stdin. |
| `lib/lemon_services/runtime/health_checker.ex` | `LemonServices.Runtime.HealthChecker` | Periodic health probes. Returns `:ignore` if no health check configured. Supports HTTP (`:httpc`), TCP (`:gen_tcp`), command (`System.cmd`), function (`apply`). Reports to Server after 2 consecutive failures. |
| `lib/lemon_services/runtime/log_buffer.ex` | `LemonServices.Runtime.LogBuffer`, `LemonServices.Runtime.LogBuffer.TableOwner` | Circular buffer (`:queue`) in ETS. 1000 lines per service. TableOwner is a nested GenServer that owns the ETS table so it survives per-service restarts. |
| `lib/lemon_services/agent/tools.ex` | `LemonServices.Agent.Tools` | 8 agent tools with JSON Schema definitions and execute functions. `all_tools/0` returns `[{name, schema_fn, execute_fn}]`. |

## Important Implementation Details

- **Nested modules**: `Config.Loader` is defined inside `config.ex`, not in a separate file. `LogBuffer.TableOwner` is defined inside `log_buffer.ex`.
- **Dual role of `Runtime.Supervisor`**: Used as both the `DynamicSupervisor` name (for the global dynamic supervisor) and the per-service supervisor module. `start_service/1` starts a new per-service supervisor as a child of the global DynamicSupervisor.
- **Registry keys**: All per-service processes use `{:via, Registry, {LemonServices.Registry, {type, service_id}}}` for naming. Types: `:service_supervisor`, `:server`, `:port_manager`, `:log_buffer`, `:health_checker`.
- **Server also registers with bare key**: Server does `Registry.register(LemonServices.Registry, definition.id, self())` in addition to the `{:server, service_id}` via-tuple. This means the service ID itself is also a registry key pointing to the Server.
- **Port mode**: Uses `:spawn` (not `:spawn_executable`), with `:stderr_to_stdout` so all output comes as `:stdout`. No separate stderr stream.
- **`:module` commands**: Spawned via `spawn_link` inside PortManager. No port, no log capture, no OS-level signals.
- **Health check threshold**: 2 consecutive failures required before marking unhealthy. Single failures are silently absorbed.
- **Log subscriber catchup**: When a process subscribes to logs via `subscribe_to_logs`, the Server immediately sends the last 100 buffered log lines.
- **Persistence caveat**: `Config.save_definition/1` writes an incomplete YAML file (just the comment header and `service:` key). Round-tripping is broken.

## Service Lifecycle States

```
:pending -> :starting -> :running -> :stopping -> :stopped
                |             |
                v             v
            :crashed      :unhealthy -> :stopping -> :stopped
                |
                v
          [backoff restart or give up based on policy]
```

- `:permanent` -- always restart
- `:transient` -- restart on non-zero exit; stop on exit code 0
- `:temporary` -- never restart

## How to Add a New Service Type

To add a new command type (beyond `:shell` and `:module`):

1. **Definition** (`service/definition.ex`):
   - Add the new type to the `@type command` typespec
   - Add a `valid_command?/1` clause for the new pattern
   - Add `command_to_map/1` and `map_to_command/1` clauses for serialization

2. **PortManager** (`runtime/port_manager.ex`):
   - Add a `do_start_port/2` clause that handles the new command tuple
   - Ensure it returns `{:ok, port_or_pid, os_pid}` or `{:error, reason}`
   - If the new type creates an OS port, existing shutdown logic should work
   - If it does not create a port, add appropriate shutdown handling in `do_stop_port/2`

3. **Config** (`config.ex`):
   - If the type should be loadable from YAML, update `map_to_command/1` and `command_to_map/1` in `Definition`

4. **Agent Tools** (`agent/tools.ex`):
   - Update `service_define_schema/0` to document the new command type
   - Update `service_define_execute/2` to handle the new command format from agent input

5. **Tests** (`test/lemon_services_test.exs`):
   - Add a lifecycle test that defines, starts, verifies, and stops a service using the new type
   - Add validation tests for the new command format

## How to Add a New Health Check Type

1. **Definition** (`service/definition.ex`):
   - Add the new type to the `@type health_check` typespec
   - Add a `valid_health_check?/1` clause
   - Add `health_check_to_map/1` and `map_to_health_check/1` clauses

2. **HealthChecker** (`runtime/health_checker.ex`):
   - Add a `run_health_check/1` clause matching the new tuple pattern
   - Return `:ok` for healthy, `{:error, reason}` for unhealthy
   - Add a `get_interval/1` clause to extract the interval from the tuple

## How to Add a New Agent Tool

1. In `agent/tools.ex`:
   - Define `tool_name_schema/0` returning a JSON Schema map
   - Define `tool_name_execute/2` taking `(params, context)` and returning `{:ok, map} | {:error, string}`
   - Add the tool to the `all_tools/0` list as `{"tool_name", &tool_name_schema/0, &tool_name_execute/2}`

2. The tool is then automatically available to any agent system that calls `all_tools/0`.

## Testing Guidance

### Running Tests

```bash
mix test apps/lemon_services
mix test apps/lemon_services --trace
```

### Test File

All tests are in `test/lemon_services_test.exs`. Covers:
- Service lifecycle (define, start, running?, stop, restart)
- Queries (list_definitions, get_definition)
- Definition validation (required fields, restart policy, health check)
- Log buffer (append, retrieve via direct LogBuffer API)
- PubSub events (subscribe, assert_receive lifecycle events)
- Agent tools (service_list, service_status, service_define)

### Testing Tips

- **Always use `restart_policy: :temporary`** in tests to prevent restart loops after stop/crash.
- **Cleanup order matters**: stop the service before unregistering the definition. `unregister_definition/1` returns `{:error, :service_running}` if the service is still running.
- **Log buffer writes are async** (GenServer cast). Add `Process.sleep(10)` or similar if you need to read logs immediately after appending.
- **Log buffer reads are sync** (direct ETS lookup via `:ets.lookup/2`).
- **Tests are not async**. They share global ETS tables (`:lemon_services_definitions`, `:lemon_services_log_buffers`) and the global DynamicSupervisor.
- **Use `Application.ensure_all_started(:lemon_services)`** in setup to ensure the full supervision tree is running.
- **PubSub events**: use `assert_receive {:service_event, service_id, event}, timeout` to wait for lifecycle events. 1000ms timeout is typical.
- **HealthChecker returns `:ignore`** if no `health_check` is configured on the definition, so it will not appear as a supervised child.

### Example Test Pattern

```elixir
test "starts and stops service" do
  {:ok, _} = LemonServices.define_service(
    id: :test_service,
    name: "Test",
    command: {:shell, "echo hello && sleep 10"},
    restart_policy: :temporary
  )

  {:ok, pid} = LemonServices.start_service(:test_service)
  assert is_pid(pid)
  assert LemonServices.running?(:test_service)

  :ok = LemonServices.stop_service(:test_service)
  refute LemonServices.running?(:test_service)
end
```

## Connections to Other Apps

This app has **no umbrella dependencies**. Other apps depend on it:

- **agent_core** / **coding_agent**: May use `LemonServices.Agent.Tools.all_tools/0` to register service management tools with the agent system.
- **lemon_control_plane**: May invoke service operations through the public `LemonServices` API.
- Any app that needs to manage external processes (dev servers, builds, workers) can depend on `:lemon_services`.

## Debugging

```elixir
# Full service state
{:ok, state} = LemonServices.get_service(:my_server)

# Direct Server call
{:ok, state} = LemonServices.Runtime.Server.get_state(:my_server)

# List all running per-service supervisors
DynamicSupervisor.which_children(LemonServices.Runtime.Supervisor)

# Registry lookups
Registry.lookup(LemonServices.Registry, {:server, :my_server})
Registry.lookup(LemonServices.Registry, {:port_manager, :my_server})
Registry.lookup(LemonServices.Registry, {:log_buffer, :my_server})
Registry.lookup(LemonServices.Registry, {:health_checker, :my_server})

# Direct ETS inspection
:ets.tab2list(:lemon_services_definitions)
:ets.lookup(:lemon_services_log_buffers, :my_server)

# Trigger immediate health check
LemonServices.Runtime.HealthChecker.check_now(:my_server)
```

## Dependencies

- `phoenix_pubsub ~> 2.1` -- Event and log broadcasting
- `yaml_elixir ~> 2.9` -- YAML config parsing
- `jason ~> 1.4` -- JSON encoding for tool schemas

No umbrella dependencies.
