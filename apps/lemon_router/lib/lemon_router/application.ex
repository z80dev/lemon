defmodule LemonRouter.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Agent profiles configuration
      LemonRouter.AgentProfiles,
      # Run orchestrator
      LemonRouter.RunOrchestrator,
      # Run supervisor (DynamicSupervisor for run processes)
      {DynamicSupervisor, strategy: :one_for_one, name: LemonRouter.RunSupervisor},
      # Stream coalescer supervisor
      {DynamicSupervisor, strategy: :one_for_one, name: LemonRouter.CoalescerSupervisor},
      # Registries
      {Registry, keys: :unique, name: LemonRouter.RunRegistry},
      {Registry, keys: :unique, name: LemonRouter.SessionRegistry},
      # Coalescer registry - required for StreamCoalescer to work
      {Registry, keys: :unique, name: LemonRouter.CoalescerRegistry}
    ]

    opts = [strategy: :one_for_one, name: LemonRouter.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
