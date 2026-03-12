defmodule LemonSim.Examples.Werewolf.Performance do
  @moduledoc """
  Objective performance summary for Werewolf runs.

  This benchmark is intended to measure hidden-information reasoning,
  social deduction, and role execution under partial observability.
  The summary intentionally reports concrete signals rather than a
  single opaque score.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        team =
          case get(info, :role) do
            "werewolf" -> "werewolves"
            _ -> "villagers"
          end

        {player_id,
         %{
           role: get(info, :role),
           model: get(info, :model),
           status: get(info, :status),
           team: team,
           team_won: winner == team,
           survived: get(info, :status) == "alive",
           votes_for_werewolf: 0,
           votes_for_villager: 0,
           skip_votes: 0,
           partner_votes: 0,
           night_actions_used: 0,
           successful_kills: 0,
           failed_kills: 0,
           wolf_checks_found: 0,
           doctor_saves: 0
         }}
      end)
      |> apply_vote_history(get(world, :vote_history, []))
      |> apply_night_history(get(world, :night_history, []))

    %{
      benchmark_focus: "hidden-information reasoning, persuasion, and role execution",
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_vote_history(metrics, vote_history) do
    Enum.reduce(vote_history, metrics, fn vote, acc ->
      voter = get(vote, :voter)
      target = get(vote, :target)
      target_role = get(vote, :target_role)
      voter_role = get(vote, :voter_role)

      update_player(acc, voter, fn item ->
        cond do
          target == "skip" ->
            Map.update!(item, :skip_votes, &(&1 + 1))

          target_role == "werewolf" ->
            Map.update!(item, :votes_for_werewolf, &(&1 + 1))

          true ->
            item
            |> Map.update!(:votes_for_villager, &(&1 + 1))
            |> maybe_increment(
              :partner_votes,
              voter_role == "werewolf" and target_role == "werewolf"
            )
        end
      end)
    end)
  end

  defp apply_night_history(metrics, night_history) do
    Enum.reduce(night_history, metrics, fn record, acc ->
      player = get(record, :player)
      action = get(record, :action)
      successful = get(record, :successful, false)
      result = get(record, :result)
      saved = get(record, :saved, false)

      update_player(acc, player, fn item ->
        item =
          if action in ["choose_victim", "investigate", "protect"] do
            Map.update!(item, :night_actions_used, &(&1 + 1))
          else
            item
          end

        case action do
          "choose_victim" ->
            item
            |> maybe_increment(:successful_kills, successful)
            |> maybe_increment(:failed_kills, not successful)

          "investigate" ->
            maybe_increment(item, :wolf_checks_found, result == "werewolf")

          "protect" ->
            maybe_increment(item, :doctor_saves, saved)

          _ ->
            item
        end
      end)
    end)
  end

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn {_player_id, metrics} -> get(metrics, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics = Enum.map(entries, fn {_player_id, item} -> item end)

      {model,
       %{
         seats: length(metrics),
         team_wins: Enum.count(metrics, &get(&1, :team_won, false)),
         survived: Enum.count(metrics, &get(&1, :survived, false)),
         votes_for_werewolf: Enum.sum(Enum.map(metrics, &get(&1, :votes_for_werewolf, 0))),
         votes_for_villager: Enum.sum(Enum.map(metrics, &get(&1, :votes_for_villager, 0))),
         successful_kills: Enum.sum(Enum.map(metrics, &get(&1, :successful_kills, 0))),
         wolf_checks_found: Enum.sum(Enum.map(metrics, &get(&1, :wolf_checks_found, 0))),
         doctor_saves: Enum.sum(Enum.map(metrics, &get(&1, :doctor_saves, 0)))
       }}
    end)
  end

  defp update_player(metrics, player_id, updater) do
    Map.update(metrics, player_id, %{}, updater)
  end

  defp maybe_increment(map, _key, false), do: map
  defp maybe_increment(map, key, true), do: Map.update!(map, key, &(&1 + 1))
end
