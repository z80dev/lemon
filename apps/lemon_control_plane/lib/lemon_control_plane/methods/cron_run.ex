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
    job_id = params["id"]

    if is_nil(job_id) do
      {:error, {:invalid_request, "id is required", nil}}
    else
      case LemonAutomation.CronManager.run_now(job_id) do
        {:ok, run} ->
          {:ok, %{
            "triggered" => true,
            "jobId" => job_id,
            "runId" => run.id
          }}

        {:error, :not_found} ->
          {:error, {:not_found, "Cron job not found: #{job_id}", nil}}

        {:error, reason} ->
          {:error, {:internal_error, inspect(reason), nil}}
      end
    end
  end
end
