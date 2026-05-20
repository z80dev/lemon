defmodule LemonControlPlane.Methods.GoalContinue do
  @moduledoc """
  Handler for `goal.continue`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.continue"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = param(params, "sessionKey")

    cond do
      missing?(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      true ->
        opts =
          [
            run_id: param(params, "runId"),
            max_continuations: param(params, "maxContinuations"),
            model: param(params, "model")
          ]
          |> Enum.reject(fn {_key, value} -> missing?(value) end)

        case continuation_mod().continue_once(session_key, opts) do
          {:ok, result} -> {:ok, format_result(result)}
          {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
        end
    end
  end

  defp format_result(%{run_id: run_id, goal: goal}) do
    %{
      "runId" => run_id,
      "goal" => %{
        "id" => goal.id,
        "sessionKey" => goal.session_key,
        "agentId" => goal.agent_id,
        "status" => goal.status,
        "updatedAtMs" => goal.updated_at_ms,
        "lastRunId" => goal.last_run_id,
        "continuationCount" => goal.continuation_count,
        "objectiveBytes" => byte_size(goal.objective || "")
      },
      "summary" => goal_summary(goal, run_id)
    }
  end

  defp goal_summary(goal, run_id) do
    %{
      "runId" => run_id,
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "continuationCount" => goal.continuation_count,
      "objectiveBytes" => byte_size(goal.objective || ""),
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

  defp continuation_mod do
    Application.get_env(
      :lemon_control_plane,
      :goal_continuation_module,
      LemonAutomation.GoalContinuationManager
    )
  end

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
