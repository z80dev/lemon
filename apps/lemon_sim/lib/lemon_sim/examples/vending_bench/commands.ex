defmodule LemonSim.Examples.VendingBench.Commands.PlaceSupplierOrder do
  @moduledoc false

  @enforce_keys [:actor, :supplier_id, :item_id, :quantity]
  defstruct [:actor, :supplier_id, :item_id, :quantity, :request_id, :negotiated?]

  def new(payload) when is_map(payload) do
    %__MODULE__{
      actor: get(payload, :actor, get(payload, :actor_id, "operator")),
      supplier_id: get(payload, :supplier_id, ""),
      item_id: get(payload, :item_id, ""),
      quantity: get(payload, :quantity, 0),
      request_id: get(payload, :request_id),
      negotiated?: get(payload, :negotiated, get(payload, :negotiated?, false))
    }
  end

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
