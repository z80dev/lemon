defmodule LemonSim.Examples.Survivor.Performance do
  @moduledoc """
  Objective performance summary for Survivor runs.

  Survivor is meant to measure a mix of social strategy, vote accuracy,
  alliance maintenance, and endgame conversion rather than pure luck.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        {player_id,
         %{
           name: player_id,
           model: get(info, :model),
           status: get(info, :status),
           won: winner == player_id,
           challenge_wins: 0,
           whispers_sent: 0,
           correct_votes: 0,
           wrong_votes: 0,
           idol_plays: 0,
           jury_votes_received: 0
         }}
      end)
      |> apply_challenge_history(get(world, :challenge_history, []))
      |> apply_whisper_history(get(world, :whisper_history, []))
      |> apply_vote_history(get(world, :vote_history, []))
      |> apply_idol_history(get(world, :idol_history, []))
      |> apply_jury_votes(get(world, :jury_votes, %{}))

    %{
      benchmark_focus:
        "social strategy, vote quality, alliance signaling, and endgame conversion",
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_challenge_history(metrics, challenge_history) do
    Enum.reduce(challenge_history, metrics, fn record, acc ->
      winner = get(record, :winner)
      update_player(acc, winner, &Map.update!(&1, :challenge_wins, fn count -> count + 1 end))
    end)
  end

  defp apply_whisper_history(metrics, whisper_history) do
    Enum.reduce(whisper_history, metrics, fn record, acc ->
      from = get(record, :from)
      update_player(acc, from, &Map.update!(&1, :whispers_sent, fn count -> count + 1 end))
    end)
  end

  defp apply_vote_history(metrics, vote_history) do
    Enum.reduce(vote_history, metrics, fn record, acc ->
      voter = get(record, :voter)
      correct? = get(record, :target_eliminated, false)
      key = if correct?, do: :correct_votes, else: :wrong_votes
      update_player(acc, voter, &Map.update!(&1, key, fn count -> count + 1 end))
    end)
  end

  defp apply_idol_history(metrics, idol_history) do
    Enum.reduce(idol_history, metrics, fn record, acc ->
      player = get(record, :player)
      update_player(acc, player, &Map.update!(&1, :idol_plays, fn count -> count + 1 end))
    end)
  end

  defp apply_jury_votes(metrics, jury_votes) do
    Enum.reduce(jury_votes, metrics, fn {_juror, finalist}, acc ->
      update_player(
        acc,
        finalist,
        &Map.update!(&1, :jury_votes_received, fn count -> count + 1 end)
      )
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
         challenge_wins: Enum.sum(Enum.map(metrics, &get(&1, :challenge_wins, 0))),
         correct_votes: Enum.sum(Enum.map(metrics, &get(&1, :correct_votes, 0))),
         jury_votes_received: Enum.sum(Enum.map(metrics, &get(&1, :jury_votes_received, 0)))
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
