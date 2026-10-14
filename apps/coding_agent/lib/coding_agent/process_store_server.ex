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

  def handle_call({:register_launch, id, owner, fingerprint}, _from, state) do
    state = ensure_tables(state)

    reply =
      case :ets.lookup(@table, id) do
        [] ->
          now = System.system_time(:second)

          record = %{
            id: id,
            owner: owner,
            launch_fingerprint: fingerprint,
            launch_classification: :queued,
            status: :queued,
            inserted_at: now,
            updated_at: now
          }

          persist_launch(id, record, [])
          :new

        [{^id, %{owner: ^owner, launch_fingerprint: ^fingerprint} = record, logs}] ->
          record = reconcile_launch_record(id, record, logs)
          {:existing, CodingAgent.ProcessStore.receipt(record)}

        _ ->
          {:error, :identity_conflict}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_launch, id, owner, fingerprint}, _from, state) do
    state = ensure_tables(state)

    reply =
      case :ets.lookup(@table, id) do
        [{^id,
          %{owner: ^owner, launch_fingerprint: ^fingerprint, launch_classification: :queued} =
            record, logs}] ->
          # Persist uncertainty BEFORE crossing the external side-effect boundary.
          # A crash after this point must never authorize another start.
          record =
            record
            |> Map.put(:launch_classification, :outcome_unknown)
            |> Map.put(:status, :starting)

          persist_launch(id, record, logs)
          :ok

        [{^id, %{owner: ^owner, launch_fingerprint: ^fingerprint} = record, _}] ->
          {:error, {:existing_launch, CodingAgent.ProcessStore.receipt(record)}}

        _ ->
          {:error, :identity_conflict}
      end

    {:reply, reply, state}
  end

  def handle_call({:classify_launch, id, classification, reason}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, id) do
      [{^id, record, logs}] ->
        # A lost queue reply must not downgrade an acknowledged process, and a
        # confirmed rejection cannot overwrite a start that crossed the boundary.
        current = Map.get(record, :launch_classification)

        if current == :queued or classification == :accepted do
          record =
            record
            |> Map.put(:launch_classification, classification)
            |> Map.put(:launch_reason, reason)

          persist_launch(id, record, logs)
        end

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:launch_receipt, id, owner}, _from, state) do
    state = ensure_tables(state)

    reply =
      case :ets.lookup(@table, id) do
        [{^id, %{owner: ^owner, launch_fingerprint: fingerprint} = record, logs}]
        when is_binary(fingerprint) ->
          record = reconcile_launch_record(id, record, logs)
          {:ok, CodingAgent.ProcessStore.receipt(record)}

        _ ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end


  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    deleted_count = do_cleanup(ttl_seconds)
    {:reply, {:ok, deleted_count}, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    if state.ets_initialized do
      :ets.foldl(
        fn {_id, record, _logs}, :ok -> CodingAgent.ProcessStore.remove_output(record) end,
        :ok,
        @table
      )

      :ets.delete_all_objects(@table)
    end

    if state.dets_initialized do
      :dets.delete_all_objects(@dets_table)
      :dets.sync(@dets_table)
    end

    {:reply, :ok, %{state | loaded_from_dets: false}}
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
  defp persist_launch(id, record, logs) do
    CodingAgent.ProcessStore.insert_record(id, record, logs)

    if dets_open?() do
      :ok = :dets.sync(@dets_table)
    end
  end

  defp reconcile_launch_record(id, record, logs) do
    if Map.get(record, :status) in [:running, :starting] and
         not CodingAgent.ProcessSession.alive?(id) do
      record =
        Map.merge(record, %{status: :lost, launch_classification: :outcome_unknown})

      persist_launch(id, record, logs)
      record
    else
      record
    end
  end


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
            if Map.get(record, :status) in [:running, :starting, :queued] do
              # Losing the BEAM owner is not proof of external termination.
              record = Map.merge(record, %{status: :lost, error: :lost_on_restart})

              if is_binary(Map.get(record, :launch_fingerprint)) do
                Map.put(record, :launch_classification, :outcome_unknown)
              else
                Map.put(record, :completed_at, now)
              end
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

    Enum.each(expired_ids, fn process_id ->
      CodingAgent.ProcessStore.delete(process_id)
    end)

    if dets_open?() and expired_ids != [] do
      :dets.sync(@dets_table)
    end

    length(expired_ids)
  end

  defp expired_record?(record, now, ttl_seconds) do
    status = Map.get(record, :status)

    if status in [:completed, :error, :killed, :lost] and
         Map.get(record, :launch_classification) != :outcome_unknown do
      completed_at =
        Map.get(record, :completed_at) || Map.get(record, :updated_at) ||
          Map.get(record, :inserted_at)

      is_integer(completed_at) and now - completed_at >= ttl_seconds
    else
      false
    end
  end

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
