defmodule LemonSim.Examples.TcgShop.Updaters.Customers do
  @moduledoc false

  alias LemonSim.Examples.TcgShop.Updaters.Memberships

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_customer_sales(world, sales) do
    Enum.reduce(sales, world, fn sale, acc ->
      segment_id = get(sale, :segment_id)

      update_customer_segment(acc, segment_id, %{
        loyalty_delta: 1,
        satisfaction_delta: 1,
        visits_delta: get(sale, :quantity, get(sale, :fulfilled_count, 0)),
        spend_delta: get(sale, :revenue, get(sale, :attach_sales, 0.0)),
        reason: get(sale, :channel, "sale")
      })
    end)
  end

  def apply_customer_stockouts(world, stockouts) do
    Enum.reduce(stockouts, world, fn stockout, acc ->
      lost_units = get(stockout, :lost_units, 0)

      update_customer_segment(acc, get(stockout, :segment_id), %{
        loyalty_delta: -min(4, lost_units),
        satisfaction_delta: -min(6, lost_units * 2),
        visits_delta: 0,
        spend_delta: 0.0,
        reason: "stockout"
      })
    end)
  end

  def update_customer_segment(world, nil, _changes), do: world

  def update_customer_segment(world, segment_id, changes) do
    customer_base = get(world, :customer_base, %{})

    case Map.get(customer_base, segment_id) do
      nil ->
        world

      segment ->
        day = get(world, :day_number, 1)
        loyalty_delta = get(changes, :loyalty_delta, 0)
        satisfaction_delta = get(changes, :satisfaction_delta, 0)
        visits_delta = get(changes, :visits_delta, 0)
        spend_delta = get(changes, :spend_delta, 0.0)

        updated =
          segment
          |> Map.update(:loyalty, 50, &clamp_int(&1 + loyalty_delta, 0, 100))
          |> Map.update(:satisfaction, 50, &clamp_int(&1 + satisfaction_delta, 0, 100))
          |> Map.update(:visits, visits_delta, &(&1 + visits_delta))
          |> Map.update(:lifetime_spend, Float.round(spend_delta, 2), fn value ->
            Float.round(value + spend_delta, 2)
          end)

        history = %{
          day: day,
          segment_id: segment_id,
          reason: get(changes, :reason, "customer_update"),
          loyalty_delta: loyalty_delta,
          satisfaction_delta: satisfaction_delta,
          visits_delta: visits_delta,
          spend_delta: Float.round(spend_delta, 2),
          loyalty: get(updated, :loyalty, 50),
          satisfaction: get(updated, :satisfaction, 50)
        }

        world
        |> put_in([:customer_base, segment_id], updated)
        |> Map.update(:customer_history, [history], &(&1 ++ [history]))
    end
  end

  def customer_demand_multiplier(world, segment_id) do
    segment =
      world
      |> get(:customer_base, %{})
      |> Map.get(segment_id, %{})

    loyalty = get(segment, :loyalty, 50)
    satisfaction = get(segment, :satisfaction, 50)
    size = get(segment, :size, 20)

    Float.round(
      (0.65 + loyalty / 180 + satisfaction / 220 + min(size, 60) / 180) *
        Memberships.membership_demand_multiplier(world, segment_id),
      2
    )
  end

  def customer_segment_for_franchise("Pokemon"), do: "league_regulars"
  def customer_segment_for_franchise("Yu-Gi-Oh!"), do: "competitive_grinders"
  def customer_segment_for_franchise("One Piece"), do: "collectors"
  def customer_segment_for_franchise("Dragon Ball Super"), do: "league_regulars"
  def customer_segment_for_franchise("Accessories"), do: "parents_new_players"
  def customer_segment_for_franchise(_), do: "league_regulars"

  def customer_queue_for(world, pulse) do
    featured = get(pulse, :featured_franchise, "Pokemon")

    world
    |> get(:customer_base, %{})
    |> Enum.map(fn {segment_id, segment} ->
      %{
        segment_id: segment_id,
        type: get(segment, :type, "customer"),
        name: get(segment, :name, segment_id),
        need: customer_need(segment, featured),
        urgency: customer_urgency(segment, featured),
        loyalty: get(segment, :loyalty, 50),
        satisfaction: get(segment, :satisfaction, 50)
      }
    end)
    |> Enum.sort_by(fn customer ->
      {urgency_rank(get(customer, :urgency, "medium")), -get(customer, :satisfaction, 50)}
    end)
    |> Enum.take(4)
  end

  defp customer_need(segment, featured) do
    if get(segment, :preferred_franchise, "") == featured do
      "#{featured} demand spike: #{get(segment, :need, "")}"
    else
      get(segment, :need, "")
    end
  end

  defp customer_urgency(segment, featured) do
    cond do
      get(segment, :satisfaction, 50) < 45 -> "at_risk"
      get(segment, :preferred_franchise, "") == featured -> "high"
      true -> "medium"
    end
  end

  defp urgency_rank("high"), do: 0
  defp urgency_rank("at_risk"), do: 1
  defp urgency_rank(_), do: 2
end
