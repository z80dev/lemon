defmodule LemonSim.Examples.VendingBench.Suppliers do
  @moduledoc """
  Static supplier directory for the Vending Bench simulation (Phase 1).

  Three honest suppliers with different item specialties, delivery times, and pricing.
  """

  @suppliers %{
    "freshco" => %{
      name: "FreshCo Distributors",
      items: %{
        "sparkling_water" => %{cost: 1.10, min_order: 6},
        "water" => %{cost: 0.40, min_order: 12},
        "energy_drink" => %{cost: 1.50, min_order: 6},
        "cola" => %{cost: 0.55, min_order: 12}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.0,
      description: "Beverage specialist. Fast 1-day delivery. Good prices on drinks."
    },
    "snackworld" => %{
      name: "SnackWorld Supply",
      items: %{
        "chips" => %{cost: 0.80, min_order: 8},
        "candy_bar" => %{cost: 0.60, min_order: 10},
        "trail_mix" => %{cost: 1.20, min_order: 6},
        "granola_bar" => %{cost: 0.85, min_order: 8}
      },
      delivery_days: 1,
      minimum_order: 6,
      markup: 0.0,
      description: "Snack specialist. 1-day delivery. Wide selection of snacks."
    },
    "drinkdepot" => %{
      name: "DrinkDepot Wholesale",
      items: %{
        "sparkling_water" => %{cost: 1.00, min_order: 12},
        "water" => %{cost: 0.35, min_order: 24},
        "energy_drink" => %{cost: 1.40, min_order: 12},
        "cola" => %{cost: 0.50, min_order: 24},
        "chips" => %{cost: 0.75, min_order: 12},
        "candy_bar" => %{cost: 0.55, min_order: 12}
      },
      delivery_days: 2,
      minimum_order: 12,
      markup: 0.0,
      description: "Bulk wholesaler. 2-day delivery but lower prices and larger selection."
    }
  }

  @spec directory() :: map()
  def directory, do: @suppliers

  @spec process_order(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, %{cost: float(), delivery_day: pos_integer()}} | {:error, String.t()}
  def process_order(supplier_id, item_id, quantity, current_day) do
    case Map.get(@suppliers, supplier_id) do
      nil ->
        {:error, "Unknown supplier: #{supplier_id}"}

      supplier ->
        case Map.get(supplier.items, item_id) do
          nil ->
            {:error, "#{supplier.name} does not carry #{item_id}"}

          item_info ->
            cond do
              quantity < item_info.min_order ->
                {:error,
                 "Minimum order for #{item_id} from #{supplier.name} is #{item_info.min_order} units"}

              quantity <= 0 ->
                {:error, "Quantity must be positive"}

              true ->
                total_cost = Float.round(item_info.cost * quantity * (1.0 + supplier.markup), 2)
                delivery_day = current_day + supplier.delivery_days

                {:ok, %{cost: total_cost, delivery_day: delivery_day}}
            end
        end
    end
  end

  @spec supplier_info_text(String.t()) :: String.t()
  def supplier_info_text(supplier_id) do
    case Map.get(@suppliers, supplier_id) do
      nil ->
        "Unknown supplier: #{supplier_id}"

      supplier ->
        items_text =
          supplier.items
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.map(fn {name, info} ->
            "  - #{name}: $#{:erlang.float_to_binary(info.cost, decimals: 2)}/unit (min order: #{info.min_order})"
          end)
          |> Enum.join("\n")

        """
        #{supplier.name} (#{supplier_id})
        #{supplier.description}
        Delivery: #{supplier.delivery_days} day(s)
        Items:
        #{items_text}
        """
    end
  end

  @spec directory_text() :: String.t()
  def directory_text do
    @suppliers
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, _} -> supplier_info_text(id) end)
    |> Enum.join("\n---\n")
  end
end
