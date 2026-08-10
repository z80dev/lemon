defmodule LemonCore.Events.RunCompleted do
  @moduledoc """
  A run reached a terminal state, successfully or not. Published on `run:<run_id>`.

  The most widely consumed payload in the umbrella — twelve subscribers across six apps.
  `meta.synthetic` marks completions the router fabricated because the engine never
  reported one (watchdog timeout, abort, gateway process death).
  """

  use LemonCore.Events.Payload,
    type: :run_completed,
    enforce: [:completed],
    fields: [completed: nil, duration_ms: nil]

  alias LemonCore.Events.Completion

  @type t :: %__MODULE__{
          completed: Completion.t(),
          duration_ms: non_neg_integer() | nil
        }

  @doc """
  Build from a legacy map, coercing the nested completion too.
  """
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    completed =
      case Map.get(attrs, :completed) || Map.get(attrs, "completed") do
        nil -> Completion.from_map(attrs)
        %Completion{} = completion -> completion
        completion when is_map(completion) -> Completion.from_map(completion)
        other -> other
      end

    %__MODULE__{
      completed: completed,
      duration_ms: Map.get(attrs, :duration_ms) || Map.get(attrs, "duration_ms")
    }
  end
end
