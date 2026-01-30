defmodule AgentCore.SubagentSupervisor do
  @moduledoc """
  Dynamic supervisor for managing subagent processes.

  This module provides a DynamicSupervisor for starting and managing
  subagent processes. Subagents are started as temporary children
  (no automatic restart on failure) since they are typically short-lived
  task-oriented processes.

  ## Usage

      # Start a subagent with AgentCore.Agent options
      {:ok, pid} = SubagentSupervisor.start_subagent(
        model: model,
        tools: tools,
        system_prompt: "You are a research agent..."
      )

      # Stop a subagent
      :ok = SubagentSupervisor.stop_subagent(pid)

      # List all subagents
      pids = SubagentSupervisor.list_subagents()
  """

  use DynamicSupervisor

  @supervisor_name __MODULE__

  @doc """
  Start the subagent supervisor.

  This is typically called by the application supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @supervisor_name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new subagent under the supervisor.

  The subagent is started as a temporary child (not restarted on failure).
  Options are passed directly to `AgentCore.Agent.start_link/1`.

  ## Options

  All options supported by `AgentCore.Agent.start_link/1`:
  - `:model` - The AI model to use
  - `:tools` - List of available tools
  - `:system_prompt` - The system prompt
  - `:messages` - Initial messages
  - etc.

  Additional options:
  - `:registry_key` - Optional `{session_id, role, index}` key for registration

  ## Examples

      {:ok, pid} = SubagentSupervisor.start_subagent(
        model: model,
        tools: tools,
        system_prompt: "You are a research agent..."
      )
  """
  @spec start_subagent(keyword()) :: DynamicSupervisor.on_start_child()
  def start_subagent(opts) do
    {registry_key, agent_opts} = Keyword.pop(opts, :registry_key)
    {name, agent_opts} = Keyword.pop(agent_opts, :name)

    agent_opts =
      cond do
        registry_key != nil ->
          Keyword.put(agent_opts, :name, AgentCore.AgentRegistry.via(registry_key))

        name != nil ->
          Keyword.put(agent_opts, :name, name)

        true ->
          agent_opts
      end

    child_spec = %{
      id: make_ref(),
      start: {AgentCore.Agent, :start_link, [agent_opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
      {:ok, pid} = result ->
        :telemetry.execute(
          [:agent_core, :subagent, :spawn],
          %{system_time: System.system_time()},
          %{
            pid: pid,
            registry_key: registry_key,
            has_registry_key: registry_key != nil
          }
        )

        result

      error ->
        error
    end
  end

  @doc """
  Start a subagent with a specific child spec.

  This allows more control over the child specification.

  ## Examples

      child_spec = %{
        id: :my_subagent,
        start: {AgentCore.Agent, :start_link, [opts]},
        restart: :temporary
      }
      {:ok, pid} = SubagentSupervisor.start_child(child_spec)
  """
  @spec start_child(Supervisor.child_spec() | {module(), term()} | module()) ::
          DynamicSupervisor.on_start_child()
  def start_child(child_spec) do
    DynamicSupervisor.start_child(@supervisor_name, child_spec)
  end

  @doc """
  Stop a subagent by PID.

  Returns `:ok` on success or `{:error, :not_found}` if the process
  is not a child of this supervisor.

  ## Examples

      :ok = SubagentSupervisor.stop_subagent(pid)
  """
  @spec stop_subagent(pid()) :: :ok | {:error, :not_found}
  def stop_subagent(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(@supervisor_name, pid) do
      :ok ->
        :telemetry.execute(
          [:agent_core, :subagent, :end],
          %{system_time: System.system_time()},
          %{pid: pid, reason: :stopped}
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Stop a subagent by its registry key.

  ## Examples

      :ok = SubagentSupervisor.stop_subagent_by_key({session_id, :research, 0})
  """
  @spec stop_subagent_by_key(AgentCore.AgentRegistry.key()) :: :ok | {:error, :not_found}
  def stop_subagent_by_key(key) do
    case AgentCore.AgentRegistry.lookup(key) do
      {:ok, pid} -> stop_subagent(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  List all subagent PIDs under this supervisor.

  ## Examples

      pids = SubagentSupervisor.list_subagents()
  """
  @spec list_subagents() :: [pid()]
  def list_subagents do
    @supervisor_name
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @doc """
  Count the number of active subagents.
  """
  @spec count() :: non_neg_integer()
  def count do
    DynamicSupervisor.count_children(@supervisor_name).active
  end

  @doc """
  Stop all subagents.

  This terminates all children of the supervisor.

  ## Examples

      :ok = SubagentSupervisor.stop_all()
  """
  @spec stop_all() :: :ok
  def stop_all do
    for pid <- list_subagents() do
      stop_subagent(pid)
    end

    :ok
  end
end
