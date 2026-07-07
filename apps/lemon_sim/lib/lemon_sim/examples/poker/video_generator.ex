defmodule LemonSim.Examples.Poker.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Poker.{FrameRenderer, GameLog}
  alias LemonSim.Examples.Rendering.FrameChrome

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
    frame_renderer: FrameRenderer,
    dir_name: "lemon_poker_replay",
    read_entries: &GameLog.read_log/1

  defp hold_count_for(entry, base_hold) do
    type = FrameChrome.get(entry, "type", "step")
    events = FrameChrome.get(entry, "events", [])
    status = FrameChrome.get(entry, "world", %{}) |> FrameChrome.get("status", "in_progress")

    multiplier =
      cond do
        type == "init" -> 4
        type == "game_over" -> 6
        status == "game_over" -> 5
        has_event?(events, "hand_completed") -> 3
        has_event?(events, "hand_started") -> 2
        has_event?(events, "game_over") -> 3
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind), do: FrameChrome.has_event?(events, kind)
end
