defmodule LemonControlPlane.Methods.NodeInvoke do
  @moduledoc """
  Handler for the node.invoke control plane method.

  Invokes a method on a remote node.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.invoke"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"] || params["node_id"]
    method = params["method"]
    args = params["args"] || %{}
    timeout_ms = params["timeoutMs"] || params["timeout_ms"] || 30_000

    cond do
      is_nil(node_id) or node_id == "" ->
        {:error, Errors.invalid_request("nodeId is required")}

      is_nil(method) or method == "" ->
        {:error, Errors.invalid_request("method is required")}

      true ->
        case LemonCore.Store.get(:nodes_registry, node_id) do
          nil ->
            {:error, Errors.not_found("Node not found")}

          node ->
            # Safe access supporting both atom and string keys (for JSONL reload)
            status = get_field(node, :status)

            if status != :online and status != "online" do
              {:error, Errors.unavailable("Node is not online")}
            else
              # Generate invoke request ID
              invoke_id = LemonCore.Id.uuid()

              # Store pending invocation
              invocation = %{
                id: invoke_id,
                node_id: node_id,
                method: method,
                args: args,
                status: :pending,
                created_at_ms: System.system_time(:millisecond),
                timeout_ms: timeout_ms
              }
              LemonCore.Store.put(:node_invocations, invoke_id, invocation)

              # Broadcast invoke request to node
              event = LemonCore.Event.new(:node_invoke_request, %{
                invoke_id: invoke_id,
                node_id: node_id,
                method: method,
                args: args,
                timeout_ms: timeout_ms
              })
              LemonCore.Bus.broadcast("nodes", event)

              {:ok, %{
                "invokeId" => invoke_id,
                "nodeId" => node_id,
                "method" => method,
                "status" => "pending"
              }}
            end
        end
    end
  end

  # Safe map access supporting both atom and string keys
  # This handles JSONL reload where keys become strings
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
