defmodule LemonControlPlane.Methods.NodeRename do
  @moduledoc """
  Handler for the node.rename control plane method.

  Renames a paired node.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.rename"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"] || params["node_id"]
    new_name = params["name"] || params["newName"] || params["new_name"]

    cond do
      is_nil(node_id) or node_id == "" ->
        {:error, Errors.invalid_request("nodeId is required")}

      is_nil(new_name) or new_name == "" ->
        {:error, Errors.invalid_request("name is required")}

      true ->
        case LemonCore.Store.get(:nodes_registry, node_id) do
          nil ->
            {:error, Errors.not_found("Node not found")}

          node ->
            # Use Map.merge instead of update syntax to handle both atom and string keys
            updated_node = Map.merge(node, %{name: new_name})
            LemonCore.Store.put(:nodes_registry, node_id, updated_node)

            {:ok, %{
              "nodeId" => node_id,
              "name" => new_name,
              "renamed" => true
            }}
        end
    end
  end
end
