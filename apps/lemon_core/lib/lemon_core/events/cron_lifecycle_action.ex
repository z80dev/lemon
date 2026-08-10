defmodule LemonCore.Events.CronLifecycleAction do
  @moduledoc """
  A durable cron lifecycle/audit action was recorded. Published on `cron`.
  """

  use LemonCore.Events.Payload,
    type: :cron_lifecycle_action,
    enforce: [:audit],
    fields: [audit: nil]

  @type t :: %__MODULE__{audit: map()}
end
