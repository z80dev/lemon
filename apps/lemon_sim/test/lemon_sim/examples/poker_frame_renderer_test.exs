defmodule LemonSim.Examples.PokerFrameRendererTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.FrameRenderer

  describe "render_frame/2" do
    test "renders the felt table, hand counter, and every seated player for a fresh hand" do
      world = Poker.initial_world(player_count: 4)
      entry = %{type: "init", step: 0, world: world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "NO-LIMIT HOLD'EM"
      assert svg =~ "Hand 1/#{world.max_hands}"

      for player_id <- Map.keys(world.players) do
        assert svg =~ player_id
      end
    end

    test "renders the final-results header once the game is over" do
      world = Poker.initial_world(player_count: 4)
      winner_id = world.players |> Map.keys() |> List.first()
      over_world = %{world | status: "game_over", winner: winner_id, winner_ids: [winner_id]}
      entry = %{type: "game_over", step: 42, world: over_world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "FINAL RESULTS"
    end
  end
end
