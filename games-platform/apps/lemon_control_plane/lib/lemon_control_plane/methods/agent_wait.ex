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
    case LemonCore.Store.get_run(run_id) do
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
    %{
      "runId" => completed[:run_id] || completed["runId"],
      "ok" => completed[:ok] || completed["ok"],
      "answer" => completed[:answer] || completed["answer"],
      "error" => format_error(completed[:error] || completed["error"])
    }
  end

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end
