defmodule LemonControlPlane.Methods.AgentWait do
  @moduledoc """
  Handler for the agent.wait method.

  Waits for a run to complete and returns the result.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.wait"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    run_id = params["runId"]
    timeout_ms = params["timeoutMs"] || 60_000
    include_answer = Map.get(params, "includeAnswer", true)

    cond do
      is_nil(run_id) ->
        {:error, {:invalid_request, "runId is required", nil}}

      not is_boolean(include_answer) ->
        {:error, {:invalid_request, "includeAnswer must be a boolean", nil}}

      true ->
        case wait_for_run(run_id, timeout_ms) do
          {:ok, completed} ->
            {:ok, format_result(completed, include_answer)}

          {:error, :timeout} ->
            {:error, {:timeout, "Run did not complete within timeout", run_id}}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to wait for run", reason}}
        end
    end
  end

  defp wait_for_run(run_id, timeout_ms) do
    # Subscribe to run events
    LemonCore.Bus.subscribe("run:#{run_id}")

    # Check if already completed
    case check_run_completed(run_id) do
      {:ok, result} ->
        LemonCore.Bus.unsubscribe("run:#{run_id}")
        {:ok, result}

      :running ->
        wait_loop(run_id, timeout_ms)
    end
  rescue
    e ->
      LemonCore.Bus.unsubscribe("run:#{run_id}")
      {:error, Exception.message(e)}
  end

  defp check_run_completed(run_id) do
    case LemonCore.RunStore.get(run_id) do
      %{summary: %{completed: completed}} when not is_nil(completed) ->
        {:ok, completed}

      _ ->
        :running
    end
  rescue
    _ -> :running
  end

  defp wait_loop(run_id, timeout_ms) do
    receive do
      %LemonCore.Event{type: :run_completed, payload: payload} ->
        completed_result(run_id, payload)

      %{type: :run_completed, payload: payload} ->
        completed_result(run_id, payload)
    after
      timeout_ms ->
        LemonCore.Bus.unsubscribe("run:#{run_id}")
        {:error, :timeout}
    end
  end

  # A `:run_completed` payload is a `LemonCore.Events.RunCompleted`. A legacy map — the cron
  # summary `LemonAutomation` forwards onto the session topic, or an injected event — is
  # coerced into one here, so the completion is read by field and never through `Access`. The
  # bare-map clause keeps a payload too incomplete to coerce (one whose nested completion has
  # no `:ok`) unwrapping the same way it did before the typed payloads landed.
  defp completed_result(run_id, payload) do
    LemonCore.Bus.unsubscribe("run:#{run_id}")

    completed =
      case LemonCore.Events.coerce(:run_completed, payload) do
        %LemonCore.Events.RunCompleted{completed: completed} when not is_nil(completed) ->
          completed

        %{completed: completed} when not is_nil(completed) ->
          completed

        other ->
          other
      end

    {:ok, completed}
  end

  defp format_result(completed, include_answer) when is_map(completed) do
    result = %{
      "runId" => completed_value(completed, :run_id, "runId"),
      "ok" => completed_value(completed, :ok, "ok"),
      "answer" =>
        if(include_answer, do: format_answer(completed_value(completed, :answer, "answer"))),
      "error" => format_error(completed_value(completed, :error, "error"))
    }

    meta = completed_value(completed, :meta, "meta") || %{}

    result = Map.put(result, "cancelled", completed_value(meta, :cancelled, "cancelled") == true)

    result =
      if include_answer do
        result
        |> maybe_put(
          "usage",
          completed
          |> completed_value(:usage, "usage")
          |> LemonControlPlane.EventProjection.action_detail()
        )
        |> maybe_put("budget", completed_value(meta, :budget, "budget"))
      else
        result
      end

    Map.put(result, "summary", summary(result))
  end

  defp maybe_put(result, _key, nil), do: result
  defp maybe_put(result, key, value), do: Map.put(result, key, value)

  defp completed_value(completed, atom_key, string_key) do
    if Map.has_key?(completed, atom_key) do
      Map.get(completed, atom_key)
    else
      Map.get(completed, string_key)
    end
  end

  defp summary(result) do
    answer = result["answer"]
    error = result["error"]

    %{
      "runId" => result["runId"],
      "ok" => result["ok"],
      "answerReturned" => is_binary(answer) and answer != "",
      "answerBytes" => if(is_binary(answer), do: byte_size(answer), else: 0),
      "hasError" => not is_nil(error),
      "errorKind" => error_kind(error),
      "cleanup" => %{
        "includesPromptText" => false,
        "redactsSensitiveAnswerValues" => true,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp error_kind(nil), do: nil
  defp error_kind(error) when is_binary(error), do: "string"
  defp error_kind(_error), do: "other"

  defp format_answer(nil), do: nil
  defp format_answer(answer) when is_binary(answer), do: LemonCore.Redact.text(answer)
  defp format_answer(answer), do: answer |> inspect() |> LemonCore.Redact.text()

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: LemonCore.Redact.text(error)
  defp format_error(error), do: error |> inspect() |> LemonCore.Redact.text()
end
