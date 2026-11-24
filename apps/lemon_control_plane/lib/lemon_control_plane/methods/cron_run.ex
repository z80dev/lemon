defmodule LemonControlPlane.Methods.CronRun do
  @moduledoc """
  Handler for the cron.run method.

  Triggers an immediate run of a cron job.

  When the outcome is unknown (an earlier run of the job is still unresolved, or
  the trigger call timed out or exited after reaching the scheduler) the method
  fails with code `UNAVAILABLE` and details
  `%{"code" => "RUN_OUTCOME_UNKNOWN", "jobId" => id, "retrySafe" => false}`:
  a run may exist, so reconcile with `cron.runs` instead of triggering again.
  """

  @behaviour LemonControlPlane.Method

  require Logger

  @impl true
  def name, do: "cron.run"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      case run_now(job_id) do
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

        {:error, :outcome_unknown} ->
          {:error,
           {:unavailable,
            "The cron run's outcome is unknown. Check cron.runs before triggering it again.",
            %{"code" => "RUN_OUTCOME_UNKNOWN", "jobId" => job_id, "retrySafe" => false}}}

        {:error, reason} ->
          Logger.warning("Could not start cron job reason=#{failure_label(reason)}")

          {:error,
           {:internal_error,
            "Could not start cron job. Run `lemon doctor` and check its status before trying again.",
            nil}}
      end
    end
  end

  # A trigger call that timed out or exited after reaching the scheduler may
  # already have started a run; only a missing scheduler is definite.
  defp run_now(job_id) do
    LemonAutomation.CronManager.run_now(job_id)
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp failure_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_label(_reason), do: "error"

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
