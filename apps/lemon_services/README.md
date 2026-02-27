# LemonServices

Long-running service management for the Lemon umbrella project, built on OTP.

## Overview

LemonServices provides a service-oriented process management system that wraps external OS processes (and Elixir functions) in a full OTP supervision tree. It is designed for managing development servers, background workers, database processes, and other long-running services that need to be started, stopped, monitored, and restarted programmatically -- including by AI agents.

Services managed by LemonServices are:

- **Named** -- looked up by atom ID (e.g., `:dev_server`, `:postgres`)
- **Persistent** -- optionally outlive sessions by persisting definitions to YAML on disk
- **Observable** -- stream stdout/stderr logs and lifecycle events via Phoenix PubSub
- **Health-checked** -- periodic HTTP, TCP, command, or function-based health probes
- **Resilient** -- configurable restart policies (permanent, transient, temporary) with exponential backoff
- **Agent-accessible** -- a full set of agent tools for starting, stopping, querying, and defining services

## Architecture

### Supervision Tree

```
LemonServices.Application (strategy: :one_for_one)
|-- Registry (unique keys by service ID, all process types)
|-- Phoenix.PubSub (named LemonServices.PubSub)
|-- DynamicSupervisor (named LemonServices.Runtime.Supervisor)
|   `-- [per-service supervisors, started on demand]
`-- LemonServices.Supervisor (strategy: :one_for_one)
    |-- Runtime.LogBuffer.TableOwner  (owns ETS table :lemon_services_log_buffers)
    |-- Service.Store                 (owns ETS table :lemon_services_definitions)
    `-- Config.Loader                 (loads YAML on boot, auto-starts services)
```

Each running service gets its own supervisor (strategy: `:one_for_all`) started as a child of the `DynamicSupervisor`:

```
Per-service supervisor (LemonServices.Runtime.Supervisor)
|-- Runtime.LogBuffer       (circular log buffer, per-service)
|-- Runtime.PortManager     (OS port lifecycle)
|-- Runtime.HealthChecker   (periodic health probes; :ignore if unconfigured)
`-- Runtime.Server          (main coordinator GenServer)
```

The `:one_for_all` strategy means that if any component of a service crashes (e.g., the PortManager), all sibling processes for that service are restarted together.

### Process Registry

All per-service processes register themselves in `LemonServices.Registry` using composite keys:

| Registry Key | Process |
|---|---|
| `{:service_supervisor, service_id}` | Per-service supervisor |
| `{:server, service_id}` | `Runtime.Server` |
| `{:port_manager, service_id}` | `Runtime.PortManager` |
| `{:log_buffer, service_id}` | `Runtime.LogBuffer` |
| `{:health_checker, service_id}` | `Runtime.HealthChecker` |

### Data Flow

1. **Startup**: `Config.Loader` reads YAML files on boot, registers definitions in `Service.Store` (ETS), and auto-starts services with `auto_start: true`.
2. **Service start**: The public API calls `Runtime.Supervisor.start_service/1`, which starts a per-service supervisor under the `DynamicSupervisor`. The supervisor starts LogBuffer, PortManager, HealthChecker, and Server.
3. **Port output**: `PortManager` receives data from the OS port and forwards it to `Server` via `send(owner, {:port_data, data})`. Server appends the log line to `LogBuffer`, broadcasts it via PubSub, and sends it directly to subscriber processes.
4. **Health checks**: `HealthChecker` runs periodic probes and sends `{:health_check, :healthy | :unhealthy}` messages to `Server`. Server updates the service state and broadcasts health events.
5. **Crash recovery**: When `Server` detects a process crash (via `Process.monitor`), it evaluates the restart policy and schedules a restart with exponential backoff if appropriate.

## Module Inventory

| Module | File | Purpose |
|---|---|---|
| `LemonServices` | `lib/lemon_services.ex` | Public API: start, stop, restart, kill, query, subscribe, define |
| `LemonServices.Application` | `lib/lemon_services/application.ex` | OTP application callback; starts top-level supervision tree |
| `LemonServices.Supervisor` | `lib/lemon_services/supervisor.ex` | Top-level supervisor for Store, LogBuffer.TableOwner, Config.Loader |
| `LemonServices.Config` | `lib/lemon_services/config.ex` | YAML config loading from `services.yml` and `services.d/*.yml`; persistence |
| `LemonServices.Config.Loader` | `lib/lemon_services/config.ex` | Nested GenServer; loads definitions and auto-starts services on boot |
| `LemonServices.Service.Definition` | `lib/lemon_services/service/definition.ex` | Definition struct with validation, YAML/map serialization |
| `LemonServices.Service.State` | `lib/lemon_services/service/state.ex` | Runtime state struct: status, health, subscribers, timestamps |
| `LemonServices.Service.Store` | `lib/lemon_services/service/store.ex` | ETS-backed GenServer for definition storage |
| `LemonServices.Runtime.Supervisor` | `lib/lemon_services/runtime/supervisor.ex` | Per-service supervisor module; also used as `DynamicSupervisor` name |
| `LemonServices.Runtime.Server` | `lib/lemon_services/runtime/server.ex` | Main lifecycle coordinator; handles restarts, events, log routing |
| `LemonServices.Runtime.PortManager` | `lib/lemon_services/runtime/port_manager.ex` | OS port management: start, stop, stdin, signal handling |
| `LemonServices.Runtime.HealthChecker` | `lib/lemon_services/runtime/health_checker.ex` | Periodic health probes (HTTP, TCP, command, function) |
| `LemonServices.Runtime.LogBuffer` | `lib/lemon_services/runtime/log_buffer.ex` | Circular log buffer in ETS via `:queue` |
| `LemonServices.Runtime.LogBuffer.TableOwner` | `lib/lemon_services/runtime/log_buffer.ex` | Nested GenServer; owns the ETS table so it survives per-service restarts |
| `LemonServices.Agent.Tools` | `lib/lemon_services/agent/tools.ex` | 8 agent tools: start, stop, restart, status, logs, list, attach, define |

## Service Lifecycle

### States

```
:pending --> :starting --> :running --> :stopping --> :stopped
                |              |                         ^
                |              v                         |
                |         :unhealthy -----> :stopping ---+
                |              |
                v              v
            :crashed <---- :crashed
                |
                v
          [restart or give up]
```

| State | Description |
|---|---|
| `:pending` | Definition registered but service never started |
| `:starting` | Port is being opened; `started_at` timestamp is set |
| `:running` | Port is open and process is alive |
| `:unhealthy` | Running but health check has failed 2+ consecutive times |
| `:stopping` | Graceful shutdown in progress (SIGTERM sent) |
| `:stopped` | Process exited normally (exit code 0) |
| `:crashed` | Process exited abnormally or failed to start |

The `running?/1` function returns `true` for both `:running` and `:unhealthy`.

### Restart Policies

| Policy | Behavior |
|---|---|
| `:permanent` | Always restart, regardless of exit code |
| `:transient` | Restart only on non-zero exit code or crash; exit code 0 means stop permanently |
| `:temporary` | Never restart; for one-off tasks |

Restart delays follow exponential backoff: 1s, 2s, 5s, 10s, 30s (capped). The delay is selected based on `restart_count`, indexing into `[1000, 2000, 5000, 10000, 30000]`.

### Shutdown Behavior

- **Graceful stop** (`stop_service/2`): Sends SIGTERM to the OS process via `kill -TERM`, waits up to `timeout` ms (default 5000), then sends SIGKILL if still alive.
- **Kill** (`kill_service/1`): Calls `stop_service` with `timeout: 0`, forcing immediate SIGKILL.
- If the OS PID cannot be determined, falls back to `Port.close/1`.

## Configuration

### Static Configuration (YAML)

Service definitions can be loaded from YAML files at boot time:

**Main file**: `config/services.yml`

```yaml
services:
  dev_server:
    name: "Next.js Dev Server"
    command:
      type: shell
      cmd: "npm run dev"
    working_dir: "~/dev/my-app"
    env:
      PORT: "3000"
      NODE_ENV: "development"
    auto_start: false
    restart_policy: transient
    health_check:
      type: http
      url: "http://localhost:3000/api/health"
      interval_ms: 5000
    tags: [dev, frontend]
```

**Additional files**: `config/services.d/*.yml`

Each file can contain a single service (`service:` key) or multiple services (`services:` map or list).

```yaml
service:
  id: worker
  name: "Background Worker"
  command:
    type: shell
    cmd: "python worker.py"
  persistent: true
```

### Runtime Configuration (Elixir)

```elixir
# Define a service
{:ok, definition} = LemonServices.Service.Definition.new(
  id: :my_worker,
  name: "My Worker",
  command: {:shell, "python worker.py"},
  working_dir: "~/workers",
  env: %{"QUEUE" => "default"},
  auto_start: false,
  restart_policy: :permanent,
  health_check: {:tcp, "localhost", 6379, 10_000},
  max_restarts: 5,
  max_memory_mb: 512,
  tags: [:infra, :backend],
  persistent: true,
  description: "Background job processor",
  created_by: "agent"
)

# Register and start
:ok = LemonServices.register_definition(definition)
{:ok, _pid} = LemonServices.start_service(:my_worker)

# Or in one step (define + register)
{:ok, definition} = LemonServices.define_service(
  id: :temp_task,
  name: "Temp Task",
  command: {:shell, "make build"},
  restart_policy: :temporary
)
```

### Definition Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `id` | `atom()` | required | Unique identifier |
| `name` | `String.t()` | required | Human-readable name |
| `command` | `command()` | required | Shell command or module function |
| `working_dir` | `Path.t()` | `nil` | Working directory (`~` is expanded) |
| `env` | `map()` | `%{}` | Environment variables |
| `auto_start` | `boolean()` | `false` | Start automatically on application boot |
| `restart_policy` | `atom()` | `:transient` | `:permanent`, `:transient`, or `:temporary` |
| `health_check` | `health_check()` | `nil` | Health check configuration |
| `max_restarts` | `pos_integer()` | `5` | Max restarts for the per-service OTP supervisor |
| `max_memory_mb` | `pos_integer()` | `nil` | Memory limit (stored but not currently enforced) |
| `tags` | `[atom()]` | `[]` | Categorization tags for filtering |
| `persistent` | `boolean()` | `false` | Whether to persist definition to disk |
| `description` | `String.t()` | `nil` | Human-readable description |
| `created_by` | `String.t()` | `nil` | Provenance tracking |

### Command Types

```elixir
# Shell command as a string
{:shell, "npm run dev"}

# Shell command as argument list (joined with spaces)
{:shell, ["npm", "run", "dev"]}

# Elixir module function (spawned via spawn_link; no port, no log capture)
{:module, MyApp.Worker, :start, []}
```

### Health Check Types

```elixir
# HTTP GET (healthy if status < 400; uses :httpc)
{:http, "http://localhost:3000/health", 5_000}

# TCP connect (healthy if connection succeeds; uses :gen_tcp)
{:tcp, "localhost", 5432, 10_000}

# Shell command (healthy if exit code 0)
{:command, "pg_isready -h localhost", 5_000}

# Elixir function (healthy if returns :ok, true, or {:ok, _})
{:function, MyApp.Health, :check, [], 5_000}
```

The last element in each tuple is the check interval in milliseconds. Health check timeout is hardcoded at 5000ms. A service is marked `:unhealthy` only after 2 consecutive failures.

## Usage

### Basic Operations

```elixir
# Start/stop/restart/kill
{:ok, pid} = LemonServices.start_service(:dev_server)
:ok = LemonServices.stop_service(:dev_server)
:ok = LemonServices.stop_service(:dev_server, timeout: 10_000)
{:ok, pid} = LemonServices.restart_service(:dev_server)
:ok = LemonServices.kill_service(:dev_server)

# Query status
{:ok, state} = LemonServices.get_service(:dev_server)
:running = LemonServices.service_status(:dev_server)
true = LemonServices.running?(:dev_server)

# List services
services = LemonServices.list_services()                   # running only
definitions = LemonServices.list_definitions()              # all registered
dev_services = LemonServices.list_services_by_tag(:dev)
infra = LemonServices.list_services_by_tag([:infra, :db])  # OR filter

# Definition management
:ok = LemonServices.register_definition(definition)
{:ok, def} = LemonServices.get_definition(:dev_server)
:ok = LemonServices.unregister_definition(:dev_server)     # must be stopped first
:ok = LemonServices.save_definition(definition)             # persists to YAML if persistent: true
```

### Log Streaming

```elixir
# Get buffered logs
logs = LemonServices.get_logs(:dev_server, 50)

# Subscribe to live logs (also delivers last 100 buffered lines)
:ok = LemonServices.subscribe_to_logs(:dev_server)

# Receive log messages
receive do
  {:service_log, :dev_server, %{timestamp: ts, stream: :stdout, data: line}} ->
    IO.puts("[#{ts}] #{line}")
end

# Unsubscribe
:ok = LemonServices.unsubscribe_from_logs(:dev_server)
```

### Event Subscription

```elixir
# Subscribe to a specific service
:ok = LemonServices.subscribe_to_events(:dev_server)

# Subscribe to all services
:ok = LemonServices.subscribe_to_events(:all)

# Receive events
receive do
  {:service_event, :dev_server, :service_started} -> IO.puts("Started!")
  {:service_event, :dev_server, {:service_crashed, code, reason}} -> IO.puts("Crashed: #{code}")
  {:service_event, :dev_server, :health_check_passed} -> IO.puts("Healthy")
end

# Or use Phoenix.PubSub directly
Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:dev_server")
Phoenix.PubSub.subscribe(LemonServices.PubSub, "services:all")
Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:dev_server:logs")
```

### PubSub Event Reference

```elixir
# Lifecycle events
{:service_event, service_id, :service_starting}
{:service_event, service_id, :service_started}
{:service_event, service_id, :service_stopping}
{:service_event, service_id, :service_stopped}
{:service_event, service_id, {:service_crashed, exit_code, reason}}
{:service_event, service_id, {:service_failed_to_start, reason}}
{:service_event, service_id, {:service_exited, exit_code}}

# Health events
{:service_event, service_id, :health_check_passed}
{:service_event, service_id, {:health_check_failed, reason}}

# Log messages
{:service_log, service_id, %{timestamp: DateTime.t(), stream: :stdout | :stderr, data: String.t(), sequence: integer()}}
```

## Agent Tools

`LemonServices.Agent.Tools` provides 8 tools for AI agent use. Each tool has a schema function (returning a JSON Schema map) and an execute function (taking `%{String.t() => value}` params and a context map, returning `{:ok, map()} | {:error, String.t()}`).

| Tool | Description |
|---|---|
| `service_start` | Start a registered service by ID |
| `service_stop` | Stop a running service with optional timeout |
| `service_restart` | Restart a running service |
| `service_status` | Get detailed service status (falls back to definition if not running) |
| `service_logs` | Get recent log lines with optional stream filter (stdout/stderr) |
| `service_list` | List all services (running and stopped) with optional tag/status filter |
| `service_attach` | Subscribe/unsubscribe session to live service logs |
| `service_define` | Define and register a new service at runtime |

```elixir
# Get all tool definitions
tools = LemonServices.Agent.Tools.all_tools()
# Returns [{name, schema_fn, execute_fn}, ...]

# Example execution
{:ok, result} = LemonServices.Agent.Tools.service_list_execute(%{"tag" => "dev"}, %{})
```

## Dependencies

| Dependency | Version | Purpose |
|---|---|---|
| `phoenix_pubsub` | `~> 2.1` | Event and log broadcasting via PubSub |
| `yaml_elixir` | `~> 2.9` | YAML config file parsing |
| `jason` | `~> 1.4` | JSON encoding for tool schemas |

This app has no dependencies on other umbrella apps. It is self-contained.

## Testing

```bash
# Run all tests
mix test apps/lemon_services

# Run with verbose output
mix test apps/lemon_services --trace
```

Tests are in `test/lemon_services_test.exs` and cover:

- Service lifecycle (define, start, stop, restart)
- Service queries (list definitions, get definition)
- Definition validation (required fields, restart policy, health check)
- Log buffer (append, retrieve)
- PubSub events (subscribe, receive lifecycle events)
- Agent tools (service_list, service_status, service_define)

Tests use `Application.ensure_all_started(:lemon_services)` in setup and clean up test services in `on_exit`. Tests are not marked `async: true` because they share global ETS state.

## Known Limitations

- `Config.save_definition/1` writes an incomplete YAML stub (header comment and `service:` key only). Persistent definitions saved at runtime are not fully round-trippable through YAML.
- `max_memory_mb` is stored on the definition but not enforced at runtime.
- `:module` command type uses `spawn_link` inside PortManager, so there is no stdout/stderr capture and no OS-level signal handling for Elixir function-based services.
- `Runtime.Supervisor` is used as both the `DynamicSupervisor` name and the per-service supervisor module, which can be confusing when reading the code.
- Health check timeout is hardcoded at 5000ms and not configurable per-service.
- `PortManager` merges stderr into stdout (`:stderr_to_stdout` port option), so all output appears as `:stdout` stream in logs.
