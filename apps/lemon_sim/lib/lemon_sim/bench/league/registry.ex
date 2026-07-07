defmodule LemonSim.Bench.League.Registry do
  @moduledoc """
  Static registry mapping scenario ids to their league adapters.

  Mirrors `LemonSim.Bench.Scorecard.Registry`: scenarios earn a league entry
  once they support per-seat model assignment and produce a final world their
  adapter can reduce to seats.
  """

  alias LemonSim.Bench.Domains

  @adapters Map.new(Domains.arena_domains(), &{&1.id, &1.league_adapter})

  @spec fetch(String.t() | atom()) :: {:ok, module()} | :error
  def fetch(scenario_id) do
    Map.fetch(@adapters, to_string(scenario_id))
  end

  @spec get(String.t() | atom()) :: module() | nil
  def get(scenario_id), do: Map.get(@adapters, to_string(scenario_id))

  @spec registered?(String.t() | atom()) :: boolean()
  def registered?(scenario_id), do: Map.has_key?(@adapters, to_string(scenario_id))

  @spec scenario_ids() :: [String.t()]
  def scenario_ids, do: @adapters |> Map.keys() |> Enum.sort()
end
