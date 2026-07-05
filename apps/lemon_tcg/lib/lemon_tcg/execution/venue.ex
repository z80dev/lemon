defmodule LemonTcg.Execution.Venue do
  @moduledoc """
  Behaviour for an execution venue.

  `LemonTcg.Execution.Venues.Paper` fills against market data; an on-chain
  venue implements the same contract with wallet signing behind it. Venues
  never see the risk policy — the desk enforces risk before calling them.
  """

  alias LemonTcg.Execution.Fill
  alias LemonTcg.MarketData.Listing
  alias LemonTcg.Portfolio

  @callback buy(Listing.t(), opts :: keyword()) :: {:ok, Fill.t()} | {:error, term()}

  @callback sell(Portfolio.position(), opts :: keyword()) :: {:ok, Fill.t()} | {:error, term()}

  @callback name() :: String.t()
end
