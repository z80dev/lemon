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

  @doc """
  Abort a session's active run.
  """
  defdelegate abort(session_key, reason \\ :user_requested), to: LemonRouter.Router

  @doc """
  Abort a specific run by ID.
  """
  defdelegate abort_run(run_id, reason \\ :user_requested), to: LemonRouter.Router

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
  Run a destructive session lifecycle operation (`:reset` or `:delete`) with
  execution for `session_key` fenced, only when the router proves the session
  has no active, queued or unresolved work.

  The fence is a durable `LemonCore.LifecycleFenceStore` row taken through the
  serialized orchestrator admission boundary, so every admission that preceded
  it is visible to the idle proof. Until the operation ends, router admission
  (any client or mode), idle native follow-ups, remote `coding_agent.run`
  dispatch and direct gateway submissions for the session are refused with
  `:session_lifecycle_in_progress`. The fence survives orchestrator restarts.
  A remote run stays present after its router run is terminal until the node
  proves it stopped (`LemonAgent.NodeInvocation`).

  The fence owner is a process scoped to this one operation, never the
  caller: it acquires, runs `fun`, marks the row finished and releases. An
  acquire that times out is cancelled by its acquisition id. A fence left
  behind by a failed release or a dead owner is released only after the
  owner exits and the orchestrator's reconcile check passes; if `fun` had not
  returned, the operation's outcome is recorded as unknown. Fences never
  expire by time.

  `fun` receives the fence generation; pass it to the mutation as
  `fence_generation:` so the mutation stops if the fence is no longer held.
  Returns `fun`'s result, or, without calling it:

    * `{:error, :session_busy}` — the session has active, queued or unresolved work;
    * `{:error, :lifecycle_in_progress}` — another reset/delete holds the fence;
    * `{:error, :unavailable}` — the fence or idle proof could not be established.

  An exception or exit in `fun` exits the caller.
  """
  @spec with_session_lifecycle_fence(binary(), :reset | :delete, (String.t() -> result)) ::
          result | {:error, :session_busy | :lifecycle_in_progress | :unavailable}
        when result: term()
  def with_session_lifecycle_fence(session_key, operation, fun)
      when is_binary(session_key) and session_key != "" and operation in [:reset, :delete] and
             is_function(fun, 1) do
    caller = self()
    tag = make_ref()

    case LemonCore.TaskSupervisor.start_child(LemonRouter.LifecycleTaskSupervisor, fn ->
           send(caller, {tag, fenced_operation(session_key, operation, fun)})
         end) do
      {:ok, owner} ->
        monitor = Process.monitor(owner)

        receive do
          {^tag, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, ^owner, reason} ->
            receive do
              {^tag, result} -> result
            after
              0 -> exit(reason)
            end
        end

      {:error, _not_started} ->
        {:error, :unavailable}
    end
  end

  defp fenced_operation(session_key, operation, fun) do
    case fence_session_lifecycle(session_key, operation) do
      {:ok, generation} ->
        case prove_session_idle(session_key) do
          :ok ->
            result = fun.(generation)
            # A release that fails leaves the row held; this owner's exit then
            # reconciles it, and the marker records that `fun` returned.
            _ = LemonCore.LifecycleFenceStore.mark_finished(session_key, generation)
            release_session_lifecycle(session_key, generation)
            result

          error ->
            _ = LemonCore.LifecycleFenceStore.mark_finished(session_key, generation)
            release_session_lifecycle(session_key, generation)
            error
        end

      error ->
        error
    end
  end

  defp fence_session_lifecycle(session_key, operation) do
    acquisition_id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    try do
      case LemonRouter.RunOrchestrator.fence_session_lifecycle(
             session_key,
             operation,
             acquisition_id
           ) do
        {:ok, generation} -> {:ok, generation}
        {:error, :fenced} -> {:error, :lifecycle_in_progress}
        {:error, _reason} -> {:error, :unavailable}
      end
    catch
      # A timed-out acquire may still apply: cancel it by its id. If it applied
      # first, the orchestrator also watches this owner, whose exit reconciles it.
      :exit, _ ->
        LemonRouter.RunOrchestrator.cancel_session_lifecycle(session_key, acquisition_id)
        {:error, :unavailable}
    end
  end

  defp prove_session_idle(session_key) do
    case run_presence(%{session_key: session_key}) do
      {:ok, %{presence: %{idle: true, complete: true}}} -> :ok
      {:ok, %{presence: %{}}} -> {:error, :session_busy}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp release_session_lifecycle(session_key, generation) do
    LemonRouter.RunOrchestrator.release_session_lifecycle(session_key, generation)
  catch
    :exit, _ -> :ok
  end

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
end
