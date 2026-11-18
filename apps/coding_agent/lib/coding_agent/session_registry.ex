defmodule CodingAgent.SessionRegistry do
  @moduledoc """
  Registry for agent session process discovery.

  This module provides a Registry-based lookup mechanism for finding
  session processes by their session ID. It enables:

  - Looking up session PIDs by session ID
  - Listing all registered session IDs
  - Via-tuple naming for GenServer registration

  ## Usage

      # Lookup a session PID
      {:ok, pid} = CodingAgent.SessionRegistry.lookup("session-123")

      # List all session IDs
      ids = CodingAgent.SessionRegistry.list_ids()

      # Use via-tuple for GenServer naming
      name = CodingAgent.SessionRegistry.via("session-123")
      GenServer.call(name, :some_message)

  ## Registry

  Uses the standard Elixir `Registry` module with unique keys,
  ensuring each session ID maps to exactly one process.
  """

  @registry __MODULE__

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {@registry, session_id}}
  end

  @doc "Look up a session in the application's registry."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(session_id) when is_binary(session_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, session_id) do
        [{pid, _value}] -> {:ok, pid}
        [] -> :error
      end
    else
      :error
    end
  end

  @spec list_ids() :: [String.t()]
  def list_ids do
    if Process.whereis(@registry) do
      Registry.select(@registry, [{{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}])
    else
      []
    end
  end

  @doc """
  Track the calling session process as live, named or not, so a runtime-wide
  fail-stop can reach every session. The entry disappears when it exits.
  """
  @spec track_live() :: :ok
  def track_live do
    if Process.whereis(@registry), do: Registry.register(@registry, {:live, self()}, nil)
    :ok
  end

  @doc "Pids of every live session process, named or not."
  @spec live_pids() :: [pid()]
  def live_pids do
    if Process.whereis(@registry) do
      Registry.select(@registry, [{{{:live, :"$1"}, :_, :_}, [], [:"$1"]}])
    else
      []
    end
  end
end
