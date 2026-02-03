defmodule LemonGateway.Runtime do
  @moduledoc false

  alias LemonGateway.Types.Job

  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job), do: LemonGateway.Scheduler.submit(job)

  @spec cancel_by_progress_msg(term(), integer()) :: :ok
  def cancel_by_progress_msg(scope, progress_msg_id) do
    case LemonGateway.Store.get_run_by_progress(scope, progress_msg_id) do
      nil -> :ok
      run_pid -> LemonGateway.Scheduler.cancel(run_pid, :user_requested)
    end
  end
end
