defmodule LemonControlPlane.Methods.NodeCapabilitiesGet do
  @moduledoc "Reads measured destination machinery, configured access and nonprompting OS grants."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Protocol.Errors
  @impl true
  def name, do: "node.capabilities.get"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx) do
    node_id = params["nodeId"]
    if is_binary(node_id) and byte_size(node_id) in 1..256 and String.trim(node_id) != "" do
      with {:ok, snapshot} <- LemonControlPlane.NodeIO.invoke(node_id, name(), %{}, ctx) do
        {:ok, Map.put(snapshot, "nodeId", node_id)}
      end
    else
      {:error, Errors.invalid_request("nodeId must be a bounded nonempty string")}
    end
  end
end
