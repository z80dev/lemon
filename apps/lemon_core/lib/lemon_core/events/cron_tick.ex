defmodule LemonCore.Events.CronTick do
  @moduledoc """
  The scheduler ticked. Published on `cron` once a minute.
  """

  use LemonCore.Events.Payload,
    type: :cron_tick,
    enforce: [:timestamp_ms],
    fields: [timestamp_ms: nil]

  @type t :: %__MODULE__{timestamp_ms: non_neg_integer()}
end
