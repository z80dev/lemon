defmodule LemonSim.Bench.Scorecard do
  @moduledoc """
  Behaviour for deterministic benchmark scorecards.

  A scorecard module derives comparable metrics only from the final world
  snapshot so artifact verification can recompute it without replaying a run.
  """

  @callback scorecard(final_world :: map()) :: map()

  @callback primary_metric() :: %{
              key: String.t() | [String.t()],
              direction: :maximize | :minimize
            }
end
