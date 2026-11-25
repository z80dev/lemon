defmodule LemonCore.Events.Completion do
  @moduledoc """
  The engine's terminal result for a run. Carried inside `LemonCore.Events.RunCompleted`.

  `usage` is a `LemonCore.Events.Usage`; `from_map/1` coerces a usage map arriving from
  outside this node.
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

  alias LemonCore.Events.Usage

  @type t :: %__MODULE__{
          ok: boolean(),
          answer: String.t() | nil,
          error: term() | nil,
          engine: String.t() | nil,
          resume: %{engine: String.t(), value: term()} | nil,
          usage: Usage.t() | nil,
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          meta: map()
        }

  @doc "Build from a legacy map, coercing the nested usage."
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    case super(attrs) do
      %__MODULE__{usage: usage} = completion when is_map(usage) ->
        %{completion | usage: Usage.from_map(usage)}

      completion ->
        completion
    end
  end
end
