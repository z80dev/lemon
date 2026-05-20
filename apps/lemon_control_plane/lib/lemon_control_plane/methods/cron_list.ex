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
    include_target_text? = truthy?(params["includeTargetText"] || params["include_target_text"])

    jobs =
      LemonAutomation.CronManager.list()
      |> maybe_filter_agent(agent_id)

    formatted_jobs = Enum.map(jobs, &format_job(&1, include_target_text?))

    {:ok,
     %{
       "jobs" => formatted_jobs,
       "total" => length(formatted_jobs),
       "summary" => summary(formatted_jobs, include_target_text?, agent_id)
     }}
  end

  defp format_job(job, include_target_text?) do
    latest_run = LemonAutomation.CronStore.list_runs(job.id, limit: 1) |> List.first()
    active_runs = LemonAutomation.CronStore.active_runs(job.id)
    prompt = job.prompt || ""
    command = job.command || ""

    %{
      "id" => job.id,
      "name" => job.name,
      "mode" => job |> LemonAutomation.CronJob.execution_mode() |> Atom.to_string(),
      "schedule" => job.schedule,
      "enabled" => job.enabled,
      "agentId" => job.agent_id,
      "sessionKey" => job.session_key,
      "prompt" => if(include_target_text?, do: job.prompt, else: nil),
      "command" => if(include_target_text?, do: job.command, else: nil),
      "promptBytes" => byte_size(prompt),
      "commandBytes" => byte_size(command),
      "cwd" => job.cwd,
      "envKeys" => env_keys(job.env),
      "timezone" => job.timezone || "UTC",
      "jitterSec" => job.jitter_sec || 0,
      "timeoutMs" => job.timeout_ms,
      "maxRetries" => job.max_retries || 0,
      "retryBackoffMs" => job.retry_backoff_ms || 30_000,
      "createdAtMs" => job.created_at_ms,
      "updatedAtMs" => job.updated_at_ms,
      "lastRunAtMs" => job.last_run_at_ms,
      "nextRunAtMs" => job.next_run_at_ms,
      "lastRunStatus" => latest_run && to_string(latest_run.status),
      "activeRunCount" => length(active_runs),
      "meta" => job.meta,
      "summary" => job_summary(job, prompt, command, include_target_text?)
    }
  end

  defp job_summary(job, prompt, command, include_target_text?) do
    %{
      "jobId" => job.id,
      "mode" => job |> LemonAutomation.CronJob.execution_mode() |> Atom.to_string(),
      "enabled" => job.enabled,
      "promptBytes" => byte_size(prompt),
      "commandBytes" => byte_size(command),
      "targetTextReturned" => include_target_text?,
      "cleanup" => cleanup_summary(include_target_text?)
    }
  end

  defp summary(jobs, include_target_text?, agent_id) do
    %{
      "jobCount" => length(jobs),
      "enabledJobCount" => Enum.count(jobs, &(&1["enabled"] == true)),
      "modeCounts" => jobs |> Enum.map(& &1["mode"]) |> Enum.frequencies(),
      "filteredByAgentId" => not is_nil(agent_id) and to_string(agent_id) != "",
      "targetTextReturned" => include_target_text?,
      "cleanup" => cleanup_summary(include_target_text?)
    }
  end

  defp cleanup_summary(include_target_text?) do
    %{
      "includesPromptText" => include_target_text?,
      "includesCommandText" => include_target_text?,
      "includesMessageBodies" => false,
      "includesCredentials" => false,
      "includesSecretValues" => false
    }
  end

  defp maybe_filter_agent(jobs, nil), do: jobs
  defp maybe_filter_agent(jobs, ""), do: jobs
  defp maybe_filter_agent(jobs, agent_id), do: Enum.filter(jobs, &(&1.agent_id == agent_id))

  defp env_keys(env) when is_map(env),
    do: env |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

  defp env_keys(_env), do: []

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
