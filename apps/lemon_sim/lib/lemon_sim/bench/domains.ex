defmodule LemonSim.Bench.Domains do
  @moduledoc """
  Single source of truth for every benchmarked scenario domain.

  `LemonSim.Bench.Scorecard.Registry` and `LemonSim.Bench.League.Registry`
  both derive their lookup maps from `all/0` below instead of keeping their
  own parallel literal maps. Registering a new scenario for scorecards, or
  wiring an existing one into the always-on arena league, means adding or
  editing one entry here rather than several.

  ## Fields kept ahead of a `lemon_sim_ui` migration

  `sim_id_prefix` mirrors the values `LemonSimUi.Arena` and
  `LemonSimUi.SimManager` hardcode today (`"ww_"`, `"pkr_"`, ...) for the five
  arena domains. `lemon_sim_ui` does not consume this module yet — that app
  currently keeps its own three parallel per-domain lists (`Arena.@domains`,
  `arena_domains.ex`, the `SimManager` id-prefix clauses). A follow-up phase
  is expected to make those derive from `arena_domains/0` here instead;
  until then this field is purely descriptive.

  `default_player_count` mirrors the `@default_player_count` module attribute
  the domain's own `LemonSim.Examples.*` module falls back to when no
  `:player_count` option is given. It's `nil` for domains that don't model a
  variable player count. Note this can differ from what the always-on arena
  actually configures at runtime (e.g. poker defaults to 4 seats on its own,
  but `LemonSimUi.Arena` runs its always-on poker table with 6).
  """

  alias LemonSim.Bench.Domains.Descriptor
  alias LemonSim.Examples

  @domains [
    %Descriptor{
      id: "courtroom",
      example_module: Examples.Courtroom,
      scorecard_module: Examples.Courtroom.Performance
    },
    %Descriptor{
      id: "diplomacy",
      example_module: Examples.Diplomacy,
      scorecard_module: Examples.Diplomacy.Performance
    },
    %Descriptor{
      id: "intel_network",
      example_module: Examples.IntelNetwork,
      scorecard_module: Examples.IntelNetwork.Performance
    },
    %Descriptor{
      id: "legislature",
      example_module: Examples.Legislature,
      scorecard_module: Examples.Legislature.Performance,
      default_player_count: 5
    },
    %Descriptor{
      id: "murder_mystery",
      example_module: Examples.MurderMystery,
      scorecard_module: Examples.MurderMystery.Performance
    },
    %Descriptor{
      id: "pandemic",
      example_module: Examples.Pandemic,
      scorecard_module: Examples.Pandemic.Performance,
      default_player_count: 6
    },
    %Descriptor{
      id: "poker",
      example_module: Examples.Poker,
      scorecard_module: Examples.Poker.Performance,
      league_adapter: Examples.Poker.League,
      sim_id_prefix: "pkr_",
      default_player_count: 4
    },
    %Descriptor{
      id: "space_station",
      example_module: Examples.SpaceStation,
      scorecard_module: Examples.SpaceStation.Performance,
      league_adapter: Examples.SpaceStation.League,
      sim_id_prefix: "spc_",
      default_player_count: 6
    },
    %Descriptor{
      id: "startup_incubator",
      example_module: Examples.StartupIncubator,
      scorecard_module: Examples.StartupIncubator.Performance
    },
    %Descriptor{
      id: "stock_market",
      example_module: Examples.StockMarket,
      scorecard_module: Examples.StockMarket.Performance,
      league_adapter: Examples.StockMarket.League,
      sim_id_prefix: "stk_",
      default_player_count: 4
    },
    %Descriptor{
      id: "supply_chain",
      example_module: Examples.SupplyChain,
      scorecard_module: Examples.SupplyChain.Performance
    },
    %Descriptor{
      id: "survivor",
      example_module: Examples.Survivor,
      scorecard_module: Examples.Survivor.Performance,
      league_adapter: Examples.Survivor.League,
      sim_id_prefix: "srv_",
      default_player_count: 8
    },
    %Descriptor{
      id: "tcg_shop",
      example_module: Examples.TcgShop,
      scorecard_module: Examples.TcgShop.Performance
    },
    %Descriptor{
      id: "vending_bench",
      example_module: Examples.VendingBench,
      scorecard_module: Examples.VendingBench.Performance
    },
    %Descriptor{
      id: "vending_bench_arena",
      example_module: Examples.VendingBench,
      scorecard_module: Examples.VendingBench.ArenaScorecard
    },
    %Descriptor{
      id: "werewolf",
      example_module: Examples.Werewolf,
      scorecard_module: Examples.Werewolf.Performance,
      league_adapter: Examples.Werewolf.League,
      sim_id_prefix: "ww_",
      default_player_count: 6
    }
  ]

  @doc "Every registered domain descriptor, in declaration order."
  @spec all() :: [Descriptor.t()]
  def all, do: @domains

  @doc "Every registered domain id."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@domains, & &1.id)

  @doc "Looks up a domain descriptor by id (string or atom). `nil` if unregistered."
  @spec get(String.t() | atom()) :: Descriptor.t() | nil
  def get(id), do: Enum.find(@domains, &(&1.id == to_string(id)))

  @doc "Looks up a domain descriptor by id (string or atom)."
  @spec fetch(String.t() | atom()) :: {:ok, Descriptor.t()} | :error
  def fetch(id) do
    case get(id) do
      nil -> :error
      descriptor -> {:ok, descriptor}
    end
  end

  @doc """
  Domains wired into the always-on arena league (those with a `league_adapter`).
  """
  @spec arena_domains() :: [Descriptor.t()]
  def arena_domains, do: Enum.filter(@domains, & &1.league_adapter)
end
