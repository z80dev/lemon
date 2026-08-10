defmodule LemonRouter do
  @moduledoc """
  LemonRouter provides orchestration and routing for agent runs.

  This app is responsible for:

  - Session key management and parsing
  - Run orchestration and lifecycle
  - Stream coalescing for efficient channel output
  - Policy merging for tool execution
  - Abort handling and run cancellation
  - Bridging between channels and gateway

  ## Session Keys

  Session keys provide a stable identifier for routing and state:

  - Main: `agent:<agent_id>:main`
  - Channel: `agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>]`

  ## Architecture

  ```
  [Channels] -> [Router] -> [Gateway] -> [Engine]
       ^          |
       |          v
       +--- [StreamCoalescer]
  ```
  """

  alias LemonCore.RunRequest

  @doc """
  Submit a run request to the router.

  Accepts either a normalized `%LemonCore.RunRequest{}` or a legacy map/keyword
  payload that can be normalized into one.
  """
  @spec submit(RunRequest.t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def submit(%RunRequest{} = params), do: LemonRouter.RunOrchestrator.submit(params)

  def submit(params) when is_map(params) or is_list(params) do
    params
    |> RunRequest.new()
    |> LemonRouter.RunOrchestrator.submit()
  end

  @doc """
  Abort a session's active run.
  """
  defdelegate abort(session_key, reason \\ :user_requested), to: LemonRouter.Router

  @doc """
  Abort a specific run by ID.
  """
  defdelegate abort_run(run_id, reason \\ :user_requested), to: LemonRouter.Router

  @doc """
  Apply a watchdog keepalive decision to a specific run.
  """
  defdelegate keep_run_alive(run_id, decision \\ :continue), to: LemonRouter.Router

  # -- Run introspection ------------------------------------------------------
  #
  # Callers outside this app used to reach into `RunRegistry`, `RunSupervisor`
  # and `RunOrchestrator` directly (Registry selects, DynamicSupervisor counts,
  # `Process.whereis` liveness probes). These functions are that surface, and
  # they own the defensiveness those call sites each reimplemented: a router
  # that is not running reports "nothing active" rather than raising.

  @typedoc "A run currently being orchestrated."
  @type active_run :: %{
          run_id: binary(),
          session_key: binary() | nil,
          agent_id: binary() | nil,
          engine: binary() | nil,
          started_at_ms: integer() | nil
        }

  @metadata_timeout_ms 1_000
  @zero_counts %{active: 0, queued: 0, completed_today: 0}

  @doc """
  Whether the router runtime is up and able to accept work.

  Use this instead of probing for a router process by name.
  """
  @spec available?() :: boolean()
  def available? do
    is_pid(Process.whereis(LemonRouter.RunOrchestrator)) and
      is_pid(Process.whereis(LemonRouter.RunRegistry))
  end

  @doc """
  Every run currently active, newest first is not guaranteed — callers that
  care about ordering should sort on `:started_at_ms`.

  Returns `[]` when the router is not running.
  """
  @spec active_runs() :: [active_run()]
  def active_runs do
    if is_pid(Process.whereis(LemonRouter.RunRegistry)) do
      LemonRouter.RunRegistry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(&describe_active_run/1)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Whether `run_id` is currently active.
  """
  @spec run_active?(binary()) :: boolean()
  def run_active?(run_id) when is_binary(run_id) do
    is_pid(Process.whereis(LemonRouter.RunRegistry)) and
      match?([{_pid, _} | _], Registry.lookup(LemonRouter.RunRegistry, run_id))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def run_active?(_run_id), do: false

  @doc """
  How many run processes are currently supervised.

  Cheaper than `active_runs/0` when only the count is needed; `0` when the
  router is not running.
  """
  @spec active_run_count() :: non_neg_integer()
  def active_run_count do
    case Process.whereis(LemonRouter.RunSupervisor) do
      pid when is_pid(pid) -> DynamicSupervisor.count_children(pid)[:active] || 0
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @typedoc "Run counts as reported by the orchestrator."
  @type run_counts :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          completed_today: non_neg_integer()
        }

  @doc """
  Orchestrator run counts.

  Always returns the full shape: when the router is not running, every counter
  is zero rather than the key being absent, so callers can read the fields
  without guarding.
  """
  @spec counts() :: run_counts()
  def counts do
    if is_pid(Process.whereis(LemonRouter.RunOrchestrator)) do
      LemonRouter.RunOrchestrator.counts()
    else
      @zero_counts
    end
  rescue
    _ -> @zero_counts
  catch
    :exit, _ -> @zero_counts
  end

  defp describe_active_run({run_id, pid}) when is_pid(pid) do
    metadata =
      try do
        GenServer.call(pid, :get_metadata, @metadata_timeout_ms)
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    %{
      run_id: run_id,
      session_key: metadata[:session_key],
      agent_id: metadata[:agent_id],
      engine: metadata[:engine],
      started_at_ms: metadata[:started_at_ms]
    }
  end

  defp describe_active_run({run_id, _pid}) do
    %{run_id: run_id, session_key: nil, agent_id: nil, engine: nil, started_at_ms: nil}
  end

  @doc """
  Send a message to an agent inbox.

  Supports `session: :latest | :new | <session_key>`.
  """
  @spec send_to_agent(binary(), binary(), keyword()) ::
          {:ok, %{run_id: binary(), session_key: binary(), selector: term()}} | {:error, term()}
  def send_to_agent(agent_id, prompt, opts \\ []) do
    LemonRouter.AgentInbox.send(agent_id, prompt, opts)
  end

  @doc """
  Resolve an agent session selector (`:latest`, `:new`, explicit key) to a concrete session.
  """
  @spec resolve_agent_session(binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_agent_session(agent_id, selector \\ :latest, opts \\ []) do
    LemonRouter.AgentInbox.resolve_session(agent_id, selector, opts)
  end

  @doc """
  List agent directory entries with routing/session discoverability metadata.
  """
  @spec list_agent_directory(keyword()) :: [map()]
  def list_agent_directory(opts \\ []) do
    LemonRouter.AgentDirectory.list_agents(opts)
  end

  @doc """
  List known sessions from the agent directory/phonebook.
  """
  @spec list_agent_sessions(keyword()) :: [map()]
  def list_agent_sessions(opts \\ []) do
    LemonRouter.AgentDirectory.list_sessions(opts)
  end

  @doc """
  List known channel targets (for example Telegram rooms/topics) with friendly labels.
  """
  @spec list_agent_targets(keyword()) :: [map()]
  def list_agent_targets(opts \\ []) do
    LemonRouter.AgentDirectory.list_targets(opts)
  end

  @doc """
  List persisted endpoint aliases.
  """
  @spec list_agent_endpoints(keyword()) :: [map()]
  def list_agent_endpoints(opts \\ []) do
    LemonRouter.AgentEndpoints.list(opts)
  end

  @doc """
  Upsert an endpoint alias for an agent.
  """
  @spec set_agent_endpoint(binary(), binary(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_agent_endpoint(agent_id, name, target, opts \\ []) do
    LemonRouter.AgentEndpoints.put(agent_id, name, target, opts)
  end

  @doc """
  Delete an endpoint alias.
  """
  @spec delete_agent_endpoint(binary(), binary()) :: :ok | {:error, term()}
  def delete_agent_endpoint(agent_id, name) do
    LemonRouter.AgentEndpoints.delete(agent_id, name)
  end
end
