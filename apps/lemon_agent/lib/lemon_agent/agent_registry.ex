defmodule LemonAgent.AgentRegistry do
  @moduledoc """
  Registry for agent process lookup and discovery.

  This module provides a wrapper around Elixir's Registry for tracking
  agent processes. Agents are registered with structured keys for
  easy lookup and enumeration.

  ## Key Format

  Keys are tuples of the form `{session_id, role, index}` where:
  - `session_id` - The parent session ID
  - `role` - The agent role (e.g., :main, :research, :implement)
  - `index` - An index for multiple agents of the same role (0-based)

  ## Examples

      # Register an agent
      LemonAgent.AgentRegistry.register({session_id, :research, 0})

      # Look up an agent
      {:ok, pid} = LemonAgent.AgentRegistry.lookup({session_id, :research, 0})

      # List all agents
      agents = LemonAgent.AgentRegistry.list()
  """

  @registry_name __MODULE__

  @type key :: {session_id :: String.t(), role :: atom(), index :: non_neg_integer()}

  @doc """
  Get the registry name for use in via tuples.
  """
  @spec registry_name() :: atom()
  def registry_name, do: @registry_name

  @doc """
  Returns a via tuple for registering a process with this registry.

  ## Examples

      GenServer.start_link(MyAgent, args, name: AgentRegistry.via({session_id, :main, 0}))
  """
  @spec via(key()) :: {:via, Registry, {atom(), key()}}
  def via(key) do
    {:via, Registry, {@registry_name, key}}
  end

  @doc """
  Register the current process with the given key.

  Returns `:ok` on success or `{:error, {:already_registered, pid}}` if
  another process is already registered with this key.

  ## Examples

      :ok = AgentRegistry.register({session_id, :research, 0})
  """
  @spec register(key()) :: :ok | {:error, {:already_registered, pid()}}
  def register(key) do
    case Registry.register(@registry_name, key, nil) do
      {:ok, _} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:already_registered, pid}}
    end
  end

  @doc """
  Register the current process with the given key and metadata.

  The metadata can be any term and is stored alongside the registration.

  ## Examples

      :ok = AgentRegistry.register({session_id, :research, 0}, %{model: "claude-3"})
  """
  @spec register(key(), term()) :: :ok | {:error, {:already_registered, pid()}}
  def register(key, metadata) do
    case Registry.register(@registry_name, key, metadata) do
      {:ok, _} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:already_registered, pid}}
    end
  end

  @doc """
  Unregister the current process from the given key.

  ## Examples

      :ok = AgentRegistry.unregister({session_id, :research, 0})
  """
  @spec unregister(key()) :: :ok
  def unregister(key) do
    Registry.unregister(@registry_name, key)
  end

  @doc """
  Look up a process by its key.

  Returns `{:ok, pid}` if found, or `:error` if not registered.

  ## Examples

      {:ok, pid} = AgentRegistry.lookup({session_id, :research, 0})
  """
  @spec lookup(key()) :: {:ok, pid()} | :error
  def lookup(key) do
    case Registry.lookup(@registry_name, key) do
      [{pid, _metadata}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  List all registered keys and their PIDs.

  ## Examples

      [{{session_id, :main, 0}, pid1}, {{session_id, :research, 0}, pid2}] = AgentRegistry.list()
  """
  @spec list() :: [{key(), pid()}]
  def list do
    Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Count the number of registered agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    Registry.count(@registry_name)
  end
end
