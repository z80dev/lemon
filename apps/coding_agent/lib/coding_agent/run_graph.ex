defmodule CodingAgent.RunGraph do
  @moduledoc """
  ETS-backed run graph for tracking parent/child relationships and join state.

  The actual ETS table is owned by RunGraphServer to ensure proper
  lifecycle management and DETS persistence.
  """

  alias CodingAgent.RunGraphServer

  @table :coding_agent_run_graph
  @dets_table :coding_agent_run_graph_dets
  @default_timeout_ms 30_000
  @poll_interval_ms 50
  @default_ttl_seconds 86_400

  @type run_id :: String.t()

  @spec new_run(map()) :: run_id()
  def new_run(attrs \\ %{}) when is_map(attrs) do
    ensure_table()
    run_id = generate_id()
    now = System.system_time(:second)

    record =
      Map.merge(
        %{
          id: run_id,
          status: :queued,
          inserted_at: now,
          updated_at: now,
          parent: nil,
          children: []
        },
        attrs
      )

    insert_record(run_id, record)
    run_id
  end

  @spec add_child(run_id(), run_id()) :: :ok
  def add_child(parent_id, child_id) do
    ensure_table()

    update(parent_id, fn record ->
      Map.update(record, :children, [child_id], fn children -> [child_id | children] end)
    end)

    update(child_id, fn record -> Map.put(record, :parent, parent_id) end)
    :ok
  end

  @spec mark_running(run_id()) :: :ok
  def mark_running(run_id) do
    update(run_id, fn record ->
      record
      |> Map.put(:status, :running)
      |> Map.put(:started_at, System.system_time(:second))
    end)
  end

  @spec finish(run_id(), term()) :: :ok
  def finish(run_id, result) do
    update(run_id, fn record ->
      record
      |> Map.put(:status, :completed)
      |> Map.put(:result, result)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @spec fail(run_id(), term()) :: :ok
  def fail(run_id, error) do
    update(run_id, fn record ->
      record
      |> Map.put(:status, :error)
      |> Map.put(:error, error)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @spec get(run_id()) :: {:ok, map()} | {:error, :not_found}
  def get(run_id) do
    ensure_table()

    case :ets.lookup(@table, run_id) do
      [{^run_id, record}] -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  @spec await([run_id()] | run_id(), :wait_all | :wait_any, non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout, map()}
  def await(run_ids, mode \\ :wait_all, timeout_ms \\ @default_timeout_ms)

  def await(run_id, mode, timeout_ms) when is_binary(run_id) do
    await([run_id], mode, timeout_ms)
  end

  def await(run_ids, mode, timeout_ms) when is_list(run_ids) and is_atom(mode) do
    ensure_table()
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(run_ids, mode, deadline)
  end

  @doc """
  Clear all runs from the graph.
  """
  def clear do
    RunGraphServer.clear()
  end

  @doc """
  Get table statistics.
  """
  def stats do
    RunGraphServer.stats()
  end

  @doc """
  Cleanup completed/error runs older than the TTL (seconds).
  """
  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ @default_ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:ok, _count} = RunGraphServer.cleanup(CodingAgent.RunGraphServer, ttl_seconds)
    :ok
  end

  @doc """
  Insert or update a record directly (used by server during load).
  """
  @spec insert_record(run_id(), map()) :: :ok
  def insert_record(run_id, record) do
    :ets.insert(@table, {run_id, record})

    if dets_open?() do
      :dets.insert(@dets_table, {run_id, record})
    end

    :ok
  end

  @doc """
  Update a run record with a function.

  The function receives the current record and should return the updated record.
  """
  @spec update(run_id(), (map() -> map())) :: :ok
  def update(run_id, update_fn) do
    case get(run_id) do
      {:ok, record} ->
        updated =
          record
          |> update_fn.()
          |> Map.put(:updated_at, System.system_time(:second))
        insert_record(run_id, updated)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Delete a run from both ETS and DETS.
  """
  @spec delete_run(run_id()) :: :ok
  def delete_run(run_id) do
    :ets.delete(@table, run_id)

    if dets_open?() do
      :dets.delete(@dets_table, run_id)
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

  defp do_await(run_ids, mode, deadline) do
    runs = get_runs(run_ids)

    case {mode, runs} do
      {:wait_all, _} ->
        if Enum.all?(runs, &terminal_status?/1) do
          {:ok, %{mode: :wait_all, runs: runs}}
        else
          wait_or_timeout(run_ids, mode, deadline, runs)
        end

      {:wait_any, _} ->
        case Enum.find(runs, &terminal_status?/1) do
          nil -> wait_or_timeout(run_ids, mode, deadline, runs)
          run -> {:ok, %{mode: :wait_any, run: run}}
        end
    end
  end

  defp wait_or_timeout(run_ids, mode, deadline, snapshot) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout, %{mode: mode, runs: snapshot}}
    else
      Process.sleep(@poll_interval_ms)
      do_await(run_ids, mode, deadline)
    end
  end

  defp get_runs(run_ids) do
    Enum.map(run_ids, fn run_id ->
      case get(run_id) do
        {:ok, record} -> record
        {:error, :not_found} -> %{id: run_id, status: :unknown}
      end
    end)
  end

  defp terminal_status?(record) do
    status =
      case Map.get(record, :status, :unknown) do
        value when is_binary(value) ->
          case value do
            "completed" -> :completed
            "error" -> :error
            "lost" -> :lost
            "killed" -> :killed
            "cancelled" -> :cancelled
            "unknown" -> :unknown
            _ -> :unknown
          end

        value ->
          value
      end

    status in [:completed, :error, :lost, :killed, :cancelled, :unknown]
  end

  defp ensure_table do
    RunGraphServer.ensure_table()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
