defmodule LemonSim.Examples.Poker.Performance do
  @moduledoc """
  Objective performance summary for poker runs.

  The benchmark emphasis is preflop discipline, positional play, and
  action-selection quality over a multi-hand session.
  """

  alias LemonCore.MapHelpers

  @behaviour LemonSim.Bench.Scorecard

  @impl true
  def scorecard(world), do: summarize(world)

  @impl true
  def primary_metric, do: %{key: "best_profit_loss", direction: :maximize}

  @spec summarize(map()) :: map()
  def summarize(world) do
    table = MapHelpers.get_key(world, :table)
    completed_hands = max(MapHelpers.get_key(world, :completed_hands) || 0, 0)
    big_blind = (table && MapHelpers.get_key(table, :big_blind)) || 1
    player_stats = MapHelpers.get_key(world, :player_stats) || %{}
    player_infos = MapHelpers.get_key(world, :players) || %{}
    winner_ids = MapHelpers.get_key(world, :winner_ids) || []

    players =
      Enum.into(player_stats, %{}, fn {player_id, stats} ->
        final_stack = final_stack(world, player_id)
        starting_stack = MapHelpers.get_key(stats, :starting_stack) || 0
        hands_played = MapHelpers.get_key(stats, :hands_played) || 0
        profit_loss = final_stack - starting_stack
        info = player_info(player_infos, player_id)

        {player_id,
         %{
           model: MapHelpers.get_key(info, :model),
           won: to_string(player_id) in Enum.map(winner_ids, &to_string/1),
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
      best_profit_loss: best_profit_loss(players),
      players: players,
      models: summarize_models(players)
    }
  end

  # World :players may be keyed by atoms or strings after a snapshot
  # round-trip; match on either.
  defp player_info(player_infos, player_id) do
    Map.get(player_infos, player_id) ||
      Map.get(player_infos, to_string(player_id)) || %{}
  end

  defp summarize_models(players) do
    players
    |> Enum.group_by(fn {_player_id, metrics} -> Map.get(metrics, :model) || "unknown" end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics = Enum.map(entries, fn {_player_id, m} -> m end)
      count = max(length(metrics), 1)

      {model,
       %{
         seats: length(metrics),
         wins: Enum.count(metrics, & &1.won),
         avg_profit_loss: Float.round(Enum.sum(Enum.map(metrics, & &1.profit_loss)) / count, 1),
         avg_bb_per_hand: Float.round(Enum.sum(Enum.map(metrics, & &1.bb_per_hand)) / count, 3),
         avg_vpip: Float.round(Enum.sum(Enum.map(metrics, & &1.vpip)) / count, 3),
         avg_pfr: Float.round(Enum.sum(Enum.map(metrics, & &1.pfr)) / count, 3)
       }}
    end)
  end

  defp best_profit_loss(players) do
    players
    |> Map.values()
    |> Enum.map(&Map.get(&1, :profit_loss, 0))
    |> Enum.max(fn -> 0 end)
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
