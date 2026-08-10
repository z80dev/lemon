defmodule LemonCore.Events.HeartbeatAlert do
  @moduledoc """
  A heartbeat returned a non-OK status. Published on `cron`.
  """

  use LemonCore.Events.Payload,
    type: :heartbeat_alert,
    enforce: [:agent_id],
    fields: [
      agent_id: nil,
      job_id: nil,
      job_name: nil,
      run_id: nil,
      response: nil,
      severity: :warning
    ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          job_id: String.t() | nil,
          job_name: String.t() | nil,
          run_id: String.t() | nil,
          response: String.t() | nil,
          severity: atom()
        }
end
