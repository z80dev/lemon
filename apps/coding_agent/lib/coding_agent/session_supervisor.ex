defmodule CodingAgent.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for managing agent session processes.

  This supervisor is responsible for:
  - Starting and stopping session processes
  - Providing session lookup functionality
  - Managing session lifecycle

  ## Usage

      # Start a new session
      {:ok, pid} = CodingAgent.SessionSupervisor.start_session(session_id: "my-session")

      # Stop a session
      :ok = CodingAgent.SessionSupervisor.stop_session(pid)

      # List all active sessions
      pids = CodingAgent.SessionSupervisor.list_sessions()

  ## Supervision Strategy

  Uses `:one_for_one` strategy with `:temporary` restart. Sessions that
  crash are not automatically restarted - the session supervisor relies
  on the session registry for recovery.

  The supervisor only runs journal ownership admission. `start_session/1`
  validates (and preloads the journal) in the caller and waits there for the
  session's deferred initialization, so a slow start (for example a profile
  MCP connection) never delays other starts, stops or `list_sessions/0`.
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

  @typedoc """
  Target options shared by every function:

    * `:supervisor` - the session supervisor (name or pid; default: `#{inspect(__MODULE__)}`)
    * `:registry` - the registry sessions register in (default: `CodingAgent.SessionRegistry`);
      `start_session/1` passes it to the session
  """
  @type target_opts :: [supervisor: Supervisor.supervisor(), registry: atom()]

  @doc """
  Start a session under the supervisor named by `:supervisor` (default: the
  application's). All other options are session options (see `CodingAgent.Session`).
  """
  @spec start_session(start_opts()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    {supervisor, opts} = Keyword.pop(opts, :supervisor, __MODULE__)
    opts = Keyword.put_new(opts, :register, true)
    child_id = Keyword.get(opts, :session_id) || make_ref()
    ref = make_ref()

    with {:ok, opts} <- CodingAgent.Session.validate_execution_options(opts) do
      child_spec = %{
        id: {CodingAgent.Session, child_id},
        start: {CodingAgent.Session, :start_owner, [opts, {self(), ref}]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      case DynamicSupervisor.start_child(supervisor, child_spec) do
        {:ok, pid} -> CodingAgent.Session.await_initialized(pid, ref)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Stop a session by pid or session id. An unknown session returns `{:error, :not_found}`."
  @spec stop_session(pid() | String.t(), target_opts()) :: :ok | {:error, term()}
  def stop_session(session, opts \\ [])

  def stop_session(session, opts) when is_pid(session) do
    DynamicSupervisor.terminate_child(Keyword.get(opts, :supervisor, __MODULE__), session)
  end

  def stop_session(session_id, opts) when is_binary(session_id) do
    case lookup(session_id, opts) do
      {:ok, pid} -> stop_session(pid, opts)
      :error -> {:error, :not_found}
    end
  end

  @spec lookup(String.t(), target_opts()) :: {:ok, pid()} | :error
  def lookup(session_id, opts \\ []) when is_binary(session_id) do
    registry = Keyword.get(opts, :registry, CodingAgent.SessionRegistry)
    CodingAgent.SessionRegistry.lookup(session_id, registry)
  end

  @spec list_sessions(target_opts()) :: [pid()]
  def list_sessions(opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

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
end
