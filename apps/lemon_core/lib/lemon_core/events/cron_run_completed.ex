defmodule LemonCore.Events.CronRunCompleted do
  @moduledoc """
  A cron job (or timer heartbeat) finished, successfully or not. Published on `cron`.
  """

  use LemonCore.Events.Payload,
    type: :cron_run_completed,
    enforce: [:cron_run_id, :job_id],
    fields: [
      cron_run_id: nil,
      router_run_id: nil,
      job_id: nil,
      agent_id: nil,
      session_key: nil,
      status: nil,
      duration_ms: nil,
      output: nil,
      error: nil,
      suppressed: false,
      run: nil
    ]

  @type t :: %__MODULE__{
          cron_run_id: String.t(),
          router_run_id: String.t() | nil,
          job_id: String.t(),
          agent_id: String.t() | nil,
          session_key: String.t() | nil,
          status: atom() | nil,
          duration_ms: non_neg_integer() | nil,
          output: String.t() | nil,
          error: term() | nil,
          suppressed: boolean(),
          run: map() | nil
        }
end
