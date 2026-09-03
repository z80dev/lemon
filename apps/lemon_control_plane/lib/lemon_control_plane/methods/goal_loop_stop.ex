defmodule LemonControlPlane.Methods.GoalLoopStop do
  @moduledoc """
  Handler for `goal.loop.stop`.
  """

  @behaviour LemonControlPlane.Method

  require Logger

  @router_abort_statuses [:accepted, :outcome_unknown, :unavailable, :rejected, :not_needed]

  @impl true
  def name, do: "goal.loop.stop"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = param(params, "sessionKey")

    cond do
      missing?(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      true ->
        case loop_mod().stop_loop(session_key) do
          {:ok, %{loop: loop, goal: goal} = result} when is_map(loop) and is_map(goal) ->
            {:ok, format_result(result)}

          {:ok, result} ->
            manager_error(result)

          {:error, :not_running} ->
            {:error, {:invalid_request, "Goal loop is not running", nil}}

          {:error, reason} ->
            manager_error(reason)
        end
    end
  end

  defp format_result(%{loop: loop, goal: goal} = result) do
    router_abort = format_router_abort(result)

    %{
      "loop" => format_loop(loop),
      "goal" => format_goal(goal),
      "routerAbort" => router_abort,
      "summary" => loop_stop_summary(loop, goal, router_abort)
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

  defp loop_stop_summary(loop, goal, router_abort) do
    formatted_goal = format_goal(goal)

    %{
      "sessionKey" => loop[:session_key],
      "loopStatus" => loop[:status],
      "goalStatus" => formatted_goal && formatted_goal["status"],
      "routerAbort" => router_abort,
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

  defp format_router_abort(result) do
    case Map.fetch(result, :router_abort) do
      {:ok, status} when status in @router_abort_statuses -> Atom.to_string(status)
      {:ok, _unexpected} -> "outcome_unknown"
      :error -> "not_needed"
    end
  end

  defp manager_error(reason) do
    Logger.warning("Goal loop stop failed class=#{failure_class(reason)}")
    {:error, {:internal_error, "Goal loop stop failed", nil}}
  end

  defp failure_class(%{__exception__: true, __struct__: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp failure_class(reason) when is_atom(reason), do: "atom"
  defp failure_class(reason) when is_tuple(reason), do: "tuple"
  defp failure_class(reason) when is_map(reason), do: "map"
  defp failure_class(reason) when is_list(reason), do: "list"
  defp failure_class(_reason), do: "other"

  defp loop_mod do
    Application.get_env(:lemon_control_plane, :goal_loop_module, LemonAutomation.GoalLoopManager)
  end

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
