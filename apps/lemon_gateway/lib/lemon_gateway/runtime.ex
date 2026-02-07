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
