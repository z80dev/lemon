# LemonServices

External service management via port-based processes.

## Purpose and Responsibilities

LemonServices manages long-running external processes (services) through an OTP-based supervision tree. Services are:

- **Named**: Looked up by atom ID (e.g., `:dev_server`)
- **Persistent**: Outlive individual sessions (optional)
- **Observable**: Stream logs and events via PubSub
- **Healthy**: Built-in health check support
- **Resilient**: Configurable restart policies with exponential backoff

## Architecture Overview

```
LemonServices.Application (strategy: :one_for_one)
├── Registry (unique keys by service ID)
├── Phoenix.PubSub (event broadcasting)
├── DynamicSupervisor (name: LemonServices.Runtime.Supervisor)
└── LemonServices.Supervisor (strategy: :one_for_one)
    ├── Runtime.LogBuffer.TableOwner (owns ETS log buffer table)
    ├── Service.Store (owns ETS definition table)
    └── Config.Loader (loads YAML configs on boot, auto-starts services)
```

Per-service supervision tree (one per running service, started under DynamicSupervisor):
```
LemonServices.Runtime.Supervisor (:one_for_all, max_restarts from definition)
├── Runtime.LogBuffer
├── Runtime.PortManager
├── Runtime.HealthChecker (only if health_check configured; returns :ignore otherwise)
└── Runtime.Server (coordinator GenServer)
```

**Important**: The module `LemonServices.Runtime.Supervisor` is used as both the DynamicSupervisor name and as the per-service supervisor module. `start_service/1` in that module starts a child supervisor under the DynamicSupervisor.

**Important**: `LemonServices.Config.Loader` and `LemonServices.Runtime.LogBuffer.TableOwner` are nested submodules defined inside `config.ex` and `log_buffer.ex` respectively, not separate files.

## Registry Keys

All processes are registered in `LemonServices.Registry`:

| Key | Process |
|-----|---------|
| `{:service_supervisor, service_id}` | Per-service supervisor |
| `{:server, service_id}` | Runtime.Server |
| `{:port_manager, service_id}` | Runtime.PortManager |
| `{:log_buffer, service_id}` | Runtime.LogBuffer |
| `{:health_checker, service_id}` | Runtime.HealthChecker |

## Service Definition Format

Service definitions are declarative configurations that can be created at runtime or loaded from YAML.

### Elixir API

```elixir
{:ok, definition} = LemonServices.Service.Definition.new(
  id: :my_server,                    # Required: atom identifier
  name: "My Server",                 # Required: human-readable name
  command: {:shell, "npm run dev"},  # Required: shell command or module function
  working_dir: "~/my-app",           # Optional: working directory (~ is expanded)
  env: %{"PORT" => "3000"},          # Optional: environment variables
  auto_start: true,                  # Optional: start on boot (default: false)
  restart_policy: :transient,        # Optional: :permanent | :transient | :temporary (default: :transient)
  health_check: {:http, "http://localhost:3000/health", 5000},  # Optional
  max_restarts: 5,                   # Optional: max restarts before OTP gives up (default: 5)
  max_memory_mb: 512,                # Optional: memory limit (stored but not enforced)
  tags: [:dev, :frontend],           # Optional: categorization tags
  persistent: false,                 # Optional: persist to disk (default: false)
  description: "My server",          # Optional: human-readable description
  created_by: "agent"               # Optional: provenance tracking
)
```

`Definition.new!/1` is also available and raises `ArgumentError` on invalid input.

### YAML Configuration

Static definitions in `config/services.yml`:

```yaml
services:
  dev_server:
    name: "Development Server"
    command:
      type: shell
      cmd: "npm run dev"
    working_dir: "~/my-app"
    env:
      PORT: "3000"
    auto_start: true
    restart_policy: transient
    tags:
      - dev
```

Or individual files in `config/services.d/*.yml`:

```yaml
service:
  id: worker
  name: "Background Worker"
  command:
    type: shell
    cmd: "python worker.py"
  persistent: true
```

`services.yml` can also use a list format (`services:` as a list of objects). Files in `services.d/` can also use the `services:` map format.

**Known limitation**: `Config.save_definition/1` writes an incomplete YAML stub (only the header comment and `service:` key). Persistent service definitions written at runtime are not fully round-trippable.

### Command Types

- `{:shell, "command string"}` - Shell command as string
- `{:shell, ["arg1", "arg2"]}` - Shell command as argument list (args are joined with spaces)
- `{:module, Module, :function, [args]}` - Elixir function spawned with `spawn_link` (no port, no log capture)

### Health Check Types

- `{:http, url, interval_ms}` - HTTP GET expecting status < 400 (uses `:httpc`)
- `{:tcp, host, port, interval_ms}` - TCP connect check (uses `:gen_tcp`)
- `{:command, cmd, interval_ms}` - Shell command (exit 0 = healthy)
- `{:function, mod, fun, args, interval_ms}` - Elixir function (`:ok`, `true`, `{:ok, _}` = healthy)

## Service Lifecycle

### States

| State | Description |
|-------|-------------|
| `:pending` | Service defined but not started |
| `:starting` | Service is being started |
| `:running` | Service is running |
| `:unhealthy` | Service running but health check failing |
| `:stopping` | Service is being stopped |
| `:stopped` | Service stopped normally |
| `:crashed` | Service crashed (may restart based on policy) |

`running?/1` returns `true` for both `:running` and `:unhealthy`.

### Restart Policies

| Policy | Behavior |
|--------|----------|
| `:permanent` | Always restart |
| `:transient` | Restart only on non-zero exit or crash (exit code 0 = no restart) |
| `:temporary` | Never restart |

Restart delays use exponential backoff: `[1000, 2000, 5000, 10000, 30000]` ms (capped at 30s).

### API

```elixir
# Start a service (must be registered first, or pass definition directly)
{:ok, pid} = LemonServices.start_service(:my_server)
{:ok, pid} = LemonServices.start_service(definition)  # also registers the definition

# Stop a service (graceful: SIGTERM, then SIGKILL after timeout)
:ok = LemonServices.stop_service(:my_server)
:ok = LemonServices.stop_service(:my_server, timeout: 10000)  # custom timeout (ms)

# Kill immediately (calls stop_service with timeout: 0, triggering immediate SIGKILL)
:ok = LemonServices.kill_service(:my_server)

# Restart (stop + 100ms sleep + start)
{:ok, pid} = LemonServices.restart_service(:my_server)

# Check status
{:ok, state} = LemonServices.get_service(:my_server)      # returns State.t()
:running = LemonServices.service_status(:my_server)         # returns status atom or {:error, :not_running}
true = LemonServices.running?(:my_server)

# Definition management
:ok = LemonServices.register_definition(definition)
{:ok, definition} = LemonServices.get_definition(:my_server)
:ok = LemonServices.unregister_definition(:my_server)  # errors if service is running
definitions = LemonServices.list_definitions()

# Define and register in one step
{:ok, definition} = LemonServices.define_service(id: :my_server, name: "...", command: {...})

# Save definition to disk (only saves if definition.persistent == true)
:ok = LemonServices.save_definition(definition)

# Event subscription
:ok = LemonServices.subscribe_to_events(:my_server)
:ok = LemonServices.subscribe_to_events(:all)
:ok = LemonServices.unsubscribe_from_events(:my_server)
:ok = LemonServices.unsubscribe_from_events(:all)

# Service listing
services = LemonServices.list_services()              # only running services (have active Server)
definitions = LemonServices.list_definitions()        # all registered definitions
dev_services = LemonServices.list_services_by_tag(:dev)
```

## Port Management

The `Runtime.PortManager` GenServer manages the OS port (process) for each service.

### Key Behaviors

- Uses `Port.open/2` with `:spawn` for shell commands (merges stderr via `:stderr_to_stdout`)
- Graceful shutdown: sends SIGTERM via `System.cmd("kill", ["-TERM", os_pid])`, waits for exit, then SIGKILL if needed
- If OS PID cannot be determined, falls back to `Port.close/1` for both SIGTERM and SIGKILL
- Port data is forwarded to the Server via `send(owner, {:port_data, data})`; exit status via `send(owner, {:port_exit, exit_code})`
- `send_input/2` sends data to stdin via `Port.command/2`
- `get_port_pid/1` returns the PortManager's own PID (not the OS PID), useful for monitoring

### Note on `:module` commands

When command is `{:module, mod, fun, args}`, the function is run via `spawn_link/1` inside the PortManager. No OS port is created, so there is no stdout/stderr capture and no OS-level kill.

## Health Checking

The `Runtime.HealthChecker` GenServer performs periodic health checks.

### Features

- Returns `:ignore` from `start_link/1` (and is not started) if `definition.health_check` is nil
- Reports `:healthy` or `:unhealthy` to the Server via direct message send
- Requires 2 consecutive failures before marking unhealthy; single failure is silently ignored
- Sends `{:health_check, :healthy}` or `{:health_check, :unhealthy, reason}` to the Server process
- Health check timeout: 5000ms (hardcoded `@default_timeout_ms`)

### Manual Check

```elixir
:ok = LemonServices.Runtime.HealthChecker.check_now(:my_server)
# Returns {:error, :not_running} if no health checker is running for that service
```

## Log Buffering

The `Runtime.LogBuffer` GenServer maintains a circular buffer of recent logs in ETS.

### Features

- Default capacity: 1000 lines per service (`@default_max_lines`)
- Stores log maps: `%{timestamp: DateTime.t(), stream: :stdout | :stderr, data: String.t(), sequence: integer()}`
- ETS table (`:lemon_services_log_buffers`) owned by `LogBuffer.TableOwner` for durability across per-service restarts
- Implemented as a queue (`:queue` module); `get_logs/2` calls `Enum.take(-count)` on the list

### API

```elixir
# Get recent logs
logs = LemonServices.get_logs(:my_server, 50)

# Subscribe to live logs (also sends last 100 buffered lines immediately)
:ok = LemonServices.subscribe_to_logs(:my_server)

# Unsubscribe
:ok = LemonServices.unsubscribe_from_logs(:my_server)

# Direct LogBuffer API
:ok = LemonServices.Runtime.LogBuffer.append(:my_server, log_map)
logs = LemonServices.Runtime.LogBuffer.get_logs(:my_server, 100)
:ok = LemonServices.Runtime.LogBuffer.clear(:my_server)
```

**Note**: `subscribe_to_logs/1` and `unsubscribe_from_logs/1` go through `Runtime.Server` (which tracks subscribers in the `State` struct). They return `{:error, :not_running}` if the Server is not running.

**Note**: On subscribe, the Server immediately sends the last 100 buffered log lines to the new subscriber process.

## PubSub Events

Two subscription mechanisms exist:

1. **PubSub** (Phoenix.PubSub) - for any process, survives process restarts
2. **Direct subscription** (tracked in `State.log_subscribers` / `State.event_subscribers`) - via `subscribe_to_events/1` and `subscribe_to_logs/1` in the public API

```elixir
# PubSub (lower-level, direct)
Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:my_server")
Phoenix.PubSub.subscribe(LemonServices.PubSub, "services:all")
Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:my_server:logs")

# High-level API (uses Server's subscriber tracking + PubSub)
LemonServices.subscribe_to_events(:my_server)
LemonServices.subscribe_to_events(:all)
LemonServices.subscribe_to_logs(:my_server)
```

Event messages:

```elixir
{:service_event, service_id, :service_starting}
{:service_event, service_id, :service_started}
{:service_event, service_id, :service_stopping}
{:service_event, service_id, :service_stopped}
{:service_event, service_id, {:service_crashed, exit_code, reason}}
{:service_event, service_id, {:service_failed_to_start, reason}}
{:service_event, service_id, {:service_exited, exit_code}}   # normal exit (not crash)
{:service_event, service_id, :health_check_passed}
{:service_event, service_id, {:health_check_failed, reason}}

{:service_log, service_id, %{timestamp: DateTime.t(), stream: :stdout | :stderr, data: String.t(), sequence: integer()}}
```

## Common Tasks

### Define and Start a New Service

```elixir
# define_service creates the definition AND registers it
{:ok, definition} = LemonServices.define_service(
  id: :temp_worker,
  name: "Temp Worker",
  command: {:shell, "python script.py"},
  working_dir: "/tmp",
  auto_start: false
)

# Start it
{:ok, pid} = LemonServices.start_service(:temp_worker)
```

### List Services

```elixir
# All definitions (including stopped/never-started)
definitions = LemonServices.list_definitions()

# Running services only (have an active Runtime.Server process)
services = LemonServices.list_services()

# By tag (also running only)
dev_services = LemonServices.list_services_by_tag(:dev)
dev_services = LemonServices.list_services_by_tag([:dev, :infra])  # multiple tags (OR)
```

### Persist a Service Definition

```elixir
{:ok, definition} = Definition.new(
  id: :persistent_service,
  name: "Persistent Service",
  command: {:shell, "./start.sh"},
  persistent: true
)

:ok = LemonServices.save_definition(definition)
# Saves to config/services.d/{id}.yml (relative to File.cwd!() at compile time)
```

### Remove a Service Definition

```elixir
# Must be stopped first (returns {:error, :service_running} otherwise)
:ok = LemonServices.stop_service(:my_service)
:ok = LemonServices.unregister_definition(:my_service)
# Also calls Config.remove_definition/1 to remove the YAML file if it exists
```

## Agent Tools

`LemonServices.Agent.Tools` exposes 8 tools for agent use. Each tool has a separate schema function and execute function:

| Tool | Schema fn | Execute fn |
|------|-----------|------------|
| `service_start` | `service_start_schema/0` | `service_start_execute/2` |
| `service_stop` | `service_stop_schema/0` | `service_stop_execute/2` |
| `service_restart` | `service_restart_schema/0` | `service_restart_execute/2` |
| `service_status` | `service_status_schema/0` | `service_status_execute/2` |
| `service_logs` | `service_logs_schema/0` | `service_logs_execute/2` |
| `service_list` | `service_list_schema/0` | `service_list_execute/2` |
| `service_attach` | `service_attach_schema/0` | `service_attach_execute/2` |
| `service_define` | `service_define_schema/0` | `service_define_execute/2` |

```elixir
# Get all tools as {name, schema_fn, execute_fn} tuples
tools = LemonServices.Agent.Tools.all_tools()

# Execute functions take (%{string_key => value}, context_map) and return {:ok, map} | {:error, string}
{:ok, result} = LemonServices.Agent.Tools.service_list_execute(%{}, %{})
```

`service_list_execute` returns both running services and stopped definitions. `service_status_execute` falls back to definition lookup if service is not running. `service_define` accepts `"command"` (string) or `"command_args"` (list) but not a health check.

## Debugging

### Check Service State

```elixir
# Get full State struct
{:ok, state} = LemonServices.get_service(:my_server)

# Direct call to Server
{:ok, state} = LemonServices.Runtime.Server.get_state(:my_server)

# List all per-service supervisors running under DynamicSupervisor
DynamicSupervisor.which_children(LemonServices.Runtime.Supervisor)
```

### Registry Lookup

```elixir
Registry.lookup(LemonServices.Registry, {:service_supervisor, :my_server})
Registry.lookup(LemonServices.Registry, {:server, :my_server})
Registry.lookup(LemonServices.Registry, {:port_manager, :my_server})
Registry.lookup(LemonServices.Registry, {:log_buffer, :my_server})
Registry.lookup(LemonServices.Registry, {:health_checker, :my_server})
```

### Log Buffer Inspection

```elixir
# Direct ETS lookup (returns [{service_id, queue, sequence_index}])
:ets.lookup(:lemon_services_log_buffers, :my_server)

# Get logs
LemonServices.Runtime.LogBuffer.get_logs(:my_server, 100)
```

## Testing Guidance

### Test Structure

Tests live in `test/`:
- `lemon_services_test.exs` - Covers lifecycle, queries, validation, log buffer, pubsub, and agent tools
- `test_helper.exs` - Test setup

### Running Tests

```bash
mix test apps/lemon_services
```

Tests use `Application.ensure_all_started(:lemon_services)` in setup. No `async: true` is set (tests share global ETS state).

### Testing Tips

- Use `restart_policy: :temporary` to prevent restart loops in tests
- `unregister_definition/1` will fail if the service is still running; always stop first
- The per-service supervisor uses `:one_for_all`, so crashing one component (e.g., PortManager) restarts all siblings
- HealthChecker starts only if `health_check` is configured; safely returns `:ignore` otherwise
- Log buffer reads from ETS directly and are synchronous; appends go through GenServer cast (async) - add `Process.sleep/1` if testing append results
- `subscribe_to_logs/1` also delivers 100 buffered lines immediately to the subscriber process

### Example Test Pattern

```elixir
defmodule LemonServicesTest do
  use ExUnit.Case

  setup do
    Application.ensure_all_started(:lemon_services)

    on_exit(fn ->
      # Stop before unregistering
      LemonServices.stop_service(:test_service)
      LemonServices.unregister_definition(:test_service)
    end)

    :ok
  end

  test "starts and stops service" do
    {:ok, _} = LemonServices.define_service(
      id: :test_service,
      name: "Test Service",
      command: {:shell, "echo hello && sleep 10"},
      restart_policy: :temporary
    )

    {:ok, pid} = LemonServices.start_service(:test_service)
    assert is_pid(pid)
    assert LemonServices.running?(:test_service)

    :ok = LemonServices.stop_service(:test_service)
    refute LemonServices.running?(:test_service)
  end
end
```

## Key Modules Reference

| Module | File | Purpose |
|--------|------|---------|
| `LemonServices` | `lemon_services.ex` | Main public API |
| `LemonServices.Application` | `application.ex` | OTP application callback |
| `LemonServices.Supervisor` | `supervisor.ex` | Top-level supervisor (Store, LogBuffer owner, Config loader) |
| `LemonServices.Service.Definition` | `service/definition.ex` | Definition struct, `new/1`, `new!/1`, `validate/1`, `to_map/1`, `from_map/1` |
| `LemonServices.Service.State` | `service/state.ex` | Runtime state struct, `set_status/3`, `set_health/2`, subscriber management |
| `LemonServices.Service.Store` | `service/store.ex` | ETS-backed definition storage GenServer |
| `LemonServices.Runtime.Supervisor` | `runtime/supervisor.ex` | Per-service supervisor module AND DynamicSupervisor name |
| `LemonServices.Runtime.Server` | `runtime/server.ex` | Main lifecycle coordinator GenServer |
| `LemonServices.Runtime.PortManager` | `runtime/port_manager.ex` | OS port management GenServer |
| `LemonServices.Runtime.HealthChecker` | `runtime/health_checker.ex` | Periodic health checks GenServer |
| `LemonServices.Runtime.LogBuffer` | `runtime/log_buffer.ex` | Circular log buffer GenServer (TableOwner nested inside) |
| `LemonServices.Config` | `config.ex` | YAML config loading/persistence (Loader GenServer nested inside) |
| `LemonServices.Agent.Tools` | `agent/tools.ex` | Agent tool definitions and executors |

## Dependencies

- `phoenix_pubsub ~> 2.1` - Event broadcasting
- `yaml_elixir ~> 2.9` - YAML config parsing
- `jason ~> 1.4` - JSON encoding (for tool schemas)

No umbrella dependencies - this app is self-contained.
