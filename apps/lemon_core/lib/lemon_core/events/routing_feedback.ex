defmodule LemonCore.Events.RoutingFeedback do
  @moduledoc """
  A finalized run's outcome, keyed by task fingerprint, for router-owned model selection.
  Published on `routing_feedback` by `lemon_memory` and consumed by `lemon_router`.
  """

  use LemonCore.Events.Payload,
    type: :routing_feedback,
    enforce: [:fingerprint_key, :outcome],
    fields: [fingerprint_key: nil, outcome: nil, duration_ms: nil]

  @type t :: %__MODULE__{
          fingerprint_key: String.t(),
          outcome: atom(),
          duration_ms: non_neg_integer() | nil
        }
end
