defmodule LemonTcg.DeskTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Desk
  alias LemonTcg.MarketData.Sources.Fixture
  alias LemonTcg.Risk.Policy

  # Fixture SOL price is 150.0 USD unless overridden; collection names are
  # unique per test so shared fixture/cache state cannot collide.

  defp start_desk(collection, opts \\ []) do
    defaults = [
      starting_cash_usd: 10_000.0,
      watchlist: [collection],
      market_opts: [source: Fixture, fresh?: true],
      policy: %Policy{
        max_trade_usd: 5_000.0,
        max_daily_spend_usd: 8_000.0,
        min_cash_reserve_usd: 0.0
      }
    ]

    start_supervised!({Desk, Keyword.merge(defaults, opts)})
  end

  test "buy → snapshot → sell round trip through the paper venue" do
    collection = "desk_round_trip_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)

    {:ok, [cheapest | _]} = Desk.listings(desk, collection)
    assert {:ok, fill} = Desk.buy(desk, collection, cheapest.mint)
    assert fill.side == :buy
    assert fill.price_usd > 0.0

    snapshot = Desk.snapshot(desk)
    assert snapshot.mark.position_count == 1
    assert snapshot.mark.cash_usd < 10_000.0
    assert Map.has_key?(snapshot.floors_usd, collection)

    assert {:ok, sell_fill} = Desk.sell(desk, cheapest.mint)
    assert sell_fill.side == :sell
    assert Desk.snapshot(desk).mark.position_count == 0
  end

  test "risk blocks are surfaced to the caller" do
    collection = "desk_risk_#{System.unique_integer([:positive])}"

    desk =
      start_desk(collection,
        policy: %Policy{max_trade_usd: 0.01, max_daily_spend_usd: 8_000.0}
      )

    {:ok, [cheapest | _]} = Desk.listings(desk, collection)

    assert {:error, {:risk_blocked, {:max_trade_exceeded, _, _}}} =
             Desk.buy(desk, collection, cheapest.mint)
  end

  test "halt blocks buys until resume; sells stay available" do
    collection = "desk_halt_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)

    {:ok, [cheapest, second | _]} = Desk.listings(desk, collection)
    assert {:ok, _} = Desk.buy(desk, collection, cheapest.mint)

    :ok = Desk.halt(desk)

    assert {:error, {:risk_blocked, :kill_switch_engaged}} =
             Desk.buy(desk, collection, second.mint)

    assert {:ok, _} = Desk.sell(desk, cheapest.mint)

    :ok = Desk.resume(desk)
    assert {:ok, _} = Desk.buy(desk, collection, second.mint)
  end

  test "buying an unknown mint fails cleanly" do
    collection = "desk_unknown_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)

    assert {:error, {:listing_not_found, "nope"}} = Desk.buy(desk, collection, "nope")
  end
end
