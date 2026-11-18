defmodule LemonControlPlane.Methods.NodeInvokeResult do
  @moduledoc """
  Handler for `node.invoke.result`.

  A node may complete only invocations owned by the node ID and live session of
  its authenticated connection. The live `LemonCore.NodeRegistry` invocation is
  the sole authority: it validates the result and delivers it to the
  invocation's recipient. Nothing is persisted here.
  """

  @behaviour LemonControlPlane.Method

  import LemonControlPlane.Methods.NodeSession,
    only: [session_generation: 1, current_session?: 2, get_field: 2]

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.invoke.result"

  @impl true
  def scopes, do: [:invoke]

  @impl true
  def handle(params, ctx) do
    auth = ctx[:auth] || ctx
    role = get_field(auth, :role)
    authenticated_node_id = get_field(auth, :client_id)
    connection_pid = ctx[:conn_pid]
    generation = session_generation(auth)
    invoke_id = params["invokeId"] || params["invoke_id"]
    result = params["result"]
    error = params["error"]

    cond do
      role != :node ->
        {:error, Errors.forbidden("This method requires node role")}

      not is_binary(authenticated_node_id) or authenticated_node_id == "" ->
        {:error, Errors.forbidden("Authenticated node identity is required")}

      not is_binary(invoke_id) or String.trim(invoke_id) == "" ->
        {:error, Errors.invalid_request("invokeId must be a non-empty string")}

      not is_pid(connection_pid) ->
        {:error, Errors.forbidden("Authenticated node connection is required")}

      not current_session?(authenticated_node_id, generation) ->
        {:error, Errors.forbidden("Node session has been superseded")}

      true ->
        complete_invocation(
          authenticated_node_id,
          connection_pid,
          generation,
          invoke_id,
          result,
          error
        )
    end
  end

  defp complete_invocation(
         authenticated_node_id,
         connection_pid,
         generation,
         invoke_id,
         result,
         error
       ) do
    case LemonCore.NodeRegistry.complete_session(
           authenticated_node_id,
           connection_pid,
           generation,
           invoke_id,
           result,
           error
         ) do
      :ok ->
        accepted_reply(authenticated_node_id, invoke_id, result, error)

      {:error, :wrong_node} ->
        {:error, Errors.forbidden("Invocation belongs to a different node")}

      {:error, :not_found} ->
        {:error, Errors.not_found("Invocation not found")}

      {:error, :stale_session} ->
        {:error, Errors.forbidden("Invocation belongs to a superseded node session")}

      {:error, {:invalid_payload, reason}} ->
        {:error,
         Errors.error(
           :invalid_request,
           "result violates JSON payload policy",
           payload_error_kind(reason)
         )}
    end
  end

  defp accepted_reply(node_id, invoke_id, result, error) do
    {:ok,
     %{
       "invokeId" => invoke_id,
       "received" => true,
       "summary" => %{
         "invokeId" => invoke_id,
         "nodeId" => node_id,
         "status" => if(error, do: "error", else: "completed"),
         "ok" => is_nil(error),
         "hasResult" => not is_nil(result),
         "hasError" => not is_nil(error),
         "cleanup" => %{
           "includesResult" => false,
           "includesError" => false,
           "includesArgs" => false,
           "includesCredentials" => false,
           "includesSecretValues" => false
         }
       }
     }}
  end

  defp payload_error_kind({kind, _detail})
       when kind in [:max_bytes, :max_depth, :max_items, :not_json_safe],
       do: kind

  defp payload_error_kind(_reason), do: :invalid
end
