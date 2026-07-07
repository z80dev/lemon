defmodule LemonSim.Examples.SurvivorFrameRendererTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Survivor
  alias LemonSim.Examples.Survivor.FrameRenderer

  describe "render_frame/2" do
    test "renders the SURVIVOR header, episode counter, and every castaway for a fresh game" do
      world = Survivor.initial_world(player_count: 8)
      entry = %{type: "init", step: 0, world: world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "SURVIVOR"
      assert svg =~ "Episode 1"
      assert svg =~ "CHALLENGE"

      for player_id <- Map.keys(world.players) do
        assert svg =~ player_id
      end
    end

    test "renders GAME OVER once a sole survivor is crowned" do
      world = Survivor.initial_world(player_count: 8)
      winner_id = world.players |> Map.keys() |> List.first()
      over_world = %{world | status: "game_over", winner: winner_id}
      entry = %{type: "game_over", step: 50, world: over_world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "GAME OVER"
      assert svg =~ "SOLE SURVIVOR CROWNED"
    end
  end
end
