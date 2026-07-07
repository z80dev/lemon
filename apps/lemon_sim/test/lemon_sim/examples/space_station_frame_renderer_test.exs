defmodule LemonSim.Examples.SpaceStationFrameRendererTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.SpaceStation
  alias LemonSim.Examples.SpaceStation.FrameRenderer

  describe "render_frame/2" do
    test "renders the station header, round counter, and every crew member for a fresh game" do
      world = SpaceStation.initial_world(player_count: 5)
      entry = %{type: "init", step: 0, world: world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "SPACE STATION"
      assert svg =~ "Round 1/#{world.max_rounds}"

      for %{name: name} <- Map.values(world.players) do
        assert svg =~ name
      end
    end

    test "renders GAME OVER once the crew's fate is decided" do
      world = SpaceStation.initial_world(player_count: 5)
      over_world = %{world | status: "game_over", winner: "crew"}
      entry = %{type: "game_over", step: 30, world: over_world, events: []}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "GAME OVER"
    end
  end
end
