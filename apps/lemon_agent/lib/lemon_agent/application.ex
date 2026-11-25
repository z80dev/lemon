defmodule LemonAgent.Application do
  @moduledoc """
  OTP Application for LemonAgent.

  This application starts the core BEAM infrastructure for agent management:

  - `LemonAgent.AgentRegistry` - Registry for agent process lookup
  - `LemonAgent.AbortSignal.Registry` - Process-owned cancellation subscriptions
  - `LemonAgent.LoopTaskSupervisor` - Task.Supervisor for agent loop tasks
  - `LemonAgent.ToolTaskSupervisor` - Task.Supervisor for tool execution tasks
  - `LemonAgent.ModelRuntime.ProviderPoolRotator` - Round-robin state for provider credential pools
  - `LemonAgent.ModelRuntime.CredentialHealth` - Cooldown state for individual provider credentials
  - `LemonAgent.ModelRuntime.SessionPins` - Per-session pinning of committed fallback candidates
  - `LemonAgent.ModelRuntime.OmpAuthBroker` - omp auth broker snapshot cache and watcher owner

  Startup also points `:lemon_ai, :kimi_device_id` at the persisted Kimi Code
  device id (`LemonAgent.ModelRuntime.AmbientCredentials.kimi_device_id/1`)
  unless one is configured.

  ## Supervision Tree

  ```
  LemonAgent.Supervisor (:one_for_one)
  ├── LemonAgent.AgentRegistry (Registry)
  ├── LemonAgent.AbortSignal.Registry (duplicate Registry)
  ├── LemonAgent.LoopTaskSupervisor (Task.Supervisor)
  ├── LemonAgent.ToolTaskSupervisor (Task.Supervisor)
  ├── LemonAgent.ModelRuntime.ProviderPoolRotator (GenServer)
  ├── LemonAgent.ModelRuntime.CredentialHealth (GenServer, owns ETS table)
  ├── LemonAgent.ModelRuntime.SessionPins (GenServer, owns ETS table)
  └── LemonAgent.ModelRuntime.OmpAuthBroker (GenServer, owns ETS table and watchers)
  ```
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Fence keys exist before any worker can wrap or check untrusted content.
    :ok = LemonAgent.Security.ExternalContent.init_key()
    :ok = LemonAgent.Security.UntrustedToolBoundary.init_key()

    # lemon_ai sends this id in the Kimi CLI fingerprint; the file under the
    # user's home is Lemon deployment state, so the runtime owns it. lemon_ai
    # evaluates the MFA when it first builds the fingerprint. An explicitly
    # configured id is kept.
    unless Application.get_env(:lemon_ai, :kimi_device_id) do
      Application.put_env(
        :lemon_ai,
        :kimi_device_id,
        {LemonAgent.ModelRuntime.AmbientCredentials, :kimi_device_id, []}
      )
    end

    children = [
      # Signal levels live in atomics; Registry owns only live subscriptions.
      {Registry, keys: :duplicate, name: LemonAgent.AbortSignal.Registry},
      # Registry for agent process lookup and discovery
      {Registry, keys: :unique, name: LemonAgent.AgentRegistry},
      # Task.Supervisor for agent loop tasks
      {LemonCore.TaskSupervisor, name: LemonAgent.LoopTaskSupervisor},
      # Task.Supervisor for tool execution tasks
      {LemonCore.TaskSupervisor, name: LemonAgent.ToolTaskSupervisor},
      # Round-robin rotation state for provider credential pools
      LemonAgent.ModelRuntime.ProviderPoolRotator,
      # Owns the credential cooldown ETS table
      LemonAgent.ModelRuntime.CredentialHealth,
      # Owns the per-session fallback pin ETS table
      LemonAgent.ModelRuntime.SessionPins,
      # omp auth broker snapshot cache (ETS-backed) and its long-poll watchers
      LemonAgent.ModelRuntime.OmpAuthBroker
    ]

    children =
      children ++
        LemonAgent.GenAISpans.children(Application.get_env(:lemon_agent, :gen_ai_spans, []))

    opts = [strategy: :one_for_one, name: LemonAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
