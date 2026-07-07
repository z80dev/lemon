defmodule LemonSim.Examples.StockMarket.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.StockMarket.{FrameRenderer, GameLog}
  alias LemonSim.Examples.Rendering.FrameChrome

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
    frame_renderer: FrameRenderer,
    dir_name: "lemon_stock_market_replay",
    read_entries: &GameLog.read_log/1

  defp hold_count_for(entry, base_hold) do
    type = FrameChrome.get(entry, "type", "step")
    events = FrameChrome.get(entry, "events", [])

    multiplier =
      cond do
        type == "init" -> 4
        type == "game_over" -> 6
        has_event?(events, "round_resolved") -> 2
        has_event?(events, "place_trade") -> 2
        has_event?(events, "broadcast_market_call") -> 2
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind), do: FrameChrome.has_event?(events, kind)
end
