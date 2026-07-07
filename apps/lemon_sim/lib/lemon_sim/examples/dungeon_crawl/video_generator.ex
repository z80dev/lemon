defmodule LemonSim.Examples.DungeonCrawl.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.DungeonCrawl.{FrameRenderer, GameLog}
  alias LemonSim.Examples.Rendering.FrameChrome

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
    frame_renderer: FrameRenderer,
    dir_name: "lemon_dungeon_crawl_replay",
    read_entries: &GameLog.read_log/1

  defp hold_count_for(entry, base_hold) do
    type = FrameChrome.get(entry, "type", "step")
    events = FrameChrome.get(entry, "events", [])

    multiplier =
      cond do
        type == "init" -> 3
        type == "game_over" -> 5
        has_event?(events, "enemy_killed") -> 2
        has_event?(events, "room_cleared") -> 3
        has_event?(events, "room_entered") -> 2
        has_event?(events, "trap_triggered") -> 2
        has_event?(events, "adventurer_downed") -> 3
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind), do: FrameChrome.has_event?(events, kind)
end
