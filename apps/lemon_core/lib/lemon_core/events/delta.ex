defmodule LemonCore.Events.Delta do
  @moduledoc """
  A chunk of streamed answer text. Local native sessions publish it in a cursor
  batch on `session:<session_key>` and the gateway relays the same delta to run
  consumers. Remote deltas are published on `run:<run_id>` and forwarded to
  the session topic. `seq` is run-local, not a session cursor.
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
