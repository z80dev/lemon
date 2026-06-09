defmodule LemonSim.Examples.VendingBench.Facts.SupplierOrderPlaced do
  @moduledoc false

  @enforce_keys [
    :supplier_id,
    :item_id,
    :quantity,
    :unit_cost,
    :total_cost,
    :delivery_day
  ]
  defstruct [
    :supplier_id,
    :item_id,
    :quantity,
    :unit_cost,
    :total_cost,
    :delivery_day,
    :metadata
  ]

  def from_quote(cmd, quote) do
    metadata = Map.get(quote, :metadata, %{})
    total_cost = Map.fetch!(quote, :cost)
    quantity = Map.fetch!(quote, :quantity)

    %__MODULE__{
      supplier_id: Map.fetch!(quote, :supplier_id),
      item_id: get(metadata, :delivered_item_id, Map.fetch!(quote, :item_id)),
      quantity: quantity,
      unit_cost: Float.round(total_cost / quantity, 4),
      total_cost: total_cost,
      delivery_day: Map.fetch!(quote, :delivery_day),
      metadata:
        metadata
        |> Map.put(:ordered_item_id, cmd.item_id)
        |> Map.put(:request_id, cmd.request_id)
    }
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
