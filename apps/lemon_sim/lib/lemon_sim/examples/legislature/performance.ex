defmodule LemonSim.Examples.Legislature.Performance do
  @moduledoc """
  Objective performance summary for Legislature runs.

  The benchmark emphasis is preference satisfaction, logrolling coordination,
  amendment success rate, and political capital efficiency.
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    scores = get(world, :scores, %{})
    bills = get(world, :bills, %{})
    message_history = get(world, :message_history, [])
    floor_statements = get(world, :floor_statements, [])
    proposed_amendments = get(world, :proposed_amendments, [])
    vote_record = get(world, :vote_record, %{})

    passed_bills =
      bills
      |> Enum.filter(fn {_id, bill} ->
        Map.get(bill, :status, Map.get(bill, "status")) == "passed"
      end)
      |> Enum.map(fn {id, _} -> id end)

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        ranking = Map.get(info, :preference_ranking, Map.get(info, "preference_ranking", []))

        preferences_satisfied =
          Enum.count(passed_bills, fn bill_id ->
            idx = Enum.find_index(ranking, &(&1 == bill_id))
            idx != nil and idx < 3
          end)

        my_amendments =
          Enum.filter(proposed_amendments, fn a ->
            Map.get(a, :proposer_id, Map.get(a, "proposer_id")) == player_id
          end)

        amendments_proposed = length(my_amendments)

        amendments_passed =
          Enum.count(my_amendments, fn a ->
            Map.get(a, :passed, false)
          end)

        messages_sent =
          Enum.count(message_history, fn record ->
            get(record, :from) == player_id
          end)

        speeches_made =
          Enum.count(floor_statements, fn s ->
            Map.get(s, "player_id", Map.get(s, :player_id)) == player_id
          end)

        my_votes = Map.get(vote_record, player_id, %{})

        capital_remaining =
          Map.get(info, :political_capital, Map.get(info, "political_capital", 0))

        final_score = Map.get(scores, player_id, 0)

        {player_id,
         %{
           faction: get(info, :faction, player_id),
           model: get(info, :model),
           won: winner == player_id,
           final_score: final_score,
           preferences_satisfied: preferences_satisfied,
           bills_passed: length(passed_bills),
           messages_sent: messages_sent,
           speeches_made: speeches_made,
           amendments_proposed: amendments_proposed,
           amendments_passed: amendments_passed,
           amendment_success_rate: amendment_success_rate(amendments_proposed, amendments_passed),
           votes_cast: map_size(my_votes),
           capital_remaining: capital_remaining
         }}
      end)

    %{
      benchmark_focus:
        "preference satisfaction, logrolling coordination, amendment success, and capital efficiency",
      bills_passed: length(passed_bills),
      passed_bill_ids: passed_bills,
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp amendment_success_rate(0, _), do: 0.0
  defp amendment_success_rate(proposed, passed), do: Float.round(passed / proposed, 2)

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn {_player_id, metrics} -> get(metrics, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics = Enum.map(entries, fn {_player_id, item} -> item end)

      {model,
       %{
         seats: length(metrics),
         wins: Enum.count(metrics, &get(&1, :won, false)),
         total_score: Enum.sum(Enum.map(metrics, &get(&1, :final_score, 0))),
         messages_sent: Enum.sum(Enum.map(metrics, &get(&1, :messages_sent, 0))),
         amendments_proposed: Enum.sum(Enum.map(metrics, &get(&1, :amendments_proposed, 0))),
         amendments_passed: Enum.sum(Enum.map(metrics, &get(&1, :amendments_passed, 0))),
         preferences_satisfied: Enum.sum(Enum.map(metrics, &get(&1, :preferences_satisfied, 0)))
       }}
    end)
  end
end
