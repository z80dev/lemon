defmodule CodingAgent.SessionRootSupervisor do
  @moduledoc """
  Per-session supervision tree.

  Each session gets its own `SessionRootSupervisor` that supervises:
  - `CodingAgent.Session` - The main session GenServer
  - Optional `CodingAgent.Coordinator` - For managing subagents

  This provides isolation between sessions - if one session crashes, it doesn't
  affect other sessions. The supervisor uses `:rest_for_one` strategy, meaning
  if the Session crashes, any dependent children (like Coordinator) will also
  be restarted.

  ## Architecture

      SessionSupervisor (DynamicSupervisor)
          |
          +-- SessionRootSupervisor (for session A)
          |       |
          |       +-- Session
          |       +-- (optional) Coordinator
          |
          +-- SessionRootSupervisor (for session B)
                  |
                  +-- Session
                  +-- (optional) Coordinator
  """

  use Supervisor

  @type start_opts :: keyword()

  @doc """
  Starts the SessionRootSupervisor with the given options.

  ## Options

  All options are passed to `CodingAgent.Session.start_link/1`, plus:

  - `:with_coordinator` - If true, also start a `CodingAgent.Coordinator` (default: false)

  ## Examples

      {:ok, pid} = CodingAgent.SessionRootSupervisor.start_link(
        cwd: "/path/to/project",
        model: my_model
      )
  """
  @spec start_link(start_opts()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {with_coordinator, session_opts} = Keyword.pop(opts, :with_coordinator, false)

    # Generate a session_id if not provided, so we can use it for both Session and Coordinator
    session_id = Keyword.get(session_opts, :session_id) || generate_session_id()
    session_opts = Keyword.put(session_opts, :session_id, session_id)

    # Use temporary restart for Session - sessions are short-lived and shouldn't auto-restart
    session_child = %{
      id: CodingAgent.Session,
      start: {CodingAgent.Session, :start_link, [session_opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    children = [session_child]

    # Optionally add Coordinator if requested
    children =
      if with_coordinator do
        cwd = Keyword.fetch!(session_opts, :cwd)
        model = Keyword.fetch!(session_opts, :model)

        coordinator_opts = [
          cwd: cwd,
          model: model,
          parent_session: session_id,
          thinking_level: Keyword.get(session_opts, :thinking_level, :off),
          settings_manager: Keyword.get(session_opts, :settings_manager)
        ]

        # Use temporary restart for Coordinator too
        coordinator_child = %{
          id: CodingAgent.Coordinator,
          start: {CodingAgent.Coordinator, :start_link, [coordinator_opts]},
          restart: :temporary,
          shutdown: 5_000,
          type: :worker
        }

        children ++ [coordinator_child]
      else
        children
      end

    # Use :rest_for_one so if Session crashes, Coordinator (which depends on it) is also terminated
    # Children have :temporary restart so they won't auto-restart on crash
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Gets the Session pid from this supervisor.

  ## Examples

      {:ok, session} = CodingAgent.SessionRootSupervisor.get_session(supervisor)
  """
  @spec get_session(Supervisor.supervisor()) :: {:ok, pid()} | :error
  def get_session(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(:error, fn
      {CodingAgent.Session, pid, :worker, _} when is_pid(pid) -> {:ok, pid}
      _ -> false
    end)
  end

  @doc """
  Gets the Coordinator pid from this supervisor, if one was started.

  ## Examples

      {:ok, coordinator} = CodingAgent.SessionRootSupervisor.get_coordinator(supervisor)
      :error = CodingAgent.SessionRootSupervisor.get_coordinator(supervisor_without_coordinator)
  """
  @spec get_coordinator(Supervisor.supervisor()) :: {:ok, pid()} | :error
  def get_coordinator(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(:error, fn
      {CodingAgent.Coordinator, pid, :worker, _} when is_pid(pid) -> {:ok, pid}
      _ -> false
    end)
  end

  @doc """
  Lists all children of this supervisor.

  Returns a list of `{module, pid}` tuples for alive children.
  """
  @spec list_children(Supervisor.supervisor()) :: [{module(), pid()}]
  def list_children(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {module, pid, _type, _modules} when is_pid(pid) -> [{module, pid}]
      _ -> []
    end)
  end

  # Generate a unique session ID
  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
