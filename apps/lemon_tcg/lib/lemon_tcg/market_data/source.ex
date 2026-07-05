defmodule LemonTcg.MarketData.Source do
  @moduledoc """
  Behaviour for a market data source.

  A source answers three questions: what is the floor for a collection,
  what asks are live, and what is SOL worth in USD. Implementations must be
  side-effect free beyond the HTTP call itself so they can be swapped for
  `LemonTcg.MarketData.Sources.Fixture` in tests and offline runs.
  """

  alias LemonTcg.MarketData.{Floor, Listing}

  @callback floor(collection :: String.t(), opts :: keyword()) ::
              {:ok, Floor.t()} | {:error, term()}

  @callback listings(collection :: String.t(), opts :: keyword()) ::
              {:ok, [Listing.t()]} | {:error, term()}

  @callback sol_price_usd(opts :: keyword()) :: {:ok, float()} | {:error, term()}

  @callback venue() :: String.t()
end
