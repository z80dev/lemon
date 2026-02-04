defmodule LemonControlPlane.Methods.NodeInvokeResult do
  @moduledoc """
  Handler for the node.invoke.result control plane method.

  Called by nodes to report the result of an invocation.
  Role: node
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.invoke.result"

  @impl true
  def scopes, do: []  # Node role required

  @impl true
  def handle(params, ctx) do
    # Verify node role - check ctx.auth.role (dispatcher passes ctx.auth in :auth key)
    auth = ctx[:auth] || ctx
    role = auth[:role] || auth.role

    if role != :node do
      {:error, Errors.forbidden("This method requires node role")}
    else
      invoke_id = params["invokeId"] || params["invoke_id"]
      result = params["result"]
      error = params["error"]

      if is_nil(invoke_id) or invoke_id == "" do
        {:error, Errors.invalid_request("invokeId is required")}
      else
        case LemonCore.Store.get(:node_invocations, invoke_id) do
          nil ->
            {:error, Errors.not_found("Invocation not found")}

          invocation ->
            # Update invocation with result (use Map.merge since keys may not exist)
            updates = %{
              status: if(error, do: :error, else: :completed),
              result: result,
              error: error,
              completed_at_ms: System.system_time(:millisecond)
            }
            updated = Map.merge(invocation, updates)
            LemonCore.Store.put(:node_invocations, invoke_id, updated)

            # Broadcast result event
            # Safe access supporting both atom and string keys (for JSONL reload)
            event = LemonCore.Event.new(:node_invoke_completed, %{
              invoke_id: invoke_id,
              node_id: get_field(invocation, :node_id),
              result: result,
              error: error,
              ok: is_nil(error)
            })
            LemonCore.Bus.broadcast("nodes", event)

            {:ok, %{
              "invokeId" => invoke_id,
              "received" => true
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
