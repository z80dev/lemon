defmodule CodingAgent.RunGraphServer do
  @moduledoc """
  GenServer that owns the RunGraph ETS table and manages DETS persistence.

  This ensures the ETS table survives process crashes and is properly reloaded
  from DETS on restart. Running runs are marked as :lost on restart.

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

  ## Async Startup

  DETS loading is performed asynchronously after init to avoid blocking
  early requests. The server tracks a `loading` flag; callers that need
  data consistency can check via `ensure_table/1` which waits for load
  completion if needed.

  ## Non-blocking Cleanup

  Periodic cleanup is offloaded to an async Task so that the GenServer
  remains responsive during large-table scans. Cleanup processes records
  in chunks to avoid long scheduler holds.
  """

  use GenServer
  require Logger

  alias CodingAgent.RunGraph

  @table :coding_agent_run_graph
  @dets_table :coding_agent_run_graph_dets
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300
  @cleanup_chunk_size 500

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
  def insert_record(run_id, record) do
    do_insert_record(run_id, record)
  end

  @doc """
  Delete a run from both ETS and DETS.
  """
  @spec delete_run(RunGraph.run_id()) :: :ok
  def delete_run(run_id) do
    :ets.delete(@table, run_id)

    if dets_open?() do
      :dets.delete(@dets_table, run_id)
    end

    :ok
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
  def dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      table: @table,
      dets_table: @dets_table,
      dets_path: dets_path(opts),
      ets_initialized: false,
      dets_initialized: false,
      loaded_from_dets: false,
      loading: false,
      cleanup_ref: nil
    }

    # Initialize ETS and DETS synchronously (fast operations)
    state = initialize_ets(state)
    state = initialize_dets(state)

    # Load DETS data asynchronously to avoid blocking early requests
    state = start_async_dets_load(state)

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    state = ensure_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:atomic_update, run_id, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, run_id) do
      [{^run_id, record}] ->
        updated =
          record
          |> update_fn.()
          |> Map.put(:updated_at, System.system_time(:second))

        do_insert_record(run_id, updated)

        status_changed? = Map.get(record, :status) != Map.get(updated, :status)
        event = if(status_changed?, do: :status_changed, else: :updated)
        broadcast_state_change(run_id, updated, event)

        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:atomic_transition, run_id, target_status, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, run_id) do
      [{^run_id, record}] ->
        current_status = Map.get(record, :status, :queued)

        if RunGraph.valid_transition?(current_status, target_status) do
          updated =
            record
            |> update_fn.()
            |> Map.put(:updated_at, System.system_time(:second))

          do_insert_record(run_id, updated)
          broadcast_state_change(run_id, updated, :status_changed)
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_transition}, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:loading?, _from, state) do
    {:reply, state.loading, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    if state.ets_initialized do
      :ets.delete_all_objects(@table)
    end

    if state.dets_initialized do
      :dets.delete_all_objects(@dets_table)
      :dets.sync(@dets_table)
    end

    {:reply, :ok, %{state | loaded_from_dets: false}}
  end

  def handle_call(:stats, _from, state) do
    state = ensure_tables(state)

    stats =
      if state.ets_initialized do
        info = :ets.info(@table)

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
    deleted_count = do_cleanup_chunked(ttl_seconds)
    {:reply, {:ok, deleted_count}, state}
  end

  def handle_call(:dets_status, _from, state) do
    info =
      if state.dets_initialized do
        case :dets.info(@dets_table) do
          :undefined -> %{status: :closed}
          info -> Map.new(info)
        end
      else
        %{status: :not_initialized}
      end

    {:reply, %{info: info, state: Map.drop(state, [:table, :dets_table])}, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)
    state = start_async_cleanup(state)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(:dets_load_complete, state) do
    {:noreply, %{state | loading: false, loaded_from_dets: true}}
  end

  def handle_info({:cleanup_complete, ref, _deleted_count}, %{cleanup_ref: ref} = state) do
    {:noreply, %{state | cleanup_ref: nil}}
  end

  def handle_info({:cleanup_complete, _ref, _deleted_count}, state) do
    # Stale cleanup result from a previous ref — ignore
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.dets_initialized do
      :dets.close(@dets_table)
    end

    :ok
  end

  # Private Functions

  defp ensure_tables(state) do
    state
    |> initialize_ets()
    |> initialize_dets()
    |> maybe_load_from_dets()
  end

  defp initialize_ets(state) do
    if state.ets_initialized do
      state
    else
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          %{state | ets_initialized: true}

        _tid ->
          %{state | ets_initialized: true}
      end
    end
  end

  defp initialize_dets(state) do
    if state.dets_initialized do
      state
    else
      File.mkdir_p!(Path.dirname(state.dets_path))

      dets_file = String.to_charlist(state.dets_path)

      case :dets.open_file(@dets_table, file: dets_file, type: :set) do
        {:ok, _} ->
          %{state | dets_initialized: true}

        {:error, {:already_open, _pid}} ->
          %{state | dets_initialized: true}

        {:error, reason} ->
          Logger.warning("Failed to open RunGraph DETS: #{inspect(reason)}")
          state
      end
    end
  end

  defp maybe_load_from_dets(%{loaded_from_dets: true} = state), do: state

  defp maybe_load_from_dets(state) do
    # The async load was started during init. If it hasn't completed yet
    # and someone explicitly calls ensure_tables, trigger a synchronous load
    # as a fallback to guarantee data availability.
    if state.dets_initialized and state.ets_initialized do
      do_sync_dets_load()
      %{state | loaded_from_dets: true, loading: false}
    else
      state
    end
  end

  defp do_insert_record(run_id, record) do
    :ets.insert(@table, {run_id, record})

    if dets_open?() do
      :dets.insert(@dets_table, {run_id, record})
    end

    :ok
  end

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
      Map.has_key?(record, key) -> Map.get(record, key)
      is_atom(key) and Map.has_key?(record, Atom.to_string(key)) -> Map.get(record, Atom.to_string(key))
      true -> nil
    end
  rescue
    _ -> nil
  end

  defp get_record_field(_record, _key), do: nil

  defp do_sync_dets_load do
    now = System.system_time(:second)

    :dets.foldl(
      fn {run_id, record}, :ok ->
        record =
          if Map.get(record, :status) == :running do
            record
            |> Map.put(:status, :lost)
            |> Map.put(:error, :lost_on_restart)
            |> Map.put(:completed_at, now)
          else
            record
          end

        :ets.insert(@table, {run_id, record})
        :ok
      end,
      :ok,
      @dets_table
    )
  end

  defp start_async_dets_load(%{dets_initialized: true, ets_initialized: true} = state) do
    server = self()

    Task.start(fn ->
      do_sync_dets_load()
      send(server, :dets_load_complete)
    end)

    %{state | loading: true, loaded_from_dets: true}
  end

  defp start_async_dets_load(state), do: state

  defp start_async_cleanup(state) do
    # If a cleanup is already in progress, skip
    if state.cleanup_ref do
      state
    else
      ref = make_ref()
      server = self()
      ttl = Application.get_env(:coding_agent, :run_graph_ttl_seconds, @default_ttl_seconds)

      Task.start(fn ->
        deleted = do_cleanup_chunked(ttl)
        send(server, {:cleanup_complete, ref, deleted})
      end)

      %{state | cleanup_ref: ref}
    end
  end

  # Chunked cleanup: collect expired IDs then delete in chunks to avoid
  # holding the scheduler for too long on large tables.
  defp do_cleanup_chunked(ttl_seconds) do
    now = System.system_time(:second)

    expired_ids =
      :ets.foldl(
        fn {run_id, record}, acc ->
          if expired_record?(record, now, ttl_seconds) do
            [run_id | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    expired_ids
    |> Enum.chunk_every(@cleanup_chunk_size)
    |> Enum.each(fn chunk ->
      Enum.each(chunk, fn run_id ->
        :ets.delete(@table, run_id)

        if dets_open?() do
          :dets.delete(@dets_table, run_id)
        end
      end)

      # Yield between chunks to let other work proceed
      Process.sleep(0)
    end)

    if dets_open?() and expired_ids != [] do
      :dets.sync(@dets_table)
    end

    length(expired_ids)
  end

  defp expired_record?(record, now, ttl_seconds) do
    status = Map.get(record, :status)

    if status in [:completed, :error, :lost, :killed, :cancelled] do
      completed_at =
        Map.get(record, :completed_at) || Map.get(record, :updated_at) ||
          Map.get(record, :inserted_at)

      is_integer(completed_at) and now - completed_at >= ttl_seconds
    else
      false
    end
  end

  defp schedule_cleanup do
    interval =
      Application.get_env(
        :coding_agent,
        :run_graph_cleanup_interval_seconds,
        @cleanup_interval_seconds
      )

    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :run_graph_path) ||
      Path.join(CodingAgent.Config.agent_dir(), "run_graph.dets")
  end
end
