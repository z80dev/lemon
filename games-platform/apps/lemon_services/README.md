# LemonServices

Long-running service management for Lemon.

## Overview

LemonServices provides a service-oriented process management system built on OTP. Services are:

- **Named**: Looked up by atom ID (e.g., `:dev_server`)
- **Persistent**: Outlive individual sessions
- **Observable**: Stream logs and events via PubSub
- **Healthy**: Built-in health check support
- **Resilient**: Configurable restart policies

## Architecture

```
LemonServices.Application
├── Registry (service process lookup)
├── PubSub (event broadcasting)
├── Runtime.Supervisor (DynamicSupervisor)
│   └── Per-service supervisor (one_for_all)
│       ├── LogBuffer (circular log storage)
│       ├── PortManager (OS process lifecycle)
│       ├── HealthChecker (periodic health checks)
│       └── Server (main coordinator)
└── Supervisor
    ├── LogBuffer.TableOwner (ETS owner)
    ├── Service.Store (definition storage)
    └── Config.Loader (static config loader)
```

## Configuration

### Static Configuration

Define services in `config/services.yml`:

```yaml
services:
  dev_server:
    name: "Next.js Dev Server"
    command:
      type: shell
      args: ["npm", "run", "dev"]
    working_dir: "~/dev/my-app"
    env:
      PORT: "3000"
    auto_start: false
    restart_policy: transient
    health_check:
      type: http
      url: "http://localhost:3000/api/health"
      interval_ms: 5000
    tags: [dev, frontend]
```

Or in `config/services.d/*.yml` for additional services.

### Runtime Configuration

```elixir
# Define a service
{:ok, definition} = LemonServices.Service.Definition.new(
  id: :my_worker,
  name: "My Worker",
  command: {:shell, "python worker.py"},
  working_dir: "~/workers",
  restart_policy: :permanent,
  persistent: true  # Save to config/services.d/
)

# Register it
:ok = LemonServices.register_definition(definition)

# Start it
{:ok, _pid} = LemonServices.start_service(:my_worker)
```

## Usage

### Basic Operations

```elixir
# Start/stop/restart
{:ok, pid} = LemonServices.start_service(:dev_server)
:ok = LemonServices.stop_service(:dev_server)
{:ok, pid} = LemonServices.restart_service(:dev_server)

# Query status
{:ok, state} = LemonServices.get_service(:dev_server)
:running = LemonServices.service_status(:dev_server)
true = LemonServices.running?(:dev_server)

# List services
services = LemonServices.list_services()
dev_services = LemonServices.list_services_by_tag(:dev)
```

### Log Streaming

```elixir
# Subscribe to logs
:ok = LemonServices.subscribe_to_logs(:dev_server)

# Receive messages
receive do
  {:service_log, :dev_server, %{timestamp: ts, stream: :stdout, data: line}} ->
    IO.puts("[#{ts}] #{line}")
end

# Unsubscribe
:ok = LemonServices.unsubscribe_from_logs(:dev_server)
```

### Event Subscription

```elixir
# Subscribe to all events for a service
:ok = LemonServices.subscribe_to_events(:dev_server)

# Or subscribe globally
:ok = LemonServices.subscribe_to_events(:all)

# Receive events
receive do
  {:service_event, :dev_server, :service_started} ->
    IO.puts("Service started!")
  
  {:service_event, :dev_server, {:service_crashed, code, reason}} ->
    IO.puts("Service crashed with code #{code}")
end
```

## Health Checks

Supported health check types:

```elixir
# HTTP GET
health_check: {:http, "http://localhost:3000/health", 5000}

# TCP connect
health_check: {:tcp, "localhost", 5432, 10000}

# Shell command (exit 0 = healthy)
health_check: {:command, "pgrep postgres", 5000}

# Elixir function
health_check: {:function, MyApp.Health, :check, [], 5000}
```

## Restart Policies

- `:permanent` - Always restart (default for critical services)
- `:transient` - Restart only on abnormal exit (default)
- `:temporary` - Never restart (for one-off tasks)

## Agent Tools

Agents can use these tools to manage services:

- `service_start` - Start a service
- `service_stop` - Stop a service  
- `service_restart` - Restart a service
- `service_status` - Get service status
- `service_logs` - Get service logs
- `service_list` - List all services
- `service_attach` - Subscribe to service logs
- `service_define` - Define a new service

## Testing

```bash
# Run tests
mix test

# Run tests with coverage
mix test --cover
```

## License

MIT
