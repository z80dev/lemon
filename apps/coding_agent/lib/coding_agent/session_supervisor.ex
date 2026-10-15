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

  ## Scoped session trees

  Lifecycle and health functions accept scope options as their final argument:
  `:supervisor` selects a DynamicSupervisor name or PID, and `:registry` selects
  a unique Registry name. Omitted targets retain the application's defaults.
  Use the same scope for admission, lookup, termination and health queries:

      scope = [supervisor: MySessionSupervisor, registry: MySessionRegistry]
      {:ok, pid} = CodingAgent.SessionSupervisor.start_session(session_opts, scope)
      :ok = CodingAgent.SessionSupervisor.stop_session(pid, scope)

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

  @doc "Start a session, optionally targeting a scoped supervisor and registry."
  @spec start_session(start_opts(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts, scope \\ []) do
    opts =
      opts
      |> Keyword.put_new(:register, true)
      |> Keyword.put_new(:registry, Keyword.get(scope, :registry, CodingAgent.SessionRegistry))

    child_id = Keyword.get(opts, :session_id) || make_ref()

    child_spec = %{
      id: {CodingAgent.Session, child_id},
      start: {CodingAgent.Session, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor(scope), child_spec)
  end

  @spec stop_session(pid() | String.t(), keyword()) :: :ok | {:error, term()}
  def stop_session(session, scope \\ [])

  def stop_session(session, scope) when is_pid(session) do
    DynamicSupervisor.terminate_child(supervisor(scope), session)
  end

  def stop_session(session_id, scope) when is_binary(session_id) do
    case lookup(session_id, scope) do
      {:ok, pid} -> stop_session(pid, scope)
      :error -> {:error, :not_found}
    end
  end

  @spec lookup(String.t(), keyword()) :: {:ok, pid()} | :error
  def lookup(session_id, scope \\ []) when is_binary(session_id) do
    registry = Keyword.get(scope, :registry, CodingAgent.SessionRegistry)

    CodingAgent.SessionRegistry.lookup(session_id, registry)
  end

  @spec list_sessions(keyword()) :: [pid()]
  def list_sessions(scope \\ []) do
    supervisor = supervisor(scope)

    if GenServer.whereis(supervisor) do
      DynamicSupervisor.which_children(supervisor)
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
  @spec health_all(keyword()) :: [map()]
  def health_all(scope \\ []) do
    list_sessions(scope)
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
  @spec health_summary(keyword()) :: map()
  def health_summary(scope \\ []) do
    health_results = health_all(scope)

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

  defp supervisor(scope), do: Keyword.get(scope, :supervisor, __MODULE__)
end
