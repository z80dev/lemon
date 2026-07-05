defmodule LemonTcg.Basis do
  @moduledoc """
  Token-vs-physical basis: is a tokenized card cheap against its
  real-world comp after every cost of closing the gap?

  The hard arbitrage route is buy token → redeem physical → sell
  physical. `evaluate/3` prices that full round trip:

      token cost   = ask × (1 + taker fee)
      redemption   = comp × redemption fee + shipping
      physical net = comp × (1 − physical marketplace fee)
      edge         = physical net − redemption − token cost

  Defaults model the current venues: 2% taker (Magic Eden-ish), 2%
  redemption (Collector Crypt vault withdrawal), $30 combined shipping,
  13% physical sell fee (eBay all-in). All tunable per call:

    * `:taker_fee_bps` — default 200
    * `:redemption_fee_bps` — default 200
    * `:shipping_usd` — default 30.0
    * `:physical_sell_fee_bps` — default 1300

  Verdicts: `"attractive"` (≥5% edge on cost), `"marginal"` (positive
  but thin), `"negative"`. The discount-to-comp is reported separately —
  a token can trade below comp and still be a negative-edge buy once
  fees and shipping eat the gap.
  """

  @default_taker_fee_bps 200
  @default_redemption_fee_bps 200
  @default_shipping_usd 30.0
  @default_physical_sell_fee_bps 1300

  @attractive_edge_pct 5.0

  @type evaluation :: %{
          token_ask_usd: float(),
          token_cost_usd: float(),
          comp_usd: float(),
          physical_net_usd: float(),
          redemption_cost_usd: float(),
          edge_usd: float(),
          edge_pct: float(),
          discount_to_comp_pct: float(),
          verdict: String.t()
        }

  @spec evaluate(number(), number(), keyword()) :: evaluation()
  def evaluate(token_ask_usd, comp_usd, opts \\ [])
      when is_number(token_ask_usd) and token_ask_usd > 0 and is_number(comp_usd) and
             comp_usd > 0 do
    taker_fee_bps = Keyword.get(opts, :taker_fee_bps, @default_taker_fee_bps)
    redemption_fee_bps = Keyword.get(opts, :redemption_fee_bps, @default_redemption_fee_bps)
    shipping_usd = Keyword.get(opts, :shipping_usd, @default_shipping_usd)

    physical_sell_fee_bps =
      Keyword.get(opts, :physical_sell_fee_bps, @default_physical_sell_fee_bps)

    token_cost = token_ask_usd * (1 + taker_fee_bps / 10_000)
    redemption_cost = comp_usd * redemption_fee_bps / 10_000 + shipping_usd
    physical_net = comp_usd * (1 - physical_sell_fee_bps / 10_000)
    edge = physical_net - redemption_cost - token_cost
    edge_pct = edge / token_cost * 100

    %{
      token_ask_usd: round2(token_ask_usd),
      token_cost_usd: round2(token_cost),
      comp_usd: round2(comp_usd),
      physical_net_usd: round2(physical_net),
      redemption_cost_usd: round2(redemption_cost),
      edge_usd: round2(edge),
      edge_pct: round2(edge_pct),
      discount_to_comp_pct: round2((1 - token_ask_usd / comp_usd) * 100),
      verdict: verdict(edge, edge_pct)
    }
  end

  defp verdict(edge, edge_pct) do
    cond do
      edge_pct >= @attractive_edge_pct -> "attractive"
      edge > 0 -> "marginal"
      true -> "negative"
    end
  end

  defp round2(value), do: Float.round(value * 1.0, 2)
end
