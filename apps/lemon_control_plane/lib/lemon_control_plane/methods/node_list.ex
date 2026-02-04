defmodule LemonControlPlane.Methods.NodeList do
  @moduledoc """
  Handler for the node.list control plane method.

  Lists all registered nodes.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "node.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    nodes =
      LemonCore.Store.list(:nodes_registry)
      |> Enum.map(fn {_id, node} -> format_node(node) end)
      |> Enum.sort_by(& &1["name"])

    {:ok, %{"nodes" => nodes}}
  end

  defp format_node(node) do
    # Safe access supporting both atom and string keys (for JSONL reload)
    %{
      "nodeId" => get_field(node, :id),
      "name" => get_field(node, :name),
      "type" => get_field(node, :type),
      "capabilities" => get_field(node, :capabilities) || %{},
      "status" => to_string(get_field(node, :status) || :unknown),
      "pairedAtMs" => get_field(node, :paired_at_ms),
      "lastSeenMs" => get_field(node, :last_seen_ms)
    }
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
