defmodule LemonCore.Events.RunStarted do
  @moduledoc """
  A run has begun executing on an engine. Published on `run:<run_id>`.
  """

  use LemonCore.Events.Payload,
    type: :run_started,
    enforce: [:run_id],
    fields: [run_id: nil, session_key: nil, engine: nil]

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_key: String.t() | nil,
          engine: String.t() | nil
        }
end
