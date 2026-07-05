defmodule LemonTcg.Execution.Fill do
  @moduledoc """
  Result of an executed order on any venue, paper or live.
  """

  @type t :: %__MODULE__{
          side: :buy | :sell,
          venue: String.t(),
          collection: String.t(),
          mint: String.t(),
          name: String.t() | nil,
          price_lamports: non_neg_integer() | nil,
          price_usd: float(),
          fee_usd: float(),
          executed_at_ms: integer(),
          txid: String.t() | nil
        }

  @enforce_keys [:side, :venue, :collection, :mint, :price_usd, :fee_usd, :executed_at_ms]
  defstruct [
    :side,
    :venue,
    :collection,
    :mint,
    :name,
    :price_lamports,
    :price_usd,
    :fee_usd,
    :executed_at_ms,
    :txid
  ]
end
