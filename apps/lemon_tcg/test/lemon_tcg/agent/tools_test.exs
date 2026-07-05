defmodule LemonTcg.Agent.ToolsTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Agent.Tools
  alias LemonTcg.Comps.Sources.Fixture, as: CompFixture
  alias LemonTcg.Desk
  alias LemonTcg.MarketData.Sources.Fixture
  alias LemonTcg.Risk.Policy

  defp start_desk(collection) do
    start_supervised!(
      {Desk,
       starting_cash_usd: 10_000.0,
       watchlist: [collection],
       market_opts: [source: Fixture, comp_source: CompFixture, fresh?: true],
       policy: %Policy{
         max_trade_usd: 5_000.0,
         max_daily_spend_usd: 8_000.0,
         min_cash_reserve_usd: 0.0
       }}
    )
  end

  defp run_tool(tools, name, params) do
    tool = Enum.find(tools, &(&1.name == name))
    assert tool, "missing tool #{name}"
    {:ok, result} = tool.execute.("call_1", params, nil, nil)
    Enum.map_join(result.content, "\n", & &1.text)
  end

  test "tools drive a full browse → buy → dashboard → sell loop" do
    collection = "tools_loop_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)
    tools = Tools.build(desk)

    listings_text = run_tool(tools, "tcg_live_listings", %{"collection" => collection})
    [first_line | _] = String.split(listings_text, "\n")
    [mint | _] = String.split(first_line, " | ")

    buy_text = run_tool(tools, "tcg_live_buy", %{"collection" => collection, "mint" => mint})
    assert buy_text =~ "Bought #{mint}"

    dashboard = run_tool(tools, "tcg_live_dashboard", %{})
    assert dashboard =~ "1 positions"

    sell_text = run_tool(tools, "tcg_live_sell", %{"mint" => mint})
    assert sell_text =~ "Sold #{mint}"
  end

  test "floor tool reports the fixture floor" do
    collection = "tools_floor_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)

    text = run_tool(Tools.build(desk), "tcg_live_floor", %{"collection" => collection})
    assert text =~ "#{collection} floor:"
  end

  test "halt tool engages the kill switch" do
    collection = "tools_halt_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)
    tools = Tools.build(desk)

    assert run_tool(tools, "tcg_live_halt", %{}) =~ "Kill switch engaged"

    buy_text =
      run_tool(tools, "tcg_live_buy", %{"collection" => collection, "mint" => "whatever"})

    assert buy_text =~ "Buy rejected"
  end

  test "support_tool? matches read-only tools" do
    assert Tools.support_tool?(%{name: "tcg_live_dashboard"})
    assert Tools.support_tool?(%{name: "tcg_live_listings"})
    assert Tools.support_tool?(%{name: "tcg_live_check_comp"})
    assert Tools.support_tool?(%{name: "tcg_live_price_basis"})
    refute Tools.support_tool?(%{name: "tcg_live_buy"})
  end

  test "comp and basis tools answer through the desk" do
    collection = "tools_comps_#{System.unique_integer([:positive])}"
    desk = start_desk(collection)
    tools = Tools.build(desk)

    comp_text =
      run_tool(tools, "tcg_live_check_comp", %{
        "query" => "tools comp card #{collection} PSA 10"
      })

    assert comp_text =~ "psa_10"

    listings_text = run_tool(tools, "tcg_live_listings", %{"collection" => collection})
    [first_line | _] = String.split(listings_text, "\n")
    [mint | _] = String.split(first_line, " | ")

    basis_text =
      run_tool(tools, "tcg_live_price_basis", %{
        "collection" => collection,
        "mint" => mint,
        "query" => "tools basis card #{collection}",
        "grade" => "ungraded"
      })

    assert basis_text =~ "Round-trip edge"
    assert basis_text =~ "Discount to comp"
  end
end
