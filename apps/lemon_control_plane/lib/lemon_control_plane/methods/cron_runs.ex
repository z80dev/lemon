defmodule LemonControlPlane.Methods.CronRuns do
  @moduledoc """
  Handler for the cron.runs method.

  Returns run history for a cron job.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.runs"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      limit = params["limit"] || 100
      runs = LemonAutomation.CronManager.runs(job_id, limit: limit)
      formatted_runs = Enum.map(runs, &format_run/1)
      {:ok, %{"jobId" => job_id, "runs" => formatted_runs}}
    end
  end

  defp format_run(run) do
    %{
      "id" => run.id,
      "jobId" => run.job_id,
      "status" => to_string(run.status),
      "triggeredBy" => to_string(run.triggered_by),
      "startedAtMs" => run.started_at_ms,
      "completedAtMs" => run.completed_at_ms,
      "output" => truncate(run.output, 500),
      "error" => run.error,
      "suppressed" => run.suppressed || false
    }
  end

  defp truncate(nil, _), do: nil
  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."
end
