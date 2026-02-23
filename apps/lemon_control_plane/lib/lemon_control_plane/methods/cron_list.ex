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
  def handle(params, _ctx) do
    params = params || %{}
    agent_id = params["agentId"] || params["agent_id"]

    jobs =
      LemonAutomation.CronManager.list()
      |> maybe_filter_agent(agent_id)

    formatted_jobs = Enum.map(jobs, &format_job/1)

    {:ok, %{"jobs" => formatted_jobs, "total" => length(formatted_jobs)}}
  end

  defp format_job(job) do
    latest_run = LemonAutomation.CronStore.list_runs(job.id, limit: 1) |> List.first()
    active_runs = LemonAutomation.CronStore.active_runs(job.id)

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
      "nextRunAtMs" => job.next_run_at_ms,
      "lastRunStatus" => latest_run && to_string(latest_run.status),
      "activeRunCount" => length(active_runs),
      "meta" => job.meta
    }
  end

  defp maybe_filter_agent(jobs, nil), do: jobs
  defp maybe_filter_agent(jobs, ""), do: jobs
  defp maybe_filter_agent(jobs, agent_id), do: Enum.filter(jobs, &(&1.agent_id == agent_id))
end
