defmodule LemonControlPlane.Methods.CronAbort do
  @moduledoc """
  Handler for the cron.abort method.

  Aborts an active cron run by cron run ID.
  """

  @behaviour LemonControlPlane.Method

  require Logger

  @impl true
  def name, do: "cron.abort"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    with {:ok, run_id} <- LemonControlPlane.Method.require_param(params, "runId") do
      case abort_run(run_id) do
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

        {:error, :outcome_unknown} ->
          {:error,
           {:unavailable,
            "The cron run's abort outcome is unknown. Check cron.runs before retrying.",
            %{"code" => "ABORT_OUTCOME_UNKNOWN", "runId" => run_id, "retrySafe" => false}}}

        {:error, reason} ->
          Logger.warning("Could not abort cron run reason=#{failure_label(reason)}")

          {:error,
           {:internal_error,
            "Could not abort cron run. Run `lemon doctor` and check its status before trying again.",
            nil}}
      end
    end
  end

  # An abort call that timed out or exited after reaching the scheduler may
  # already have taken effect; only a missing scheduler is definite.
  defp abort_run(run_id) do
    LemonAutomation.CronManager.abort_run(run_id)
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp failure_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_label(_reason), do: "error"

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
