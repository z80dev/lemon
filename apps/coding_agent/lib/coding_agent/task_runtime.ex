defmodule CodingAgent.TaskRuntime do
  @moduledoc """
  Supervision and lookup for native task children.

  Every child has its own supervised owner, `CodingAgent.TaskRuntime.Child`.
  The owner is the one live authority for its child's lifecycle phase, worker,
  session, pending messages and cancellation; it does all blocking work (session
  shutdown, store writes) itself, so one slow child cannot stall another. The
  durable authority for results is the `CodingAgent.TaskStore` record.

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
  Effective status of a child from its projection and stored record. A pending
  cancellation, an aborted signal and a terminal record win over the live phase.
  """
  @spec status(map(), String.t() | nil) :: atom()
  def status(projection, id) do
    stored =
      if id do
        case TaskStore.get_record(id) do
          {:ok, record} -> record[:status]
          _ -> :missing
        end
      end

    cond do
      projection.phase in [:cancelling, :killed] or AbortSignal.aborted?(projection.signal) or
          AbortSignal.aborted?(projection.parent_signal) ->
        :cancelled

      stored in [:error, :cancelled, :killed, :aborted, :lost, :missing] ->
        stored

      projection.phase in [:idle, :parked, :aborted, :killed, :completed] ->
        projection.phase

      stored == :completed ->
        stored

      projection.phase == :dead ->
        :dead

      is_pid(projection.session) ->
        :running

      is_nil(id) ->
        :dead

      true ->
        :queued
    end
  end
end
