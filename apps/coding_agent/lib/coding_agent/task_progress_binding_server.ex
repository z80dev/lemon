defmodule CodingAgent.TaskProgressBindingServer do
  @moduledoc """
  GenServer that owns transient ETS tables for task progress bindings.

  This store is intentionally ETS-only and transient. It maintains a primary
  binding table keyed by `child_run_id` plus a secondary index keyed by
  `task_id`, and periodically prunes stale entries.
  """

  use GenServer

  @binding_table :coding_agent_task_progress_bindings
  @task_index_table :coding_agent_task_progress_binding_task_index
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def binding_table_name, do: @binding_table
  def task_index_table_name, do: @task_index_table

  def ensure_tables(server \\ __MODULE__) do
    GenServer.call(server, :ensure_tables, 5_000)
  end

  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  def put_binding(server \\ __MODULE__, binding) when is_map(binding) do
    GenServer.call(server, {:put_binding, binding}, 5_000)
  end

  def mark_completed(server \\ __MODULE__, child_run_id) when is_binary(child_run_id) do
    GenServer.call(server, {:mark_completed, child_run_id}, 5_000)
  end

  def delete_binding(server \\ __MODULE__, child_run_id) when is_binary(child_run_id) do
    GenServer.call(server, {:delete_binding, child_run_id}, 5_000)
  end

  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear, 5_000)
  end

  def get_by_task_id(server \\ __MODULE__, task_id) when is_binary(task_id) do
    GenServer.call(server, {:get_by_task_id, task_id}, 5_000)
  end

  def get_by_child_run_id(server \\ __MODULE__, child_run_id) when is_binary(child_run_id) do
    GenServer.call(server, {:get_by_child_run_id, child_run_id}, 5_000)
  end

  def list_all(server \\ __MODULE__) do
    GenServer.call(server, :list_all, 5_000)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      binding_table: @binding_table,
      task_index_table: @task_index_table,
      initialized: false
    }

    state = ensure_state_tables(state)
    _ = do_cleanup(startup_ttl_seconds())
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_tables, _from, state) do
    state = ensure_state_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_state_tables(state)
    {:reply, {:ok, do_cleanup(ttl_seconds)}, state}
  end

  def handle_call({:put_binding, binding}, _from, state) do
    state = ensure_state_tables(state)
    :ok = upsert_binding(binding)
    {:reply, :ok, state}
  end

  def handle_call({:mark_completed, child_run_id}, _from, state) do
    state = ensure_state_tables(state)

    case :ets.lookup(@binding_table, child_run_id) do
      [{^child_run_id, binding}] ->
        updated_binding =
          binding
          |> Map.put(:status, :completed)
          |> Map.put(:completed_at_ms, System.system_time(:millisecond))

        :ets.insert(@binding_table, {child_run_id, updated_binding})
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete_binding, child_run_id}, _from, state) do
    state = ensure_state_tables(state)
    {:reply, delete_binding_row(child_run_id), state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_state_tables(state)
    :ets.delete_all_objects(@binding_table)
    :ets.delete_all_objects(@task_index_table)
    {:reply, :ok, state}
  end

  def handle_call({:get_by_task_id, task_id}, _from, state) do
    state = ensure_state_tables(state)

    reply =
      case :ets.lookup(@task_index_table, task_id) do
        [{^task_id, child_run_id}] -> lookup_binding(child_run_id)
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_by_child_run_id, child_run_id}, _from, state) do
    state = ensure_state_tables(state)
    {:reply, lookup_binding(child_run_id), state}
  end

  def handle_call(:list_all, _from, state) do
    state = ensure_state_tables(state)

    bindings =
      :ets.foldl(fn {_child_run_id, binding}, acc -> [binding | acc] end, [], @binding_table)
      |> Enum.sort_by(& &1.inserted_at_ms)

    {:reply, bindings, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_state_tables(state)

    ttl_seconds =
      Application.get_env(
        :coding_agent,
        :task_progress_binding_store_ttl_seconds,
        @default_ttl_seconds
      )

    _deleted_count = do_cleanup(ttl_seconds)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp ensure_state_tables(%{initialized: true} = state), do: state

  defp ensure_state_tables(state) do
    if :ets.whereis(@binding_table) == :undefined do
      :ets.new(@binding_table, [:named_table, :protected, :set, read_concurrency: true])
    end

    if :ets.whereis(@task_index_table) == :undefined do
      :ets.new(@task_index_table, [:named_table, :protected, :set, read_concurrency: true])
    end

    %{state | initialized: true}
  end

  defp do_cleanup(ttl_seconds) do
    now_ms = System.system_time(:millisecond)

    expired_child_run_ids =
      :ets.foldl(
        fn {child_run_id, binding}, acc ->
          if expired?(binding, now_ms, ttl_seconds) do
            [child_run_id | acc]
          else
            acc
          end
        end,
        [],
        @binding_table
      )

    Enum.each(expired_child_run_ids, &delete_binding_row/1)
    length(expired_child_run_ids)
  end

  defp expired?(binding, now_ms, ttl_seconds) do
    ttl_ms = ttl_seconds * 1_000

    case Map.get(binding, :status) do
      :completed ->
        completed_at_ms = Map.get(binding, :completed_at_ms)
        is_integer(completed_at_ms) and now_ms - completed_at_ms >= ttl_ms

      _running_or_unknown ->
        false
    end
  end

  defp upsert_binding(%{child_run_id: child_run_id, task_id: task_id} = binding) do
    :ok = delete_binding_row(child_run_id)

    case :ets.lookup(@task_index_table, task_id) do
      [{^task_id, existing_child_run_id}] -> delete_binding_row(existing_child_run_id)
      [] -> :ok
    end

    :ets.insert(@binding_table, {child_run_id, binding})
    :ets.insert(@task_index_table, {task_id, child_run_id})
    :ok
  end

  defp lookup_binding(child_run_id) do
    case :ets.lookup(@binding_table, child_run_id) do
      [{^child_run_id, binding}] -> {:ok, binding}
      [] -> {:error, :not_found}
    end
  end

  defp delete_binding_row(child_run_id) do
    case :ets.lookup(@binding_table, child_run_id) do
      [{^child_run_id, binding}] ->
        :ets.delete(@binding_table, child_run_id)
        :ets.delete(@task_index_table, binding.task_id)
        :ok

      [] ->
        :ok
    end
  end

  defp schedule_cleanup do
    interval =
      Application.get_env(
        :coding_agent,
        :task_progress_binding_store_cleanup_interval_seconds,
        @cleanup_interval_seconds
      )

    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp startup_ttl_seconds do
    Application.get_env(
      :coding_agent,
      :task_progress_binding_store_ttl_seconds,
      @default_ttl_seconds
    )
  end
end
