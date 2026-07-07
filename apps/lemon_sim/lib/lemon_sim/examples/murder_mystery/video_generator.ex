defmodule LemonSim.Examples.MurderMystery.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.MurderMystery.{FrameRenderer, GameLog}
  alias LemonSim.Examples.Rendering.FrameChrome

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
    frame_renderer: FrameRenderer,
    dir_name: "lemon_murder_mystery_replay",
    read_entries: &GameLog.read_log/1

  defp hold_count_for(entry, base_hold) do
    type = FrameChrome.get(entry, "type", "step")
    events = FrameChrome.get(entry, "events", [])

    multiplier =
      cond do
        type == "init" -> 3
        type == "game_over" -> 6
        has_event?(events, "accusation_made") -> 4
        has_event?(events, "game_over") -> 5
        has_event?(events, "round_advanced") -> 2
        has_event?(events, "phase_changed") -> 2
        has_event?(events, "evidence_planted") -> 3
        has_event?(events, "clue_destroyed") -> 3
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind), do: FrameChrome.has_event?(events, kind)
end
