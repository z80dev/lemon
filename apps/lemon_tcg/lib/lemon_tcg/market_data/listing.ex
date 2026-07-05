defmodule LemonTcg.MarketData.Listing do
  @moduledoc """
  Normalized ask for one token on one venue, across chains.

  `price` is the amount in `currency` units ("SOL", "USDC", "ETH", ...);
  `price_usd` is precomputed when the source knows it cheaply (stables),
  otherwise `LemonTcg.Fx.listing_usd/2` converts on demand. Solana
  listings also carry `price_lamports`/`price_sol` for exact on-chain
  amounts; EVM tokens use `mint` as `"contract:token_id"`.
  """

  @type t :: %__MODULE__{
          venue: String.t(),
          chain: atom(),
          collection: String.t(),
          mint: String.t(),
          name: String.t() | nil,
          price: float() | nil,
          currency: String.t(),
          price_usd: float() | nil,
          price_lamports: non_neg_integer() | nil,
          price_sol: float() | nil,
          seller: String.t() | nil,
          raw: map()
        }

  @enforce_keys [:venue, :collection, :mint]
  defstruct [
    :venue,
    :collection,
    :mint,
    :name,
    :price,
    :price_usd,
    :price_lamports,
    :price_sol,
    :seller,
    chain: :solana,
    currency: "SOL",
    raw: %{}
  ]

  @lamports_per_sol 1_000_000_000

  def lamports_per_sol, do: @lamports_per_sol

  def sol_to_lamports(sol) when is_number(sol), do: round(sol * @lamports_per_sol)

  def lamports_to_sol(lamports) when is_integer(lamports),
    do: lamports / @lamports_per_sol

  @doc "Price in `currency` units, falling back to `price_sol` for SOL listings."
  @spec native_price(t()) :: float() | nil
  def native_price(%__MODULE__{price: price}) when is_number(price), do: price * 1.0
  def native_price(%__MODULE__{price_sol: sol}) when is_number(sol), do: sol * 1.0
  def native_price(%__MODULE__{}), do: nil
end
