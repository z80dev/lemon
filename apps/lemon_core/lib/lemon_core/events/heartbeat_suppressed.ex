defmodule LemonCore.Events.HeartbeatSuppressed do
  @moduledoc """
  A healthy heartbeat response was suppressed rather than delivered. Published on `cron`.
  """

  use LemonCore.Events.Payload,
    type: :heartbeat_suppressed,
    enforce: [:agent_id],
    fields: [agent_id: nil, job_id: nil, job_name: nil, run_id: nil]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          job_id: String.t() | nil,
          job_name: String.t() | nil,
          run_id: String.t() | nil
        }
end
