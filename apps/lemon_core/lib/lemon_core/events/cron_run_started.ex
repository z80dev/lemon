defmodule LemonCore.Events.CronRunStarted do
  @moduledoc """
  A cron job (or timer heartbeat) began executing. Published on `cron`.

  Fields are flat rather than nesting the job and run records: consumers only ever read
  these, and the nested form is what let two emitters drift apart before Phase 3.1.
  """

  use LemonCore.Events.Payload,
    type: :cron_run_started,
    enforce: [:cron_run_id, :job_id],
    fields: [
      cron_run_id: nil,
      router_run_id: nil,
      job_id: nil,
      job_name: nil,
      agent_id: nil,
      session_key: nil,
      triggered_by: :schedule,
      started_at_ms: nil,
      run: nil
    ]

  @type t :: %__MODULE__{
          cron_run_id: String.t(),
          router_run_id: String.t() | nil,
          job_id: String.t(),
          job_name: String.t() | nil,
          agent_id: String.t() | nil,
          session_key: String.t() | nil,
          triggered_by: atom(),
          started_at_ms: non_neg_integer() | nil,
          run: map() | nil
        }
end
