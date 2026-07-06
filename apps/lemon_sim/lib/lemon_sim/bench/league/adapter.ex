defmodule LemonSim.Bench.League.Adapter do
  @moduledoc """
  Behaviour for scenario-specific league adapters.

  An adapter reduces a finished world to the seat-level facts the generic
  league engine (`LemonSim.Bench.League`) needs: which model sat in which
  seat, what role it played, whether it ended on the winning side, and any
  numeric metrics worth accumulating in standings.

  Two rating modes are supported:

    * `:team` — the game splits seats into a winning and a losing side
      (werewolf, space station, or winner-take-all games like survivor).
      Ratings pair every winning-side model against every losing-side model.
    * `{:ranked, direction}` — each seat produces a numeric `value`
      (e.g. final portfolio value). Ratings compare per-model mean values
      pairwise within each game.
  """

  @type seat :: %{
          required(:model) => String.t() | nil,
          required(:won) => boolean(),
          optional(:role) => String.t() | nil,
          optional(:value) => number() | nil,
          optional(:metrics) => %{optional(String.t()) => number()}
        }

  @type game_summary :: %{
          required(:winner) => String.t() | nil,
          required(:rounds) => non_neg_integer(),
          required(:seats) => %{optional(String.t()) => seat()}
        }

  @doc "Scenario id, matching the scorecard registry (e.g. `\"werewolf\"`)."
  @callback scenario_id() :: String.t()

  @doc "Rating mode: `:team` or `{:ranked, :maximize | :minimize}`."
  @callback mode() :: :team | {:ranked, :maximize | :minimize}

  @doc "Reduces a finished world to winner, round count, and per-seat facts."
  @callback game_summary(map()) :: game_summary()
end
