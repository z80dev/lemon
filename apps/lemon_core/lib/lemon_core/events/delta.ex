defmodule LemonCore.Events.Delta do
  @moduledoc """
  A chunk of streamed answer text. Published on `run:<run_id>` and forwarded to
  `session:<session_key>`. The highest-volume payload on the bus.
  """

  use LemonCore.Events.Payload,
    type: :delta,
    enforce: [:run_id, :seq, :text],
    fields: [run_id: nil, seq: nil, text: nil, ts_ms: nil, meta: %{}]

  @type t :: %__MODULE__{
          run_id: String.t(),
          seq: non_neg_integer(),
          text: String.t(),
          ts_ms: non_neg_integer() | nil,
          meta: map()
        }
end
