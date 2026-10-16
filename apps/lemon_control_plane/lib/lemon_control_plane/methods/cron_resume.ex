defmodule LemonControlPlane.Methods.CronResume do
  @moduledoc """
  Handler for the cron.resume method.

  Resumes a paused cron job by enabling future scheduled launches. With
  `all: true` (and no `id`) it instead lifts the durable global pause; runs
  missed during the pause are skipped, never caught up.
  """

  @behaviour LemonControlPlane.Method

  require Logger

  @impl true
  def name, do: "cron.resume"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(%{"all" => true} = params, _ctx) do
    if Map.has_key?(params, "id") do
      {:error, {:invalid_request, "Pass either id or all, not both", nil}}
    else
      resume_all()
    end
  end

  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      case LemonAutomation.CronManager.update(job_id, %{enabled: true}) do
        {:ok, job} ->
          {:ok,
           %{
             "id" => job.id,
             "resumed" => true,
             "enabled" => job.enabled,
             "nextRunAtMs" => job.next_run_at_ms,
             "summary" => summary(job)
           }}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron job not found: #{job_id}", nil}}

        {:error, reason} ->
          Logger.warning("Could not resume cron job: #{inspect(reason)}")

          {:error,
           {:internal_error, "Could not resume cron job. Run `lemon doctor` before trying again.",
            nil}}
      end
    end
  end

  defp resume_all do
    case LemonAutomation.CronManager.resume_all() do
      {:ok, result} ->
        {:ok,
         %{
           "all" => true,
           "resumed" => result.resumed,
           "skippedJobCount" => result.skipped_job_count,
           "skippedRetryCount" => result.skipped_retry_count,
           "summary" => %{
             "all" => true,
             "resumed" => result.resumed,
             "skippedJobCount" => result.skipped_job_count,
             "skippedRetryCount" => result.skipped_retry_count,
             "targetTextReturned" => false,
             "cleanup" => cleanup_summary()
           }
         }}

      {:error, reason} ->
        Logger.warning("Could not resume all cron jobs: #{inspect(reason)}")

        {:error,
         {:internal_error, "Could not resume cron jobs. Run `lemon doctor` before trying again.",
          nil}}
    end
  end

  defp summary(job) do
    %{
      "jobId" => job.id,
      "resumed" => true,
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
