defmodule LemonSim.Examples.Diplomacy.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Diplomacy.{FrameRenderer, GameLog}
  alias LemonSim.Examples.Rendering.FrameChrome

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
    frame_renderer: FrameRenderer,
    dir_name: "lemon_diplomacy_replay",
    read_entries: &GameLog.read_log/1

  defp hold_count_for(entry, base_hold) do
    type = FrameChrome.get(entry, "type", "step")
    events = FrameChrome.get(entry, "events", [])

    multiplier =
      cond do
        type == "init" -> 3
        type == "game_over" -> 5
        has_event?(events, "territory_captured") -> 3
        has_event?(events, "round_advanced") -> 2
        has_event?(events, "bounce") -> 2
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind), do: FrameChrome.has_event?(events, kind)
end
