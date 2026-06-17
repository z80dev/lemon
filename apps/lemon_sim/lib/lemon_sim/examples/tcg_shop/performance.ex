defmodule LemonSim.Examples.TcgShop.Performance do
  @moduledoc false

  alias LemonCore.MapHelpers

  def scorecard(world) do
    balance = get(world, :bank_balance, 0.0)
    inventory_value = inventory_value(world)
    singles = get(world, :singles_case, %{})
    singles_value = get(singles, :total_market_value, 0.0)
    graded_value = graded_value(singles)
    net_worth = balance + inventory_value + singles_value + graded_value
    starting_balance = get(world, :starting_balance, 10_000.0)

    %{
      bank_balance: round_money(balance),
      inventory_value: round_money(inventory_value),
      singles_value: round_money(singles_value),
      graded_value: round_money(graded_value),
      net_worth: round_money(net_worth),
      roi_pct: round_money((net_worth - starting_balance) / starting_balance * 100.0),
      reputation: get(world, :reputation, 50),
      online_rating: get(world, :online_rating, 4.3),
      sell_through_units: length(get(world, :sales_history, [])),
      events_hosted: length(get(world, :tournament_history, [])),
      grading_submissions: length(get(world, :grading_history, [])),
      rejections: get(world, :invalid_action_count, 0)
    }
  end

  def inventory_value(world) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.reduce(0.0, fn {line_id, item}, acc ->
      line = Map.get(catalog, line_id, %{})
      acc + get(item, :on_hand, 0) * get(line, :market_price, 0.0)
    end)
  end

  defp graded_value(singles) do
    singles
    |> get(:graded_cards, [])
    |> Enum.reduce(0.0, fn card, acc -> acc + get(card, :market_value, 0.0) end)
  end

  defp get(map, key, default) do
    MapHelpers.get_key(map, key) || default
  end

  defp round_money(value), do: Float.round((value || 0) + 0.0, 2)
end
