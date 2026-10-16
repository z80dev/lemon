defmodule LemonControlPlane.Methods.CronPause do
  @moduledoc """
  Handler for the cron.pause method.

  Pauses a cron job by disabling future scheduled launches. With `all: true`
  (and no `id`) it instead sets the durable global pause that holds back every
  cron job until `cron.resume` with `all: true`.
  """

  @behaviour LemonControlPlane.Method

  require Logger

  @impl true
  def name, do: "cron.pause"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(%{"all" => true} = params, _ctx) do
    if Map.has_key?(params, "id") do
      {:error, {:invalid_request, "Pass either id or all, not both", nil}}
    else
      pause_all()
    end
  end

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

  defp pause_all do
    case LemonAutomation.CronManager.pause_all() do
      {:ok, %{paused_at_ms: paused_at_ms}} ->
        {:ok,
         %{
           "all" => true,
           "paused" => true,
           "pausedAtMs" => paused_at_ms,
           "summary" => %{
             "all" => true,
             "paused" => true,
             "targetTextReturned" => false,
             "cleanup" => cleanup_summary()
           }
         }}

      {:error, reason} ->
        Logger.warning("Could not pause all cron jobs: #{inspect(reason)}")

        {:error,
         {:internal_error, "Could not pause cron jobs. Run `lemon doctor` before trying again.",
          nil}}
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
