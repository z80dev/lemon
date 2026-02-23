defmodule CodingAgent.RunGraph do
  @moduledoc """
  ETS-backed run graph for tracking parent/child relationships and join state.

  The actual ETS table is owned by RunGraphServer to ensure proper
  lifecycle management and DETS persistence.

  ## Concurrency Model

  All state-mutating operations (`mark_running/1`, `finish/2`, `fail/2`,
  `add_child/2`, `update/2`) are serialized through RunGraphServer to
  guarantee atomic read-modify-write semantics. Reads (`get/1`) go directly
  to ETS for maximum throughput.

  ## State Machine

  Run statuses follow a monotonic transition order:

      queued -> running -> {completed | error | killed | cancelled | lost}

  Backward transitions are rejected to prevent state corruption under
  concurrent updates.

  ## Await Model

  `await/3` uses `LemonCore.Bus` (Phoenix PubSub) notifications for
  instant wake-up on run state changes, replacing the previous polling
  loop. Timeout guarantees are preserved via `receive` deadlines.
  """

  alias CodingAgent.RunGraphServer

  @table :coding_agent_run_graph
  @default_timeout_ms 30_000
  @default_ttl_seconds 86_400

  @type run_id :: String.t()

  # Monotonic state ordering. Higher values can only transition forward.
  @state_order %{
    queued: 0,
    running: 1,
    completed: 2,
    error: 2,
    killed: 2,
    cancelled: 2,
    lost: 2
  }

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

    :ok =
      RunGraphServer.atomic_update(parent_id, fn record ->
        Map.update(record, :children, [child_id], fn children -> [child_id | children] end)
      end)

    :ok =
      RunGraphServer.atomic_update(child_id, fn record ->
        Map.put(record, :parent, parent_id)
      end)

    :ok
  end

  @spec mark_running(run_id()) :: :ok | {:error, :invalid_transition}
  def mark_running(run_id) do
    RunGraphServer.atomic_transition(run_id, :running, fn record ->
      record
      |> Map.put(:status, :running)
      |> Map.put(:started_at, System.system_time(:second))
    end)
  end

  @spec finish(run_id(), term()) :: :ok | {:error, :invalid_transition}
  def finish(run_id, result) do
    RunGraphServer.atomic_transition(run_id, :completed, fn record ->
      record
      |> Map.put(:status, :completed)
      |> Map.put(:result, result)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  @spec fail(run_id(), term()) :: :ok | {:error, :invalid_transition}
  def fail(run_id, error) do
    RunGraphServer.atomic_transition(run_id, :error, fn record ->
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

  @spec await([run_id()] | run_id(), :wait_all | :wait_any, non_neg_integer() | :infinity | nil) ::
          {:ok, map()} | {:error, :timeout, map()}
  def await(run_ids, mode \\ :wait_all, timeout_ms \\ @default_timeout_ms)

  def await(run_id, mode, timeout_ms) when is_binary(run_id) do
    await([run_id], mode, timeout_ms)
  end

  def await(run_ids, mode, timeout_ms) when is_list(run_ids) and is_atom(mode) do
    ensure_table()

    # Subscribe to PubSub topics for all awaited runs
    Enum.each(run_ids, fn run_id ->
      safe_subscribe(run_id)
    end)

    result =
      case timeout_ms do
        :infinity ->
          do_await(run_ids, mode, :infinity)

        nil ->
          do_await(run_ids, mode, :infinity)

        ms when is_integer(ms) and ms >= 0 ->
          deadline = System.monotonic_time(:millisecond) + ms
          do_await(run_ids, mode, deadline)

        _ ->
          deadline = System.monotonic_time(:millisecond) + @default_timeout_ms
          do_await(run_ids, mode, deadline)
      end

    # Unsubscribe after await completes
    Enum.each(run_ids, fn run_id ->
      safe_unsubscribe(run_id)
    end)

    result
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
  def cleanup(ttl_seconds \\ @default_ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:ok, _count} = RunGraphServer.cleanup(CodingAgent.RunGraphServer, ttl_seconds)
    :ok
  end

  @doc """
  Insert or update a record directly (used by server during load).
  """
  @spec insert_record(run_id(), map()) :: :ok
  def insert_record(run_id, record) do
    RunGraphServer.insert_record(run_id, record)
  end

  @doc """
  Update a run record with a function.

  The function receives the current record and should return the updated record.
  All updates are serialized through RunGraphServer to prevent race conditions.
  """
  @spec update(run_id(), (map() -> map())) :: :ok
  def update(run_id, update_fn) do
    RunGraphServer.atomic_update(run_id, update_fn)
  end

  @doc """
  Delete a run from both ETS and DETS.
  """
  @spec delete_run(run_id()) :: :ok
  def delete_run(run_id) do
    RunGraphServer.delete_run(run_id)
  end

  @doc """
  Check if DETS is available.
  """
  @spec dets_open?() :: boolean()
  def dets_open? do
    RunGraphServer.dets_open?()
  end

  @doc """
  Check whether a state transition is valid (monotonically forward).

  Returns `true` if `from` -> `to` is a valid forward transition.
  """
  @spec valid_transition?(atom(), atom()) :: boolean()
  def valid_transition?(from, to) do
    from_order = Map.get(@state_order, normalize_status(from), -1)
    to_order = Map.get(@state_order, normalize_status(to), -1)
    to_order > from_order
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

  defp wait_or_timeout(run_ids, mode, :infinity, _snapshot) do
    # Wait for PubSub notification (no deadline)
    receive do
      {:run_graph, :state_changed, _run_id} -> :ok
    after
      # Safety fallback: re-check every 5s in case a notification was missed
      5_000 -> :ok
    end

    do_await(run_ids, mode, :infinity)
  end

  defp wait_or_timeout(run_ids, mode, deadline, snapshot) do
    now = System.monotonic_time(:millisecond)
    remaining = deadline - now

    if remaining <= 0 do
      {:error, :timeout, %{mode: mode, runs: snapshot}}
    else
      # Wait for PubSub notification or timeout
      receive do
        {:run_graph, :state_changed, _run_id} -> :ok
      after
        min(remaining, 5_000) -> :ok
      end

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
    status = normalize_status(Map.get(record, :status, :unknown))
    status in [:completed, :error, :lost, :killed, :cancelled, :unknown]
  end

  @doc false
  def normalize_status(value) when is_atom(value), do: value

  def normalize_status(value) when is_binary(value) do
    case value do
      "completed" -> :completed
      "error" -> :error
      "lost" -> :lost
      "killed" -> :killed
      "cancelled" -> :cancelled
      "running" -> :running
      "queued" -> :queued
      "unknown" -> :unknown
      _ -> :unknown
    end
  end

  def normalize_status(_), do: :unknown

  defp safe_subscribe(run_id) do
    try do
      LemonCore.Bus.subscribe("run_graph:#{run_id}")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp safe_unsubscribe(run_id) do
    try do
      LemonCore.Bus.unsubscribe("run_graph:#{run_id}")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp ensure_table do
    RunGraphServer.ensure_table()
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
