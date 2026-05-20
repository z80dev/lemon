defmodule LemonAutomation.GoalLoop do
  @moduledoc false

  alias LemonAutomation.{GoalContinuation, GoalJudge, RunCompletionWaiter}
  alias LemonCore.GoalStore

  @spec run_once(binary(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :paused | :completed | term()}
  def run_once(session_key, opts \\ []) when is_binary(session_key) do
    with {:ok, goal} <- active_goal(session_key) do
      case judge(goal, opts) do
        {:ok, verdict} ->
          with {:ok, _goal_with_verdict} <-
                 GoalStore.record_loop_verdict(session_key, verdict_map(verdict), opts) do
            apply_verdict(session_key, verdict, opts)
          end

        {:error, reason} ->
          handle_judge_failure(session_key, goal, reason, opts)
      end
    end
  end

  @spec run_autonomous(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_autonomous(session_key, opts \\ []) when is_binary(session_key) do
    max_ticks = Keyword.get(opts, :max_ticks, 3)

    cond do
      not is_integer(max_ticks) or max_ticks < 1 ->
        {:error, :invalid_max_ticks}

      true ->
        run_autonomous_tick(session_key, opts, 0, max_ticks, nil)
    end
  end

  defp run_autonomous_tick(session_key, _opts, tick_count, max_ticks, last_result)
       when tick_count >= max_ticks do
    {:ok,
     %{
       status: :limit_reached,
       tick_count: tick_count,
       last_result: last_result,
       goal: GoalStore.get(session_key)
     }}
  end

  defp run_autonomous_tick(session_key, opts, tick_count, max_ticks, _last_result) do
    case run_once(session_key, opts) do
      {:ok, %{verdict: %{action: :continue}, run_id: run_id} = result} when is_binary(run_id) ->
        case wait_for_run(run_id, opts) do
          {:ok, _output} ->
            maybe_sleep(opts)
            run_autonomous_tick(session_key, opts, tick_count + 1, max_ticks, result)

          :timeout ->
            GoalStore.pause(session_key, run_id: run_id)
            {:error, {:run_timeout, run_id}}

          {:error, reason} ->
            GoalStore.pause(session_key, run_id: run_id)
            {:error, {:run_failed, run_id, reason}}
        end

      {:ok, %{verdict: %{action: action}} = result} ->
        {:ok,
         %{
           status: terminal_status(action),
           tick_count: tick_count + 1,
           last_result: result,
           goal: result.goal
         }}

      {:ok, result} ->
        {:ok,
         %{
           status: :finished,
           tick_count: tick_count + 1,
           last_result: result,
           goal: result.goal
         }}

      error ->
        error
    end
  end

  defp active_goal(session_key) do
    case GoalStore.get(session_key) do
      %{} = goal when map_size(goal) == 0 -> {:error, :not_found}
      %{status: "paused"} -> {:error, :paused}
      %{status: "completed"} -> {:error, :completed}
      goal -> {:ok, goal}
    end
  end

  defp judge(goal, opts) do
    judge_mod = Keyword.get(opts, :judge_mod, GoalJudge)
    judge_mod.judge(goal, opts)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp apply_verdict(session_key, %{action: :continue} = verdict, opts) do
    case GoalContinuation.continue_once(session_key, opts) do
      {:ok, result} ->
        {:ok, Map.put(result, :verdict, verdict)}

      {:error, :budget_exhausted} ->
        GoalStore.record_loop_status(session_key, :limit_reached)
        GoalStore.pause(session_key, opts)
        {:error, :budget_exhausted}

      error ->
        error
    end
  end

  defp apply_verdict(session_key, %{action: :done} = verdict, opts) do
    with {:ok, goal} <- GoalStore.complete(session_key, opts) do
      {:ok, %{run_id: nil, goal: goal, verdict: verdict}}
    end
  end

  defp apply_verdict(session_key, %{action: action} = verdict, opts)
       when action in [:blocked, :needs_input] do
    with {:ok, goal} <- GoalStore.pause(session_key, opts) do
      {:ok, %{run_id: nil, goal: goal, verdict: verdict}}
    end
  end

  defp apply_verdict(_session_key, verdict, _opts), do: {:error, {:unsupported_verdict, verdict}}

  defp handle_judge_failure(session_key, _goal, reason, opts) do
    case Keyword.get(opts, :judge_failure_policy, :pause) do
      :continue_once ->
        verdict = %{
          action: :continue,
          reason: "judge failed; continuing once by policy",
          source: "judge_failure_policy"
        }

        with {:ok, _goal_with_verdict} <-
               GoalStore.record_loop_verdict(session_key, verdict_map(verdict), opts) do
          apply_verdict(session_key, verdict, opts)
        end

      :needs_input ->
        verdict = %{
          action: :needs_input,
          reason: "judge failed: #{inspect(reason, limit: 80)}",
          source: "judge_failure_policy"
        }

        with {:ok, _goal_with_verdict} <-
               GoalStore.record_loop_verdict(session_key, verdict_map(verdict), opts) do
          apply_verdict(session_key, verdict, opts)
        end

      _pause ->
        GoalStore.record_loop_status(session_key, :error, error: inspect(reason, limit: 80))
        GoalStore.pause(session_key, opts)
        {:error, {:judge_failed, reason}}
    end
  end

  defp wait_for_run(run_id, opts) do
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    timeout_ms = Keyword.get(opts, :wait_timeout_ms, 300_000)
    wait_opts = Keyword.get(opts, :wait_opts, [])
    waiter_mod.wait(run_id, timeout_ms, wait_opts)
  end

  defp maybe_sleep(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, 0)

    if is_integer(interval_ms) and interval_ms > 0 do
      Process.sleep(interval_ms)
    end
  end

  defp terminal_status(:done), do: :finished
  defp terminal_status(:blocked), do: :blocked
  defp terminal_status(:needs_input), do: :needs_input
  defp terminal_status(_), do: :finished

  defp verdict_map(verdict) do
    %{
      action: verdict.action,
      reason: verdict.reason,
      source: verdict.source
    }
  end
end
