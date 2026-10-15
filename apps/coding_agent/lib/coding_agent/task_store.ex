defmodule CodingAgent.TaskStore do
  @moduledoc """
  ETS-backed store for tracking async task tool runs.

  Stores task status and a bounded list of recent events for polling.
  The actual ETS table is owned by `TaskStoreServer`, which serializes every
  mutation before updating ETS and DETS. Reads remain direct ETS lookups.

  Lifecycle transitions within a turn are monotonic and idempotent. Only the
  task control owner may explicitly begin another turn on a completed idle or
  parked child. `agent_state` tracks the live child's lifecycle independently
  of the current turn's result; cancellation never permits another turn.
  """

  alias CodingAgent.TaskStoreServer

  @table :coding_agent_tasks
  @default_ttl_seconds 86_400

  @type task_id :: String.t()

  @doc """
  Create a new task entry and return its id.
  """
  @spec new_task(map()) :: task_id()
  def new_task(attrs \\ %{}) when is_map(attrs) do
    ensure_table()
    task_id = generate_id()
    now = System.system_time(:second)

    record =
      Map.merge(
        %{
          id: task_id,
          status: :queued,
          inserted_at: now,
          updated_at: now
        },
        attrs
      )

    TaskStoreServer.insert_record(task_id, record, [])
    task_id
  end

  @doc """
  Append an event to a task's event list (bounded).
  """
  @spec append_event(task_id(), term()) :: :ok
  def append_event(task_id, event) when is_binary(task_id) do
    TaskStoreServer.append_event(task_id, event)
  end

  @doc """
  Mark a task as running.
  """
  @spec mark_running(task_id()) :: :ok
  def mark_running(task_id) when is_binary(task_id) do
    TaskStoreServer.transition(task_id, :running, fn record ->
      record
      |> Map.put(:status, :running)
      |> Map.put(:started_at, System.system_time(:second))
    end)
  end

  @doc "Explicitly reopen a completed, addressable child for a new message turn."
  def begin_agent_turn(task_id), do: TaskStoreServer.begin_agent_turn(task_id)

  @doc "Persist the native child's lifecycle without changing its turn result."
  def set_agent_state(task_id, state, attrs \\ %{})
      when state in [:running, :idle, :parked, :aborted, :killed] do
    TaskStoreServer.update_record(task_id, fn record ->
      record |> Map.merge(attrs) |> Map.put(:agent_state, state)
    end)
  end

  @doc """
  Finish a task with a result payload.
  """
  @spec finish(task_id(), term()) :: :ok
  def finish(task_id, result) when is_binary(task_id) do
    TaskStoreServer.transition(task_id, :completed, fn record ->
      record
      |> Map.put(:status, :completed)
      |> Map.put(:result, result)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @doc """
  Fail a task with an error payload.
  """
  @spec fail(task_id(), term()) :: :ok
  def fail(task_id, error) when is_binary(task_id) do
    TaskStoreServer.transition(task_id, :error, fn record ->
      record
      |> Map.put(:status, :error)
      |> Map.put(:error, error)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @doc """
  Cancel a queued or running task with a durable reason.

  Cancellation is a terminal, first-writer-wins transition. The owner of the
  actual work remains responsible for signalling the live process; this store
  method only records the authoritative lifecycle state.
  """
  @spec cancel(task_id(), term()) :: :ok
  def cancel(task_id, reason \\ :cancelled) when is_binary(task_id) do
    TaskStoreServer.transition(task_id, :cancelled, fn record ->
      record
      |> Map.put(:status, :cancelled)
      |> Map.put(:agent_state, :killed)
      |> Map.put(:error, reason)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @doc """
  Mark local completion tracking as lost without declaring the delegated run
  failed. A later authoritative result may still complete or fail this task.
  """
  @spec mark_tracking_lost(task_id(), term()) :: :ok
  def mark_tracking_lost(task_id, reason) when is_binary(task_id) do
    TaskStoreServer.transition(task_id, :tracking_lost, fn record ->
      record
      |> Map.put(:status, :tracking_lost)
      |> Map.put(:tracking_error, reason)
      |> Map.put(:tracking_lost_at, System.system_time(:second))
    end)
  end

  @doc """
  Suppress async auto followup delivery for a task that is being explicitly joined.
  """
  @spec suppress_auto_followup(task_id()) :: :ok
  def suppress_auto_followup(task_id) when is_binary(task_id) do
    TaskStoreServer.update_record(task_id, fn record ->
      Map.put(record, :auto_followup_suppressed_at, System.system_time(:second))
    end)
  end

  @doc "Reserve followup delivery while an explicit multi-task join chooses its result."
  @spec begin_auto_followup_join([task_id()], reference()) :: :ok
  def begin_auto_followup_join(task_ids, join_token) when is_list(task_ids) do
    TaskStoreServer.begin_auto_followup_join(task_ids, join_token)
  end

  @doc "Resolve a join reservation, permanently suppressing only selected tasks."
  @spec finish_auto_followup_join([task_id()], [task_id()], reference()) :: :ok
  def finish_auto_followup_join(task_ids, suppressed_task_ids, join_token)
      when is_list(task_ids) and is_list(suppressed_task_ids) do
    TaskStoreServer.finish_auto_followup_join(task_ids, suppressed_task_ids, join_token)
  end

  @doc """
  Return whether async auto followup delivery has been suppressed for this task.
  """
  @spec auto_followup_suppressed?(task_id()) :: boolean()
  def auto_followup_suppressed?(task_id) when is_binary(task_id) do
    case get(task_id) do
      {:ok, record, _events} ->
        not is_nil(Map.get(record, :auto_followup_suppressed_at)) or
          Map.get(record, :auto_followup_join_tokens, []) != []

      _ ->
        false
    end
  end

  @doc """
  Get task record and recent events.
  """
  @spec get(task_id()) :: {:ok, map(), [term()]} | {:error, :not_found}
  def get(task_id) when is_binary(task_id) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] -> {:ok, record, Enum.reverse(events)}
      _ -> {:error, :not_found}
    end
  end

  @doc "Read task metadata without copying or reversing its retained event stream."
  @spec get_record(task_id()) :: {:ok, map()} | {:error, :not_found}
  def get_record(task_id) when is_binary(task_id) do
    ensure_table()

    case :ets.lookup_element(@table, task_id, 2, nil) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc "Read only lifecycle status, without copying prompts, results or event history."
  @spec get_status(task_id()) :: {:ok, atom()} | {:error, :not_found}
  def get_status(task_id) when is_binary(task_id) do
    ensure_table()

    case :ets.select(@table, [{{task_id, %{status: :"$1"}, :_}, [], [:"$1"]}]) do
      [status] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all tasks with optional status filter.
  """
  @spec list(atom()) :: [{task_id(), map()}]
  def list(status_filter \\ :all) do
    ensure_table()

    :ets.foldl(
      fn {task_id, record, _events}, acc ->
        if status_filter == :all or Map.get(record, :status) == status_filter do
          [{task_id, record} | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
  end

  @doc """
  Clear all tasks (tests).
  """
  @spec clear() :: :ok
  def clear do
    TaskStoreServer.clear(CodingAgent.TaskStoreServer)
  end

  @doc """
  Cleanup completed/error tasks older than the TTL (seconds).
  """
  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ @default_ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:ok, _count} = TaskStoreServer.cleanup(CodingAgent.TaskStoreServer, ttl_seconds)
    :ok
  end

  @doc """
  Insert or update a record directly (used by server during load).
  """
  @spec insert_record(task_id(), map(), [term()]) :: :ok
  def insert_record(task_id, record, events) do
    TaskStoreServer.insert_record(task_id, record, events)
  end

  @doc """
  Delete a task from both ETS and DETS.
  """
  @spec delete_task(task_id()) :: :ok
  def delete_task(task_id) do
    TaskStoreServer.delete_task(task_id)
  end

  @doc """
  Check if DETS is available.
  """
  @spec dets_open?() :: boolean()
  def dets_open? do
    TaskStoreServer.dets_open?()
  end

  # Private Functions

  defp ensure_table do
    TaskStoreServer.ensure_table(CodingAgent.TaskStoreServer)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
