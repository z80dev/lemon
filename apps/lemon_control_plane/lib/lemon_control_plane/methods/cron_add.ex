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
      enabled: params["enabled"] != false,
      timezone: params["timezone"] || "UTC",
      jitter_sec: params["jitterSec"] || 0,
      timeout_ms: params["timeoutMs"] || 300_000,
      meta: params["meta"]
    }

    case LemonAutomation.CronManager.add(job_params) do
      {:ok, job} ->
        {:ok, %{
          "id" => job.id,
          "name" => job.name,
          "schedule" => job.schedule,
          "nextRunAtMs" => job.next_run_at_ms
        }}

      {:error, {:missing_keys, keys}} ->
        {:error, {:invalid_request, "Missing required fields: #{inspect(keys)}", nil}}

      {:error, {:invalid_schedule, reason}} ->
        {:error, {:invalid_request, "Invalid cron schedule: #{reason}", nil}}

      {:error, reason} ->
        {:error, {:internal_error, inspect(reason), nil}}
    end
  end
end
