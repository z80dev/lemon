defmodule LemonSim.Bench.Domains.Descriptor do
  @moduledoc """
  One benchmarked scenario domain: what it's called, what module runs it,
  and what (if anything) plugs it into scorecards or the always-on league.

  See `LemonSim.Bench.Domains` for the full registered list.
  """

  @enforce_keys [:id, :example_module, :scorecard_module]
  defstruct [
    :id,
    :example_module,
    :scorecard_module,
    :league_adapter,
    :sim_id_prefix,
    :default_player_count
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          example_module: module(),
          scorecard_module: module(),
          league_adapter: module() | nil,
          sim_id_prefix: String.t() | nil,
          default_player_count: pos_integer() | nil
        }
end
