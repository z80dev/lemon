defmodule CodingAgent.TaskStore do
  @moduledoc """
  ETS-backed store for tracking async task tool runs.

  Stores task status and a bounded list of recent events for polling.
  The actual ETS table is owned by `TaskStoreServer`, which serializes every
  mutation before updating ETS and DETS. Reads remain direct ETS lookups.

  Lifecycle transitions are monotonic and idempotent: queued tasks may become
  running or terminal, running tasks may become terminal, and terminal tasks
  never change status or terminal payload. This makes late progress/start
  messages and competing finish/fail calls safe.
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
  Suppress async auto followup delivery for a task that is being explicitly joined.
  """
  @spec suppress_auto_followup(task_id()) :: :ok
  def suppress_auto_followup(task_id) when is_binary(task_id) do
    TaskStoreServer.update_record(task_id, fn record ->
      Map.put(record, :auto_followup_suppressed_at, System.system_time(:second))
    end)
  end

  @doc """
  Return whether async auto followup delivery has been suppressed for this task.
  """
  @spec auto_followup_suppressed?(task_id()) :: boolean()
  def auto_followup_suppressed?(task_id) when is_binary(task_id) do
    case get(task_id) do
      {:ok, record, _events} -> not is_nil(Map.get(record, :auto_followup_suppressed_at))
      _ -> false
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
