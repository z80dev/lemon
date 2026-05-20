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

    if is_nil(run_id) do
      {:error, {:invalid_request, "runId is required", nil}}
    else
      case wait_for_run(run_id, timeout_ms) do
        {:ok, result} ->
          {:ok, result}

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
        {:ok, format_result(completed)}

      _ ->
        :running
    end
  rescue
    _ -> :running
  end

  defp wait_loop(run_id, timeout_ms) do
    receive do
      %LemonCore.Event{type: :run_completed, payload: payload} ->
        LemonCore.Bus.unsubscribe("run:#{run_id}")
        completed = payload[:completed] || payload
        {:ok, format_result(completed)}

      %{type: :run_completed, payload: payload} ->
        LemonCore.Bus.unsubscribe("run:#{run_id}")
        completed = payload[:completed] || payload
        {:ok, format_result(completed)}
    after
      timeout_ms ->
        LemonCore.Bus.unsubscribe("run:#{run_id}")
        {:error, :timeout}
    end
  end

  defp format_result(completed) when is_map(completed) do
    result = %{
      "runId" => completed_value(completed, :run_id, "runId"),
      "ok" => completed_value(completed, :ok, "ok"),
      "answer" => format_answer(completed_value(completed, :answer, "answer")),
      "error" => format_error(completed_value(completed, :error, "error"))
    }

    Map.put(result, "summary", summary(result))
  end

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
  defp format_answer(answer) when is_binary(answer), do: redact_text(answer)
  defp format_answer(answer), do: answer |> inspect() |> redact_text()

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: redact_text(error)
  defp format_error(error), do: error |> inspect() |> redact_text()

  defp redact_text(text) do
    text
    |> then(fn value ->
      Regex.replace(
        ~r/(?i)\b(api[_-]?key|token|secret|password|private[_-]?key|credential)\s*=\s*([^\s,;]+)/,
        value,
        "\\1=[REDACTED]"
      )
    end)
    |> then(fn value ->
      Regex.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/=-]+/, value, "Bearer [REDACTED]")
    end)
  end
end
