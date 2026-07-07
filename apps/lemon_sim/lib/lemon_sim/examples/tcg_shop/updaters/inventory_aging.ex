defmodule LemonSim.Examples.TcgShop.Updaters.InventoryAging do
  @moduledoc false

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_inventory_aging_and_markdowns({world, revenue}, day) do
    {apply_inventory_aging_and_markdowns(world, day), revenue}
  end

  def apply_inventory_aging_and_markdowns(world, day) do
    catalog = get(world, :catalog, %{})

    {inventory, entries} =
      world
      |> get(:inventory, %{})
      |> Enum.reduce({%{}, []}, fn {line_id, item}, {inventory_acc, entries_acc} ->
        line = Map.get(catalog, line_id, %{})
        aged_item = age_inventory_item(item)

        case stale_inventory_markdown(line_id, line, aged_item, day) do
          nil ->
            {Map.put(inventory_acc, line_id, aged_item), entries_acc}

          {marked_item, entry} ->
            {Map.put(inventory_acc, line_id, marked_item), entries_acc ++ [entry]}
        end
      end)

    world =
      world
      |> Map.put(:inventory, inventory)

    if entries == [] do
      world
    else
      Map.update(world, :stale_inventory_history, entries, &(&1 ++ entries))
    end
  end

  defp age_inventory_item(item) do
    if get(item, :on_hand, 0) > 0 do
      Map.update(item, :age_days, 1.0, &Float.round((&1 + 1) / 1, 2))
    else
      Map.put(item, :age_days, 0)
    end
  end

  defp stale_inventory_markdown(line_id, line, item, day) do
    on_hand = get(item, :on_hand, 0)
    age_days = get(item, :age_days, 0)
    threshold = stale_age_threshold(line)
    current_price = get(item, :price, get(line, :suggested_price, 0.0))
    target_price = stale_target_price(line, item, threshold)

    if on_hand > 0 and age_days >= threshold and target_price < current_price do
      new_price = Float.round(target_price, 2)
      markdown_loss = Float.round((current_price - new_price) * on_hand, 2)

      entry = %{
        day: day,
        line_id: line_id,
        franchise: get(line, :franchise, "Unknown"),
        category: get(line, :category, "unknown"),
        units: on_hand,
        age_days: age_days,
        old_price: current_price,
        new_price: new_price,
        markdown_loss: markdown_loss,
        reason: stale_inventory_reason(line, age_days, threshold)
      }

      {
        item
        |> Map.put(:price, new_price)
        |> Map.put(:last_markdown_day, day),
        entry
      }
    end
  end

  defp stale_age_threshold(line) do
    case get(line, :category, "sealed") do
      "accessory" -> 8
      _ -> 8
    end
  end

  defp stale_target_price(line, item, threshold) do
    age_days = get(item, :age_days, 0)
    market_price = get(line, :market_price, get(item, :price, 0.0))
    markdown_pct = min(0.25, 0.06 + max(0, age_days - threshold) * 0.025)

    Float.round(market_price * (1.0 - markdown_pct), 2)
  end

  defp stale_inventory_reason(line, age_days, threshold) do
    category = get(line, :category, "sealed")

    if category == "accessory" do
      "slow accessory turnover after #{age_days} days on shelf"
    else
      "stale sealed inventory exceeded #{threshold}-day target turn"
    end
  end
end
