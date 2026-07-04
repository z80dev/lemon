defmodule LemonAutomation.GoalLoopManager do
  @moduledoc false

  use GenServer

  alias LemonAutomation.GoalLoop
  alias LemonCore.GoalStore

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def run_once(session_key, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:run_once, session_key, opts},
      Keyword.get(opts, :timeout, 30_000)
    )
  end

  def start_loop(session_key, opts \\ []) do
    GenServer.call(__MODULE__, {:start_loop, session_key, opts})
  end

  def stop_loop(session_key) do
    GenServer.call(__MODULE__, {:stop_loop, session_key})
  end

  def status(session_key) do
    GenServer.call(__MODULE__, {:status, session_key})
  end

  @impl true
  def init(opts) do
    state =
      %{
        calls: %{},
        loops: %{},
        loop_refs: %{},
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
      error -> {:reply, error, state}
    end
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call({:stop_loop, session_key}, _from, state) do
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

      loop ->
        Process.demonitor(loop.ref, [:flush])
        Process.exit(loop.pid, :shutdown)

        _ = GoalStore.configure_loop_auto(session_key, false)
        {:ok, goal} = GoalStore.record_loop_status(session_key, :stopped)

        state =
          state
          |> update_in([:loops], &Map.delete(&1, session_key))
          |> update_in([:loop_refs], &Map.delete(&1 || %{}, loop.ref))

        {:reply, {:ok, %{loop: public_loop(%{loop | status: "stopped"}), goal: goal}}, state}
    end
  end

  def handle_call({:status, session_key}, _from, state) do
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

  defp start_loop_reply(session_key, opts, auto?, state) do
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

  @impl true
  def handle_info(:auto_tick, state) do
    state =
      state
      |> start_due_auto_loops()
      |> schedule_auto_tick()

    {:noreply, state}
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
      status = loop_result_status(result)
      opts = if status == :error, do: [error: inspect(result, limit: 120)], else: []
      GoalStore.record_loop_status(session_key, status, opts)

      state
      |> update_in([:loops], &Map.delete(&1, session_key))
      |> update_in([:loop_refs], &Map.delete(&1 || %{}, ref))
    else
      state
    end
  end

  defp loop_result_status({:ok, %{status: :limit_reached}}), do: :limit_reached
  defp loop_result_status({:ok, _result}), do: :finished
  defp loop_result_status({:error, _reason}), do: :error
  defp loop_result_status(_), do: :error

  defp start_loop_task(session_key, opts, state) do
    with {:ok, _goal} <- ensure_active_goal(session_key),
         {:ok, _goal} <- GoalStore.record_loop_status(session_key, :running, opts) do
      loop_mod = state.loop_mod

      task =
        Task.Supervisor.async_nolink(LemonAutomation.TaskSupervisor, fn ->
          loop_mod.run_autonomous(session_key, opts)
        end)

      loop = %{
        session_key: session_key,
        ref: task.ref,
        pid: task.pid,
        status: "running",
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
      max_ticks: loop.max_ticks
    }
  end

  defp app_env(key, default), do: Application.get_env(:lemon_automation, key, default)

  defp now_ms, do: System.system_time(:millisecond)
end
