defmodule LemonSim.Examples.StockMarketFrameRendererTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.StockMarket
  alias LemonSim.Examples.StockMarket.FrameRenderer

  describe "render_frame/2" do
    test "renders the exchange header, round counter, and every trader for a fresh game" do
      world = StockMarket.initial_world(player_count: 4)
      entry = %{type: "init", step: 0, world: world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "STOCK EXCHANGE"
      assert svg =~ "Round 1/#{world.max_rounds}"

      for %{name: name} <- Map.values(world.players) do
        assert svg =~ name
      end
    end

    test "renders the final-results header once trading ends" do
      world = StockMarket.initial_world(player_count: 4)
      winner_id = world.players |> Map.keys() |> List.first()
      over_world = %{world | status: "game_over", winner: winner_id}
      entry = %{type: "game_over", step: 20, world: over_world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "FINAL RESULTS"
    end
  end
end
