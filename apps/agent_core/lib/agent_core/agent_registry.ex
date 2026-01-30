defmodule AgentCore.AgentRegistry do
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
      AgentCore.AgentRegistry.register({session_id, :research, 0})

      # Look up an agent
      {:ok, pid} = AgentCore.AgentRegistry.lookup({session_id, :research, 0})

      # List all agents for a session
      agents = AgentCore.AgentRegistry.list_by_session(session_id)
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
  Look up a process and its metadata by key.

  Returns `{:ok, pid, metadata}` if found, or `:error` if not registered.

  ## Examples

      {:ok, pid, %{model: "claude-3"}} = AgentRegistry.lookup_with_metadata({session_id, :research, 0})
  """
  @spec lookup_with_metadata(key()) :: {:ok, pid(), term()} | :error
  def lookup_with_metadata(key) do
    case Registry.lookup(@registry_name, key) do
      [{pid, metadata}] -> {:ok, pid, metadata}
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
  List all agents for a specific session.

  Returns a list of `{role, index, pid}` tuples for all agents
  belonging to the given session.

  ## Examples

      [{:main, 0, pid1}, {:research, 0, pid2}] = AgentRegistry.list_by_session(session_id)
  """
  @spec list_by_session(String.t()) :: [{atom(), non_neg_integer(), pid()}]
  def list_by_session(session_id) do
    # Use match spec to find all entries where the first element of the key matches session_id
    Registry.select(@registry_name, [
      {{{session_id, :"$1", :"$2"}, :"$3", :_}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  @doc """
  List all agents with a specific role across all sessions.

  Returns a list of `{session_id, index, pid}` tuples.

  ## Examples

      [{session1, 0, pid1}, {session2, 0, pid2}] = AgentRegistry.list_by_role(:research)
  """
  @spec list_by_role(atom()) :: [{String.t(), non_neg_integer(), pid()}]
  def list_by_role(role) do
    Registry.select(@registry_name, [
      {{{:"$1", role, :"$2"}, :"$3", :_}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  @doc """
  Count the number of registered agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    Registry.count(@registry_name)
  end

  @doc """
  Count agents for a specific session.
  """
  @spec count_by_session(String.t()) :: non_neg_integer()
  def count_by_session(session_id) do
    session_id
    |> list_by_session()
    |> length()
  end
end
