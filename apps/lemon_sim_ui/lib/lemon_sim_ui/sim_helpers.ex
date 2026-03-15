defmodule LemonSimUi.SimHelpers do
  @moduledoc """
  Utility functions for inspecting and summarizing sim state.
  """

  alias LemonCore.MapHelpers
  alias LemonSim.State

  @spec infer_domain_type(State.t()) ::
          :tic_tac_toe | :skirmish | :werewolf | :stock_market | :survivor | :space_station | :auction | :diplomacy | :dungeon_crawl | :unknown
  def infer_domain_type(%State{world: world}) do
    cond do
      Map.has_key?(world, :board) or Map.has_key?(world, "board") -> :tic_tac_toe
      Map.has_key?(world, :units) or Map.has_key?(world, "units") -> :skirmish
      Map.has_key?(world, :stocks) or Map.has_key?(world, "stocks") -> :stock_market
      Map.has_key?(world, :systems) or Map.has_key?(world, "systems") -> :space_station
      Map.has_key?(world, :tribes) or Map.has_key?(world, "tribes") -> :survivor
      Map.has_key?(world, :auction_schedule) or Map.has_key?(world, "auction_schedule") -> :auction
      Map.has_key?(world, :territories) or Map.has_key?(world, "territories") -> :diplomacy
      Map.has_key?(world, :rooms) or Map.has_key?(world, "rooms") -> :dungeon_crawl
      Map.has_key?(world, :day_number) or Map.has_key?(world, "day_number") -> :werewolf
      Map.has_key?(world, :players) or Map.has_key?(world, "players") -> :werewolf
      true -> :unknown
    end
  end

  @spec sim_summary(State.t()) :: map()
  def sim_summary(%State{} = state) do
    %{
      sim_id: state.sim_id,
      version: state.version,
      domain_type: infer_domain_type(state),
      status: MapHelpers.get_key(state.world, :status) || "unknown",
      event_count: length(state.recent_events),
      last_activity: last_event_time(state),
      world_summary: world_summary(state)
    }
  end

  defp last_event_time(%State{recent_events: []}), do: nil

  defp last_event_time(%State{recent_events: events}) do
    events
    |> List.last()
    |> Map.get(:ts_ms)
  end

  defp world_summary(%State{} = state) do
    case infer_domain_type(state) do
      :tic_tac_toe ->
        player = MapHelpers.get_key(state.world, :current_player)
        moves = MapHelpers.get_key(state.world, :move_count) || 0
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "#{player}'s turn (#{moves} moves)"
        end

      :skirmish ->
        round = MapHelpers.get_key(state.world, :round) || 1
        actor = MapHelpers.get_key(state.world, :active_actor_id)
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Round #{round} - #{actor}"
        end

      :werewolf ->
        phase = MapHelpers.get_key(state.world, :phase) || "unknown"
        day = MapHelpers.get_key(state.world, :day_number) || 1
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Day #{day} - Phase: #{phase}"
        end

      :stock_market ->
        round = MapHelpers.get_key(state.world, :round) || 1
        phase = MapHelpers.get_key(state.world, :phase) || "unknown"
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Round #{round} - #{phase}"
        end

      :survivor ->
        episode = MapHelpers.get_key(state.world, :episode) || 1
        phase = MapHelpers.get_key(state.world, :phase) || "unknown"
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Sole Survivor: #{winner}"
        else
          "Ep #{episode} - #{phase}"
        end

      :space_station ->
        round = MapHelpers.get_key(state.world, :round) || 1
        phase = MapHelpers.get_key(state.world, :phase) || "unknown"
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Round #{round}/8 - #{phase}"
        end

      :auction ->
        round = MapHelpers.get_key(state.world, :current_round) || 1
        phase = MapHelpers.get_key(state.world, :phase) || "bidding"
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Round #{round}/8 - #{phase}"
        end

      :diplomacy ->
        round = MapHelpers.get_key(state.world, :round) || 1
        phase = MapHelpers.get_key(state.world, :phase) || "diplomacy"
        winner = MapHelpers.get_key(state.world, :winner)

        if winner do
          "Winner: #{winner}"
        else
          "Round #{round}/10 - #{phase}"
        end

      :dungeon_crawl ->
        room = (MapHelpers.get_key(state.world, :current_room) || 0) + 1
        status = MapHelpers.get_key(state.world, :status)

        case status do
          "won" -> "Dungeon Cleared!"
          "lost" -> "Party Wiped (Room #{room})"
          _ -> "Room #{room}/5"
        end

      :unknown ->
        "v#{state.version}"
    end
  end

  @spec format_ts(non_neg_integer() | nil) :: String.t()
  def format_ts(nil), do: "--"

  def format_ts(ts_ms) when is_integer(ts_ms) do
    seconds_ago = div(System.system_time(:millisecond) - ts_ms, 1000)

    cond do
      seconds_ago < 5 -> "just now"
      seconds_ago < 60 -> "#{seconds_ago}s ago"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)}m ago"
      true -> "#{div(seconds_ago, 3600)}h ago"
    end
  end

  @spec status_color(String.t() | nil) :: String.t()
  def status_color("in_progress"), do: "text-blue-400"
  def status_color("won"), do: "text-emerald-400"
  def status_color("draw"), do: "text-amber-400"
  def status_color("lost"), do: "text-red-400"
  def status_color("game_over"), do: "text-emerald-400"
  def status_color("finished"), do: "text-gray-400"
  def status_color(_), do: "text-gray-500"

  @spec domain_label(atom()) :: String.t()
  def domain_label(:tic_tac_toe), do: "Tic Tac Toe"
  def domain_label(:skirmish), do: "Skirmish"
  def domain_label(:werewolf), do: "Werewolf"
  def domain_label(:stock_market), do: "Stock Market"
  def domain_label(:survivor), do: "Survivor"
  def domain_label(:space_station), do: "Space Station"
  def domain_label(:auction), do: "Auction"
  def domain_label(:diplomacy), do: "Diplomacy"
  def domain_label(:dungeon_crawl), do: "Dungeon Crawl"
  def domain_label(_), do: "Unknown"

  @spec domain_badge_color(atom()) :: String.t()
  def domain_badge_color(:tic_tac_toe), do: "bg-violet-900/60 text-violet-300 border-violet-500/30"
  def domain_badge_color(:skirmish), do: "bg-orange-900/60 text-orange-300 border-orange-500/30"
  def domain_badge_color(:werewolf), do: "bg-fuchsia-900/60 text-fuchsia-300 border-fuchsia-500/30"
  def domain_badge_color(:stock_market), do: "bg-emerald-900/60 text-emerald-300 border-emerald-500/30"
  def domain_badge_color(:survivor), do: "bg-amber-900/60 text-amber-300 border-amber-500/30"
  def domain_badge_color(:space_station), do: "bg-cyan-900/60 text-cyan-300 border-cyan-500/30"
  def domain_badge_color(:auction), do: "bg-yellow-900/60 text-yellow-300 border-yellow-500/30"
  def domain_badge_color(:diplomacy), do: "bg-rose-900/60 text-rose-300 border-rose-500/30"
  def domain_badge_color(:dungeon_crawl), do: "bg-purple-900/60 text-purple-300 border-purple-500/30"
  def domain_badge_color(_), do: "bg-gray-800/60 text-gray-400 border-gray-600/30"
end
