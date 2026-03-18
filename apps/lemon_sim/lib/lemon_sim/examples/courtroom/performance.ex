defmodule LemonSim.Examples.Courtroom.Performance do
  @moduledoc """
  Objective performance summary for Courtroom Trial runs.

  Metrics cover evidence utilization, objection success rate, jury influence,
  and testimony consistency.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    outcome = get(world, :outcome, "unknown")
    verdict_votes = get(world, :verdict_votes, %{})
    objections = get(world, :objections, [])
    testimony_log = get(world, :testimony_log, [])
    evidence_presented = get(world, :evidence_presented, [])
    case_file = get(world, :case_file, %{})
    total_evidence = length(get(case_file, :evidence_list, []))

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        role = get(info, :role, "unknown")

        base = %{
          role: role,
          model: get(info, :model),
          won: winner == player_id,
          statements_made: 0,
          questions_asked: 0,
          objections_raised: 0,
          objections_sustained: 0,
          evidence_presented: 0,
          jury_votes_influenced: 0
        }

        {player_id, base}
      end)
      |> apply_testimony_log(testimony_log)
      |> apply_objection_history(objections)
      |> apply_evidence_presented(evidence_presented)
      |> apply_jury_influence(verdict_votes, winner)

    evidence_utilization =
      if total_evidence > 0 do
        Float.round(length(evidence_presented) / total_evidence * 100, 1)
      else
        0.0
      end

    %{
      benchmark_focus: "evidence utilization, objection success, jury influence, testimony consistency",
      outcome: outcome,
      winner: winner,
      evidence_utilization_pct: evidence_utilization,
      total_objections: length(objections),
      sustained_objections: Enum.count(objections, &(get(&1, :ruling) == "sustained")),
      total_testimony_entries: length(testimony_log),
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_testimony_log(metrics, testimony_log) do
    Enum.reduce(testimony_log, metrics, fn entry, acc ->
      type = get(entry, :type, get(entry, "type", ""))
      player_id = get(entry, :player_id, get(entry, "player_id", nil))
      asker_id = get(entry, :asker_id, get(entry, "asker_id", nil))

      acc =
        case type do
          "statement" ->
            update_player(acc, player_id, &Map.update!(&1, :statements_made, fn n -> n + 1 end))

          "question" ->
            update_player(acc, asker_id, &Map.update!(&1, :questions_asked, fn n -> n + 1 end))

          "challenge" ->
            update_player(acc, player_id, &Map.update!(&1, :questions_asked, fn n -> n + 1 end))

          _ ->
            acc
        end

      acc
    end)
  end

  defp apply_objection_history(metrics, objections) do
    Enum.reduce(objections, metrics, fn objection, acc ->
      player_id = get(objection, :player_id, get(objection, "player_id", nil))
      ruling = get(objection, :ruling, get(objection, "ruling", "overruled"))

      acc
      |> update_player(player_id, &Map.update!(&1, :objections_raised, fn n -> n + 1 end))
      |> then(fn a ->
        if ruling == "sustained" do
          update_player(a, player_id, &Map.update!(&1, :objections_sustained, fn n -> n + 1 end))
        else
          a
        end
      end)
    end)
  end

  defp apply_evidence_presented(metrics, evidence_presented) do
    # Credit evidence to prosecution and defense based on world state
    # Since we don't track who presented each item individually here,
    # we count the total items presented and report globally
    Enum.reduce(metrics, %{}, fn {player_id, player_metrics}, acc ->
      role = get(player_metrics, :role, "")

      updated =
        if role in ["prosecution", "defense"] do
          Map.put(player_metrics, :evidence_presented, length(evidence_presented))
        else
          player_metrics
        end

      Map.put(acc, player_id, updated)
    end)
  end

  defp apply_jury_influence(metrics, verdict_votes, winner) do
    # Winner's "team" is the side the verdict favored
    # Count how many jurors voted for the winning outcome
    if winner do
      winning_vote = if Map.get(metrics, winner, %{}) |> Map.get(:role) == "prosecution" do
        "guilty"
      else
        "not_guilty"
      end

      influenced_count =
        verdict_votes
        |> Map.values()
        |> Enum.count(&(&1 == winning_vote))

      update_player(
        metrics,
        winner,
        &Map.put(&1, :jury_votes_influenced, influenced_count)
      )
    else
      metrics
    end
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
         statements_made: Enum.sum(Enum.map(metrics, &get(&1, :statements_made, 0))),
         questions_asked: Enum.sum(Enum.map(metrics, &get(&1, :questions_asked, 0))),
         objections_raised: Enum.sum(Enum.map(metrics, &get(&1, :objections_raised, 0))),
         objections_sustained: Enum.sum(Enum.map(metrics, &get(&1, :objections_sustained, 0)))
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
