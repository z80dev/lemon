defmodule LemonSimUi.SimHelpers do
  @moduledoc """
  Utility functions for inspecting and summarizing sim state.
  """

  alias LemonCore.MapHelpers
  alias LemonSim.State

  @spec infer_domain_type(State.t()) :: :tic_tac_toe | :skirmish | :unknown
  def infer_domain_type(%State{world: world}) do
    cond do
      Map.has_key?(world, :board) or Map.has_key?(world, "board") -> :tic_tac_toe
      Map.has_key?(world, :units) or Map.has_key?(world, "units") -> :skirmish
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
  def status_color("finished"), do: "text-gray-400"
  def status_color(_), do: "text-gray-500"

  @spec domain_label(:tic_tac_toe | :skirmish | :unknown) :: String.t()
  def domain_label(:tic_tac_toe), do: "Tic Tac Toe"
  def domain_label(:skirmish), do: "Skirmish"
  def domain_label(_), do: "Unknown"

  @spec domain_badge_color(:tic_tac_toe | :skirmish | :unknown) :: String.t()
  def domain_badge_color(:tic_tac_toe), do: "bg-violet-900 text-violet-300"
  def domain_badge_color(:skirmish), do: "bg-orange-900 text-orange-300"
  def domain_badge_color(_), do: "bg-gray-800 text-gray-400"
end
