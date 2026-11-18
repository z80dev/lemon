defmodule LemonAutomation.KanbanDispatcher do
  @moduledoc """
  Supervised dispatcher for durable Kanban task leases.

  `stop_board/2` kills owned waiters and aborts their claimed router runs.
  Unsubmitted leases are reclaimed; ambiguous submissions and aborts retain
  durable run ownership until reconciliation. Exact-lease terminal writes
  prevent an obsolete worker from terminalizing a newer lease.

  Starting a board reclaims only unsubmitted leases left by the same worker
  ID. Tracked invocations reconcile against durable run completion instead.

  Operator callers may pass `expected_revision:` from `status/2` to start or
  stop. The manager checks it before mutation, binding confirmation to the board,
  its durable cards and the exact dispatcher invocation and owned workers.
  Drift returns `{:error, :stale}` without touching the replacement invocation.

  A board without recorded `LemonAgent.Workspace.KanbanAuthority` is
  quarantined: `start_board/2` returns `{:error, :kanban_authority_missing}`.
  Only the operator surfaces `reauthorize_board/2` (idle boards only) and
  `share_board/3`, both bound to `expected_revision:`, change authority here.
  Control paths use the lease-recorded `meta.kanbanRun.runId`.
  """

  use GenServer

  alias LemonAgent.Workspace.{KanbanAuthority, KanbanStore}
  alias LemonAutomation.{KanbanCodingWorkflow, KanbanGitWorkflow}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def start_board(board_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:start_board, board_id, opts, Keyword.get(opts, :expected_revision)}
    )
  end

  def stop_board(board_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:stop_board, board_id, Keyword.get(opts, :expected_revision)}
    )
  end

  def status(board_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:status, board_id})
  end

  @doc "Operator path: grant operator authority to an idle (e.g. quarantined) board."
  def reauthorize_board(board_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:operator_authority, board_id, :reauthorize, Keyword.fetch!(opts, :expected_revision)}
    )
  end

  @doc "Operator path: share a board with another trusted session key."
  def share_board(board_id, session_key, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:operator_authority, board_id, {:share, session_key},
       Keyword.fetch!(opts, :expected_revision)}
    )
  end

  @doc """
  What a publication grant for `board_id` would authorize right now: the
  requested settings, the destinations resolved from the board workspace's
  remote configuration (exact push URLs, PR repository and base) and the
  `digest` binding both (`KanbanAuthority.publish_digest/2`).
  """
  def publication_preview(board_id, opts \\ []) do
    board = KanbanStore.get_board(board_id)
    settings = get_in(board, [:meta, "codingWorkflow", "publish"])

    with true <- is_map(settings) or {:error, :publication_not_requested},
         {:ok, authority} <- KanbanAuthority.fetch(board),
         {:ok, workspace} <- KanbanAuthority.check_workspace(authority, board[:workspace]),
         {:ok, destinations} <-
           KanbanGitWorkflow.resolve_destinations(
             workspace,
             settings,
             Keyword.take(opts, [:runner, :task_supervisor])
           ) do
      {:ok,
       %{
         settings: settings,
         destinations: destinations,
         digest: KanbanAuthority.publish_digest(settings, destinations)
       }}
    end
  end

  @doc """
  Operator path: grant publication for the board's requested settings and the
  destinations resolved now. Bound to `expected_revision:` and to the
  `publish_digest:` of the previewed settings and destinations: a remote URL
  that changed since the preview refuses with `:stale`.
  """
  def grant_publication(board_id, opts \\ []) do
    with {:ok, %{destinations: destinations}} <- publication_preview(board_id, opts) do
      GenServer.call(
        Keyword.get(opts, :name, __MODULE__),
        {:operator_authority, board_id,
         {:publish, Keyword.fetch!(opts, :publish_digest), destinations},
         Keyword.fetch!(opts, :expected_revision)}
      )
    end
  end

  @doc """
  Operator path: allow in-place execution in the board's workspace (non-Git
  workspaces). Bound to `expected_revision:` and to the previewed
  `workspace_digest:` (`KanbanAuthority.workspace_digest/1`).
  """
  def grant_in_place(board_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:operator_authority, board_id, {:in_place, Keyword.fetch!(opts, :workspace_digest)},
       Keyword.fetch!(opts, :expected_revision)}
    )
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
  def handle_call({:start_board, board_id, opts, expected}, from, state) do
    if is_nil(expected) or expected == control_revision(board_id, state) do
      handle_call({:start_board, board_id, opts}, from, state)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:start_board, board_id, opts}, _from, state) do
    case KanbanStore.get_board(board_id) do
      %{} = board when map_size(board) == 0 ->
        {:reply, {:error, :board_not_found}, state}

      board ->
        cond do
          Map.has_key?(state.boards, board_id) ->
            {:reply, {:error, :already_running}, state}

          match?({:error, _}, KanbanAuthority.fetch(board)) ->
            {:reply, {:error, :kanban_authority_missing}, state}

          true ->
            worker_id = Keyword.get(opts, :worker_id, "kanban-dispatcher")
            {:ok, _reclaimed} = KanbanStore.reclaim_worker_leases(board_id, worker_id)

            dispatcher = %{
              board_id: board.id,
              invocation_id: make_ref(),
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

  def handle_call({:operator_authority, board_id, change, expected}, _from, state) do
    reply =
      cond do
        expected != control_revision(board_id, state) ->
          {:error, :stale}

        change == :reauthorize and Map.has_key?(state.boards, board_id) ->
          {:error, :already_running}

        change == :reauthorize ->
          KanbanStore.reauthorize_board(board_id)

        match?({:in_place, _}, change) ->
          {:in_place, digest} = change
          KanbanStore.grant_in_place(board_id, digest)

        match?({:publish, _, _}, change) ->
          {:publish, digest, destinations} = change
          KanbanStore.grant_publication(board_id, digest, destinations)

        true ->
          {:share, session_key} = change
          KanbanStore.share_board(board_id, session_key)
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_run, task_id, lease_id, run_id, attrs}, _from, state) do
    owner =
      Enum.find(state.refs, fn {_ref, worker} ->
        worker.task_id == task_id and worker.lease_id == lease_id
      end)

    reply =
      case owner do
        nil ->
          {:error, :lease_not_owned}

        _ when is_map(attrs) ->
          task = KanbanStore.get_task(task_id)

          if get_in(task, [:meta, "codingWorkflow", "cancelRequested"]) == true do
            {:error, :cancelled}
          else
            case KanbanStore.track_leased_run(task_id, lease_id, run_id, attrs) do
              {:ok, _task} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:checkpoint_workflow, task_id, lease_id, checkpoint}, _from, state) do
    owned? =
      Enum.any?(state.refs, fn {_, worker} ->
        worker.task_id == task_id and worker.lease_id == lease_id
      end)

    task = KanbanStore.get_task(task_id)
    cancelled? = get_in(task, [:meta, "codingWorkflow", "cancelRequested"]) == true

    result =
      cond do
        not owned? ->
          {:error, :lease_not_owned}

        cancelled? and checkpoint["cancelRequested"] != true ->
          {:error, :cancelled}

        true ->
          case KanbanStore.checkpoint_leased_workflow(task_id, lease_id, checkpoint) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end

    {:reply, result, state}
  end

  def handle_call({:stop_board, board_id, expected}, from, state) do
    if is_nil(expected) or expected == control_revision(board_id, state) do
      handle_call({:stop_board, board_id}, from, state)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:stop_board, board_id}, _from, state) do
    case Map.get(state.boards, board_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      dispatcher ->
        case mark_workflow_cancellations(board_id) do
          :ok ->
            if dispatcher.timer, do: Process.cancel_timer(dispatcher.timer)

            state =
              dispatcher.running
              |> Enum.reduce(state, fn {ref, worker}, acc ->
                Process.exit(worker.pid, :kill)
                Process.demonitor(ref, [:flush])
                task = KanbanStore.get_task(worker.task_id)

                if not tracked_run?(task),
                  do: KanbanStore.reclaim_task_lease(worker.task_id, worker.lease_id)

                update_in(acc.refs, &Map.delete(&1, ref))
              end)
              |> update_in([:boards], &Map.delete(&1, board_id))

            aborts =
              KanbanStore.list_tasks(board_id, limit: 10_000)
              |> Enum.filter(&tracked_run?/1)
              |> Enum.map(fn task ->
                workflow? = KanbanCodingWorkflow.workflow?(task)
                phase = get_in(task, [:meta, "codingWorkflow", "phase"])

                result =
                  if workflow? and phase not in ["coding", "review"],
                    do: :outcome_unknown,
                    else: request_abort(task, dispatcher.worker_opts)

                if workflow? do
                  mark_unknown(task.id, lease_id(task))
                else
                  if result == :ok,
                    do: fail_card(task.id, lease_id(task), "cancelled")
                end

                result = if workflow? and result == :ok, do: :outcome_unknown, else: result

                %{run_id: tracked_run_id(task), result: result}
              end)

            if Enum.any?(aborts, &(&1.result == :outcome_unknown)),
              do: Process.send_after(self(), {:reconcile_stopped, board_id}, 1_000)

            stopped = public_dispatcher(%{dispatcher | status: "stopped", running: %{}})
            {:reply, {:ok, Map.put(stopped, :aborts, aborts)}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:status, board_id}, _from, state) do
    dispatcher = Map.get(state.boards, board_id)
    reconcile_board(board_id, if(dispatcher, do: dispatcher.running, else: %{}))

    {:reply,
     {:ok,
      %{
        running: not is_nil(dispatcher),
        control_revision: control_revision(board_id, state),
        reconciling_count:
          length(unowned_runs(board_id, if(dispatcher, do: dispatcher.running, else: %{}))),
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

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_worker(ref, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, finish_worker(ref, {:worker_down, :worker_crashed}, state)}
  end

  def handle_info({:reconcile_stopped, board_id}, state) do
    if not Map.has_key?(state.boards, board_id) do
      reconcile_board(board_id, %{})

      if unowned_runs(board_id, %{}) != [],
        do: Process.send_after(self(), {:reconcile_stopped, board_id}, 1_000)
    end

    {:noreply, state}
  end

  defp dispatch_board(state, board_id) do
    case Map.get(state.boards, board_id) do
      nil ->
        state

      dispatcher ->
        reconcile_board(board_id, dispatcher.running)
        state = resume_workflows(state, board_id)
        dispatcher = Map.fetch!(state.boards, board_id)
        # Renew before expiry reclamation. Only monitored workers still alive in
        # this VM are authoritative; recovered/unknown runs retain normal recovery.
        Enum.each(dispatcher.running, fn {_ref, worker} ->
          if Process.alive?(worker.pid) do
            KanbanStore.renew_task_lease(worker.task_id, worker.lease_id,
              lease_ms: dispatcher.lease_ms
            )
          end
        end)

        {:ok, _reclaimed} = KanbanStore.reclaim_expired_leases(board_id)
        reconciling = length(unowned_runs(board_id, dispatcher.running))

        available =
          max(dispatcher.max_concurrency - map_size(dispatcher.running) - reconciling, 0)

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
        start_leased_worker(state, board_id, task)

      {:error, :no_available_task} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp mark_workflow_cancellations(board_id) do
    case KanbanStore.list_tasks(board_id, limit: 10_000, strict: true) do
      {:ok, tasks} ->
        tasks
        |> Enum.filter(&(tracked_run?(&1) and KanbanCodingWorkflow.workflow?(&1)))
        |> Enum.reduce_while(:ok, fn task, :ok ->
          checkpoint = Map.put(task.meta["codingWorkflow"], "cancelRequested", true)

          case KanbanStore.checkpoint_leased_workflow(task.id, lease_id(task), checkpoint) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} -> {:halt, {:error, :cancel_intent_unavailable}}
          end
        end)

      _ ->
        {:error, :cancel_intent_unavailable}
    end
  end

  defp start_leased_worker(state, board_id, task) do
    dispatcher = Map.fetch!(state.boards, board_id)
    lease_id = lease_id(task)
    owner = self()

    worker_opts =
      dispatcher.worker_opts
      |> Keyword.put(:on_submitting, fn run_id, attrs ->
        GenServer.call(owner, {:claim_run, task.id, lease_id, run_id, attrs})
      end)
      |> Keyword.put(:on_checkpoint, fn checkpoint ->
        GenServer.call(owner, {:checkpoint_workflow, task.id, lease_id, checkpoint})
      end)

    case start_task(state.task_supervisor, dispatcher.worker_mod, task, worker_opts) do
      {:ok, task_ref} ->
        worker = %{task_id: task.id, lease_id: lease_id, pid: task_ref.pid}

        state
        |> put_in([:refs, task_ref.ref], Map.put(worker, :board_id, board_id))
        |> put_in([:boards, board_id, :running, task_ref.ref], worker)

      {:error, _reason} ->
        if not tracked_run?(task), do: KanbanStore.reclaim_task_lease(task.id, lease_id)
        state
    end
  end

  defp resume_workflows(state, board_id) do
    dispatcher = Map.fetch!(state.boards, board_id)
    capacity = max(dispatcher.max_concurrency - map_size(dispatcher.running), 0)

    unowned_runs(board_id, dispatcher.running)
    |> Enum.filter(
      &(KanbanCodingWorkflow.workflow?(&1) and KanbanCodingWorkflow.ready_to_resume?(&1))
    )
    |> Enum.take(capacity)
    |> Enum.reduce(state, fn task, acc -> start_leased_worker(acc, board_id, task) end)
  end

  defp start_task(task_supervisor, worker_mod, task, worker_opts) do
    LemonCore.TaskSupervisor.async_nolink(task_supervisor, fn ->
      worker_mod.run(task, worker_opts)
    end)
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
            complete_card(task_id, lease_id)

          {:ok, attrs} when is_map(attrs) ->
            complete_card(task_id, lease_id, Map.to_list(attrs))

          {:ok, _value} ->
            complete_card(task_id, lease_id)

          {:outcome_unknown, _run_id} ->
            mark_unknown(task_id, lease_id)

          {:worker_down, reason} ->
            if tracked_run?(KanbanStore.get_task(task_id)) do
              mark_unknown(task_id, lease_id)
            else
              fail_card(task_id, lease_id, Atom.to_string(reason))
            end

          {:error, reason} ->
            fail_card(task_id, lease_id, failure_class(reason))

          _other ->
            fail_card(task_id, lease_id, "invalid_worker_result")
        end

        state
    end
  end

  defp reconcile_board(board_id, running) do
    unowned_runs(board_id, running)
    |> Enum.each(fn task ->
      if KanbanCodingWorkflow.workflow?(task) do
        checkpoint = task.meta["codingWorkflow"]

        if checkpoint["cancelRequested"] == true and checkpoint["phase"] != "publish_pending" and
             KanbanCodingWorkflow.ready_to_resume?(task) do
          fail_card(task.id, lease_id(task), "cancelled")
        end
      else
        case LemonCore.RunStore.get(tracked_run_id(task)) do
          %{summary: summary} when not is_nil(summary) ->
            case LemonAutomation.RunCompletionWaiter.extract_output_from_completion(summary) do
              {:ok, output} ->
                complete_card(task.id, lease_id(task),
                  run_id: tracked_run_id(task),
                  output: output
                )

              {:error, _reason} ->
                fail_card(task.id, lease_id(task), "run_failed")
            end

          _ ->
            :ok
        end
      end
    end)
  end

  defp complete_card(task_id, lease_id, opts \\ []) do
    notify_card(KanbanStore.complete_leased_task(task_id, lease_id, opts), lease_id)
  end

  defp fail_card(task_id, lease_id, reason) do
    notify_card(KanbanStore.fail_leased_task(task_id, lease_id, reason), lease_id)
  end

  defp notify_card({:ok, task} = result, lease_id) do
    LemonAutomation.RunNotifications.kanban_finished(task, lease_id)
    result
  end

  defp notify_card(result, _lease_id), do: result

  defp unowned_runs(board_id, running) do
    active = MapSet.new(Enum.map(running, fn {_ref, worker} -> worker.task_id end))

    KanbanStore.list_tasks(board_id, limit: 10_000)
    |> Enum.filter(&(tracked_run?(&1) and not MapSet.member?(active, &1.id)))
  end

  defp mark_unknown(task_id, lease_id) do
    task = KanbanStore.get_task(task_id)
    attrs = Map.put(task.meta["kanbanRun"], "status", "outcome_unknown")
    KanbanStore.track_leased_run(task_id, lease_id, tracked_run_id(task), attrs)
  end

  defp request_abort(task, opts) do
    run = task.meta["kanbanRun"]

    if run["abortRequested"] do
      :outcome_unknown
    else
      attrs = run |> Map.put("abortRequested", true) |> Map.put("status", "outcome_unknown")

      case KanbanStore.track_leased_run(task.id, lease_id(task), run["runId"], attrs) do
        {:ok, _} -> abort_run(run["runId"], opts)
        _ -> :outcome_unknown
      end
    end
  end

  defp tracked_run?(task),
    do: get_in(task, [:meta, "kanbanRun", "status"]) in ["running", "outcome_unknown"]

  # The router invocation recorded under the exact lease by `track_leased_run/4`;
  # the card's top-level `run_id` is a projection and never routes control.
  defp tracked_run_id(task), do: get_in(task, [:meta, "kanbanRun", "runId"])

  defp abort_run(run_id, opts) do
    router = Keyword.get(opts, :router_mod, LemonRouter)

    case router.abort_run(run_id, :kanban_board_stop) do
      :ok -> :ok
      _ -> :outcome_unknown
    end
  rescue
    _ -> :outcome_unknown
  catch
    _, _ -> :outcome_unknown
  end

  defp failure_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_class(_reason), do: "run_failed"

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
            interval_ms || min(dispatcher.interval_ms, max(div(dispatcher.lease_ms, 3), 1))
          )

        put_in(state.boards[board_id].timer, timer)
    end
  end

  # Bind operator confirmation to the exact dispatcher and durable leases/runs.
  defp control_revision(board_id, state) do
    dispatcher = Map.get(state.boards, board_id)

    invocation =
      dispatcher && {dispatcher.invocation_id, dispatcher.started_at_ms, dispatcher.running}

    {KanbanStore.get_board(board_id), KanbanStore.list_tasks(board_id, limit: 10_000), invocation}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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

  defp lease_id(task) do
    lease = task.meta["kanbanLease"] || task.meta[:kanbanLease] || %{}
    lease["id"] || lease[:id]
  end
end
