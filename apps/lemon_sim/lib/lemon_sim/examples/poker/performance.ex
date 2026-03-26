defmodule LemonSim.Examples.Poker.Performance do
  @moduledoc """
  Objective performance summary for poker runs.

  The benchmark emphasis is preflop discipline, positional play, and
  action-selection quality over a multi-hand session.
  """

  alias LemonCore.MapHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    table = MapHelpers.get_key(world, :table)
    completed_hands = max(MapHelpers.get_key(world, :completed_hands) || 0, 0)
    big_blind = (table && table.big_blind) || 1
    player_stats = MapHelpers.get_key(world, :player_stats) || %{}

    players =
      Enum.into(player_stats, %{}, fn {player_id, stats} ->
        final_stack = final_stack(world, player_id)
        starting_stack = MapHelpers.get_key(stats, :starting_stack) || 0
        hands_played = MapHelpers.get_key(stats, :hands_played) || 0
        profit_loss = final_stack - starting_stack

        {player_id,
         %{
           final_stack: final_stack,
           profit_loss: profit_loss,
           bb_per_hand: bb_per_hand(profit_loss, completed_hands, big_blind),
           hands_played: hands_played,
           hands_won: MapHelpers.get_key(stats, :hands_won) || 0,
           vpip: rate(MapHelpers.get_key(stats, :vpip_hands) || 0, hands_played),
           pfr: rate(MapHelpers.get_key(stats, :pfr_hands) || 0, hands_played),
           total_actions: MapHelpers.get_key(stats, :total_actions) || 0,
           fold_count: MapHelpers.get_key(stats, :fold_count) || 0,
           check_count: MapHelpers.get_key(stats, :check_count) || 0,
           call_count: MapHelpers.get_key(stats, :call_count) || 0,
           bet_count: MapHelpers.get_key(stats, :bet_count) || 0,
           raise_count: MapHelpers.get_key(stats, :raise_count) || 0
         }}
      end)

    %{
      benchmark_focus: "preflop selection, aggression timing, and stack preservation",
      hands_completed: completed_hands,
      big_blind: big_blind,
      players: players
    }
  end

  defp final_stack(world, player_id) do
    world
    |> MapHelpers.get_key(:chip_counts)
    |> List.wrap()
    |> Enum.find_value(0, fn seat_info ->
      if Map.get(seat_info, "player_id") == player_id do
        Map.get(seat_info, "stack", 0)
      end
    end)
  end

  defp rate(_count, 0), do: 0.0
  defp rate(count, total), do: Float.round(count / total, 3)

  defp bb_per_hand(_profit_loss, 0, _big_blind), do: 0.0

  defp bb_per_hand(profit_loss, hands, big_blind),
    do: Float.round(profit_loss / hands / big_blind, 3)
end
