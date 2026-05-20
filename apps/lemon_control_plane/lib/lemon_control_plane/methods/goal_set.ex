defmodule LemonControlPlane.Methods.GoalSet do
  @moduledoc """
  Handler for `goal.set`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.set"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = param(params, "sessionKey")
    objective = param(params, "objective")

    cond do
      missing?(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      missing?(objective) ->
        {:error, {:invalid_request, "objective is required", nil}}

      true ->
        case LemonCore.GoalStore.set(session_key, objective,
               agent_id: param(params, "agentId"),
               run_id: param(params, "runId"),
               budget: budget(params)
             ) do
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
      "continuationCount" => goal.continuation_count,
      "budget" => format_budget(goal.budget),
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

  defp budget(params) do
    case parse_non_negative_integer(param(params, "maxContinuations")) do
      nil -> nil
      value -> %{"max_continuations" => value}
    end
  end

  defp format_budget(%{} = budget) do
    %{"maxContinuations" => budget["max_continuations"] || budget[:max_continuations]}
  end

  defp format_budget(_), do: %{}

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_non_negative_integer(_), do: nil

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
