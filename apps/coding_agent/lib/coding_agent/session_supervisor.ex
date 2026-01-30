defmodule CodingAgent.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for managing agent session processes.

  This supervisor is responsible for:
  - Starting and stopping session processes
  - Monitoring session health
  - Providing session lookup functionality
  - Managing session lifecycle

  ## Usage

      # Start a new session
      {:ok, pid} = CodingAgent.SessionSupervisor.start_session(session_id: "my-session")

      # Stop a session
      :ok = CodingAgent.SessionSupervisor.stop_session(pid)

      # List all active sessions
      pids = CodingAgent.SessionSupervisor.list_sessions()

      # Check health of all sessions
      health = CodingAgent.SessionSupervisor.health_all()

  ## Supervision Strategy

  Uses `:one_for_one` strategy with `:temporary` restart. Sessions that
  crash are not automatically restarted - the session supervisor relies
  on the session registry for recovery.
  """

  use DynamicSupervisor

  @type start_opts :: keyword()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(start_opts()) :: DynamicSupervisor.on_start_child()
  def start_session(opts) do
    opts = Keyword.put_new(opts, :register, true)
    child_id = Keyword.get(opts, :session_id) || make_ref()

    child_spec = %{
      id: {CodingAgent.Session, child_id},
      start: {CodingAgent.Session, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec stop_session(pid() | String.t()) :: :ok | {:error, term()}
  def stop_session(session) when is_pid(session) do
    DynamicSupervisor.terminate_child(__MODULE__, session)
  end

  def stop_session(session_id) when is_binary(session_id) do
    case CodingAgent.SessionRegistry.lookup(session_id) do
      {:ok, pid} -> stop_session(pid)
      :error -> {:error, :not_found}
    end
  end

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(session_id) when is_binary(session_id) do
    CodingAgent.SessionRegistry.lookup(session_id)
  end

  @spec list_sessions() :: [pid()]
  def list_sessions do
    if Process.whereis(__MODULE__) do
      DynamicSupervisor.which_children(__MODULE__)
      |> Enum.flat_map(fn
        {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
        _ -> []
      end)
    else
      []
    end
  end

  @doc """
  Check the health status of all supervised sessions.

  Returns a list of health check results for each session, sorted by status
  (unhealthy first, then degraded, then healthy).
  """
  @spec health_all() :: [map()]
  def health_all do
    list_sessions()
    |> Enum.map(fn pid ->
      try do
        CodingAgent.Session.health_check(pid)
      catch
        :exit, _ -> %{status: :unhealthy, session_id: nil, error: :process_exited}
      end
    end)
    |> Enum.sort_by(fn result ->
      case result.status do
        :unhealthy -> 0
        :degraded -> 1
        :healthy -> 2
      end
    end)
  end

  @doc """
  Get a summary of session health across all supervised sessions.

  Returns a map with counts for each status and an overall status.
  The overall status is:
  - `:unhealthy` if any session is unhealthy
  - `:degraded` if any session is degraded
  - `:healthy` if all sessions are healthy
  - `:no_sessions` if there are no active sessions
  """
  @spec health_summary() :: map()
  def health_summary do
    health_results = health_all()

    healthy_count = Enum.count(health_results, &(&1.status == :healthy))
    degraded_count = Enum.count(health_results, &(&1.status == :degraded))
    unhealthy_count = Enum.count(health_results, &(&1.status == :unhealthy))
    total = length(health_results)

    overall =
      cond do
        total == 0 -> :no_sessions
        unhealthy_count > 0 -> :unhealthy
        degraded_count > 0 -> :degraded
        true -> :healthy
      end

    %{
      total: total,
      healthy: healthy_count,
      degraded: degraded_count,
      unhealthy: unhealthy_count,
      overall: overall
    }
  end
end
