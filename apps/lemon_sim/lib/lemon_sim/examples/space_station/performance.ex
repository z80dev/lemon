defmodule LemonSim.Examples.SpaceStation.Performance do
  @moduledoc """
  Objective performance metrics for Space Station Crisis.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    saboteur_id = LemonSim.Examples.SpaceStation.Roles.find_saboteur(players)

    base =
      players
      |> Enum.map(fn {player_id, info} ->
        role = get(info, :role, "crew")
        team = if role == "saboteur", do: "saboteur", else: "crew"

        %{
          player_id: player_id,
          name: get(info, :name, player_id),
          model: get(info, :model),
          role: role,
          team: team,
          team_won: winner == team,
          survived: get(info, :status) == "alive",
          repairs: 0,
          sabotages: 0,
          fake_repairs: 0,
          scans: 0,
          locks: 0,
          vents: 0,
          emergency_meetings: 0,
          correct_votes: 0,
          wrong_votes: 0,
          voted_for_saboteur: false,
          was_ejected: get(info, :status) == "ejected"
        }
      end)

    metrics =
      base
      |> apply_action_history(get(world, :action_history, []))
      |> apply_vote_history(get(world, :vote_history, []), saboteur_id)

    %{
      benchmark_focus: "hidden-role reasoning, cooperative coordination, and deception",
      winner: winner,
      saboteur_id: saboteur_id,
      players: metrics,
      models: summarize_models(metrics)
    }
  end

  defp apply_action_history(metrics, history) do
    Enum.reduce(history, metrics, fn round_actions, acc ->
      actions = get(round_actions, :actions, %{})

      Enum.reduce(actions, acc, fn {player_id, action}, player_acc ->
        case get(action, :action) do
          "repair" ->
            update_player(player_acc, player_id, &increment(&1, :repairs))

          "sabotage" ->
            update_player(player_acc, player_id, &increment(&1, :sabotages))

          "fake_repair" ->
            update_player(player_acc, player_id, &increment(&1, :fake_repairs))

          "scan" ->
            update_player(player_acc, player_id, &increment(&1, :scans))

          "lock" ->
            update_player(player_acc, player_id, &increment(&1, :locks))

          "vent" ->
            update_player(player_acc, player_id, &increment(&1, :vents))

          "emergency_meeting" ->
            update_player(player_acc, player_id, &increment(&1, :emergency_meetings))

          _ ->
            player_acc
        end
      end)
    end)
  end

  defp apply_vote_history(metrics, history, saboteur_id) do
    Enum.reduce(history, metrics, fn vote_record, acc ->
      votes = get(vote_record, :votes, %{})

      Enum.reduce(votes, acc, fn {voter_id, target_id}, player_acc ->
        cond do
          target_id == "skip" ->
            player_acc

          target_id == saboteur_id ->
            player_acc
            |> update_player(voter_id, &increment(&1, :correct_votes))
            |> update_player(voter_id, &Map.put(&1, :voted_for_saboteur, true))

          true ->
            update_player(player_acc, voter_id, &increment(&1, :wrong_votes))
        end
      end)
    end)
  end

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn m -> get(m, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      {model,
       %{
         seats: length(entries),
         team_wins: Enum.count(entries, &get(&1, :team_won, false)),
         survived: Enum.count(entries, &get(&1, :survived, false)),
         repairs: Enum.sum(Enum.map(entries, &get(&1, :repairs, 0))),
         sabotages: Enum.sum(Enum.map(entries, &get(&1, :sabotages, 0))),
         scans: Enum.sum(Enum.map(entries, &get(&1, :scans, 0))),
         correct_votes: Enum.sum(Enum.map(entries, &get(&1, :correct_votes, 0))),
         wrong_votes: Enum.sum(Enum.map(entries, &get(&1, :wrong_votes, 0)))
       }}
    end)
  end

  defp update_player(metrics, player_id, fun) do
    Enum.map(metrics, fn player ->
      if get(player, :player_id) == player_id, do: fun.(player), else: player
    end)
  end

  defp increment(player, key) do
    Map.update!(player, key, &(&1 + 1))
  end
end
