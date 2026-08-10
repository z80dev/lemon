defmodule LemonCore.Events.RunFailed do
  @moduledoc """
  The router's run process terminated abnormally without the engine reporting a completion.
  Published on `run:<run_id>`.
  """

  use LemonCore.Events.Payload,
    type: :run_failed,
    enforce: [:run_id, :reason],
    fields: [run_id: nil, session_key: nil, reason: nil]

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_key: String.t() | nil,
          reason: term()
        }
end
