defmodule LemonControlPlane.Methods.GoalLoopOnce do
  @moduledoc """
  Handler for `goal.loop.once`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.loop.once"

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
            judge_model: param(params, "judgeModel"),
            judge_failure_policy: policy(param(params, "judgeFailurePolicy")),
            model: param(params, "model")
          ]
          |> Enum.reject(fn {_key, value} -> missing?(value) end)

        case loop_mod().run_once(session_key, opts) do
          {:ok, result} -> {:ok, format_result(result)}
          {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
        end
    end
  end

  defp format_result(%{goal: goal, verdict: verdict} = result) do
    %{
      "runId" => result[:run_id],
      "verdict" => %{
        "action" => to_string(verdict.action),
        "reason" => verdict.reason,
        "source" => verdict.source
      },
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
      "summary" => loop_summary(goal, verdict, result[:run_id])
    }
  end

  defp loop_summary(goal, verdict, run_id) do
    reason = verdict.reason || ""

    %{
      "runId" => run_id,
      "sessionKey" => goal.session_key,
      "agentId" => goal.agent_id,
      "status" => goal.status,
      "verdictAction" => to_string(verdict.action),
      "verdictSource" => verdict.source,
      "verdictReasonBytes" => byte_size(reason),
      "verdictReasonReturned" => true,
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

  defp loop_mod do
    Application.get_env(:lemon_control_plane, :goal_loop_module, LemonAutomation.GoalLoopManager)
  end

  defp param(params, key) when is_map(params),
    do: Map.get(params, key) || Map.get(params, Macro.underscore(key))

  defp param(_params, _key), do: nil

  defp policy(nil), do: nil
  defp policy("continue_once"), do: :continue_once
  defp policy("continueOnce"), do: :continue_once
  defp policy("needs_input"), do: :needs_input
  defp policy("needsInput"), do: :needs_input
  defp policy("pause"), do: :pause
  defp policy(_), do: nil

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
