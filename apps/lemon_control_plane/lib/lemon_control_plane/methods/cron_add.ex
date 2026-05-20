defmodule LemonControlPlane.Methods.CronAdd do
  @moduledoc """
  Handler for the cron.add method.

  Adds a new cron job.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.add"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    job_params = %{
      name: params["name"],
      schedule: params["schedule"],
      agent_id: params["agentId"],
      session_key: params["sessionKey"],
      prompt: params["prompt"],
      command: params["command"],
      cwd: params["cwd"],
      env: params["env"],
      enabled: params["enabled"] != false,
      timezone: params["timezone"] || "UTC",
      jitter_sec: params["jitterSec"] || 0,
      timeout_ms: params["timeoutMs"] || 300_000,
      max_retries: params["maxRetries"] || 0,
      retry_backoff_ms: params["retryBackoffMs"] || 30_000,
      meta: params["meta"]
    }

    case LemonAutomation.CronManager.add(job_params) do
      {:ok, job} ->
        {:ok,
         %{
           "id" => job.id,
           "name" => job.name,
           "mode" => job |> LemonAutomation.CronJob.execution_mode() |> Atom.to_string(),
           "schedule" => job.schedule,
           "timezone" => job.timezone,
           "nextRunAtMs" => job.next_run_at_ms,
           "summary" => summary(job)
         }}

      {:error, {:missing_keys, keys}} ->
        {:error, {:invalid_request, "Missing required fields: #{inspect(keys)}", nil}}

      {:error, {:invalid_schedule, reason}} ->
        {:error, {:invalid_request, "Invalid cron schedule: #{reason}", nil}}

      {:error, {:invalid_target, reason}} ->
        {:error, {:invalid_request, reason, nil}}

      {:error, reason} ->
        {:error, {:internal_error, inspect(reason), nil}}
    end
  end

  defp summary(job) do
    %{
      "jobId" => job.id,
      "mode" => job |> LemonAutomation.CronJob.execution_mode() |> Atom.to_string(),
      "enabled" => job.enabled,
      "promptBytes" => byte_size(job.prompt || ""),
      "commandBytes" => byte_size(job.command || ""),
      "targetTextReturned" => false,
      "cleanup" => cleanup_summary()
    }
  end

  defp cleanup_summary do
    %{
      "includesPromptText" => false,
      "includesCommandText" => false,
      "includesOutputText" => false,
      "includesErrorText" => false,
      "includesMessageBodies" => false,
      "includesCredentials" => false,
      "includesSecretValues" => false
    }
  end
end
