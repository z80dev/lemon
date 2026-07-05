defmodule LemonTcg.Markets do
  @moduledoc """
  Venue-qualified collection addressing.

  Watchlist entries name their market with a prefix:

      "collector_crypt:Pokemon"     — Collector Crypt, Pokemon category
      "collector_crypt:all"         — Collector Crypt, whole marketplace
      "phygitals:all"               — Phygitals feed (or a search term)
      "opensea:courtyard-nft"       — OpenSea slug (Courtyard, Polygon)
      "magic_eden:collector_crypt"  — Magic Eden symbol
      "fixture:anything"            — deterministic offline source

  Unqualified strings resolve to the configured default source
  (`opts[:source]` / app env), which keeps single-source desks and the
  existing tests working unchanged.
  """

  alias LemonTcg.MarketData

  @sources %{
    "collector_crypt" => LemonTcg.MarketData.Sources.CollectorCrypt,
    "phygitals" => LemonTcg.MarketData.Sources.Phygitals,
    "opensea" => LemonTcg.MarketData.Sources.OpenSea,
    "magic_eden" => LemonTcg.MarketData.Sources.MagicEden,
    "fixture" => LemonTcg.MarketData.Sources.Fixture
  }

  @doc "Known venue prefixes."
  def venues, do: Map.keys(@sources)

  @doc "Resolve a (possibly qualified) collection to `{source_module, collection}`."
  @spec resolve(String.t(), keyword()) :: {module(), String.t()}
  def resolve(qualified, opts \\ []) when is_binary(qualified) do
    case String.split(qualified, ":", parts: 2) do
      [prefix, rest] when rest != "" ->
        case Map.get(@sources, prefix) do
          nil -> {MarketData.source(opts), qualified}
          source -> {source, rest}
        end

      _ ->
        {MarketData.source(opts), qualified}
    end
  end
end
