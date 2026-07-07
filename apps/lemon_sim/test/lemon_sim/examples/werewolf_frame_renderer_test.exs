defmodule LemonSim.Examples.WerewolfFrameRendererTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.{FrameRenderer, TranscriptLogger}

  describe "render_frame/2" do
    test "renders a game_start frame with the title, day counter, and every player seat" do
      world = Werewolf.initial_world(player_count: 5)

      player_info =
        Enum.into(world.players, %{}, fn {id, p} ->
          {id, %{role: p.role, model: "openai/gpt-5", name: nil}}
        end)

      entry = %{
        type: "game_start",
        players: player_info,
        world: %{phase: world.phase, day_number: world.day_number}
      }

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "WEREWOLF"
      assert svg =~ "Day 1"

      for player_id <- Map.keys(world.players) do
        assert svg =~ player_id
      end
    end

    test "renders a turn_result frame built from the real transcript logger" do
      world = Werewolf.initial_world(player_count: 5) |> Map.put(:phase, "night")
      step_meta = TranscriptLogger.step_meta(world)
      entry = TranscriptLogger.turn_result_entry(1, step_meta, world)

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360, players: %{})

      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ "Step 1"
      assert svg =~ "Night"
    end

    test "renders the game_over banner for the winning side" do
      world = Werewolf.initial_world(player_count: 5)
      entry = %{type: "game_over", winner: "villagers", players: %{}, world: world}

      svg = FrameRenderer.render_frame(entry, width: 640, height: 360)

      assert svg =~ "VILLAGERS WIN!"
    end
  end
end
