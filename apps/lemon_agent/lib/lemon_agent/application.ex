defmodule LemonAgent.Application do
  @moduledoc """
  OTP Application for LemonAgent.

  This application starts the core BEAM infrastructure for agent management:

  - `LemonAgent.AgentRegistry` - Registry for agent process lookup
  - `LemonAgent.SubagentSupervisor` - DynamicSupervisor for subagent processes
  - `LemonAgent.LoopTaskSupervisor` - Task.Supervisor for agent loop tasks
  - `LemonAgent.ToolTaskSupervisor` - Task.Supervisor for tool execution tasks
  - `LemonAgent.ModelRuntime.ProviderPoolRotator` - Round-robin state for provider credential pools
  - `LemonAgent.ModelRuntime.CredentialHealth` - Cooldown state for individual provider credentials
  - `LemonAgent.ModelRuntime.SessionPins` - Per-session pinning of committed fallback candidates

  ## Supervision Tree

  ```
  LemonAgent.Supervisor (:one_for_one)
  ├── LemonAgent.AgentRegistry (Registry)
  ├── LemonAgent.SubagentSupervisor (DynamicSupervisor)
  ├── LemonAgent.LoopTaskSupervisor (Task.Supervisor)
  ├── LemonAgent.ToolTaskSupervisor (Task.Supervisor)
  ├── LemonAgent.ModelRuntime.ProviderPoolRotator (GenServer)
  ├── LemonAgent.ModelRuntime.CredentialHealth (GenServer, owns ETS table)
  └── LemonAgent.ModelRuntime.SessionPins (GenServer, owns ETS table)
  ```
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Owns the abort-signal ETS table so it doesn't get created by short-lived processes.
      LemonAgent.AbortSignal.TableOwner,
      # Registry for agent process lookup and discovery
      {Registry, keys: :unique, name: LemonAgent.AgentRegistry},
      # DynamicSupervisor for subagent processes
      {LemonAgent.SubagentSupervisor, name: LemonAgent.SubagentSupervisor},
      # Task.Supervisor for agent loop tasks
      {Task.Supervisor, name: LemonAgent.LoopTaskSupervisor},
      # Task.Supervisor for tool execution tasks
      {Task.Supervisor, name: LemonAgent.ToolTaskSupervisor},
      # Round-robin rotation state for provider credential pools
      LemonAgent.ModelRuntime.ProviderPoolRotator,
      # Owns the credential cooldown ETS table
      LemonAgent.ModelRuntime.CredentialHealth,
      # Owns the per-session fallback pin ETS table
      LemonAgent.ModelRuntime.SessionPins
    ]

    opts = [strategy: :one_for_one, name: LemonAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
