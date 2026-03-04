defmodule LemonSim.PlanStep do
  @moduledoc """
  Compact plan-history entry retained across decisions.
  """

  @enforce_keys [:summary, :ts_ms]
  defstruct [:summary, :ts_ms, rationale: nil, meta: %{}]

  @type t :: %__MODULE__{
          summary: String.t(),
          ts_ms: non_neg_integer(),
          rationale: String.t() | nil,
          meta: map()
        }

  @doc """
  Builds a new plan step with current timestamp by default.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(summary, opts \\ []) when is_binary(summary) and is_list(opts) do
    %__MODULE__{
      summary: summary,
      ts_ms: Keyword.get(opts, :ts_ms, System.system_time(:millisecond)),
      rationale: Keyword.get(opts, :rationale),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end
