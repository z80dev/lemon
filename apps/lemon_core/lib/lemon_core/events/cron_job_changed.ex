defmodule LemonCore.Events.CronJobChanged do
  @moduledoc """
  A cron job was created, updated or deleted. Published on `cron`; the specific transition
  is the `LemonCore.Event` type (`:cron_job_created`, `:cron_job_updated`,
  `:cron_job_deleted`). Deletions carry no `job` record.
  """

  use LemonCore.Events.Payload,
    type: :cron_job_changed,
    enforce: [:action, :job_id],
    fields: [action: nil, job_id: nil, name: nil, agent_id: nil, job: nil]

  @type action :: :created | :updated | :deleted
  @type t :: %__MODULE__{
          action: action(),
          job_id: String.t(),
          name: String.t() | nil,
          agent_id: String.t() | nil,
          job: map() | nil
        }
end
