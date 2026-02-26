defmodule CodingAgent.TaskStore do
  @moduledoc """
  ETS-backed store for tracking async task tool runs.

  Stores task status and a bounded list of recent events for polling.
  The actual ETS table is owned by TaskStoreServer to ensure proper
  lifecycle management and DETS persistence.
  """

  alias CodingAgent.TaskStoreServer

  @table :coding_agent_tasks
  @dets_table :coding_agent_tasks_dets
  @max_events 100
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

    insert_record(task_id, record, [])
    task_id
  end

  @doc """
  Append an event to a task's event list (bounded).
  """
  @spec append_event(task_id(), term()) :: :ok
  def append_event(task_id, event) when is_binary(task_id) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        events = [event | events] |> Enum.take(@max_events)
        record = Map.put(record, :updated_at, System.system_time(:second))
        insert_record(task_id, record, events)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Mark a task as running.
  """
  @spec mark_running(task_id()) :: :ok
  def mark_running(task_id) when is_binary(task_id) do
    update_record(task_id, fn record ->
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
    update_record(task_id, fn record ->
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
    update_record(task_id, fn record ->
      record
      |> Map.put(:status, :error)
      |> Map.put(:error, error)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
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
    :ets.insert(@table, {task_id, record, events})

    if dets_open?() do
      :dets.insert(@dets_table, {task_id, record, events})
    end

    :ok
  end

  @doc """
  Delete a task from both ETS and DETS.
  """
  @spec delete_task(task_id()) :: :ok
  def delete_task(task_id) do
    :ets.delete(@table, task_id)

    if dets_open?() do
      :dets.delete(@dets_table, task_id)
    end

    :ok
  end

  @doc """
  Check if DETS is available.
  """
  @spec dets_open?() :: boolean()
  def dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  # Private Functions

  defp ensure_table do
    TaskStoreServer.ensure_table(CodingAgent.TaskStoreServer)
  end

  defp update_record(task_id, fun) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        updated =
          record
          |> fun.()
          |> Map.put(:updated_at, System.system_time(:second))

        insert_record(task_id, updated, events)
        :ok

      _ ->
        :ok
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
