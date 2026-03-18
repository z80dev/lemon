defmodule LemonSim.Examples.StartupIncubator.Performance do
  @moduledoc """
  Objective performance summary for Startup Incubator runs.

  Tracks deals closed, capital efficiency, pivot timing, portfolio
  diversification, and bluff/question activity.
  """

  import LemonSim.GameHelpers

  alias LemonSim.Examples.StartupIncubator.Market

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    startups = get(world, :startups, %{})
    investors = get(world, :investors, %{})
    market_conditions = get(world, :market_conditions, Market.initial_conditions())

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        role = get(info, :role, "founder")

        base = %{
          role: role,
          model: get(info, :model),
          won: winner == player_id,
          pitches_made: 0,
          questions_asked: 0,
          questions_answered: 0,
          offers_made: 0,
          deals_closed: 0,
          deals_rejected: 0,
          merges_done: 0,
          pivots_done: 0
        }

        metrics =
          if role == "founder" do
            startup = Map.get(startups, player_id, %{})
            final_valuation = Market.compute_valuation(startup, market_conditions)
            funding = Map.get(startup, :funding_raised, Map.get(startup, "funding_raised", 0))
            pivoted = Map.get(startup, :pivoted?, Map.get(startup, "pivoted?", false))
            merged = Map.get(startup, :merged_into)

            Map.merge(base, %{
              final_valuation: final_valuation,
              funding_raised: funding,
              pivoted: pivoted == true,
              merged_into: merged,
              final_traction: Map.get(startup, :traction, Map.get(startup, "traction", 0)),
              final_employees: Map.get(startup, :employees, Map.get(startup, "employees", 0)),
              final_sector: Map.get(startup, :sector, Map.get(startup, "sector", "unknown"))
            })
          else
            investor = Map.get(investors, player_id, %{})
            fund_size = Map.get(investor, :fund_size, Map.get(investor, "fund_size", 0))
            remaining = Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0))
            portfolio = Map.get(investor, :portfolio, Map.get(investor, "portfolio", []))
            deployed = fund_size - remaining

            total_portfolio_value =
              Enum.reduce(portfolio, 0, fn entry, acc ->
                entry_founder = Map.get(entry, "founder_id")
                equity = Map.get(entry, "equity_pct", 0.0)
                startup = Map.get(startups, entry_founder, %{})
                valuation = Market.compute_valuation(startup, market_conditions)
                acc + round(valuation * equity / 100.0)
              end)

            return_pct =
              if deployed > 0, do: Float.round((total_portfolio_value - deployed) / deployed * 100.0, 2), else: 0.0

            sectors_invested =
              portfolio
              |> Enum.map(fn entry ->
                founder_id = Map.get(entry, "founder_id")
                startup = Map.get(startups, founder_id, %{})
                Map.get(startup, :sector, Map.get(startup, "sector", "unknown"))
              end)
              |> Enum.uniq()
              |> length()

            Map.merge(base, %{
              fund_size: fund_size,
              capital_deployed: deployed,
              portfolio_companies: length(portfolio),
              portfolio_value: total_portfolio_value,
              return_pct: return_pct,
              sector_diversification: sectors_invested
            })
          end

        {player_id, metrics}
      end)
      |> apply_pitch_log(get(world, :pitch_log, []))
      |> apply_question_log(get(world, :question_log, []))
      |> apply_deal_history(get(world, :deal_history, []))

    %{
      benchmark_focus:
        "deals closed, capital efficiency, pivot timing, portfolio diversification",
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_pitch_log(metrics, pitch_log) do
    Enum.reduce(pitch_log, metrics, fn record, acc ->
      founder_id = get(record, :founder_id) || get(record, "founder_id")
      update_player(acc, founder_id, &Map.update!(&1, :pitches_made, fn c -> c + 1 end))
    end)
  end

  defp apply_question_log(metrics, question_log) do
    Enum.reduce(question_log, metrics, fn record, acc ->
      investor_id = get(record, :investor_id) || get(record, "investor_id")
      founder_id = get(record, :founder_id) || get(record, "founder_id")

      # If record has an "answer" key it's an answer entry, else a question entry
      if Map.has_key?(record, "answer") or Map.has_key?(record, :answer) do
        update_player(acc, founder_id, &Map.update!(&1, :questions_answered, fn c -> c + 1 end))
      else
        update_player(acc, investor_id, &Map.update!(&1, :questions_asked, fn c -> c + 1 end))
      end
    end)
  end

  defp apply_deal_history(metrics, deal_history) do
    Enum.reduce(deal_history, metrics, fn record, acc ->
      founder_id = get(record, :founder_id) || get(record, "founder_id")
      investor_id = get(record, :investor_id) || get(record, "investor_id")

      acc
      |> update_player(founder_id, &Map.update!(&1, :deals_closed, fn c -> c + 1 end))
      |> update_player(investor_id, &Map.update!(&1, :offers_made, fn c -> c + 1 end))
      |> update_player(investor_id, &Map.update!(&1, :deals_closed, fn c -> c + 1 end))
    end)
  end

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn {_id, m} -> get(m, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics = Enum.map(entries, fn {_id, m} -> m end)

      {model,
       %{
         seats: length(metrics),
         wins: Enum.count(metrics, &get(&1, :won, false)),
         deals_closed: Enum.sum(Enum.map(metrics, &get(&1, :deals_closed, 0))),
         pitches_made: Enum.sum(Enum.map(metrics, &get(&1, :pitches_made, 0))),
         questions_asked: Enum.sum(Enum.map(metrics, &get(&1, :questions_asked, 0)))
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
