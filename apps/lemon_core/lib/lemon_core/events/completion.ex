defmodule LemonCore.Events.Completion do
  @moduledoc """
  The engine's terminal result for a run. Carried inside `LemonCore.Events.RunCompleted`.

  `usage` stays a plain map: token accounting is owned by `LemonAi.Tokens`, and `lemon_core`
  must not depend on the AI package to describe it.
  """

  use LemonCore.Events.Payload,
    type: :completion,
    enforce: [:ok],
    fields: [
      ok: nil,
      answer: nil,
      error: nil,
      engine: nil,
      resume: nil,
      usage: nil,
      run_id: nil,
      session_key: nil,
      meta: %{}
    ]

  @type t :: %__MODULE__{
          ok: boolean(),
          answer: String.t() | nil,
          error: term() | nil,
          engine: String.t() | nil,
          resume: %{engine: String.t(), value: term()} | nil,
          usage: map() | nil,
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          meta: map()
        }
end
