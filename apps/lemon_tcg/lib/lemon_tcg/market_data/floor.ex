defmodule LemonTcg.MarketData.Floor do
  @moduledoc """
  Normalized floor-price snapshot for one collection on one venue.

  `floor` is in `currency` units; `floor_usd` is precomputed when the
  source knows it (stables), otherwise `LemonTcg.Fx.floor_usd/2` converts.
  Solana floors also carry lamports/SOL fields.
  """

  @type t :: %__MODULE__{
          collection: String.t(),
          venue: String.t(),
          chain: atom(),
          floor: float() | nil,
          currency: String.t(),
          floor_usd: float() | nil,
          floor_lamports: non_neg_integer() | nil,
          floor_sol: float() | nil,
          listed_count: non_neg_integer() | nil,
          as_of_ms: integer()
        }

  @enforce_keys [:collection, :venue, :as_of_ms]
  defstruct [
    :collection,
    :venue,
    :floor,
    :floor_usd,
    :floor_lamports,
    :floor_sol,
    :listed_count,
    :as_of_ms,
    chain: :solana,
    currency: "SOL"
  ]

  @doc "Floor in `currency` units, falling back to `floor_sol`."
  @spec native_floor(t()) :: float() | nil
  def native_floor(%__MODULE__{floor: floor}) when is_number(floor), do: floor * 1.0
  def native_floor(%__MODULE__{floor_sol: sol}) when is_number(sol), do: sol * 1.0
  def native_floor(%__MODULE__{}), do: nil
end
