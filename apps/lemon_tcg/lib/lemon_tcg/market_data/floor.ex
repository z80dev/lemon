defmodule LemonTcg.MarketData.Floor do
  @moduledoc """
  Normalized floor-price snapshot for one collection on one venue.
  """

  @type t :: %__MODULE__{
          collection: String.t(),
          venue: String.t(),
          floor_lamports: non_neg_integer() | nil,
          floor_sol: float() | nil,
          listed_count: non_neg_integer() | nil,
          as_of_ms: integer()
        }

  @enforce_keys [:collection, :venue, :as_of_ms]
  defstruct [:collection, :venue, :floor_lamports, :floor_sol, :listed_count, :as_of_ms]
end
