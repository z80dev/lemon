defmodule LemonControlPlane.Methods.GoalLoopStatus do
  @moduledoc """
  Handler for `goal.loop.status`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.loop.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    session_key = param(params, "sessionKey")

    cond do
      missing?(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      true ->
        case loop_mod().status(session_key) do
          {:ok, result} -> {:ok, format_result(result)}
          {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
        end
    end
  end

  defp format_result(%{running: running, loop: loop, goal: goal} = result) do
    %{
      "running" => running,
      "loop" => loop && format_loop(loop),
      "goal" => format_goal(goal),
      "auto" => result[:auto] || %{"enabled" => false},
      "summary" => loop_status_summary(running, loop, goal)
    }
  end

  defp format_loop(loop) do
    %{
      "sessionKey" => loop[:session_key],
      "status" => loop[:status],
      "startedAtMs" => loop[:started_at_ms],
      "maxTicks" => loop[:max_ticks]
    }
  end

  defp format_goal(%{} = goal) when map_size(goal) == 0, do: nil

  defp format_goal(goal) do
    %{
      "id" => goal.id,
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "updatedAtMs" => goal.updated_at_ms,
      "lastRunId" => goal.last_run_id,
      "continuationCount" => goal.continuation_count,
      "objectiveBytes" => byte_size(goal.objective || "")
    }
  end

  defp loop_status_summary(running, loop, goal) do
    formatted_goal = format_goal(goal)

    %{
      "running" => running,
      "sessionKey" => loop && loop[:session_key],
      "loopStatus" => loop && loop[:status],
      "goalStatus" => formatted_goal && formatted_goal["status"],
      "objectiveBytes" => if(formatted_goal, do: formatted_goal["objectiveBytes"], else: 0),
      "objectiveReturned" => false,
      "cleanup" => cleanup_summary()
    }
  end

  defp cleanup_summary do
    %{
      "includesObjectiveText" => false,
      "includesPromptText" => false,
      "includesMessageBodies" => false,
      "includesCredentials" => false,
      "includesSecretValues" => false
    }
  end

  defp loop_mod do
    Application.get_env(:lemon_control_plane, :goal_loop_module, LemonAutomation.GoalLoopManager)
  end

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
