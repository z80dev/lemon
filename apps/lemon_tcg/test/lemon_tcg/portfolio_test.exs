defmodule LemonTcg.PortfolioTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Execution.Fill
  alias LemonTcg.Portfolio

  defp fill(side, mint, price, fee) do
    %Fill{
      side: side,
      venue: "paper",
      collection: "test_collection",
      mint: mint,
      price_usd: price,
      fee_usd: fee,
      executed_at_ms: System.system_time(:millisecond)
    }
  end

  test "buy moves cash to a position and records fees" do
    {:ok, portfolio} = Portfolio.apply_buy(Portfolio.new(500.0), fill(:buy, "m1", 100.0, 2.0))

    assert portfolio.cash_usd == 398.0
    assert %{cost_basis_usd: 100.0} = portfolio.positions["m1"]
    assert portfolio.fees_usd == 2.0
  end

  test "buy rejects insufficient cash and duplicate positions" do
    portfolio = Portfolio.new(50.0)

    assert {:error, {:insufficient_cash, _, _}} =
             Portfolio.apply_buy(portfolio, fill(:buy, "m1", 100.0, 2.0))

    {:ok, holding} = Portfolio.apply_buy(Portfolio.new(500.0), fill(:buy, "m1", 100.0, 2.0))

    assert {:error, {:already_holding, "m1"}} =
             Portfolio.apply_buy(holding, fill(:buy, "m1", 90.0, 2.0))
  end

  test "sell realizes pnl net of fees" do
    {:ok, portfolio} = Portfolio.apply_buy(Portfolio.new(500.0), fill(:buy, "m1", 100.0, 2.0))
    {:ok, portfolio} = Portfolio.apply_sell(portfolio, fill(:sell, "m1", 130.0, 3.0))

    assert portfolio.positions == %{}
    assert portfolio.realized_pnl_usd == 27.0
    assert portfolio.cash_usd == 525.0
  end

  test "sell of unheld mint is rejected" do
    assert {:error, {:not_holding, "ghost"}} =
             Portfolio.apply_sell(Portfolio.new(100.0), fill(:sell, "ghost", 10.0, 0.5))
  end

  test "mark_to_market uses floors and falls back to cost basis" do
    {:ok, portfolio} = Portfolio.apply_buy(Portfolio.new(500.0), fill(:buy, "m1", 100.0, 2.0))

    marked = Portfolio.mark_to_market(portfolio, %{"test_collection" => 150.0})
    assert marked.inventory_value_usd == 150.0
    assert marked.unrealized_pnl_usd == 50.0
    assert marked.net_worth_usd == 548.0
    assert marked.unpriced_positions == 0

    unpriced = Portfolio.mark_to_market(portfolio, %{})
    assert unpriced.inventory_value_usd == 100.0
    assert unpriced.unpriced_positions == 1
  end
end
