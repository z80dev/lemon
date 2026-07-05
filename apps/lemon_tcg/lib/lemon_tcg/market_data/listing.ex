defmodule LemonTcg.MarketData.Listing do
  @moduledoc """
  Normalized ask for one token on one venue.

  `price_lamports` is authoritative for Solana venues; `price_sol` is the
  same amount as a float for display and USD conversion.
  """

  @type t :: %__MODULE__{
          venue: String.t(),
          collection: String.t(),
          mint: String.t(),
          name: String.t() | nil,
          price_lamports: non_neg_integer(),
          price_sol: float(),
          seller: String.t() | nil,
          raw: map()
        }

  @enforce_keys [:venue, :collection, :mint, :price_lamports, :price_sol]
  defstruct [:venue, :collection, :mint, :name, :price_lamports, :price_sol, :seller, raw: %{}]

  @lamports_per_sol 1_000_000_000

  def lamports_per_sol, do: @lamports_per_sol

  def sol_to_lamports(sol) when is_number(sol), do: round(sol * @lamports_per_sol)

  def lamports_to_sol(lamports) when is_integer(lamports),
    do: lamports / @lamports_per_sol
end
