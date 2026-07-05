defmodule LemonTcg.BasisTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Basis

  test "deep discount to comp yields an attractive edge" do
    # $500 comp, token at $300: cost 306, physical net 435, redemption 40.
    result = Basis.evaluate(300.0, 500.0)

    assert result.token_cost_usd == 306.0
    assert result.physical_net_usd == 435.0
    assert result.redemption_cost_usd == 40.0
    assert result.edge_usd == 89.0
    assert result.verdict == "attractive"
    assert result.discount_to_comp_pct == 40.0
  end

  test "a token below comp can still be a negative-edge trade" do
    # 10% discount to comp gets eaten by fees and shipping.
    result = Basis.evaluate(90.0, 100.0)

    assert result.discount_to_comp_pct == 10.0
    assert result.edge_usd < 0.0
    assert result.verdict == "negative"
  end

  test "marginal band sits between negative and attractive" do
    result = Basis.evaluate(375.0, 500.0)

    assert result.edge_usd > 0.0
    assert result.edge_pct < 5.0
    assert result.verdict == "marginal"
  end

  test "fee overrides shift the edge" do
    cheap_route =
      Basis.evaluate(90.0, 100.0,
        taker_fee_bps: 0,
        redemption_fee_bps: 0,
        shipping_usd: 0.0,
        physical_sell_fee_bps: 0
      )

    assert cheap_route.edge_usd == 10.0
    assert cheap_route.verdict == "attractive"
  end
end
