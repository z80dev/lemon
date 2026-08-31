defmodule LemonAutomation.KanbanDispatcher do
  @moduledoc """
  Supervised dispatcher for durable Kanban task leases.

  `stop_board/2` is a hard stop: owned worker processes are killed, their exact
  lease IDs are reclaimed immediately, and their monitor associations are
  removed before the call returns. Late replies are ignored, and guarded store
  updates prevent an obsolete worker from terminalizing a newer lease.

  Starting a board reconciles unexpired leases left by the same dispatcher
  worker ID, which makes manager restart recovery independent of lease expiry.
  """

  use GenServer

  alias LemonAgent.Workspace.KanbanStore

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def start_board(board_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:start_board, board_id, opts})
  end

  def stop_board(board_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:stop_board, board_id})
  end

  def status(board_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:status, board_id})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       boards: %{},
       refs: %{},
       worker_mod:
         Keyword.get(
           opts,
           :worker_mod,
           app_env(:kanban_worker_module, LemonAutomation.KanbanRunWorker)
         ),
       task_supervisor: Keyword.get(opts, :task_supervisor, LemonAutomation.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call({:start_board, board_id, opts}, _from, state) do
    case KanbanStore.get_board(board_id) do
      %{} = board when map_size(board) == 0 ->
        {:reply, {:error, :board_not_found}, state}

      board ->
        if Map.has_key?(state.boards, board_id) do
          {:reply, {:error, :already_running}, state}
        else
          worker_id = Keyword.get(opts, :worker_id, "kanban-dispatcher")
          {:ok, _reclaimed} = KanbanStore.reclaim_worker_leases(board_id, worker_id)

          dispatcher = %{
            board_id: board.id,
            status: "running",
            interval_ms: Keyword.get(opts, :interval_ms, 1_000),
            max_concurrency: Keyword.get(opts, :max_concurrency, 1),
            lease_ms: Keyword.get(opts, :lease_ms, 300_000),
            worker_id: worker_id,
            worker_profile: Keyword.get(opts, :worker_profile),
            worker_mod: Keyword.get(opts, :worker_mod, state.worker_mod),
            worker_opts: Keyword.get(opts, :worker_opts, []),
            running: %{},
            timer: nil,
            started_at_ms: now_ms()
          }

          state =
            state
            |> put_in([:boards, board_id], dispatcher)
            |> schedule_tick(board_id, 0)

          {:reply, {:ok, public_dispatcher(dispatcher)}, state}
        end
    end
  end

  def handle_call({:stop_board, board_id}, _from, state) do
    case Map.get(state.boards, board_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      dispatcher ->
        if dispatcher.timer, do: Process.cancel_timer(dispatcher.timer)

        state =
          dispatcher.running
          |> Enum.reduce(state, fn {ref, worker}, acc ->
            Process.exit(worker.pid, :kill)
            Process.demonitor(ref, [:flush])
            _ = KanbanStore.reclaim_task_lease(worker.task_id, worker.lease_id)
            update_in(acc.refs, &Map.delete(&1, ref))
          end)
          |> update_in([:boards], &Map.delete(&1, board_id))

        {:reply, {:ok, public_dispatcher(%{dispatcher | status: "stopped", running: %{}})}, state}
    end
  end

  def handle_call({:status, board_id}, _from, state) do
    dispatcher = Map.get(state.boards, board_id)

    {:reply,
     {:ok,
      %{
        running: not is_nil(dispatcher),
        dispatcher: dispatcher && public_dispatcher(dispatcher)
      }}, state}
  end

  @impl true
  def handle_info({:dispatch_tick, board_id}, state) do
    state =
      state
      |> dispatch_board(board_id)
      |> schedule_tick(board_id)

    {:noreply, state}
  end

  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_worker(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, finish_worker(ref, {:error, reason}, state)}
  end

  defp dispatch_board(state, board_id) do
    case Map.get(state.boards, board_id) do
      nil ->
        state

      dispatcher ->
        {:ok, _reclaimed} = KanbanStore.reclaim_expired_leases(board_id)
        available = max(dispatcher.max_concurrency - map_size(dispatcher.running), 0)

        if available > 0 do
          Enum.reduce(1..available, state, fn _, acc -> maybe_start_worker(acc, board_id) end)
        else
          state
        end
    end
  end

  defp maybe_start_worker(state, board_id) do
    dispatcher = Map.fetch!(state.boards, board_id)

    case KanbanStore.lease_task(board_id, dispatcher.worker_id,
           lease_ms: dispatcher.lease_ms,
           worker_profile: dispatcher.worker_profile
         ) do
      {:ok, task} ->
        lease_id = lease_id(task)

        case start_task(
               state.task_supervisor,
               dispatcher.worker_mod,
               task,
               dispatcher.worker_opts
             ) do
          {:ok, task_ref} ->
            worker = %{task_id: task.id, lease_id: lease_id, pid: task_ref.pid}

            state
            |> put_in([:refs, task_ref.ref], Map.put(worker, :board_id, board_id))
            |> put_in([:boards, board_id, :running, task_ref.ref], worker)

          {:error, _reason} ->
            _ = KanbanStore.reclaim_task_lease(task.id, lease_id)
            state
        end

      {:error, :no_available_task} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp start_task(task_supervisor, worker_mod, task, worker_opts) do
    if supervisor_alive?(task_supervisor) do
      {:ok,
       Task.Supervisor.async_nolink(task_supervisor, fn -> worker_mod.run(task, worker_opts) end)}
    else
      {:error, :task_supervisor_unavailable}
    end
  rescue
    error -> {:error, {:task_start_exception, error}}
  catch
    :exit, reason -> {:error, {:task_start_exit, reason}}
  end

  defp finish_worker(ref, result, state) do
    case pop_in(state.refs[ref]) do
      {nil, state} ->
        state

      {%{board_id: board_id, task_id: task_id, lease_id: lease_id}, state} ->
        state = update_in(state.boards[board_id].running, &Map.delete(&1 || %{}, ref))

        case result do
          :ok ->
            KanbanStore.complete_leased_task(task_id, lease_id)

          {:ok, attrs} when is_map(attrs) ->
            KanbanStore.complete_leased_task(task_id, lease_id, Map.to_list(attrs))

          {:ok, _value} ->
            KanbanStore.complete_leased_task(task_id, lease_id)

          {:error, reason} ->
            KanbanStore.fail_leased_task(task_id, lease_id, inspect(reason, limit: 120))

          other ->
            KanbanStore.fail_leased_task(task_id, lease_id, inspect(other, limit: 120))
        end

        state
    end
  end

  defp schedule_tick(state, board_id, interval_ms \\ nil) do
    case Map.get(state.boards, board_id) do
      nil ->
        state

      dispatcher ->
        if dispatcher.timer, do: Process.cancel_timer(dispatcher.timer)

        timer =
          Process.send_after(
            self(),
            {:dispatch_tick, board_id},
            interval_ms || dispatcher.interval_ms
          )

        put_in(state.boards[board_id].timer, timer)
    end
  end

  defp public_dispatcher(dispatcher) do
    %{
      board_id: dispatcher.board_id,
      status: dispatcher.status,
      interval_ms: dispatcher.interval_ms,
      max_concurrency: dispatcher.max_concurrency,
      lease_ms: dispatcher.lease_ms,
      worker_id: dispatcher.worker_id,
      worker_profile: dispatcher.worker_profile,
      running_count: map_size(dispatcher.running || %{}),
      started_at_ms: dispatcher.started_at_ms
    }
  end

  defp app_env(key, default), do: Application.get_env(:lemon_automation, key, default)
  defp now_ms, do: System.system_time(:millisecond)

  defp supervisor_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp supervisor_alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp supervisor_alive?(_), do: false

  defp lease_id(task) do
    lease = task.meta["kanbanLease"] || task.meta[:kanbanLease] || %{}
    lease["id"] || lease[:id]
  end
end
