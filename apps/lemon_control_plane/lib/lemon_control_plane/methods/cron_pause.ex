defmodule LemonControlPlane.Methods.CronPause do
  @moduledoc """
  Handler for the cron.pause method.

  Pauses a cron job by disabling future scheduled launches.
  """

  @behaviour LemonControlPlane.Method

  require Logger

  @impl true
  def name, do: "cron.pause"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      case LemonAutomation.CronManager.update(job_id, %{enabled: false}) do
        {:ok, job} ->
          {:ok,
           %{
             "id" => job.id,
             "paused" => true,
             "enabled" => job.enabled,
             "nextRunAtMs" => job.next_run_at_ms,
             "summary" => summary(job)
           }}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron job not found: #{job_id}", nil}}

        {:error, reason} ->
          Logger.warning("Could not pause cron job: #{inspect(reason)}")

          {:error,
           {:internal_error, "Could not pause cron job. Run `lemon doctor` before trying again.",
            nil}}
      end
    end
  end

  defp summary(job) do
    %{
      "jobId" => job.id,
      "paused" => true,
      "enabled" => job.enabled,
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
