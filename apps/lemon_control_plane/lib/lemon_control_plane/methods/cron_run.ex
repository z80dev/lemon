defmodule LemonControlPlane.Methods.CronRun do
  @moduledoc """
  Handler for the cron.run method.

  Triggers an immediate run of a cron job.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.run"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      case LemonAutomation.CronManager.run_now(job_id) do
        {:ok, run} ->
          {:ok,
           %{
             "triggered" => true,
             "jobId" => job_id,
             "runId" => run.id,
             "summary" => summary(run)
           }}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron job not found: #{job_id}", nil}}

        {:error, reason} ->
          {:error, {:internal_error, inspect(reason), nil}}
      end
    end
  end

  defp summary(run) do
    %{
      "jobId" => run.job_id,
      "runId" => run.id,
      "status" => Atom.to_string(run.status),
      "triggeredBy" => Atom.to_string(run.triggered_by),
      "rawIdsReturned" => true,
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
