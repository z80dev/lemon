defmodule LemonTcg.MarketData.Sources.Fixture do
  @moduledoc """
  Deterministic offline source for tests, CI, and paper-trading demos.

  Quotes are derived from the collection name, so runs are reproducible
  without network access. Override any quote with `put_floor/2`,
  `put_listings/2`, or `put_sol_price/1`; overrides live in a shared ETS
  table, so async tests should use unique collection names for isolation
  (the SOL price override is global).
  """

  @behaviour LemonTcg.MarketData.Source

  alias LemonTcg.MarketData.{Floor, Listing}

  @default_sol_usd 150.0
  @table :lemon_tcg_fixture_overrides

  @impl true
  def venue, do: "fixture"

  @impl true
  def floor(collection, _opts \\ []) do
    case override(:floor, collection) do
      nil ->
        floor_lamports = base_floor_lamports(collection)

        {:ok,
         %Floor{
           collection: collection,
           venue: venue(),
           floor_lamports: floor_lamports,
           floor_sol: Listing.lamports_to_sol(floor_lamports),
           listed_count: 25,
           as_of_ms: System.system_time(:millisecond)
         }}

      %Floor{} = floor ->
        {:ok, floor}
    end
  end

  @impl true
  def listings(collection, opts \\ []) do
    case override(:listings, collection) do
      nil ->
        limit = Keyword.get(opts, :limit, 20)
        floor_lamports = base_floor_lamports(collection)

        listings =
          for i <- 1..min(limit, 5) do
            price_lamports = floor_lamports + (i - 1) * div(floor_lamports, 20)

            %Listing{
              venue: venue(),
              collection: collection,
              mint: "#{collection}_mint_#{i}",
              name: "#{collection} card ##{i}",
              price_lamports: price_lamports,
              price_sol: Listing.lamports_to_sol(price_lamports),
              seller: "fixture_seller_#{i}"
            }
          end

        {:ok, listings}

      listings when is_list(listings) ->
        {:ok, listings}
    end
  end

  @impl true
  def sol_price_usd(_opts \\ []) do
    {:ok, override(:sol_price, :global) || @default_sol_usd}
  end

  def put_floor(collection, %Floor{} = floor), do: put_override(:floor, collection, floor)

  def put_listings(collection, listings) when is_list(listings),
    do: put_override(:listings, collection, listings)

  def put_sol_price(price) when is_number(price),
    do: put_override(:sol_price, :global, price * 1.0)

  def clear_overrides do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp base_floor_lamports(collection) do
    # Stable per-collection price in the 0.5-8.5 SOL band.
    base = rem(:erlang.phash2(collection), 8_000_000_000)
    500_000_000 + base
  end

  defp override(kind, key) do
    ensure_table()

    case :ets.lookup(@table, {kind, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  defp put_override(kind, key, value) do
    ensure_table()
    :ets.insert(@table, {{kind, key}, value})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          # Raced another process creating it; the table now exists.
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
