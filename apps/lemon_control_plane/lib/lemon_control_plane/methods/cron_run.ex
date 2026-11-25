defmodule LemonControlPlane.Methods.CronRun do
  @moduledoc """
  Handler for the cron.run method.

  Triggers an immediate run of a cron job. The cron run ID is allocated here,
  before the scheduler is called, and the scheduler claims exactly that ID.

  When the trigger call timed out, exited after reaching the scheduler, or its
  claim write is unconfirmed, the method fails with code `UNAVAILABLE` and
  details `%{"code" => "RUN_OUTCOME_UNKNOWN", "jobId" => id, "runId" => run_id,
  "retrySafe" => false}`: that run may exist, so reconcile it with `cron.runs`
  instead of triggering again.

  When an earlier run of the job still has an unknown outcome, the scheduler
  refuses before claiming the new ID. The details are
  `%{"code" => "PRIOR_RUN_OUTCOME_UNKNOWN", "jobId" => id,
  "priorRunId" => earlier_id, "retrySafe" => false}` (`priorRunId` is omitted
  when the active runs cannot be read); no new run exists, but triggering stays
  unsafe until the earlier run is reconciled.
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
      run_id = LemonCore.Id.run_id()

      case run_now(job_id, run_id) do
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
            "The cron run's outcome is unknown. Check cron.runs for runId before triggering it again.",
            %{
              "code" => "RUN_OUTCOME_UNKNOWN",
              "jobId" => job_id,
              "runId" => run_id,
              "retrySafe" => false
            }}}

        {:error, {:prior_run_unresolved, prior_run_id}} ->
          details =
            %{"code" => "PRIOR_RUN_OUTCOME_UNKNOWN", "jobId" => job_id, "retrySafe" => false}

          details =
            if is_binary(prior_run_id),
              do: Map.put(details, "priorRunId", prior_run_id),
              else: details

          {:error,
           {:unavailable,
            "An earlier run of this cron job has an unknown outcome. Reconcile it with cron.runs before triggering again.",
            details}}

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
  defp run_now(job_id, run_id) do
    LemonAutomation.CronManager.run_now_with_id(job_id, run_id)
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
