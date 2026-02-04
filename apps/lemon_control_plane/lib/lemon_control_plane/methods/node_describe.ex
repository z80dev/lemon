defmodule LemonControlPlane.Methods.NodeDescribe do
  @moduledoc """
  Handler for the node.describe control plane method.

  Gets detailed information about a specific node.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.describe"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"] || params["node_id"]

    if is_nil(node_id) or node_id == "" do
      {:error, Errors.invalid_request("nodeId is required")}
    else
      case LemonCore.Store.get(:nodes_registry, node_id) do
        nil ->
          {:error, Errors.not_found("Node not found")}

        node ->
          # Safe access supporting both atom and string keys (for JSONL reload)
          {:ok, %{
            "nodeId" => get_field(node, :id),
            "name" => get_field(node, :name),
            "type" => get_field(node, :type),
            "capabilities" => get_field(node, :capabilities) || %{},
            "status" => to_string(get_field(node, :status) || :unknown),
            "pairedAtMs" => get_field(node, :paired_at_ms),
            "lastSeenMs" => get_field(node, :last_seen_ms),
            "metadata" => get_field(node, :metadata) || %{}
          }}
      end
    end
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
