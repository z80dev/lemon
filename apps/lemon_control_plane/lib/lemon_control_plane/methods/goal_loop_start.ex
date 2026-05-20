defmodule LemonControlPlane.Methods.GoalLoopStart do
  @moduledoc """
  Handler for `goal.loop.start`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.loop.start"

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
            max_ticks: param(params, "maxTicks"),
            max_continuations: param(params, "maxContinuations"),
            interval_ms: param(params, "intervalMs"),
            wait_timeout_ms: param(params, "waitTimeoutMs"),
            judge_model: param(params, "judgeModel"),
            judge_failure_policy: policy(param(params, "judgeFailurePolicy")),
            model: param(params, "model"),
            auto: truthy?(param(params, "auto"))
          ]
          |> Enum.reject(fn {_key, value} -> missing?(value) end)

        case loop_mod().start_loop(session_key, opts) do
          {:ok, loop} -> {:ok, %{"loop" => format_loop(loop), "summary" => loop_summary(loop)}}
          {:error, reason} -> {:error, {:invalid_request, inspect(reason), nil}}
        end
    end
  end

  defp format_loop(loop) do
    %{
      "sessionKey" => loop[:session_key],
      "status" => loop[:status],
      "startedAtMs" => loop[:started_at_ms],
      "maxTicks" => loop[:max_ticks]
    }
  end

  defp loop_summary(loop) do
    %{
      "sessionKey" => loop[:session_key],
      "status" => loop[:status],
      "maxTicks" => loop[:max_ticks],
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: nil

  defp missing?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
