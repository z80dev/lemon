defmodule LemonCore.Events.RunStarted do
  @moduledoc """
  A run has begun executing on an engine. Published on `run:<run_id>`.

  `model`, `provider` and `thinking_level` describe what the router *resolved* for this
  run, which is the only place that value is ever observable — nothing persists it. They
  stay optional: a publisher that does not know them leaves them nil rather than guessing.
  """

  use LemonCore.Events.Payload,
    type: :run_started,
    enforce: [:run_id],
    fields: [
      run_id: nil,
      session_key: nil,
      engine: nil,
      model: nil,
      provider: nil,
      thinking_level: nil
    ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_key: String.t() | nil,
          engine: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          thinking_level: String.t() | atom() | nil
        }
end
