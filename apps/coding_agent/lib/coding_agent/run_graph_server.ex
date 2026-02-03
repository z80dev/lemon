defmodule CodingAgent.RunGraphServer do
  @moduledoc """
  GenServer that owns the RunGraph ETS table and manages DETS persistence.

  This ensures the ETS table survives process crashes and is properly reloaded
  from DETS on restart. Running runs are marked as :lost on restart.
  """

  use GenServer
  require Logger

  @table :coding_agent_run_graph
  @dets_table :coding_agent_run_graph_dets
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300

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
    deleted_count = do_cleanup(ttl_seconds)
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
    ttl_seconds = Application.get_env(:coding_agent, :run_graph_ttl_seconds, @default_ttl_seconds)
    _deleted_count = do_cleanup(ttl_seconds)
    schedule_cleanup()
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
    if state.dets_initialized and state.ets_initialized do
      now = System.system_time(:second)

      :dets.foldl(
        fn {run_id, record}, :ok ->
          record =
            if Map.get(record, :status) == :running do
              # Mark running runs as :lost since we can't recover them
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

      %{state | loaded_from_dets: true}
    else
      state
    end
  end

  defp do_cleanup(ttl_seconds) do
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

    Enum.each(expired_ids, fn run_id ->
      :ets.delete(@table, run_id)

      if dets_open?() do
        :dets.delete(@dets_table, run_id)
      end
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

  defp dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp schedule_cleanup do
    interval = Application.get_env(:coding_agent, :run_graph_cleanup_interval_seconds, @cleanup_interval_seconds)
    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :run_graph_path) ||
      Path.join(CodingAgent.Config.agent_dir(), "run_graph.dets")
  end
end
