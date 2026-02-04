defmodule LemonControlPlane.Methods.CronList do
  @moduledoc """
  Handler for the cron.list method.

  Lists all cron jobs.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    jobs = LemonAutomation.CronManager.list()

    formatted_jobs = Enum.map(jobs, &format_job/1)

    {:ok, %{"jobs" => formatted_jobs}}
  end

  defp format_job(job) do
    %{
      "id" => job.id,
      "name" => job.name,
      "schedule" => job.schedule,
      "enabled" => job.enabled,
      "agentId" => job.agent_id,
      "sessionKey" => job.session_key,
      "prompt" => job.prompt,
      "timezone" => job.timezone || "UTC",
      "jitterSec" => job.jitter_sec || 0,
      "timeoutMs" => job.timeout_ms,
      "createdAtMs" => job.created_at_ms,
      "updatedAtMs" => job.updated_at_ms,
      "lastRunAtMs" => job.last_run_at_ms,
      "nextRunAtMs" => job.next_run_at_ms
    }
  end
end
