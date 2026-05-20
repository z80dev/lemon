defmodule LemonControlPlane.Methods.GoalStatus do
  @moduledoc """
  Handler for `goal.status`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_key = param(params, "sessionKey")

    cond do
      present?(session_key) ->
        goal = format_goal(LemonCore.GoalStore.get(session_key))

        {:ok,
         %{
           "goal" => goal,
           "summary" => status_summary(List.wrap(goal), %{"sessionKey" => session_key})
         }}

      true ->
        goals =
          LemonCore.GoalStore.list(
            agent_id: param(params, "agentId"),
            status: param(params, "status"),
            limit: param(params, "limit") || 50
          )
          |> Enum.map(&format_goal/1)

        {:ok,
         %{
           "goals" => goals,
           "total" => length(goals),
           "summary" => status_summary(goals, params)
         }}
    end
  end

  defp format_goal(%{} = goal) when map_size(goal) == 0, do: nil

  defp format_goal(goal) do
    %{
      "id" => goal.id,
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "createdAtMs" => goal.created_at_ms,
      "updatedAtMs" => goal.updated_at_ms,
      "pausedAtMs" => goal.paused_at_ms,
      "completedAtMs" => goal.completed_at_ms,
      "lastRunId" => goal.last_run_id,
      "continuationCount" => goal.continuation_count,
      "budget" => format_budget(goal.budget),
      "goalLoop" => redacted_loop(goal.meta),
      "objectiveBytes" => byte_size(goal.objective || ""),
      "summary" => goal_summary(goal)
    }
  end

  defp goal_summary(goal) do
    %{
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "objectiveBytes" => byte_size(goal.objective || ""),
      "objectiveReturned" => false,
      "cleanup" => cleanup_summary()
    }
  end

  defp status_summary(goals, params) do
    goals = Enum.reject(goals, &is_nil/1)
    statuses = goals |> Enum.map(& &1["status"]) |> Enum.reject(&is_nil/1) |> Enum.frequencies()

    %{
      "goalCount" => length(goals),
      "statuses" => statuses,
      "filteredBySessionKey" => present?(param(params, "sessionKey")),
      "filteredByAgentId" => present?(param(params, "agentId")),
      "filteredByStatus" => present?(param(params, "status")),
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

  defp format_budget(%{} = budget) do
    %{"maxContinuations" => budget["max_continuations"] || budget[:max_continuations]}
  end

  defp format_budget(_), do: %{}

  defp redacted_loop(meta) when is_map(meta) do
    loop = meta["goalLoop"] || meta[:goalLoop] || %{}

    case loop do
      %{} = loop when map_size(loop) > 0 ->
        verdict = loop["lastVerdict"] || loop[:lastVerdict] || %{}

        %{
          "status" => loop["status"] || loop[:status],
          "verdictCount" => loop["verdictCount"] || loop[:verdictCount],
          "lastAction" => verdict["action"] || verdict[:action],
          "lastSource" => verdict["source"] || verdict[:source],
          "lastRunId" =>
            verdict["runId"] || verdict[:runId] || loop["lastRunId"] || loop[:lastRunId]
        }

      _ ->
        nil
    end
  end

  defp redacted_loop(_), do: nil

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil

  defp present?(value), do: not is_nil(value) and String.trim(to_string(value)) != ""
end
