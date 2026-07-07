defmodule LemonSim.Examples.TcgShop.Updaters.Grading do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Finance
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_submit_grading(%State{} = state, event) do
    count = as_int(get(event.payload, "card_count", 0))
    service = get(event.payload, "service_level", "bulk")
    service_data = grading_service(service)
    singles = get(state.world, :singles_case, %{})
    cost = count * service_data.cost

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_positive(count),
         :ok <- ensure_cards(singles, count),
         :ok <- ensure_cash(state.world, cost) do
      day = get(state.world, :day_number, 1)
      avg_value = get(singles, :total_market_value, 0.0) / max(get(singles, :cards_on_hand, 1), 1)
      raw_value = Float.round(avg_value * count, 2)
      grading_profile = grading_submission_profile(state.world, count)

      submission = %{
        day: day,
        card_count: count,
        service_level: service,
        cost: cost,
        raw_value: raw_value,
        condition_mix: get(grading_profile, :condition_mix, %{}),
        authentication_risk_pct: get(grading_profile, :authentication_risk_pct, 0),
        expected_authentication_failures:
          get(grading_profile, :expected_authentication_failures, 0),
        return_day: day + service_data.delay
      }

      next =
        state
        |> State.update_world(fn world ->
          update_in(world, [:singles_case], fn singles ->
            singles
            |> Map.update(:cards_on_hand, 0, &(&1 - count))
            |> Map.update(:total_market_value, 0.0, &Float.round(max(0.0, &1 - raw_value), 2))
          end)
          |> Map.update!(:bank_balance, &Float.round(&1 - cost, 2))
          |> Map.update(:pending_grading, [submission], &(&1 ++ [submission]))
          |> Map.update(:grading_history, [submission], &(&1 ++ [submission]))
          |> Staffing.consume_staff_hours(Float.round(0.75 + count * 0.03, 2), "grading_prep")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "submitted #{count} cards for grading"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  def apply_due_grading(world, day) do
    {due, pending} =
      world
      |> get(:pending_grading, [])
      |> Enum.split_with(&(get(&1, :return_day, 0) <= day))

    updated =
      Enum.reduce(due, world, fn submission, acc ->
        outcome = grading_outcome(submission, day, get(acc, :seed, 1))
        graded_value = get(outcome, :graded_value, 0.0)

        graded_card = %{
          returned_day: day,
          card_count: get(outcome, :graded_count, 0),
          service_level: get(submission, :service_level, "bulk"),
          market_value: graded_value,
          grade_mix: get(outcome, :grade_mix, %{}),
          authenticated_failures: get(outcome, :authentication_failures, 0)
        }

        loss =
          if get(outcome, :authentication_failures, 0) > 0 do
            [
              %{
                day: day,
                card_count: get(outcome, :authentication_failures, 0),
                raw_value_lost: get(outcome, :authentication_loss, 0.0),
                source: "grading_authentication"
              }
            ]
          else
            []
          end

        acc
        |> update_in([:singles_case, :graded_cards], &((&1 || []) ++ [graded_card]))
        |> Map.update(:grading_result_history, [graded_card], &(&1 ++ [graded_card]))
        |> Map.update(:authentication_loss_history, loss, &(&1 ++ loss))
      end)

    Map.put(updated, :pending_grading, pending)
  end

  defp ensure_cards(singles, count) do
    if get(singles, :cards_on_hand, 0) >= count, do: :ok, else: {:error, :not_enough_raw_singles}
  end

  defp grading_service("express"), do: %{cost: 38.0, delay: 2}
  defp grading_service("standard"), do: %{cost: 22.0, delay: 4}
  defp grading_service(_), do: %{cost: 14.0, delay: 7}

  defp grading_submission_profile(world, count) do
    recent_buy =
      world
      |> get(:buylist_history, [])
      |> Enum.reverse()
      |> Enum.find(&get(&1, :condition_mix, nil))

    condition_mix =
      get(recent_buy || %{}, :condition_mix, %{
        near_mint: 55,
        light_play: 30,
        moderate_play: 12,
        damaged: 3
      })

    auth_risk = get(recent_buy || %{}, :authentication_risk_pct, 1)
    failures = min(count, div(count * auth_risk + 99, 100))

    %{
      condition_mix: condition_mix,
      authentication_risk_pct: auth_risk,
      expected_authentication_failures: failures
    }
  end

  defp grading_outcome(submission, day, seed) do
    count = get(submission, :card_count, 0)
    failures = min(count, deterministic_authentication_failures(submission, day, seed))
    graded_count = max(0, count - failures)
    raw_value = get(submission, :raw_value, 0.0)
    value_per_card = raw_value / max(count, 1)
    grade_mix = grade_mix_for(submission, graded_count, day, seed)
    multiplier = grade_mix_multiplier(grade_mix)
    graded_value = Float.round(value_per_card * graded_count * multiplier, 2)

    %{
      graded_count: graded_count,
      authentication_failures: failures,
      authentication_loss: Float.round(value_per_card * failures, 2),
      grade_mix: grade_mix,
      graded_value: graded_value
    }
  end

  defp deterministic_authentication_failures(submission, day, seed) do
    expected = get(submission, :expected_authentication_failures, 0)
    risk = get(submission, :authentication_risk_pct, 0)
    count = get(submission, :card_count, 0)

    if rem(seed + day + risk + count, 5) == 0 do
      min(count, expected + 1)
    else
      min(count, expected)
    end
  end

  defp grade_mix_for(_submission, 0, _day, _seed), do: %{gem_mint: 0, mint: 0, near_mint: 0}

  defp grade_mix_for(submission, graded_count, day, seed) do
    condition = get(submission, :condition_mix, %{})
    near_mint_pct = get(condition, :near_mint, 55)
    service_bonus = if get(submission, :service_level, "bulk") == "express", do: 1, else: 0
    deterministic_bonus = rem(seed + day + graded_count, 3)
    gem_mint = min(graded_count, max(0, div(graded_count * near_mint_pct, 220) + service_bonus))

    mint =
      min(
        graded_count - gem_mint,
        max(0, div(graded_count * near_mint_pct, 160) + deterministic_bonus)
      )

    near_mint = max(0, graded_count - gem_mint - mint)

    %{gem_mint: gem_mint, mint: mint, near_mint: near_mint}
  end

  defp grade_mix_multiplier(grade_mix) do
    total =
      grade_mix
      |> Map.values()
      |> Enum.sum()

    if total == 0 do
      0.0
    else
      weighted =
        get(grade_mix, :gem_mint, 0) * 2.1 +
          get(grade_mix, :mint, 0) * 1.45 +
          get(grade_mix, :near_mint, 0) * 1.05

      Float.round(weighted / total, 3)
    end
  end

  def apply_graded_sales(world, pulse) do
    singles = get(world, :singles_case, %{})
    graded_cards = get(singles, :graded_cards, [])

    case graded_cards do
      [] ->
        {world, 0.0, []}

      [card | remaining] ->
        day = get(pulse, :day, get(world, :day_number, 1))
        market_value = get(card, :market_value, 0.0)
        revenue = Float.round(market_value * 0.95, 2)

        sale = %{
          day: day,
          channel: "graded_case",
          segment_id: "collectors",
          quantity: get(card, :card_count, 1),
          revenue: revenue,
          cost_of_goods_sold: market_value,
          gross_profit: Float.round(revenue - market_value, 2),
          sales_tax_collected: Finance.sales_tax_for(world, revenue),
          market_value_removed: market_value,
          service_level: get(card, :service_level, "bulk")
        }

        next = put_in(world, [:singles_case, :graded_cards], remaining)
        {next, revenue, [sale]}
    end
  end
end
