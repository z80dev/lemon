defmodule LemonGateway.Runtime do
  @moduledoc """
  Runtime API for submitting and cancelling gateway runs.

  Provides the internal entry points used by transports and the public API
  to submit jobs and cancel active runs by progress message ID or run ID.
  """

  alias LemonGateway.Types.Job

  @doc "Submits a job to the scheduler for execution."
  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job), do: LemonGateway.Scheduler.submit(job)

  @doc "Cancels a run identified by its progress message ID within a scope."
  @spec cancel_by_progress_msg(term(), integer()) :: :ok
  def cancel_by_progress_msg(scope, progress_msg_id) do
    case LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) do
      nil -> :ok
      run_pid -> LemonGateway.Scheduler.cancel(run_pid, :user_requested)
    end
  end

  @doc "Cancels a run identified by its run ID. No-op if the run is not found."
  @spec cancel_by_run_id(binary(), term()) :: :ok
  def cancel_by_run_id(run_id, reason \\ :user_requested) when is_binary(run_id) do
    case Registry.lookup(LemonGateway.RunRegistry, run_id) do
      [{run_pid, _meta}] when is_pid(run_pid) ->
        LemonGateway.Scheduler.cancel(run_pid, reason)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
