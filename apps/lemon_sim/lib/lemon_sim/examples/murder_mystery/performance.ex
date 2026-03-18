defmodule LemonSim.Examples.MurderMystery.Performance do
  @moduledoc """
  Objective performance summary for Murder Mystery runs.

  Tracks investigative effectiveness, killer evasion, and deduction accuracy
  across all players.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    solution = get(world, :solution, %{})
    killer_id = get(solution, :killer_id, nil)

    accusations = get(world, :accusations, [])
    interrogation_log = get(world, :interrogation_log, [])
    discussion_log = get(world, :discussion_log, [])
    planted_evidence = get(world, :planted_evidence, [])
    destroyed_evidence = get(world, :destroyed_evidence, [])

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        role = get(info, :role, "investigator")
        clues_found = get(info, :clues_found, [])

        {player_id,
         %{
           role: role,
           model: get(info, :model),
           won: player_won?(winner, role, player_id),
           clues_found: length(clues_found),
           questions_asked: 0,
           discussion_entries: 0,
           accusations_made: 0,
           correct_accusation: false,
           accusations_remaining: get(info, :accusations_remaining, 0),
           evidence_planted: if(role == "killer", do: length(planted_evidence), else: 0),
           evidence_destroyed: if(role == "killer", do: length(destroyed_evidence), else: 0)
         }}
      end)
      |> apply_interrogation_history(interrogation_log)
      |> apply_discussion_history(discussion_log)
      |> apply_accusation_history(accusations, killer_id)

    %{
      benchmark_focus: "investigative accuracy, interrogation quality, and killer evasion",
      winner: winner,
      killer_id: killer_id,
      correct_weapon: get(solution, :weapon, nil),
      correct_room: get(solution, :room_id, nil),
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp player_won?("investigators", "investigator", _player_id), do: true
  defp player_won?("killer", "killer", _player_id), do: true
  defp player_won?(_winner, _role, _player_id), do: false

  defp apply_interrogation_history(metrics, interrogation_log) do
    Enum.reduce(interrogation_log, metrics, fn entry, acc ->
      asker = Map.get(entry, "asker_id")
      update_player(acc, asker, &Map.update!(&1, :questions_asked, fn count -> count + 1 end))
    end)
  end

  defp apply_discussion_history(metrics, discussion_log) do
    Enum.reduce(discussion_log, metrics, fn entry, acc ->
      player = Map.get(entry, "player_id")
      update_player(acc, player, &Map.update!(&1, :discussion_entries, fn count -> count + 1 end))
    end)
  end

  defp apply_accusation_history(metrics, accusations, _killer_id) do
    Enum.reduce(accusations, metrics, fn accusation, acc ->
      player = Map.get(accusation, "player_id")
      correct = Map.get(accusation, "correct", false)

      acc
      |> update_player(player, &Map.update!(&1, :accusations_made, fn count -> count + 1 end))
      |> then(fn m ->
        if correct do
          update_player(m, player, &Map.put(&1, :correct_accusation, true))
        else
          m
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
         wins: Enum.count(metrics, &get(&1, :won, false)),
         clues_found: Enum.sum(Enum.map(metrics, &get(&1, :clues_found, 0))),
         questions_asked: Enum.sum(Enum.map(metrics, &get(&1, :questions_asked, 0))),
         discussion_entries: Enum.sum(Enum.map(metrics, &get(&1, :discussion_entries, 0))),
         accusations_made: Enum.sum(Enum.map(metrics, &get(&1, :accusations_made, 0))),
         correct_accusations: Enum.count(metrics, &get(&1, :correct_accusation, false))
       }}
    end)
  end

  defp update_player(metrics, nil, _updater), do: metrics

  defp update_player(metrics, player_id, updater) do
    case Map.fetch(metrics, player_id) do
      {:ok, item} -> Map.put(metrics, player_id, updater.(item))
      :error -> metrics
    end
  end
end
