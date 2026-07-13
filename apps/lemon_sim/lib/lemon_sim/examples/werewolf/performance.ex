defmodule LemonSim.Examples.Werewolf.Performance do
  @moduledoc """
  Objective performance summary for Werewolf runs.

  This benchmark is intended to measure hidden-information reasoning,
  social deduction, and role execution under partial observability.
  The summary intentionally reports concrete signals rather than a
  single opaque score.
  """

  import LemonSim.Examples.Helpers

  @behaviour LemonSim.Bench.Scorecard

  @impl true
  def scorecard(world) do
    summary = summarize(world)
    Map.put(summary, :team_won, team_won_value(summary.players))
  end

  @impl true
  def primary_metric, do: %{key: "team_won", direction: :maximize}

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
           doctor_saves: 0,
           protections_of_villagers: 0,
           protections_of_wolves: 0,
           statements: 0,
           correct_accusations: 0,
           false_accusations: 0,
           role_score: 0.0
         }}
      end)
      |> apply_vote_history(get(world, :vote_history, []))
      |> apply_night_history(get(world, :night_history, []))
      |> apply_discussion_history(world, players)
      |> apply_role_scores()

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
            item
            |> maybe_increment(:doctor_saves, saved)
            |> maybe_increment(
              :protections_of_villagers,
              get(record, :target_role) in ["seer", "doctor", "villager"]
            )
            |> maybe_increment(:protections_of_wolves, get(record, :target_role) == "werewolf")

          _ ->
            item
        end
      end)
    end)
  end

  defp apply_discussion_history(metrics, world, players) do
    past =
      world
      |> get(:past_transcripts, %{})
      |> Map.values()
      |> List.flatten()

    entries = past ++ get(world, :discussion_transcript, [])

    Enum.reduce(entries, metrics, fn entry, acc ->
      player_id = get(entry, :player)
      target_id = get(entry, :target)
      accusation? = get(entry, :type) == "accusation" and is_binary(target_id)
      target_role = players |> Map.get(target_id, %{}) |> get(:role)

      update_player(acc, player_id, fn item ->
        item
        |> Map.update!(:statements, &(&1 + 1))
        |> maybe_increment(:correct_accusations, accusation? and target_role == "werewolf")
        |> maybe_increment(:false_accusations, accusation? and target_role != "werewolf")
      end)
    end)
  end

  defp apply_role_scores(metrics) do
    Enum.into(metrics, %{}, fn {player_id, item} ->
      {player_id, Map.put(item, :role_score, role_score(item))}
    end)
  end

  defp role_score(item) do
    team = if get(item, :team_won, false), do: 1.0, else: 0.0
    survival = if get(item, :survived, false), do: 1.0, else: 0.0

    vote_quality =
      ratio_or_neutral(get(item, :votes_for_werewolf, 0), get(item, :votes_for_villager, 0))

    accusation_quality =
      ratio_or_neutral(
        get(item, :correct_accusations, 0),
        get(item, :false_accusations, 0)
      )

    score =
      case get(item, :role) do
        "werewolf" ->
          kill_quality =
            ratio_or_neutral(get(item, :successful_kills, 0), get(item, :failed_kills, 0))

          concealment =
            ratio_or_neutral(get(item, :votes_for_villager, 0), get(item, :partner_votes, 0))

          0.35 * team + 0.20 * survival + 0.25 * kill_quality + 0.20 * concealment

        "seer" ->
          check_quality = min(get(item, :wolf_checks_found, 0), 1)
          0.35 * team + 0.15 * survival + 0.30 * check_quality + 0.20 * vote_quality

        "doctor" ->
          protection_quality =
            ratio_or_neutral(
              get(item, :protections_of_villagers, 0),
              get(item, :protections_of_wolves, 0)
            )

          save_quality = min(get(item, :doctor_saves, 0), 1)

          0.35 * team + 0.10 * survival + 0.20 * vote_quality +
            0.20 * protection_quality + 0.15 * save_quality

        _ ->
          0.40 * team + 0.15 * survival + 0.30 * vote_quality + 0.15 * accusation_quality
      end

    Float.round(score, 4)
  end

  defp ratio_or_neutral(positive, negative) when positive + negative == 0, do: 0.5
  defp ratio_or_neutral(positive, negative), do: positive / (positive + negative)

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
         doctor_saves: Enum.sum(Enum.map(metrics, &get(&1, :doctor_saves, 0))),
         protections_of_villagers:
           Enum.sum(Enum.map(metrics, &get(&1, :protections_of_villagers, 0))),
         protections_of_wolves: Enum.sum(Enum.map(metrics, &get(&1, :protections_of_wolves, 0))),
         correct_accusations: Enum.sum(Enum.map(metrics, &get(&1, :correct_accusations, 0))),
         false_accusations: Enum.sum(Enum.map(metrics, &get(&1, :false_accusations, 0))),
         role_score_mean:
           metrics |> Enum.map(&get(&1, :role_score, 0.0)) |> then(&(Enum.sum(&1) / length(&1)))
       }}
    end)
  end

  defp team_won_value(players) do
    if Enum.any?(Map.values(players), &get(&1, :team_won, false)), do: 1, else: 0
  end

  defp update_player(metrics, player_id, updater) do
    Map.update(metrics, player_id, %{}, updater)
  end

  defp maybe_increment(map, _key, false), do: map
  defp maybe_increment(map, key, true), do: Map.update!(map, key, &(&1 + 1))
end
