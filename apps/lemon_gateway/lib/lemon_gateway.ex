defmodule LemonGateway do
  @moduledoc false

  alias LemonGateway.Types.Job

  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job), do: LemonGateway.Runtime.submit(job)
end
