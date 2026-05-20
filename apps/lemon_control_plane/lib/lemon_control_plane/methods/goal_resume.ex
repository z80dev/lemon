defmodule LemonControlPlane.Methods.GoalResume do
  @moduledoc """
  Handler for `goal.resume`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.resume"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = param(params || %{}, "sessionKey")

    if is_nil(session_key) or String.trim(to_string(session_key)) == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      case LemonCore.GoalStore.resume(session_key, run_id: param(params, "runId")) do
        {:ok, goal} -> {:ok, format_goal(goal)}
        {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
      end
    end
  end

  defp format_goal(goal) do
    %{
      "id" => goal.id,
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "createdAtMs" => goal.created_at_ms,
      "updatedAtMs" => goal.updated_at_ms,
      "pausedAtMs" => goal.paused_at_ms,
      "continuationCount" => goal.continuation_count,
      "objectiveBytes" => byte_size(goal.objective || ""),
      "summary" => summary(goal)
    }
  end

  defp summary(goal) do
    %{
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "objectiveBytes" => byte_size(goal.objective || ""),
      "objectiveReturned" => false,
      "cleanup" => %{
        "includesObjectiveText" => false,
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil
end
