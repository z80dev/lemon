defmodule LemonAutomation.GoalLoopManager do
  @moduledoc """
  Owns supervised goal-loop calls and autonomous loop tasks.

  Stop semantics are explicit:

  * `:hard` (default) disables auto restart, aborts the currently authoritative
    judge or continuation router run once, kills the loop task, and prevents a
    later tick. Its result includes a sanitized `router_abort` status; an
    `:outcome_unknown` status means the abort may have taken effect, is not
    retried automatically, and retains ownership until durable reconciliation.
  * `:graceful` disables auto restart but lets the already bounded loop finish;
    status remains `stopping` until its task returns.

  Router run IDs are captured from the shared submit-and-wait primitive only
  after the primitive fixes the exact ID and before it enters router submission.
  That synchronous ownership claim, paired with the router's abort tombstone,
  closes the acceptance window where a hard stop previously could miss a run.
  The manager API timeout is computed above the judge/continuation wait timeout,
  avoiding a caller exit while its supervised judge is still within its
  configured deadline.
  """

  use GenServer

  alias LemonAutomation.GoalLoop
  alias LemonAgent.Workspace.GoalStore
  alias LemonCore.RunStore

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def run_once(session_key, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:run_once, session_key, opts},
      call_timeout(opts)
    )
  end

  def start_loop(session_key, opts \\ []) do
    GenServer.call(__MODULE__, {:start_loop, session_key, opts})
  end

  def stop_loop(session_key, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      {:stop_loop, session_key, Keyword.get(opts, :mode, :hard)}
    )
  end

  def status(session_key) do
    GenServer.call(__MODULE__, {:status, session_key})
  end

  @doc false
  def call_timeout(opts) when is_list(opts) do
    configured = Keyword.get(opts, :call_timeout_ms) || Keyword.get(opts, :timeout)

    if is_integer(configured) and configured > 0 do
      configured
    else
      judge_timeout = positive_timeout(Keyword.get(opts, :judge_wait_timeout_ms), 60_000)

      continuation_timeout =
        if Keyword.get(opts, :await_completion, false) do
          positive_timeout(Keyword.get(opts, :wait_timeout_ms), 300_000)
        else
          0
        end

      internal_timeout = max(judge_timeout, continuation_timeout)

      internal_timeout + 5_000
    end
  end

  @impl true
  def init(opts) do
    state =
      %{
        calls: %{},
        loops: %{},
        loop_refs: %{},
        goal_store: Keyword.get(opts, :goal_store, GoalStore),
        loop_mod: Keyword.get(opts, :loop_mod, app_env(:goal_loop_module, GoalLoop)),
        auto_scan_limit: Keyword.get(opts, :auto_scan_limit, app_env(:goal_loop_scan_limit, 50)),
        scheduler_interval_ms:
          Keyword.get(
            opts,
            :scheduler_interval_ms,
            app_env(:goal_loop_scheduler_interval_ms, 30_000)
          ),
        auto_timer: nil
      }
      |> schedule_auto_tick()

    {:ok, state}
  end

  @impl true
  def handle_call({:run_once, session_key, opts}, from, state) do
    loop_mod = state.loop_mod

    task =
      Task.Supervisor.async_nolink(LemonAutomation.TaskSupervisor, fn ->
        loop_mod.run_once(session_key, opts)
      end)

    {:noreply, put_in(state.calls[task.ref], from)}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call({:start_loop, session_key, opts}, _from, state) do
    auto? = Keyword.get(opts, :auto, false) == true

    case maybe_configure_auto(session_key, auto?, opts) do
      {:ok, _goal} ->
        start_loop_reply(session_key, opts, auto?, state)

      error ->
        {:reply, error, state}
    end
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call({:stop_loop, session_key}, from, state) do
    handle_call({:stop_loop, session_key, :hard}, from, state)
  end

  def handle_call({:stop_loop, session_key, mode}, _from, state)
      when mode in [:hard, :graceful] do
    state = restore_persisted_reconciliation(state, session_key)

    case Map.get(state.loops, session_key) do
      nil ->
        case disable_auto(session_key) do
          {:ok, goal} ->
            loop = %{
              session_key: session_key,
              status: "stopped",
              started_at_ms: nil,
              max_ticks: nil
            }

            {:reply, {:ok, %{loop: public_loop(loop), goal: goal}}, state}

          {:error, :not_auto} ->
            {:reply, {:error, :not_running}, state}

          error ->
            {:reply, error, state}
        end

      loop when mode == :graceful and loop.status != "reconciling" ->
        case safe_configure_loop_auto(state.goal_store, session_key, false) do
          {:ok, goal} ->
            loop = %{loop | status: "stopping"}
            state = put_in(state.loops[session_key], loop)

            {:reply, {:ok, %{loop: public_loop(loop), goal: goal, mode: :graceful}}, state}

          {:error, _reason} ->
            {:reply, {:error, :goal_store_unavailable}, state}
        end

      loop ->
        case safe_configure_loop_auto(state.goal_store, session_key, false) do
          {:ok, _goal} ->
            case persist_hard_stop_intent(session_key, loop, state) do
              {:ok, _goal} ->
                router_abort = abort_active_run(loop)
                stop_loop_task(loop)

                {loop, goal, state} = finish_hard_stop(session_key, loop, router_abort, state)

                {:reply,
                 {:ok,
                  %{
                    loop: public_loop(loop),
                    goal: goal,
                    mode: :hard,
                    router_abort: router_abort
                  }}, state}

              {:error, _reason} ->
                {:reply, {:error, :goal_store_unavailable}, state}
            end

          {:error, _reason} ->
            {:reply, {:error, :goal_store_unavailable}, state}
        end
    end
  end

  def handle_call({:status, session_key}, _from, state) do
    state = restore_persisted_reconciliation(state, session_key)
    state = reconcile_ambiguous_loop(session_key, state)
    loop = Map.get(state.loops, session_key)

    {:reply,
     {:ok,
      %{
        running: not is_nil(loop),
        loop: loop && public_loop(loop),
        goal: GoalStore.get(session_key),
        auto: goal_auto(GoalStore.get(session_key))
      }}, state}
  end

  def handle_call(
        {:claim_goal_loop_run, session_key, worker_pid, kind, run_id, router_mod},
        _from,
        state
      )
      when kind in [:judge, :continuation] and is_binary(run_id) do
    case Map.get(state.loops, session_key) do
      %{pid: ^worker_pid, status: "running"} = loop ->
        active_run = %{
          id: run_id,
          kind: kind,
          router_mod: router_mod,
          phase: :submitting,
          aborted: false
        }

        case safe_record_loop_status(state.goal_store, session_key, :running, run_id: run_id) do
          {:ok, _goal} ->
            {:reply, :ok, put_in(state.loops[session_key], %{loop | active_run: active_run})}

          {:error, _reason} ->
            {:reply, {:error, :goal_store_unavailable}, state}
        end

      _ ->
        {:reply, {:error, :goal_loop_stopped}, state}
    end
  end

  defp start_loop_reply(session_key, opts, auto?, state) do
    state = restore_persisted_reconciliation(state, session_key)
    state = reconcile_ambiguous_loop(session_key, state)

    cond do
      Map.has_key?(state.loops, session_key) ->
        loop = Map.fetch!(state.loops, session_key)
        reply = if auto?, do: {:ok, public_loop(loop)}, else: {:error, :already_running}
        {:reply, reply, state}

      true ->
        case start_loop_task(session_key, opts, state) do
          {:ok, loop, state} -> {:reply, {:ok, public_loop(loop)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp safe_configure_loop_auto(goal_store, session_key, enabled) do
    goal_store.configure_loop_auto(session_key, enabled)
  rescue
    _error -> {:error, :goal_store_unavailable}
  catch
    _kind, _reason -> {:error, :goal_store_unavailable}
  end

  defp safe_record_loop_status(goal_store, session_key, status, opts) do
    goal_store.record_loop_status(session_key, status, opts)
  rescue
    _error -> {:error, :goal_store_unavailable}
  catch
    _kind, _reason -> {:error, :goal_store_unavailable}
  end

  @impl true
  def handle_info(:auto_tick, state) do
    state =
      state
      |> reconcile_ambiguous_loops()
      |> start_due_auto_loops()
      |> schedule_auto_tick()

    {:noreply, state}
  end

  def handle_info(
        {:goal_loop_run_started, session_key, worker_pid, kind, run_id, router_mod},
        state
      ) do
    case Map.get(state.loops, session_key) do
      %{pid: ^worker_pid} = loop when is_binary(run_id) ->
        active_run = %{
          id: run_id,
          kind: kind,
          router_mod: router_mod,
          phase: :accepted,
          aborted: false
        }

        _ = GoalStore.record_loop_status(session_key, :running, run_id: run_id)
        {:noreply, put_in(state.loops[session_key], %{loop | active_run: active_run})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:goal_loop_run_terminal, session_key, worker_pid, run_id}, state) do
    case Map.get(state.loops, session_key) do
      %{pid: ^worker_pid, active_run: %{id: ^run_id}} = loop ->
        {:noreply, put_in(state.loops[session_key], %{loop | active_run: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) do
    Process.demonitor(ref, [:flush])

    case pop_in(state.calls[ref]) do
      {nil, state} ->
        {:noreply, finish_loop(ref, result, state)}

      {from, state} ->
        GenServer.reply(from, result)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case pop_in(state.calls[ref]) do
      {nil, state} ->
        {:noreply, finish_loop(ref, {:error, :loop_task_down}, state)}

      {from, state} ->
        GenServer.reply(from, {:error, :loop_task_down})
        {:noreply, state}
    end
  end

  defp ensure_active_goal(session_key) do
    case GoalStore.get(session_key) do
      %{} = goal when map_size(goal) == 0 -> {:error, :not_found}
      %{status: "paused"} -> {:error, :paused}
      %{status: "completed"} -> {:error, :completed}
      goal -> {:ok, goal}
    end
  end

  defp finish_loop(ref, result, state) do
    session_key = get_in(state, [:loop_refs, ref])

    if session_key do
      case retained_run_after_worker_down(result, session_key, state) ||
             ambiguous_submission_run_id(result) do
        run_id when is_binary(run_id) ->
          retain_reconciliation(session_key, ref, run_id, state)

        nil ->
          status = loop_result_status(result)
          opts = if status == :error, do: [error: inspect(result, limit: 120)], else: []
          GoalStore.record_loop_status(session_key, status, opts)

          state
          |> update_in([:loops], &Map.delete(&1, session_key))
          |> update_in([:loop_refs], &Map.delete(&1 || %{}, ref))
      end
    else
      state
    end
  end

  defp retained_run_after_worker_down({:error, :loop_task_down}, session_key, state),
    do: get_in(state, [:loops, session_key, :active_run, :id])

  defp retained_run_after_worker_down(_result, _session_key, _state), do: nil

  defp retain_reconciliation(session_key, ref, run_id, state) do
    case get_in(state, [:loops, session_key]) do
      %{active_run: %{id: ^run_id}} = loop ->
        _ =
          GoalStore.record_loop_status(session_key, :reconciling,
            run_id: run_id,
            error: "submission outcome unknown"
          )

        loop = %{loop | status: "reconciling", ref: nil, pid: nil}

        state
        |> put_in([:loops, session_key], loop)
        |> update_in([:loop_refs], &Map.delete(&1 || %{}, ref))

      _ ->
        state
        |> update_in([:loops], &Map.delete(&1, session_key))
        |> update_in([:loop_refs], &Map.delete(&1 || %{}, ref))
    end
  end

  defp finish_hard_stop(session_key, loop, router_abort, state)
       when router_abort in [:accepted, :not_needed] do
    {:ok, goal} =
      GoalStore.record_loop_status(session_key, :stopped, run_id: active_run_id(loop))

    state =
      state
      |> update_in([:loops], &Map.delete(&1, session_key))
      |> update_in([:loop_refs], &Map.delete(&1 || %{}, loop.ref))

    {%{loop | status: "stopped"}, goal, state}
  end

  defp finish_hard_stop(session_key, loop, router_abort, state) do
    loop_ref = loop.ref

    {:ok, goal} =
      GoalStore.record_loop_status(session_key, :reconciling,
        run_id: active_run_id(loop),
        error: "router abort outcome unknown",
        abort_attempted: true,
        abort_result: router_abort
      )

    active_run =
      case loop.active_run do
        %{} = active_run -> Map.merge(active_run, %{aborted: true, abort_result: router_abort})
        nil -> nil
      end

    loop = %{loop | status: "reconciling", pid: nil, ref: nil, active_run: active_run}

    state =
      state
      |> put_in([:loops, session_key], loop)
      |> update_in([:loop_refs], &Map.delete(&1 || %{}, loop_ref))

    {loop, goal, state}
  end

  defp persist_hard_stop_intent(session_key, loop, state) do
    case active_run_id(loop) do
      run_id when is_binary(run_id) ->
        safe_record_loop_status(state.goal_store, session_key, :reconciling,
          run_id: run_id,
          error: "router abort in progress",
          abort_attempted: true,
          abort_result: :outcome_unknown
        )

      _no_active_run ->
        {:ok, nil}
    end
  end

  defp reconcile_ambiguous_loops(state) do
    state =
      GoalStore.list(status: "active", limit: state.auto_scan_limit)
      |> Enum.reduce(state, fn goal, state ->
        restore_persisted_reconciliation(state, goal.session_key)
      end)

    Enum.reduce(Map.keys(state.loops), state, &reconcile_ambiguous_loop/2)
  rescue
    _error -> state
  end

  defp restore_persisted_reconciliation(state, session_key)
       when is_map(state) and is_binary(session_key) do
    if Map.has_key?(state.loops, session_key) do
      state
    else
      goal = GoalStore.get(session_key)
      persisted = get_in(goal, [:meta, "goalLoop"]) || %{}
      run_id = persisted["lastRunId"]

      if persisted["status"] in ["reconciling", "running"] and is_binary(run_id) do
        _ =
          GoalStore.record_loop_status(session_key, :reconciling,
            run_id: run_id,
            error: "run ownership restored after manager restart"
          )

        abort_result = persisted_abort_result(persisted)

        loop = %{
          session_key: session_key,
          ref: nil,
          pid: nil,
          status: "reconciling",
          active_run: %{
            id: run_id,
            kind: nil,
            router_mod: LemonCore.RouterBridge,
            phase: :reconciling,
            aborted: persisted["abortAttempted"] == true,
            abort_result: abort_result
          },
          started_at_ms: persisted["startedAtMs"],
          max_ticks: nil
        }

        put_in(state.loops[session_key], loop)
      else
        state
      end
    end
  rescue
    _error -> state
  end

  defp persisted_abort_result(%{"abortResult" => result}) when is_binary(result) do
    case result do
      "accepted" -> :accepted
      "unavailable" -> :unavailable
      "rejected" -> :rejected
      _ -> :outcome_unknown
    end
  end

  defp persisted_abort_result(_persisted), do: :outcome_unknown

  defp reconcile_ambiguous_loop(session_key, state) do
    case get_in(state, [:loops, session_key]) do
      %{status: "reconciling", active_run: %{id: run_id}} when is_binary(run_id) ->
        case RunStore.get(run_id) do
          %{summary: summary} when not is_nil(summary) ->
            _ = GoalStore.configure_loop_auto(session_key, false)

            _ =
              GoalStore.record_loop_status(session_key, :error,
                run_id: run_id,
                error: "ambiguous submission reached terminal state; restart required"
              )

            update_in(state.loops, &Map.delete(&1, session_key))

          _ ->
            state
        end

      _ ->
        state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp ambiguous_submission_run_id({:error, reason}), do: ambiguous_submission_run_id(reason)

  defp ambiguous_submission_run_id({:submission_outcome_unknown, run_id})
       when is_binary(run_id),
       do: run_id

  defp ambiguous_submission_run_id({:completion_outcome_unknown, run_id})
       when is_binary(run_id),
       do: run_id

  defp ambiguous_submission_run_id({:judge_failed, reason}),
    do: ambiguous_submission_run_id(reason)

  defp ambiguous_submission_run_id(_result), do: nil

  defp loop_result_status({:ok, %{status: :limit_reached}}), do: :limit_reached
  defp loop_result_status({:ok, _result}), do: :finished
  defp loop_result_status({:error, _reason}), do: :error
  defp loop_result_status(_), do: :error

  defp start_loop_task(session_key, opts, state) do
    with {:ok, _goal} <- ensure_active_goal(session_key),
         {:ok, _goal} <- GoalStore.record_loop_status(session_key, :running, opts) do
      loop_mod = state.loop_mod
      manager = self()
      continuation_router = Keyword.get(opts, :router_mod, LemonRouter)
      judge_router = Keyword.get(opts, :judge_router_mod, LemonRouter)

      opts =
        opts
        |> Keyword.put(:on_submitting, fn run_id ->
          GenServer.call(
            manager,
            {:claim_goal_loop_run, session_key, self(), :continuation, run_id,
             continuation_router}
          )
        end)
        |> Keyword.put(:on_submitted, fn run_id ->
          send(
            manager,
            {:goal_loop_run_started, session_key, self(), :continuation, run_id,
             continuation_router}
          )
        end)
        |> Keyword.put(:on_terminal, fn run_id ->
          send(manager, {:goal_loop_run_terminal, session_key, self(), run_id})
        end)
        |> Keyword.put(:judge_on_submitting, fn run_id ->
          GenServer.call(
            manager,
            {:claim_goal_loop_run, session_key, self(), :judge, run_id, judge_router}
          )
        end)
        |> Keyword.put(:judge_on_submitted, fn run_id ->
          send(
            manager,
            {:goal_loop_run_started, session_key, self(), :judge, run_id, judge_router}
          )
        end)
        |> Keyword.put(:judge_on_terminal, fn run_id ->
          send(manager, {:goal_loop_run_terminal, session_key, self(), run_id})
        end)

      task =
        Task.Supervisor.async_nolink(LemonAutomation.TaskSupervisor, fn ->
          loop_mod.run_autonomous(session_key, opts)
        end)

      loop = %{
        session_key: session_key,
        ref: task.ref,
        pid: task.pid,
        status: "running",
        active_run: nil,
        started_at_ms: now_ms(),
        max_ticks: Keyword.get(opts, :max_ticks, 3)
      }

      state =
        state
        |> put_in([:loops, session_key], loop)
        |> put_in([:loop_refs, task.ref], session_key)

      {:ok, loop, state}
    end
  end

  defp maybe_configure_auto(_session_key, false, _opts), do: {:ok, nil}

  defp maybe_configure_auto(session_key, true, opts) do
    with {:ok, _goal} <- ensure_active_goal(session_key) do
      GoalStore.configure_loop_auto(session_key, true, opts)
    end
  end

  defp disable_auto(session_key) do
    goal = GoalStore.get(session_key)

    cond do
      goal == %{} ->
        {:error, :not_auto}

      loop_auto_enabled?(goal) ->
        GoalStore.configure_loop_auto(session_key, false)

      true ->
        {:error, :not_auto}
    end
  end

  defp start_due_auto_loops(state) do
    GoalStore.list(status: "active", limit: state.auto_scan_limit)
    |> Enum.reduce(state, fn goal, state ->
      if loop_auto_enabled?(goal) and not Map.has_key?(state.loops, goal.session_key) and
           not budget_exhausted?(goal) do
        case start_loop_task(goal.session_key, goal_auto_opts(goal), state) do
          {:ok, _loop, state} -> state
          {:error, _reason} -> state
        end
      else
        state
      end
    end)
  rescue
    _error -> state
  end

  defp schedule_auto_tick(%{scheduler_interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    %{state | auto_timer: Process.send_after(self(), :auto_tick, interval_ms)}
  end

  defp schedule_auto_tick(state), do: state

  defp goal_auto(%{} = goal) when map_size(goal) == 0, do: %{"enabled" => false}

  defp goal_auto(goal) do
    case get_in(goal, [:meta, "goalLoop", "auto"]) || get_in(goal, [:meta, :goalLoop, :auto]) do
      %{} = auto -> auto
      _ -> %{"enabled" => false}
    end
  end

  defp loop_auto_enabled?(goal), do: goal_auto(goal)["enabled"] == true

  defp goal_auto_opts(goal) do
    goal
    |> goal_auto()
    |> Map.get("options", %{})
    |> Enum.reduce([], fn
      {"maxTicks", value}, opts when is_integer(value) and value > 0 ->
        Keyword.put(opts, :max_ticks, value)

      {"maxContinuations", value}, opts when is_integer(value) and value >= 0 ->
        Keyword.put(opts, :max_continuations, value)

      {"intervalMs", value}, opts when is_integer(value) and value >= 0 ->
        Keyword.put(opts, :interval_ms, value)

      {"waitTimeoutMs", value}, opts when is_integer(value) and value > 0 ->
        Keyword.put(opts, :wait_timeout_ms, value)

      {"judgeModel", value}, opts when is_binary(value) ->
        Keyword.put(opts, :judge_model, value)

      {"judgeFailurePolicy", value}, opts ->
        case policy(value) do
          nil -> opts
          policy -> Keyword.put(opts, :judge_failure_policy, policy)
        end

      {"model", value}, opts when is_binary(value) ->
        Keyword.put(opts, :model, value)

      {_key, _value}, opts ->
        opts
    end)
  end

  defp policy("continue_once"), do: :continue_once
  defp policy("needs_input"), do: :needs_input
  defp policy("pause"), do: :pause
  defp policy(_), do: nil

  defp budget_exhausted?(%{budget: %{} = budget, continuation_count: count}) do
    case budget["max_continuations"] || budget[:max_continuations] do
      max when is_integer(max) -> (count || 0) >= max
      _ -> false
    end
  end

  defp budget_exhausted?(_), do: false

  defp public_loop(loop) do
    %{
      session_key: loop.session_key,
      status: loop.status,
      started_at_ms: loop.started_at_ms,
      max_ticks: loop.max_ticks,
      active_run_id: active_run_id(loop),
      active_run_kind: get_in(loop, [:active_run, :kind])
    }
  end

  defp abort_active_run(%{active_run: %{aborted: true, abort_result: abort_result}}),
    do: abort_result

  defp abort_active_run(%{active_run: %{id: run_id, router_mod: router_mod}})
       when is_binary(run_id) do
    result =
      cond do
        function_exported?(router_mod, :abort_run, 2) ->
          router_mod.abort_run(run_id, :goal_loop_hard_stop)

        function_exported?(router_mod, :abort_run, 1) ->
          router_mod.abort_run(run_id)

        true ->
          LemonCore.RouterBridge.abort_run(run_id, :goal_loop_hard_stop)
      end

    normalize_abort_result(result)
  rescue
    _error -> :outcome_unknown
  catch
    _kind, _reason -> :outcome_unknown
  end

  defp abort_active_run(_loop), do: :not_needed

  defp stop_loop_task(loop) do
    if is_reference(loop.ref), do: Process.demonitor(loop.ref, [:flush])
    if is_pid(loop.pid) and Process.alive?(loop.pid), do: Process.exit(loop.pid, :kill)
    :ok
  end

  defp normalize_abort_result(:ok), do: :accepted
  defp normalize_abort_result({:error, :outcome_unknown}), do: :outcome_unknown
  defp normalize_abort_result({:error, :unavailable}), do: :unavailable
  defp normalize_abort_result({:error, _reason}), do: :rejected
  defp normalize_abort_result(_malformed_acknowledgement), do: :outcome_unknown

  defp active_run_id(%{active_run: %{id: run_id}}), do: run_id
  defp active_run_id(_loop), do: nil

  defp positive_timeout(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value, default), do: default

  defp app_env(key, default), do: Application.get_env(:lemon_automation, key, default)

  defp now_ms, do: System.system_time(:millisecond)
end
