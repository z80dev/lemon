defmodule CodingAgent.RunGraphServer do
  @moduledoc """
  GenServer that owns the RunGraph ETS table and manages DETS persistence.

  ## Restart Semantics

  `CodingAgent.DurableTable` gives the mirror an ETS heir. If this owner
  crashes, its restart reclaims the live table unchanged: queued and running
  runs keep their status and their workers' later transitions are accepted.

  Only a boot (first start, application restart or a clean owner stop) loads
  from DETS. Rows whose workers cannot have survived are then normalized:
  `:queued` and `:running` become `:lost` with `:lost_on_restart`, and that
  outcome is persisted so a waiting join returns instead of hanging.

  ## Serialized Writes

  All state-mutating operations are serialized through this GenServer's
  mailbox to guarantee atomic read-modify-write semantics. This prevents
  race conditions when concurrent processes update the same run.

  Read operations go directly to ETS (`:public` table with
  `read_concurrency: true`) for maximum throughput.

  ## State Change Notifications

  On every status change, a `{:run_graph, :state_changed, run_id}` message
  is broadcast via `LemonCore.Bus` to the topic `"run_graph:<run_id>"`.
  This enables `RunGraph.await/3` to wake up immediately rather than polling.

  ## Startup Readiness

  DETS loading completes synchronously in `init/1`. `start_link/1` does not
  return, and no call can observe or mutate the ETS table, until the persisted
  snapshot has been loaded and boot normalization has been persisted.

  ## Cleanup

  The shared `CodingAgent.DurableTable` owner sweeps its expiration index in
  this mailbox. Retained runs are not scanned and no background sweep task can
  race a live update. Terminal runs expire after `:run_graph_ttl_seconds`.
  A queued or running run without an update for
  `:run_graph_stale_ttl_seconds` (default 7 days) is marked `:lost` with
  `:stale` instead of being deleted, so joins on it return; the terminal row
  then expires normally.
  """

  use CodingAgent.DurableTable

  alias CodingAgent.RunGraph

  @table :coding_agent_run_graph
  @dets_table :coding_agent_run_graph_dets
  @default_ttl_seconds 86_400

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the ETS table name for direct access by RunGraph API.
  """
  def table_name, do: @table

  @doc """
  Ensure the table is initialized. Called by RunGraph API functions.
  """
  def ensure_table(server \\ __MODULE__) do
    GenServer.call(server, :ensure_table, 5_000)
  end

  @doc """
  Atomically update a run record through the GenServer.

  The update function receives the current record and returns the updated record.
  The entire read-modify-write is serialized in the GenServer process.
  """
  @spec atomic_update(RunGraph.run_id(), (map() -> map())) :: :ok
  def atomic_update(run_id, update_fn, server \\ __MODULE__) do
    GenServer.call(server, {:atomic_update, run_id, update_fn}, 10_000)
  end

  @doc """
  Atomically modify a run and return an operation-specific reply.

  The callback must return `{:ok, updated_record, reply}` to persist a new
  record, or `{:error, reason}` to leave the record unchanged. This is used by
  budget accounting when the limit check and counter update must be one
  indivisible operation.
  """
  @spec atomic_modify(RunGraph.run_id(), (map() -> {:ok, map(), term()} | {:error, term()})) ::
          term() | {:error, term()}
  def atomic_modify(run_id, modify_fn, server \\ __MODULE__) do
    GenServer.call(server, {:atomic_modify, run_id, modify_fn}, 10_000)
  end

  @doc """
  Atomically transition a run to a new status with monotonic enforcement.

  Returns `:ok` if the transition was applied, or `:ok` if the run was not
  found (consistent with previous behavior). Returns `{:error, :invalid_transition}`
  if the transition would violate monotonic ordering.
  """
  @spec atomic_transition(RunGraph.run_id(), atom(), (map() -> map())) ::
          :ok | {:error, :invalid_transition}
  def atomic_transition(run_id, target_status, update_fn, server \\ __MODULE__) do
    GenServer.call(server, {:atomic_transition, run_id, target_status, update_fn}, 10_000)
  end

  @doc """
  Insert or update a record directly. Used for initial record creation
  and server-side operations (DETS load, test setup).
  """
  @spec insert_record(RunGraph.run_id(), map()) :: :ok
  def insert_record(run_id, record, server \\ __MODULE__) do
    GenServer.call(server, {:insert_record, run_id, record}, 10_000)
  end

  @doc """
  Delete a run from both ETS and DETS.
  """
  @spec delete_run(RunGraph.run_id()) :: :ok
  def delete_run(run_id, server \\ __MODULE__) do
    GenServer.call(server, {:delete_run, run_id}, 10_000)
  end

  @doc """
  Clear all runs from ETS and DETS.
  """
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear, 5_000)
  end

  @doc """
  Get table statistics.
  """
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats, 5_000)
  end

  @doc """
  Trigger a cleanup of expired runs.
  """
  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  @doc """
  Get DETS table status for debugging.
  """
  def dets_status(server \\ __MODULE__) do
    GenServer.call(server, :dets_status, 5_000)
  end

  @doc """
  Check if DETS is available.
  """
  @spec dets_open?() :: boolean()
  def dets_open?(server \\ __MODULE__) do
    GenServer.call(server, :dets_open?, 5_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state =
      DurableTable.open(%{}, opts,
        table: @table,
        dets_table: @dets_table,
        path: dets_path(opts),
        row_arity: 2,
        normalize: &__MODULE__.normalize_row/2,
        after_load: &__MODULE__.persist_restored_rows/1,
        timestamp: &__MODULE__.expiry_timestamp/1,
        ttl_key: :run_graph_ttl_seconds,
        interval_key: :run_graph_cleanup_interval_seconds
      )

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    state = ensure_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:atomic_update, run_id, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(state.table, run_id) do
      [{^run_id, record}] ->
        updated =
          record
          |> update_fn.()
          |> Map.put(:updated_at, System.system_time(:second))

        do_insert_record(state, run_id, updated)

        status_changed? = Map.get(record, :status) != Map.get(updated, :status)
        event = if(status_changed?, do: :status_changed, else: :updated)
        broadcast_state_change(run_id, updated, event)

        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:atomic_modify, run_id, modify_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(state.table, run_id) do
      [{^run_id, record}] ->
        case modify_fn.(record) do
          {:ok, updated_record, reply} ->
            updated = Map.put(updated_record, :updated_at, System.system_time(:second))
            do_insert_record(state, run_id, updated)

            status_changed? = Map.get(record, :status) != Map.get(updated, :status)
            event = if(status_changed?, do: :status_changed, else: :updated)
            broadcast_state_change(run_id, updated, event)
            {:reply, reply, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:atomic_transition, run_id, target_status, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(state.table, run_id) do
      [{^run_id, record}] ->
        current_status = Map.get(record, :status, :queued)

        if RunGraph.valid_transition?(current_status, target_status) do
          updated =
            record
            |> update_fn.()
            |> Map.put(:updated_at, System.system_time(:second))

          do_insert_record(state, run_id, updated)
          broadcast_state_change(run_id, updated, :status_changed)
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_transition}, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:insert_record, run_id, record}, _from, state) do
    state = ensure_tables(state)
    do_insert_record(state, run_id, record)
    {:reply, :ok, state}
  end

  def handle_call({:delete_run, run_id}, _from, state) do
    state = ensure_tables(state)
    DurableTable.delete(state.table, run_id)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    DurableTable.clear(state)
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    state = ensure_tables(state)

    stats =
      if state.ets_initialized do
        info = :ets.info(state.table)

        %{
          size: info[:size] || 0,
          memory: info[:memory] || 0,
          initialized: true
        }
      else
        %{initialized: false}
      end

    {:reply, stats, state}
  end

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    deleted_count = DurableTable.cleanup(state, ttl_seconds, &expire_run(state, &1))
    {:reply, {:ok, deleted_count}, state}
  end

  def handle_call(:dets_status, _from, state) do
    {:reply, DurableTable.status(state), state}
  end

  def handle_call(:dets_open?, _from, state) do
    {:reply, DurableTable.open?(state.dets_table), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)
    DurableTable.periodic_cleanup(state, &expire_run(state, &1))
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Private Functions

  defp ensure_tables(state), do: DurableTable.ensure(state)

  defp do_insert_record(state, run_id, record),
    do: DurableTable.put(state.table, {run_id, record})

  defp broadcast_state_change(run_id, record, event) do
    try do
      LemonCore.Bus.broadcast(
        "run_graph:#{run_id}",
        {:run_graph, :state_changed, run_id}
      )

      payload = %{
        run_id: run_id,
        parent_run_id: get_record_field(record, :parent),
        session_key: get_record_field(record, :session_key),
        status: get_record_field(record, :status),
        event: event,
        timestamp_ms: System.system_time(:millisecond)
      }

      meta = %{
        run_id: run_id,
        parent_run_id: get_record_field(record, :parent),
        session_key: get_record_field(record, :session_key)
      }

      event_message = LemonCore.Event.new(:run_graph_changed, payload, meta)
      LemonCore.Bus.broadcast("run:#{run_id}", event_message)

      parent_run_id = get_record_field(record, :parent)

      if is_binary(parent_run_id) and parent_run_id != run_id do
        LemonCore.Bus.broadcast("run:#{parent_run_id}", event_message)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp get_record_field(nil, _key), do: nil

  defp get_record_field(record, key) when is_map(record) do
    cond do
      Map.has_key?(record, key) ->
        Map.get(record, key)

      is_atom(key) and Map.has_key?(record, Atom.to_string(key)) ->
        Map.get(record, Atom.to_string(key))

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp get_record_field(_record, _key), do: nil

  # Boot only: a queued or running run's worker did not survive the restart.
  @doc false
  def normalize_row({run_id, record}, _state) do
    record =
      if RunGraph.normalize_status(record[:status]) in [:queued, :running] do
        record
        |> Map.put(:status, :lost)
        |> Map.put(:error, :lost_on_restart)
        |> Map.put(:completed_at, System.system_time(:second))
      else
        record
      end

    {run_id, record}
  end

  @doc false
  def persist_restored_rows(state) do
    :ets.foldl(
      fn
        {_id, %{status: :lost, error: :lost_on_restart}} = row, :ok ->
          DurableTable.persist(state.table, row)

        _row, :ok ->
          :ok
      end,
      :ok,
      state.table
    )

    :ok = DurableTable.sync(state.table)
    state
  end

  @doc false
  def expiry_timestamp({_id, record}) do
    if terminal?(record) do
      DurableTable.terminal_timestamp(record)
    else
      # Offset so the shared sweep (cutoff = now - ttl) reaches a queued or
      # running row once it has been idle for the stale TTL.
      case DurableTable.terminal_timestamp(record) do
        timestamp when is_integer(timestamp) ->
          timestamp + (stale_ttl_seconds() - ttl_seconds()) * 1_000

        nil ->
          nil
      end
    end
  end

  defp terminal?(record),
    do:
      RunGraph.normalize_status(record[:status]) in [
        :completed,
        :error,
        :lost,
        :killed,
        :cancelled
      ]

  # A stale non-terminal run becomes terminal (and re-indexed as such) rather
  # than disappearing under a waiting join; only terminal rows are deleted.
  defp expire_run(state, run_id) do
    case :ets.lookup(state.table, run_id) do
      [{^run_id, record}] ->
        if terminal?(record) do
          DurableTable.delete(state.table, run_id)
        else
          updated =
            Map.merge(record, %{
              status: :lost,
              error: :stale,
              completed_at: System.system_time(:second),
              updated_at: System.system_time(:second)
            })

          do_insert_record(state, run_id, updated)
          broadcast_state_change(run_id, updated, :status_changed)
          :retained
        end

      [] ->
        :ok
    end
  end

  defp ttl_seconds, do: Application.get_env(:coding_agent, :run_graph_ttl_seconds, 86_400)

  defp stale_ttl_seconds,
    do: Application.get_env(:coding_agent, :run_graph_stale_ttl_seconds, 604_800)

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :run_graph_path) ||
      CodingAgent.StatePaths.dets_path("run_graph.dets")
  end
end
