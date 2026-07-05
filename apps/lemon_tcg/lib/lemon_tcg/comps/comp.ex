defmodule LemonTcg.Comps.Comp do
  @moduledoc """
  Normalized physical-card comp: what the same card sells for off-chain,
  by grade, in USD.

  `prices` keys are the canonical grade buckets from `LemonTcg.Comps.Grade`
  (`"ungraded"`, `"grade_9"`, `"grade_9_5"`, `"psa_10"`, `"bgs_10"`,
  `"cgc_10"`, `"sgc_10"`); absent buckets mean the source had no sales data.
  """

  @type t :: %__MODULE__{
          query: String.t(),
          id: String.t() | nil,
          name: String.t() | nil,
          set: String.t() | nil,
          prices: %{String.t() => float()},
          source: String.t(),
          as_of_ms: integer(),
          raw: map()
        }

  @enforce_keys [:query, :prices, :source, :as_of_ms]
  defstruct [:query, :id, :name, :set, :prices, :source, :as_of_ms, raw: %{}]

  @doc "USD comp for a grade bucket, nil when the source lacks data for it."
  @spec price(t(), String.t()) :: float() | nil
  def price(%__MODULE__{prices: prices}, bucket) when is_binary(bucket) do
    Map.get(prices, bucket)
  end
end
