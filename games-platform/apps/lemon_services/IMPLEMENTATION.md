# LemonServices Implementation Summary

## Overview

LemonServices is a complete OTP application for long-running service management in Lemon. It provides a service-oriented architecture for managing processes that outlive individual agent sessions.

## Architecture

### Supervision Tree

```
LemonServices.Application (Supervisor)
├── Registry (keys: :unique, name: LemonServices.Registry)
├── Phoenix.PubSub (name: LemonServices.PubSub)
├── DynamicSupervisor (name: LemonServices.Runtime.Supervisor)
└── LemonServices.Supervisor
    ├── LogBuffer.TableOwner (ETS table owner)
    ├── Service.Store (ETS-based definition storage)
    └── Config.Loader (boot-time config loader)
```

### Per-Service Supervision Tree

When a service is started, a new supervisor is added under the DynamicSupervisor:

```
Runtime.Supervisor (for service :dev_server)
├── LogBuffer (circular log buffer)
├── PortManager (OS process management)
├── HealthChecker (periodic health checks) - optional
└── Server (main coordinator GenServer)
```

## Key Modules

### Core API

- **`LemonServices`** - Public API facade
- **`LemonServices.Application`** - OTP application
- **`LemonServices.Supervisor`** - Top-level supervisor

### Service Definition

- **`LemonServices.Service.Definition`** - Service struct and validation
- **`LemonServices.Service.State`** - Runtime state tracking
- **`LemonServices.Service.Store`** - ETS-backed definition storage

### Runtime

- **`LemonServices.Runtime.Supervisor`** - Per-service supervisor
- **`LemonServices.Runtime.Server`** - Main service coordinator
- **`LemonServices.Runtime.PortManager`** - OS process lifecycle
- **`LemonServices.Runtime.HealthChecker`** - Health check scheduling
- **`LemonServices.Runtime.LogBuffer`** - Circular log buffer

### Configuration

- **`LemonServices.Config`** - YAML configuration loading
- **`LemonServices.Config.Loader`** - Boot-time loader

### Agent Integration

- **`LemonServices.Agent.Tools`** - Agent tool definitions

## Features

### Service Lifecycle

- **Start/Stop/Restart**: Full lifecycle management
- **Restart Policies**: `:permanent`, `:transient`, `:temporary`
- **Health Checks**: HTTP, TCP, command, or Elixir function
- **Log Streaming**: PubSub-based log streaming
- **Event Broadcasting**: Service events via PubSub

### Configuration

- **Static Config**: `config/services.yml` and `config/services.d/*.yml`
- **Runtime Config**: Programmatic service definition
- **Persistence**: Save runtime definitions to disk

### Health Checks

```elixir
# HTTP GET
{:http, "http://localhost:3000/health", 5000}

# TCP connect
{:tcp, "localhost", 5432, 10000}

# Shell command
{:command, "pgrep postgres", 5000}

# Elixir function
{:function, MyApp.Health, :check, [], 5000}
```

### Commands

```elixir
# Shell command (string)
{:shell, "npm run dev"}

# Shell command (args)
{:shell, ["npm", "run", "dev"]}

# Elixir module
{:module, MyApp.Worker, :start_link, [[port: 8080]]}
```

## Agent Tools

- `service_start` - Start a service
- `service_stop` - Stop a service
- `service_restart` - Restart a service
- `service_status` - Get service status
- `service_logs` - Get service logs
- `service_list` - List all services
- `service_attach` - Subscribe to service logs
- `service_define` - Define a new service

## Example Usage

```elixir
# Define a service
{:ok, definition} = LemonServices.Service.Definition.new(
  id: :dev_server,
  name: "Next.js Dev Server",
  command: {:shell, "npm run dev"},
  working_dir: "~/my-app",
  env: %{"PORT" => "3000"},
  auto_start: false,
  restart_policy: :transient,
  health_check: {:http, "http://localhost:3000/api/health", 5000},
  tags: [:dev, :frontend]
)

# Register and start
:ok = LemonServices.register_definition(definition)
{:ok, _pid} = LemonServices.start_service(:dev_server)

# Query status
{:ok, state} = LemonServices.get_service(:dev_server)
LemonServices.running?(:dev_server)

# Stream logs
:ok = LemonServices.subscribe_to_logs(:dev_server)

# Receive events
:ok = LemonServices.subscribe_to_events(:dev_server)

# Stop
:ok = LemonServices.stop_service(:dev_server)
```

## Configuration File Example

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

## Registry Keys

The Registry uses the following key patterns:

- `{:service_supervisor, service_id}` - Service supervisor
- `{:server, service_id}` - Service server GenServer
- `{:port_manager, service_id}` - Port manager
- `{:health_checker, service_id}` - Health checker
- `{:log_buffer, service_id}` - Log buffer

## PubSub Topics

- `"service:#{service_id}"` - Service-specific events
- `"service:#{service_id}:logs"` - Service log stream
- `"services:all"` - All service events

## Testing

Run tests:

```bash
cd apps/lemon_services
mix test
```

## Integration

The application is automatically picked up by the umbrella. No additional configuration needed in `mix.exs`.

## Future Enhancements

- Service dependencies (start order)
- Service groups (start/stop multiple)
- Resource limits (CPU, memory)
- Metrics collection
- Web dashboard
