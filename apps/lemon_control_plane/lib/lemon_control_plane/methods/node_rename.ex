defmodule LemonControlPlane.Methods.NodeRename do
  @moduledoc """
  Handler for the node.rename control plane method.

  Renames a paired node.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.rename"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"] || params["node_id"]
    new_name = params["name"] || params["newName"] || params["new_name"]
    new_name = if(is_binary(new_name), do: String.trim(new_name), else: new_name)

    cond do
      is_nil(node_id) or node_id == "" ->
        {:error, Errors.invalid_request("nodeId is required")}

      is_nil(new_name) or new_name == "" ->
        {:error, Errors.invalid_request("name is required")}

      true ->
        case NodeStore.get_node(node_id) do
          nil ->
            {:error, Errors.not_found("Node not found")}

          node ->
            rename_node(node_id, node, new_name)
        end
    end
  end

  defp rename_node(node_id, node, new_name) do
    previous_name = old_name(node)

    case NodeStore.reserve_node_name(new_name, node_id) do
      :ok ->
        case rename_live_node(node_id, new_name) do
          :ok ->
            persist_rename(node_id, node, previous_name, new_name)

          {:error, {:name_taken, _name}} ->
            NodeStore.release_node_name(new_name, node_id)
            {:error, Errors.conflict("Node name is already in use")}
        end

      {:error, {:name_taken, _name}} ->
        {:error, Errors.conflict("Node name is already in use")}

      {:error, :invalid_name} ->
        {:error, Errors.invalid_request("name is required")}

      {:error, reason} ->
        {:error, Errors.internal_error("Failed to reserve node name", reason)}
    end
  end

  defp persist_rename(node_id, node, previous_name, new_name) do
    # Map.merge supports durable records reloaded with string keys.
    updated_node = Map.merge(node, %{name: new_name})

    case NodeStore.put_node(node_id, updated_node) do
      :ok ->
        if previous_name != new_name do
          NodeStore.release_node_name(previous_name, node_id)
        end

        {:ok,
         %{
           "nodeId" => node_id,
           "name" => new_name,
           "renamed" => true,
           "summary" => %{
             "nodeId" => node_id,
             "renamed" => true,
             "nameChanged" => previous_name != new_name,
             "cleanup" => %{
               "includesPreviousName" => false,
               "includesCapabilities" => false,
               "includesMetadata" => false,
               "includesCredentials" => false,
               "includesSecretValues" => false
             }
           }
         }}

      {:error, reason} ->
        if previous_name != new_name do
          NodeStore.release_node_name(new_name, node_id)
          restore_live_name(node_id, previous_name)
        end

        {:error, Errors.internal_error("Failed to rename node", reason)}
    end
  end

  defp rename_live_node(node_id, new_name) do
    case LemonCore.NodeRegistry.rename(node_id, new_name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, {:name_taken, _name}} = error -> error
    end
  end

  defp restore_live_name(node_id, previous_name) when is_binary(previous_name) do
    case LemonCore.NodeRegistry.rename(node_id, previous_name) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp restore_live_name(_node_id, _previous_name), do: :ok

  defp old_name(node) when is_map(node), do: Map.get(node, :name) || Map.get(node, "name")
end
