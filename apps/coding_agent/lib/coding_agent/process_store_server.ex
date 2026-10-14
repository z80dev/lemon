defmodule CodingAgent.ProcessStoreServer do
  @moduledoc """
  GenServer that owns the ProcessStore ETS table and manages DETS persistence.

  This ensures the ETS table survives process crashes and is properly reloaded
  from DETS on restart. It also handles marking running processes as :lost
  when the system restarts (since we can't reconnect to OS PIDs).
  """

  use GenServer
  require Logger

  @table :coding_agent_processes
  @dets_table :coding_agent_processes_dets
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Returns the ETS table name for direct access by ProcessStore API.
  """
  def table_name, do: @table

  @doc """
  Ensure the table is initialized. Called by ProcessStore API functions.
  """
  def ensure_table(server \\ __MODULE__) do
    GenServer.call(server, :ensure_table, 5_000)
  end

  @doc """
  Trigger a cleanup of expired processes.
  """
  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  @doc """
  Clear all processes from both ETS and DETS.
  """
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear, 5_000)
  end

  @doc """
  Get DETS table status for debugging.
  """
  def dets_status(server \\ __MODULE__) do
    GenServer.call(server, :dets_status, 5_000)
  end

  @doc """
  Reserve artifact capacity for a process within its owner's aggregate budget,
  reclaiming finished artifacts if needed. See
  `CodingAgent.ProcessStore.reserve_artifact/4`.
  """
  def reserve_artifact(server, process_id, requested, owner_budget, runtime_budget) do
    GenServer.call(
      server,
      {:reserve_artifact, process_id, requested, owner_budget, runtime_budget},
      30_000
    )
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Trap exits to ensure we can close DETS properly
    Process.flag(:trap_exit, true)

    state = %{
      table: @table,
      dets_table: @dets_table,
      dets_path: dets_path(opts),
      ets_initialized: false,
      dets_initialized: false,
      loaded_from_dets: false
    }

    # Initialize tables synchronously during init
    state = initialize_ets(state)
    state = initialize_dets(state)
    state = maybe_load_from_dets(state)

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    state = ensure_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    deleted_count = do_cleanup(ttl_seconds)
    {:reply, {:ok, deleted_count}, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    failed? =
      :ets.foldl(
        fn {id, _record, _logs}, failed? ->
          CodingAgent.ProcessStore.delete(id) != :ok or failed?
        end,
        false,
        @table
      )

    if state.dets_initialized, do: :dets.sync(@dets_table)
    reply = if failed?, do: {:error, :output_cleanup_failed}, else: :ok
    {:reply, reply, state}
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

  def handle_call(
        {:reserve_artifact, process_id, requested, owner_budget, runtime_budget},
        _from,
        state
      ) do
    state = ensure_tables(state)
    {:reply, do_reserve_artifact(process_id, requested, owner_budget, runtime_budget), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)

    ttl_seconds =
      Application.get_env(:coding_agent, :process_store_ttl_seconds, @default_ttl_seconds)

    _deleted_count = do_cleanup(ttl_seconds)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Handle linked process exits if needed
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
    state =
      state
      |> initialize_ets()
      |> initialize_dets()
      |> maybe_reset_loaded_from_dets()

    maybe_load_from_dets(state)
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
          Logger.warning("Failed to open DETS: #{inspect(reason)}")
          state
      end
    end
  end

  defp maybe_load_from_dets(%{loaded_from_dets: true} = state), do: state

  defp maybe_load_from_dets(state) do
    if state.dets_initialized and state.ets_initialized do
      now = System.system_time(:second)

      :dets.foldl(
        fn {process_id, record, logs}, :ok ->
          record =
            if Map.get(record, :status) == :running do
              # Mark running processes as :lost since we can't reconnect to OS PIDs
              record
              |> Map.put(:status, :lost)
              |> Map.put(:error, :lost_on_restart)
              |> Map.put(:completed_at, now)
            else
              record
            end

          :ets.insert(@table, {process_id, record, logs})
          :ok
        end,
        :ok,
        @dets_table
      )

      %{state | loaded_from_dets: true}
    else
      state
    end
  end

  defp maybe_reset_loaded_from_dets(state) do
    if state.loaded_from_dets and state.dets_initialized and state.ets_initialized do
      case :ets.info(@table, :size) do
        0 ->
          case :dets.info(@dets_table, :size) do
            size when is_integer(size) and size > 0 -> %{state | loaded_from_dets: false}
            _ -> state
          end

        _ ->
          state
      end
    else
      state
    end
  end

  defp do_cleanup(ttl_seconds) do
    now = System.system_time(:second)

    expired_ids =
      :ets.foldl(
        fn {process_id, record, _logs}, acc ->
          if expired_record?(record, now, ttl_seconds) do
            [process_id | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    # A finalized session can linger for final polling after its file is closed.
    # Let delete/1 distinguish that safe case from a still-draining capture and
    # preserve the charge when file removal fails.
    deleted_count =
      Enum.count(expired_ids, fn process_id ->
        CodingAgent.ProcessStore.delete(process_id) == :ok
      end)

    if dets_open?() and expired_ids != [] do
      :dets.sync(@dets_table)
    end

    deleted_count
  end

  defp expired_record?(record, now, ttl_seconds) do
    status = Map.get(record, :status)

    if status in [:completed, :error, :killed, :lost] do
      completed_at =
        Map.get(record, :completed_at) || Map.get(record, :updated_at) ||
          Map.get(record, :inserted_at)

      is_integer(completed_at) and now - completed_at >= ttl_seconds
    else
      false
    end
  end

  defp do_reserve_artifact(process_id, requested, owner_budget, runtime_budget) do
    case :ets.lookup(@table, process_id) do
      [{^process_id, record, logs}] ->
        owner = Map.get(record, :owner)

        # Project records, not log buffers: aggregate accounting must not copy
        # every process's retained output into the store server's heap.
        records = :ets.select(@table, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

        {owner_usage, runtime_usage, reclaimable} =
          Enum.reduce(records, {0, 0, []}, fn {id, other}, {owned, total, candidates} = acc ->
            if id == process_id do
              acc
            else
              charge = artifact_charge(other)
              owned = owned + if(Map.get(other, :owner) == owner, do: charge, else: 0)

              candidates =
                if charge > 0 and reclaimable?(id),
                  do: [{id, other} | candidates],
                  else: candidates

              {owned, total + charge, candidates}
            end
          end)

        candidates = Enum.sort_by(reclaimable, fn {id, other} -> {finished_at(other), id} end)
        owned = Enum.filter(candidates, fn {_id, other} -> Map.get(other, :owner) == owner end)

        {owner_usage, runtime_usage} =
          reclaim_artifacts(
            owned,
            owner_usage,
            runtime_usage,
            requested,
            owner_budget,
            :owner,
            owner
          )

        {owner_usage, runtime_usage} =
          reclaim_artifacts(
            candidates,
            owner_usage,
            runtime_usage,
            requested,
            runtime_budget,
            :runtime,
            owner
          )

        granted =
          requested
          |> min(owner_budget - owner_usage)
          |> min(runtime_budget - runtime_usage)
          |> max(0)

        output = Map.put(Map.get(record, :output) || %{}, :artifact_capacity, granted)
        CodingAgent.ProcessStore.insert_record(process_id, Map.put(record, :output, output), logs)
        {:ok, granted}

      _ ->
        {:error, :not_found}
    end
  end

  # Deletes the oldest artifacts of stopped sessions until the reservation
  # fits. Records stay readable; they report the reclamation instead of a
  # dangling path.
  defp reclaim_artifacts([], owned, total, _requested, _budget, _scope, _owner),
    do: {owned, total}

  defp reclaim_artifacts([{id, _snapshot} | older], owned, total, requested, budget, scope, owner) do
    usage = if scope == :owner, do: owned, else: total

    if usage + requested <= budget do
      {owned, total}
    else
      # A previous pass may already have reclaimed this file. Re-read its
      # charge, and keep accounting unchanged when deletion fails.
      {owned, total} =
        case :ets.lookup(@table, id) do
          [{^id, record, logs}] ->
            charge = artifact_charge(record)

            if charge > 0 and reclaimable?(id) and
                 CodingAgent.ProcessStore.remove_output(record) == :ok do
              output =
                (Map.get(record, :output) || %{})
                |> Map.merge(%{artifact_capacity: 0, artifact_reclaimed: true})

              reclaimed = record |> Map.put(:full_output_path, nil) |> Map.put(:output, output)
              CodingAgent.ProcessStore.insert_record(id, reclaimed, logs)
              {owned - if(Map.get(record, :owner) == owner, do: charge, else: 0), total - charge}
            else
              {owned, total}
            end

          _ ->
            {owned, total}
        end

      reclaim_artifacts(older, owned, total, requested, budget, scope, owner)
    end
  end

  # A running process is charged its reserved capacity; a finished one the
  # bytes it wrote (its session shrinks the reservation when it finalizes).
  defp artifact_charge(record) do
    case Map.get(record, :output) do
      %{artifact_capacity: capacity} when is_integer(capacity) and capacity > 0 ->
        capacity

      _ ->
        # Pre-quota persisted records still occupy disk and must count toward
        # aggregate reclamation after upgrading.
        case Map.get(record, :full_output_path) do
          path when is_binary(path) ->
            case File.stat(path) do
              {:ok, %{type: :regular, size: size}} -> size
              _ -> 0
            end

          _ ->
            0
        end
    end
  end

  # Only a stopped session's file is safe to delete: a live session may still
  # write to it. Stopped covers finished, lost and orphaned running records.
  defp reclaimable?(process_id), do: not CodingAgent.ProcessSession.alive?(process_id)

  defp finished_at(record),
    do: Map.get(record, :completed_at) || Map.get(record, :inserted_at) || 0

  defp dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp schedule_cleanup do
    interval =
      Application.get_env(
        :coding_agent,
        :process_store_cleanup_interval_seconds,
        @cleanup_interval_seconds
      )

    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :process_store_path) ||
      Path.join(CodingAgent.Config.agent_dir(), "processes.dets")
  end
end
