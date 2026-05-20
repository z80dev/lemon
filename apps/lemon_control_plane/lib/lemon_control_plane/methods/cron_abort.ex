defmodule LemonControlPlane.Methods.CronAbort do
  @moduledoc """
  Handler for the cron.abort method.

  Aborts an active cron run by cron run ID.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "cron.abort"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, run_id} <- LemonControlPlane.Method.require_param(params, "runId") do
      case LemonAutomation.CronManager.abort_run(run_id) do
        {:ok, run} ->
          {:ok,
           %{
             "aborted" => true,
             "runId" => run.id,
             "jobId" => run.job_id,
             "status" => Atom.to_string(run.status),
             "routerRunId" => run.run_id,
             "summary" => summary(run)
           }}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron run not found: #{run_id}", nil}}

        {:error, :not_active} ->
          {:error, {:invalid_request, "Cron run is not active: #{run_id}", nil}}

        {:error, reason} ->
          {:error, {:internal_error, inspect(reason), nil}}
      end
    end
  end

  defp summary(run) do
    %{
      "runId" => run.id,
      "jobId" => run.job_id,
      "status" => Atom.to_string(run.status),
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
