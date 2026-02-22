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
LemonServices.Application
├── Registry (unique keys by service ID)
├── Phoenix.PubSub (event broadcasting)
├── DynamicSupervisor (runtime service supervisors)
└── LemonServices.Supervisor
    ├── LogBuffer.TableOwner (ETS table owner)
    ├── Service.Store (ETS-backed definition storage)
    └── Config.Loader (loads YAML configs on boot)
```

Per-service supervision tree (under DynamicSupervisor):
```
Runtime.Supervisor (:one_for_all)
├── Runtime.LogBuffer
├── Runtime.PortManager
├── Runtime.HealthChecker (optional)
└── Runtime.Server (coordinator)
```

## Service Definition Format

Service definitions are declarative configurations that can be created at runtime or loaded from YAML.

### Elixir API

```elixir
{:ok, definition} = LemonServices.Service.Definition.new(
  id: :my_server,                    # Required: atom identifier
  name: "My Server",                 # Required: human-readable name
  command: {:shell, "npm run dev"},  # Required: shell command or module function
  working_dir: "~/my-app",           # Optional: working directory
  env: %{"PORT" => "3000"},          # Optional: environment variables
  auto_start: true,                  # Optional: start on boot (default: false)
  restart_policy: :transient,        # Optional: :permanent | :transient | :temporary
  health_check: {:http, "http://localhost:3000/health", 5000},  # Optional
  max_restarts: 5,                   # Optional: max restarts before giving up
  max_memory_mb: 512,                # Optional: memory limit (not enforced yet)
  tags: [:dev, :frontend],           # Optional: categorization tags
  persistent: false                  # Optional: persist to disk
)
```

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

### Command Types

- `{:shell, "command string"}` - Shell command as string
- `{:shell, ["arg1", "arg2"]}` - Shell command as argument list
- `{:module, Module, :function, [args]}` - Elixir function call

### Health Check Types

- `{:http, url, interval_ms}` - HTTP GET expecting 2xx/3xx
- `{:tcp, host, port, interval_ms}` - TCP connect check
- `{:command, cmd, interval_ms}` - Shell command (exit 0 = healthy)
- `{:function, mod, fun, args, interval_ms}` - Elixir function call

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

### Restart Policies

| Policy | Behavior |
|--------|----------|
| `:permanent` | Always restart (default for critical services) |
| `:transient` | Restart only on abnormal exit (default) |
| `:temporary` | Never restart (for one-off tasks) |

Restart delays use exponential backoff: `[1000, 2000, 5000, 10000, 30000]` ms.

### API

```elixir
# Start a service
{:ok, pid} = LemonServices.start_service(:my_server)

# Stop a service (graceful shutdown)
:ok = LemonServices.stop_service(:my_server)
:ok = LemonServices.stop_service(:my_server, timeout: 10000)  # custom timeout

# Kill immediately (SIGKILL)
:ok = LemonServices.kill_service(:my_server)

# Restart
{:ok, pid} = LemonServices.restart_service(:my_server)

# Check status
{:ok, state} = LemonServices.get_service(:my_server)
:running = LemonServices.service_status(:my_server)
true = LemonServices.running?(:my_server)
```

## Port Management

The `Runtime.PortManager` GenServer manages the OS port (process) for each service.

### Key Behaviors

- Uses `Port.open/2` with `:spawn` for shell commands
- Captures stdout/stderr (merged via `:stderr_to_stdout`)
- Receives exit status notifications
- Supports graceful shutdown (SIGTERM) with timeout, then SIGKILL
- Works in working directory with custom environment variables

### Shutdown Flow

1. Send SIGTERM to OS process
2. Wait for exit status (configurable timeout, default 5s)
3. If timeout, send SIGKILL

## Health Checking

The `Runtime.HealthChecker` GenServer performs periodic health checks.

### Features

- Only starts if health check is configured
- Reports `:healthy` or `:unhealthy` to the Server
- Requires 2 consecutive failures before marking unhealthy
- Triggers state transition to `:unhealthy` status
- Broadcasts events via PubSub

### Manual Check

```elixir
:ok = LemonServices.Runtime.HealthChecker.check_now(:my_server)
```

## Log Buffering

The `Runtime.LogBuffer` GenServer maintains a circular buffer of recent logs in ETS.

### Features

- Default capacity: 1000 lines per service
- Stores: timestamp, stream (:stdout/:stderr), data, sequence number
- ETS table owned by `LogBuffer.TableOwner` for durability
- Logs broadcast via PubSub on `service:{id}:logs` topic

### API

```elixir
# Get recent logs
logs = LemonServices.get_logs(:my_server, 50)

# Subscribe to live logs
:ok = LemonServices.subscribe_to_logs(:my_server)

# Unsubscribe
:ok = LemonServices.unsubscribe_from_logs(:my_server)
```

## PubSub Events

Subscribe to events:

```elixir
# Specific service
Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:my_server")

# All services
Phoenix.PubSub.subscribe(LemonServices.PubSub, "services:all")

# Service logs
Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:my_server:logs")
```

Event messages:

```elixir
{:service_event, service_id, :service_starting}
{:service_event, service_id, :service_started}
{:service_event, service_id, :service_stopping}
{:service_event, service_id, :service_stopped}
{:service_event, service_id, {:service_crashed, exit_code, reason}}
{:service_event, service_id, {:service_failed_to_start, reason}}
{:service_event, service_id, :health_check_passed}
{:service_event, service_id, {:health_check_failed, reason}}

{:service_log, service_id, %{timestamp: DateTime.t(), stream: :stdout | :stderr, data: String.t()}}
```

## Common Tasks

### Define and Start a New Service

```elixir
# Define
{:ok, definition} = LemonServices.define_service(
  id: :temp_worker,
  name: "Temp Worker",
  command: {:shell, "python script.py"},
  working_dir: "/tmp",
  auto_start: false
)

# Start later
{:ok, pid} = LemonServices.start_service(:temp_worker)
```

### List Services

```elixir
# All definitions
definitions = LemonServices.list_definitions()

# Running services
services = LemonServices.list_services()

# By tag
dev_services = LemonServices.list_services_by_tag(:dev)
```

### Persist a Service Definition

```elixir
{:ok, definition} = LemonServices.Service.Definition.new(
  id: :persistent_service,
  name: "Persistent Service",
  command: {:shell, "./start.sh"},
  persistent: true  # Saves to config/services.d/{id}.yml
)

:ok = LemonServices.save_definition(definition)
```

### Remove a Service Definition

```elixir
# Must be stopped first
:ok = LemonServices.stop_service(:my_service)
:ok = LemonServices.unregister_definition(:my_service)
```

## Debugging

### Check Service State

```elixir
# Get full state
{:ok, state} = LemonServices.Runtime.Server.get_state(:my_server)

# Inspect process
:sys.get_state(Registry.lookup(LemonServices.Registry, {:server, :my_server}) |> hd() |> elem(0))

# List running service supervisors
DynamicSupervisor.which_children(LemonServices.Runtime.Supervisor)
```

### Registry Lookup

```elixir
# Find service supervisor
Registry.lookup(LemonServices.Registry, {:service_supervisor, :my_server})

# Find server
Registry.lookup(LemonServices.Registry, {:server, :my_server})

# Find port manager
Registry.lookup(LemonServices.Registry, {:port_manager, :my_server})
```

### Log Buffer Inspection

```elixir
# Direct ETS lookup
:ets.lookup(:lemon_services_log_buffers, :my_server)

# Get logs
LemonServices.Runtime.LogBuffer.get_logs(:my_server, 100)
```

## Testing Guidance

### Test Structure

Tests live in `apps/lemon_services/test/`:
- `lemon_services_test.exs` - Main test file
- `test_helper.exs` - Test setup

### Running Tests

```bash
# All tests for this app
mix test apps/lemon_services

# With integration tests (if any)
mix test apps/lemon_services --include integration
```

### Testing Tips

- Services use `:one_for_all` supervision, so crashing one component restarts all
- Log buffer uses ETS with a separate TableOwner process for durability
- PortManager uses actual OS ports; consider mocking for unit tests
- HealthChecker requires actual endpoints/ports for HTTP/TCP checks
- Use `temporary` restart policy in tests to avoid restart loops

### Example Test Pattern

```elixir
defmodule LemonServicesTest do
  use ExUnit.Case

  setup do
    # Define a test service
    {:ok, definition} = LemonServices.Service.Definition.new(
      id: :test_service,
      name: "Test Service",
      command: {:shell, "echo hello && sleep 10"},
      restart_policy: :temporary
    )
    
    :ok = LemonServices.register_definition(definition)
    
    on_exit(fn ->
      LemonServices.stop_service(:test_service)
      LemonServices.unregister_definition(:test_service)
    end)
    
    {:ok, definition: definition}
  end
  
  test "starts and stops service", %{definition: definition} do
    {:ok, pid} = LemonServices.start_service(:test_service)
    assert is_pid(pid)
    
    :ok = LemonServices.stop_service(:test_service)
    assert {:error, :not_running} = LemonServices.get_service(:test_service)
  end
end
```

## Key Modules Reference

| Module | Purpose |
|--------|---------|
| `LemonServices` | Main public API |
| `LemonServices.Application` | OTP application callback |
| `LemonServices.Supervisor` | Top-level supervisor |
| `LemonServices.Service.Definition` | Service definition struct and validation |
| `LemonServices.Service.State` | Runtime state struct |
| `LemonServices.Service.Store` | ETS-backed definition storage |
| `LemonServices.Runtime.Supervisor` | Per-service supervisor |
| `LemonServices.Runtime.Server` | Main service lifecycle coordinator |
| `LemonServices.Runtime.PortManager` | OS port management |
| `LemonServices.Runtime.HealthChecker` | Periodic health checks |
| `LemonServices.Runtime.LogBuffer` | Circular log buffer |
| `LemonServices.Config` | YAML config loading/persistence |
| `LemonServices.Agent.Tools` | Agent tool definitions |

## Dependencies

- `phoenix_pubsub` - Event broadcasting
- `yaml_elixir` - YAML config parsing
- `jason` - JSON encoding (for tools)

No umbrella dependencies - this app is self-contained.
