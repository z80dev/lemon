defmodule LemonTcg.RiskTest do
  use ExUnit.Case, async: true

  alias LemonTcg.{Portfolio, Risk}
  alias LemonTcg.Risk.Policy

  @policy %Policy{
    max_trade_usd: 100.0,
    max_daily_spend_usd: 150.0,
    min_cash_reserve_usd: 50.0,
    allowed_collections: ["good_collection"]
  }

  test "allows a compliant buy" do
    assert :ok = Risk.check(@policy, Portfolio.new(500.0), {:buy, "good_collection", 80.0})
  end

  test "kill switch blocks buys but never sells" do
    policy = %{@policy | kill_switch: true}
    portfolio = Portfolio.new(500.0)

    assert {:error, {:risk_blocked, :kill_switch_engaged}} =
             Risk.check(policy, portfolio, {:buy, "good_collection", 10.0})

    assert :ok = Risk.check(policy, portfolio, {:sell, "any_mint"})
  end

  test "blocks collections off the allowlist" do
    assert {:error, {:risk_blocked, {:collection_not_allowed, "sketchy"}}} =
             Risk.check(@policy, Portfolio.new(500.0), {:buy, "sketchy", 10.0})
  end

  test "empty allowlist allows any collection" do
    policy = %{@policy | allowed_collections: []}
    assert :ok = Risk.check(policy, Portfolio.new(500.0), {:buy, "anything", 10.0})
  end

  test "blocks oversized trades" do
    assert {:error, {:risk_blocked, {:max_trade_exceeded, _, _}}} =
             Risk.check(@policy, Portfolio.new(500.0), {:buy, "good_collection", 101.0})
  end

  test "blocks trades that would exceed the daily spend window" do
    portfolio = Portfolio.new(1_000.0)
    ledger = LemonTcg.Ledger.record(portfolio.ledger, :buy, 90.0)
    portfolio = %{portfolio | ledger: ledger}

    assert {:error, {:risk_blocked, {:daily_spend_exceeded, spent, 150.0}}} =
             Risk.check(@policy, portfolio, {:buy, "good_collection", 70.0})

    assert spent == 90.0
  end

  test "blocks trades that breach the cash reserve" do
    assert {:error, {:risk_blocked, {:cash_reserve_breached, _, _}}} =
             Risk.check(@policy, Portfolio.new(120.0), {:buy, "good_collection", 80.0})
  end
end
