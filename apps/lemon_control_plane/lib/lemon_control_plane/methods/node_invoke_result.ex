defmodule LemonControlPlane.Methods.NodeInvokeResult do
  @moduledoc """
  Handler for `node.invoke.result` and registry-driven terminal outcomes.

  A node may complete only invocations owned by the node ID in its authenticated
  connection context. The live registry remains the authority for pending
  invocation ownership; the control-plane store is the durable status view.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
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
    invoke_id = params["invokeId"] || params["invoke_id"]
    result = params["result"]
    error = params["error"]

    cond do
      role != :node ->
        {:error, Errors.forbidden("This method requires node role")}

      not is_binary(authenticated_node_id) or authenticated_node_id == "" ->
        {:error, Errors.forbidden("Authenticated node identity is required")}

      is_nil(invoke_id) or invoke_id == "" ->
        {:error, Errors.invalid_request("invokeId is required")}

      true ->
        complete_invocation(authenticated_node_id, invoke_id, result, error)
    end
  end

  @doc false
  def record_registry_result(invoke_id, {:ok, result}) when is_binary(invoke_id) do
    settle_pending(invoke_id, result, nil)
  end

  def record_registry_result(invoke_id, {:error, {:remote, error}})
      when is_binary(invoke_id) do
    settle_pending(invoke_id, nil, error)
  end

  def record_registry_result(invoke_id, {:error, reason}) when is_binary(invoke_id) do
    settle_pending(invoke_id, nil, inspect(reason))
  end

  defp complete_invocation(authenticated_node_id, invoke_id, result, error) do
    case NodeStore.get_invocation(invoke_id) do
      nil ->
        {:error, Errors.not_found("Invocation not found")}

      invocation ->
        expected_node_id = get_field(invocation, :node_id)

        cond do
          expected_node_id != authenticated_node_id ->
            {:error, Errors.forbidden("Invocation belongs to a different node")}

          not pending?(invocation) ->
            {:error, Errors.conflict("Invocation is no longer pending")}

          true ->
            complete_live_invocation(
              invocation,
              authenticated_node_id,
              invoke_id,
              result,
              error
            )
        end
    end
  end

  defp complete_live_invocation(
         invocation,
         authenticated_node_id,
         invoke_id,
         result,
         error
       ) do
    case LemonCore.NodeRegistry.complete(authenticated_node_id, invoke_id, result, error) do
      :ok ->
        settle_and_reply(invocation, invoke_id, result, error)

      {:error, :wrong_node} ->
        {:error, Errors.forbidden("Invocation belongs to a different node")}

      {:error, :not_found} ->
        if get_field(invocation, :registry_managed) do
          {:error, Errors.conflict("Invocation is no longer pending")}
        else
          # Compatibility for durable invocations created before NodeRegistry
          # became the live delivery authority.
          settle_and_reply(invocation, invoke_id, result, error)
        end
    end
  end

  defp settle_and_reply(invocation, invoke_id, result, error) do
    :ok = settle(invocation, invoke_id, result, error)

    {:ok,
     %{
       "invokeId" => invoke_id,
       "received" => true,
       "summary" => %{
         "invokeId" => invoke_id,
         "nodeId" => get_field(invocation, :node_id),
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

  defp settle_pending(invoke_id, result, error) do
    case NodeStore.get_invocation(invoke_id) do
      invocation when is_map(invocation) ->
        if pending?(invocation), do: settle(invocation, invoke_id, result, error), else: :ok

      _ ->
        :ok
    end
  end

  defp settle(invocation, invoke_id, result, error) do
    updated =
      Map.merge(invocation, %{
        status: if(error, do: :error, else: :completed),
        result: result,
        error: error,
        completed_at_ms: System.system_time(:millisecond)
      })

    with :ok <- NodeStore.put_invocation(invoke_id, updated) do
      event =
        LemonCore.Event.new(:node_invoke_completed, %{
          invoke_id: invoke_id,
          node_id: get_field(invocation, :node_id),
          result: result,
          error: error,
          ok: is_nil(error)
        })

      LemonCore.Bus.broadcast("nodes", event)
      :ok
    end
  end

  defp pending?(invocation), do: get_field(invocation, :status) in [:pending, "pending"]

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
