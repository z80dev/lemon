defmodule LemonAutomation.GoalJudge.RouterRunner do
  @moduledoc false

  alias LemonAutomation.RunCompletionWaiter

  def judge(goal, context) when is_map(goal) and is_map(context) do
    run_id = Map.get(context, :run_id) || LemonCore.Id.run_id()
    router_mod = Map.get(context, :router_mod, LemonRouter)
    waiter_mod = Map.get(context, :waiter_mod, RunCompletionWaiter)
    timeout_ms = Map.get(context, :wait_timeout_ms, 60_000)
    wait_opts = Map.get(context, :wait_opts, [])

    params =
      %{
        origin: :goal_judge,
        session_key: judge_session_key(goal.session_key),
        agent_id: goal.agent_id || "default",
        queue_mode: :followup,
        prompt: prompt(goal, context),
        run_id: run_id,
        meta: %{
          goal_id: goal.id,
          goal_judge: true,
          goal_objective_bytes: byte_size(goal.objective || "")
        }
      }
      |> maybe_put(:model, Map.get(context, :model))

    with {:ok, submitted_run_id} <- submit(router_mod, params),
         {:ok, output} <- waiter_mod.wait(submitted_run_id, timeout_ms, wait_opts),
         {:ok, verdict} <- parse_verdict(output) do
      {:ok, verdict}
    end
  end

  defp submit(router_mod, params) do
    case router_mod.submit(params) do
      {:ok, run_id} when is_binary(run_id) -> {:ok, run_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_submit_result, other}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp parse_verdict(output) when is_binary(output) do
    output
    |> extract_json()
    |> Jason.decode()
    |> case do
      {:ok, %{} = verdict} -> {:ok, verdict}
      {:ok, _} -> {:error, :invalid_judge_response}
      {:error, reason} -> {:error, {:invalid_judge_response, inspect(reason, limit: 80)}}
    end
  end

  defp parse_verdict(_), do: {:error, :invalid_judge_response}

  defp extract_json(output) do
    trimmed = String.trim(output)

    cond do
      String.starts_with?(trimmed, "```") ->
        trimmed
        |> String.replace_prefix("```json", "")
        |> String.replace_prefix("```", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        trimmed
    end
  end

  defp prompt(goal, context) do
    """
    You are Lemon's persistent-goal judge.

    Decide the next action for this standing goal. Return only JSON:
    {"action":"continue|done|blocked|needs_input","reason":"short reason"}

    Goal:
    #{goal.objective}

    Continuations so far: #{goal.continuation_count || 0}
    Max output chars: #{Map.get(context, :max_output_chars, 1_000)}
    """
  end

  defp judge_session_key(session_key), do: "#{session_key}:goal_judge"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
