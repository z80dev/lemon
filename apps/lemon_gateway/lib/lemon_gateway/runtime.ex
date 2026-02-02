defmodule LemonGateway.Runtime do
  @moduledoc false

  alias LemonGateway.Types.Job

  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job), do: LemonGateway.Scheduler.submit(job)

  @spec cancel_by_progress_msg(term(), integer()) :: :ok
  def cancel_by_progress_msg(_scope, _progress_msg_id), do: :ok
end
