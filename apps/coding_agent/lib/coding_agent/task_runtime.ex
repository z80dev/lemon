defmodule CodingAgent.TaskRuntime do
  @moduledoc """
  Supervision, lookup and status of native task children.

  The runtime is `TaskRuntime.Control` (invocation-bound commands), `Async`
  (launch and the turn finalizer), `Runner` (child session steps), `Restore`
  (crash continuation), `Followup` (completion notices) and `Hub` (the operator
  Agent Hub). Every child has its own supervised owner,
  `CodingAgent.TaskRuntime.Child`, which holds its live lifecycle phase, worker,
  session, pending messages and cancellation and does all blocking work
  (session shutdown, store writes) itself, so one slow child cannot stall
  another.

  The `CodingAgent.TaskStore` record is the one status authority: results,
  cancellation and the owner's recorded agent state (`idle`, `parked`,
  `killed`, `aborted`). Owner phases and `RunGraph` rows are projections used
  for liveness and join coordination; neither decides a terminal status.

  Owners publish a small projection (phase, signal references, session and
  worker handles, public metadata) as their registry value. Lookups, family
  resolution and the Agent Hub read those values without calling any owner.

  Each owner journals its state in a table that outlives it. A crashed owner is
  restarted and adopts its live worker and session; after repeated crashes, or
  when the worker is gone, it terminalizes the child. Restarting the dependency
  group (registry failure) re-adopts every journaled child the same way.
  """

  alias CodingAgent.TaskRuntime.{Child, Journal}
  alias CodingAgent.TaskStore
  alias LemonAgent.AbortSignal

  @registry __MODULE__.Registry
  @parents __MODULE__.Parents
  @supervisor __MODULE__.Supervisor
  @failed_statuses [:error, :cancelled, :killed, :lost, :timeout]

  @doc false
  def child_spec(_opts) do
    LemonCore.Supervision.subtree(__MODULE__.Tree, [
      Journal,
      {Registry, keys: :unique, name: @registry},
      {Registry, keys: :duplicate, name: @parents},
      %{id: @supervisor, start: {__MODULE__, :start_supervisor, []}, type: :supervisor}
    ])
  end

  @doc false
  def start_supervisor do
    # Each owner restarts at most twice before terminalizing its child, so this
    # bound only has to absorb a burst of distinct owners crashing together.
    with {:ok, pid} <-
           DynamicSupervisor.start_link(
             name: @supervisor,
             strategy: :one_for_one,
             max_restarts: 100,
             max_seconds: 5
           ) do
      for id <- Journal.ids(), is_nil(whereis(id)) do
        DynamicSupervisor.start_child(@supervisor, {Child, {id, nil}})
      end

      {:ok, pid}
    end
  end

  @doc "Start the owner of a registered task child."
  @spec start(String.t(), map()) :: :ok | {:error, term()}
  def start(id, spec) when is_binary(id) do
    case DynamicSupervisor.start_child(@supervisor, {Child, {id, Map.put(spec, :id, id)}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> {:error, :already_registered}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :task_supervisor_unavailable}
  end

  @doc false
  def via(id, projection), do: {:via, Registry, {@registry, id, projection}}

  @doc false
  def publish(id, projection), do: Registry.update_value(@registry, id, fn _ -> projection end)

  @doc false
  def watch_parent(parent) when is_pid(parent), do: Registry.register(@parents, parent, nil)

  @doc "The owner process of a task, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _projection}] -> pid
      [] -> nil
    end
  end

  def whereis(_id), do: nil

  @doc "The owner and its published projection, or nil."
  @spec lookup(String.t()) :: {pid(), map()} | nil
  def lookup(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, projection}] -> {pid, projection}
      [] -> nil
    end
  end

  def lookup(_id), do: nil

  @doc "Every live child as `{task_id, owner, projection}`."
  @spec entries() :: [{String.t(), pid(), map()}]
  def entries do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc "Owners of children launched by `parent` (a native session process)."
  @spec owners_of_parent(pid()) :: [pid()]
  def owners_of_parent(parent) when is_pid(parent) do
    for {owner, _} <- Registry.lookup(@parents, parent), do: owner
  end

  @doc "Owner and worker processes of the given tasks, for join monitors."
  @spec pids([String.t()]) :: [pid()]
  def pids(ids) do
    ids
    |> Enum.flat_map(fn id ->
      case lookup(id) do
        {owner, projection} -> [owner | List.wrap(projection.worker)]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Effective status of a child. The stored record is the authority: a failed or
  cancelled result, or a cancellation the owner recorded (`agent_state:
  :killed`), wins; a completed result stays completed (whatever else the owner
  recorded) unless it is resumable (`idle`/`parked`). The projection only adds
  what the store cannot know yet: a cancellation in flight (which refuses a
  resumable child's wakeup), a session that died, or a turn still starting.
  """
  @spec status(map(), String.t() | nil) :: atom()
  def status(projection, id) do
    record =
      if id do
        case TaskStore.get_record(id) do
          {:ok, record} -> record
          _ -> nil
        end
      end

    stored = record[:status]
    agent_state = record[:agent_state]

    cond do
      id && is_nil(record) -> :missing
      stored in @failed_statuses -> stored
      agent_state == :killed -> :cancelled
      stored == :completed and agent_state not in [:idle, :parked] -> :completed
      # A cancellation in flight ends a live or resumable child before the
      # owner records it.
      cancelling?(projection) -> :cancelled
      stored == :completed -> agent_state
      agent_state == :aborted -> :aborted
      projection.phase == :dead -> :dead
      is_pid(projection.session) -> :running
      is_nil(id) -> :dead
      true -> :queued
    end
  end

  defp cancelling?(projection) do
    projection.phase in [:cancelling, :killed] or AbortSignal.aborted?(projection.signal) or
      AbortSignal.aborted?(projection.parent_signal)
  end
end
