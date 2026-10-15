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

  @doc "Submit a fixed intent and return its durable queue/runtime disposition."
  defdelegate submit_with_receipt(request), to: LemonRouter.RunOrchestrator

  @doc "Reconcile a fixed admission ID without replaying dispatch."
  defdelegate run_receipt(run_id), to: LemonRouter.RunOrchestrator

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
  # Callers outside this app use this surface rather than private runtime
  # registries. Authoritative reads preserve unavailable state; informational
  # startup counters below remain best-effort.

  @typedoc "A run currently being orchestrated."
  @type active_run :: %{
          run_id: binary(),
          session_key: binary() | nil,
          agent_id: binary() | nil,
          profile_id: binary() | nil,
          engine: binary() | nil,
          started_at_ms: integer() | nil
        }

  @metadata_timeout_ms 100
  @unavailable_counts %{active: nil, queued: nil, completed_today: nil, failed_today: nil}

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

  Returns `{:error, :unavailable}` when either runtime owner is absent and
  `{:error, :query_failed}` when the registry cannot be read.

  Metadata reads have a 100 ms bound and never terminate the run. A busy or
  disappearing run keeps its fixed ID in the snapshot with unavailable fields
  set to `nil`; prompts, private metadata and process identifiers are excluded.
  """
  @spec active_runs() :: {:ok, [active_run()]} | {:error, :unavailable | :query_failed}
  def active_runs do
    orchestrator = Process.whereis(LemonRouter.RunOrchestrator)
    registry = Process.whereis(LemonRouter.RunRegistry)

    if is_pid(orchestrator) and is_pid(registry) do
      case GenServer.call(orchestrator, :presence_barrier, @metadata_timeout_ms) do
        :ok ->
          runs =
            LemonRouter.RunRegistry
            |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
            |> Enum.map(&describe_active_run/1)

          if Process.whereis(LemonRouter.RunOrchestrator) == orchestrator and
               Process.whereis(LemonRouter.RunRegistry) == registry,
             do: {:ok, runs},
             else: {:error, :unavailable}

        _ ->
          {:error, :query_failed}
      end
    else
      {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :query_failed}
  catch
    :exit, _ -> {:error, :query_failed}
  end

  @doc "Authoritative scoped active, queued and unresolved work; read failures never prove idle."
  defdelegate run_presence(filters \\ %{}), to: LemonRouter.RunPresence, as: :query

  @doc """
  Whether `run_id` is currently active.
  """
  @spec run_active?(binary()) :: boolean()
  def run_active?(run_id) when is_binary(run_id) do
    is_pid(Process.whereis(LemonRouter.RunRegistry)) and
      match?([{_pid, _} | _], Registry.lookup(LemonRouter.RunRegistry, run_id))
  rescue
    ArgumentError -> false
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
  catch
    :exit, _ -> 0
  end

  @typedoc "Run counts as reported by the orchestrator."
  @type run_counts :: %{
          active: non_neg_integer() | nil,
          queued: non_neg_integer() | nil,
          completed_today: non_neg_integer() | nil,
          failed_today: non_neg_integer() | nil
        }

  @doc """
  Orchestrator run counts.

  Always returns the full shape. Unavailable counters are nil, not invented zeros.
  """
  @spec counts() :: run_counts()
  def counts do
    if is_pid(Process.whereis(LemonRouter.RunOrchestrator)) do
      LemonRouter.RunOrchestrator.counts()
    else
      @unavailable_counts
    end
  catch
    :exit, _ -> @unavailable_counts
  end

  defp describe_active_run({run_id, pid}) when is_pid(pid) do
    metadata =
      try do
        case GenServer.call(pid, :get_metadata, @metadata_timeout_ms) do
          metadata when is_map(metadata) -> metadata
          _ -> %{}
        end
      catch
        :exit, _ -> %{}
      end

    %{
      run_id: run_id,
      session_key: Map.get(metadata, :session_key),
      agent_id: Map.get(metadata, :agent_id),
      profile_id: Map.get(metadata, :profile_id),
      engine: Map.get(metadata, :engine),
      started_at_ms: Map.get(metadata, :started_at_ms)
    }
  end

  defp describe_active_run({run_id, _pid}) do
    %{
      run_id: run_id,
      session_key: nil,
      agent_id: nil,
      profile_id: nil,
      engine: nil,
      started_at_ms: nil
    }
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
  @spec list_agent_directory(keyword()) :: [map()] | {:error, :unavailable}
  def list_agent_directory(opts \\ []) do
    LemonRouter.AgentDirectory.list_agents(opts)
  end

  @doc """
  List known sessions from the agent directory/phonebook.
  """
  @spec list_agent_sessions(keyword()) :: [map()] | {:error, :unavailable}
  def list_agent_sessions(opts \\ []) do
    LemonRouter.AgentDirectory.list_sessions(opts)
  end

  @doc """
  List known channel targets (for example Telegram rooms/topics) with friendly labels.
  """
  @spec list_agent_targets(keyword()) :: [map()] | {:error, :unavailable}
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
