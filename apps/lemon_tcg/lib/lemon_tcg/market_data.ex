defmodule LemonTcg.MarketData do
  @moduledoc """
  Facade over pluggable market data sources with a short-TTL cache.

  Collections may be venue-qualified (`"collector_crypt:Pokemon"`,
  `"opensea:courtyard-nft"` — see `LemonTcg.Markets`); unqualified names
  resolve to `opts[:source]`, then the `:lemon_tcg, :market_data_source`
  app env, then the live `Sources.MagicEden`. Returned listings and
  floors keep the caller's qualified collection string so positions and
  sell paths round-trip through the same market. Pass `fresh?: true` to
  bypass the cache.
  """

  alias LemonTcg.Markets
  alias LemonTcg.MarketData.Cache
  alias LemonTcg.MarketData.Sources.MagicEden

  @spec floor(String.t(), keyword()) :: {:ok, LemonTcg.MarketData.Floor.t()} | {:error, term()}
  def floor(collection, opts \\ []) when is_binary(collection) do
    {source, raw_collection} = Markets.resolve(collection, opts)

    with {:ok, floor} <-
           cached({:floor, source.venue(), raw_collection}, opts, fn ->
             source.floor(raw_collection, opts)
           end) do
      {:ok, %{floor | collection: collection}}
    end
  end

  @spec listings(String.t(), keyword()) ::
          {:ok, [LemonTcg.MarketData.Listing.t()]} | {:error, term()}
  def listings(collection, opts \\ []) when is_binary(collection) do
    {source, raw_collection} = Markets.resolve(collection, opts)
    limit = Keyword.get(opts, :limit, 20)

    with {:ok, listings} <-
           cached({:listings, source.venue(), raw_collection, limit}, opts, fn ->
             source.listings(raw_collection, opts)
           end) do
      {:ok, Enum.map(listings, &%{&1 | collection: collection})}
    end
  end

  @spec sol_price_usd(keyword()) :: {:ok, float()} | {:error, term()}
  def sol_price_usd(opts \\ []) do
    source = source(opts)

    cached({:sol_price_usd, source.venue()}, opts, fn ->
      source.sol_price_usd(opts)
    end)
  end

  @doc "USD value of `lamports` at the current SOL price."
  @spec lamports_to_usd(non_neg_integer(), keyword()) :: {:ok, float()} | {:error, term()}
  def lamports_to_usd(lamports, opts \\ []) when is_integer(lamports) do
    with {:ok, sol_usd} <- sol_price_usd(opts) do
      {:ok, Float.round(lamports / LemonTcg.MarketData.Listing.lamports_per_sol() * sol_usd, 2)}
    end
  end

  def source(opts) do
    Keyword.get(opts, :source) ||
      Application.get_env(:lemon_tcg, :market_data_source, MagicEden)
  end

  defp cached(key, opts, fun) do
    Cache.get_or_run(key, fun, Keyword.take(opts, [:ttl_ms, :fresh?]))
  end
end
