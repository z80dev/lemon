defmodule CodingAgent.TaskStoreServer do
  @moduledoc """
  GenServer that owns the TaskStore ETS table and manages DETS persistence.

  This ensures the ETS table survives process crashes and is properly reloaded
  from DETS on restart. All record, event, lifecycle, and followup-suppression
  mutations pass through the server mailbox, so a mutation always reads the
  latest tuple and writes one coherent ETS/DETS snapshot.
  """

  use GenServer
  require Logger

  @table :coding_agent_tasks
  @dets_table :coding_agent_tasks_dets
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300
  @max_events 100
  @terminal_statuses [:completed, :error, :lost, :killed, :cancelled]

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Returns the ETS table name for direct access by TaskStore API.
  """
  def table_name, do: @table

  @doc """
  Ensure the table is initialized. Called by TaskStore API functions.
  """
  def ensure_table(server \\ __MODULE__) do
    GenServer.call(server, :ensure_table, 5_000)
  end

  @doc "Insert or replace a complete task tuple through the serialized owner."
  @spec insert_record(String.t(), map(), [term()], GenServer.server()) :: :ok
  def insert_record(task_id, record, events, server \\ __MODULE__) do
    GenServer.call(server, {:insert_record, task_id, record, events}, 10_000)
  end

  @doc "Atomically update a task record while preserving its current events."
  @spec update_record(String.t(), (map() -> map()), GenServer.server()) :: :ok
  def update_record(task_id, update_fn, server \\ __MODULE__) do
    GenServer.call(server, {:update_record, task_id, update_fn}, 10_000)
  end

  @doc "Atomically append a bounded event while preserving the current record."
  @spec append_event(String.t(), term(), GenServer.server()) :: :ok
  def append_event(task_id, event, server \\ __MODULE__) do
    GenServer.call(server, {:append_event, task_id, event}, 10_000)
  end

  @doc "Apply a monotonic, idempotent lifecycle transition."
  @spec transition(String.t(), atom(), (map() -> map()), GenServer.server()) :: :ok
  def transition(task_id, target_status, update_fn, server \\ __MODULE__) do
    GenServer.call(server, {:transition, task_id, target_status, update_fn}, 10_000)
  end

  @doc "Delete a task from ETS and DETS through the serialized owner."
  @spec delete_task(String.t(), GenServer.server()) :: :ok
  def delete_task(task_id, server \\ __MODULE__) do
    GenServer.call(server, {:delete_task, task_id}, 10_000)
  end

  @doc """
  Trigger a cleanup of expired tasks.
  """
  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  @doc """
  Clear all tasks from both ETS and DETS.
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

  @doc "Return whether the owned DETS table is open."
  @spec dets_open?(GenServer.server()) :: boolean()
  def dets_open?(server \\ __MODULE__) do
    GenServer.call(server, :dets_open?, 5_000)
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

  def handle_call({:insert_record, task_id, record, events}, _from, state) do
    state = ensure_tables(state)
    do_insert_record(task_id, record, events)
    {:reply, :ok, state}
  end

  def handle_call({:update_record, task_id, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        updated =
          record
          |> update_fn.()
          |> Map.put(:updated_at, System.system_time(:second))

        do_insert_record(task_id, updated, events)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:append_event, task_id, event}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        updated_events = [event | events] |> Enum.take(@max_events)
        updated_record = Map.put(record, :updated_at, System.system_time(:second))
        do_insert_record(task_id, updated_record, updated_events)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:transition, task_id, target_status, update_fn}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, task_id) do
      [{^task_id, record, events}] ->
        if transition_allowed?(Map.get(record, :status, :queued), target_status) do
          updated =
            record
            |> update_fn.()
            |> Map.put(:updated_at, System.system_time(:second))

          do_insert_record(task_id, updated, events)
        end

        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete_task, task_id}, _from, state) do
    state = ensure_tables(state)
    :ets.delete(@table, task_id)

    if state.dets_initialized do
      :dets.delete(@dets_table, task_id)
    end

    {:reply, :ok, state}
  end

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    deleted_count = do_cleanup(ttl_seconds)
    {:reply, {:ok, deleted_count}, state}
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

  def handle_call(:dets_open?, _from, state) do
    {:reply, state.dets_initialized and dets_table_open?(), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)

    ttl_seconds =
      Application.get_env(:coding_agent, :task_store_ttl_seconds, @default_ttl_seconds)

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
        fn {task_id, record, events}, :ok ->
          record =
            if Map.get(record, :status) == :running do
              record
              |> Map.put(:status, :lost)
              |> Map.put(:error, :lost_on_restart)
              |> Map.put(:completed_at, now)
            else
              record
            end

          :ets.insert(@table, {task_id, record, events})
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

  defp do_insert_record(task_id, record, events) do
    :ets.insert(@table, {task_id, record, events})

    if dets_table_open?() do
      :dets.insert(@dets_table, {task_id, record, events})
    end

    :ok
  end

  defp transition_allowed?(status, _target_status) when status in @terminal_statuses,
    do: false

  defp transition_allowed?(:running, :running), do: false
  defp transition_allowed?(:queued, :running), do: true

  defp transition_allowed?(status, target_status) when status in [:queued, :running],
    do: target_status in @terminal_statuses

  defp transition_allowed?(_status, _target_status), do: false

  defp do_cleanup(ttl_seconds) do
    now = System.system_time(:second)

    expired_ids =
      :ets.foldl(
        fn {task_id, record, _events}, acc ->
          if expired_record?(record, now, ttl_seconds) do
            [task_id | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    Enum.each(expired_ids, fn task_id ->
      :ets.delete(@table, task_id)

      if dets_table_open?() do
        :dets.delete(@dets_table, task_id)
      end
    end)

    if dets_table_open?() and expired_ids != [] do
      :dets.sync(@dets_table)
    end

    length(expired_ids)
  end

  defp expired_record?(record, now, ttl_seconds) do
    status = Map.get(record, :status)

    if status in [:completed, :error, :lost] do
      completed_at =
        Map.get(record, :completed_at) || Map.get(record, :updated_at) ||
          Map.get(record, :inserted_at)

      is_integer(completed_at) and now - completed_at >= ttl_seconds
    else
      false
    end
  end

  defp dets_table_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp schedule_cleanup do
    interval =
      Application.get_env(
        :coding_agent,
        :task_store_cleanup_interval_seconds,
        @cleanup_interval_seconds
      )

    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :task_store_path) ||
      Path.join(CodingAgent.Config.agent_dir(), "tasks.dets")
  end
end
