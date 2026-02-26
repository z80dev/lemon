defmodule AgentCore.Application do
  @moduledoc """
  OTP Application for AgentCore.

  This application starts the core BEAM infrastructure for agent management:

  - `AgentCore.AgentRegistry` - Registry for agent process lookup
  - `AgentCore.SubagentSupervisor` - DynamicSupervisor for subagent processes
  - `AgentCore.LoopTaskSupervisor` - Task.Supervisor for agent loop tasks
  - `AgentCore.ToolTaskSupervisor` - Task.Supervisor for tool execution tasks

  ## Supervision Tree

  ```
  AgentCore.Supervisor (:one_for_one)
  ├── AgentCore.AgentRegistry (Registry)
  ├── AgentCore.SubagentSupervisor (DynamicSupervisor)
  ├── AgentCore.LoopTaskSupervisor (Task.Supervisor)
  └── AgentCore.ToolTaskSupervisor (Task.Supervisor)
  ```
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Owns the abort-signal ETS table so it doesn't get created by short-lived processes.
      AgentCore.AbortSignal.TableOwner,
      # Registry for agent process lookup and discovery
      {Registry, keys: :unique, name: AgentCore.AgentRegistry},
      # DynamicSupervisor for subagent processes
      {AgentCore.SubagentSupervisor, name: AgentCore.SubagentSupervisor},
      # Task.Supervisor for agent loop tasks
      {Task.Supervisor, name: AgentCore.LoopTaskSupervisor},
      # Task.Supervisor for tool execution tasks
      {Task.Supervisor, name: AgentCore.ToolTaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: AgentCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
