defmodule LemonControlPlane.Methods.NodeInvoke do
  @moduledoc """
  Handler for the node.invoke control plane method.

  Invokes a method on one authenticated live node connection. Raw arguments
  are used only for the live dispatch; durable invocation records retain a
  content-free argument summary.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.invoke"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    node_id = params["nodeId"] || params["node_id"]
    method = params["method"]
    args = params["args"] || %{}
    timeout_ms = params["timeoutMs"] || params["timeout_ms"] || 30_000

    cond do
      not is_binary(node_id) or String.trim(node_id) == "" ->
        {:error, Errors.invalid_request("nodeId must be a non-empty string")}

      not is_binary(method) or String.trim(method) == "" ->
        {:error, Errors.invalid_request("method must be a non-empty string")}

      not is_map(args) ->
        {:error, Errors.invalid_request("args must be an object")}

      true ->
        invoke_bounded(node_id, method, args, timeout_ms, ctx)
    end
  end

  defp invoke_bounded(node_id, method, args, timeout_ms, ctx) do
    max_payload = LemonControlPlane.max_payload()

    case LemonCore.JSONPayload.validate(args, max_bytes: max_payload) do
      {:ok, stats} ->
        invoke_live_node(node_id, method, args, timeout_ms, ctx, max_payload, stats)

      {:error, reason} ->
        {:error,
         Errors.error(
           :invalid_request,
           "args violate JSON payload policy",
           payload_error_kind(reason)
         )}
    end
  end

  defp invoke_live_node(node_id, method, args, timeout_ms, ctx, max_payload, args_stats) do
    case NodeStore.get_node(node_id) do
      nil ->
        {:error, Errors.not_found("Node not found")}

      _node ->
        recipient = ctx[:conn_pid] || self()

        case LemonCore.NodeRegistry.invoke(node_id, method, args,
               recipient: recipient,
               timeout_ms: timeout_ms,
               max_payload_bytes: max_payload
             ) do
          {:ok, invoke_id} ->
            invocation = %{
              id: invoke_id,
              node_id: node_id,
              method: method,
              args_summary: payload_summary(args_stats),
              status: :pending,
              created_at_ms: System.system_time(:millisecond),
              timeout_ms: timeout_ms,
              registry_managed: true
            }

            case NodeStore.put_invocation(invoke_id, invocation) do
              :ok ->
                {:ok,
                 %{
                   "invokeId" => invoke_id,
                   "nodeId" => node_id,
                   "method" => method,
                   "status" => "pending",
                   "summary" => %{
                     "nodeId" => node_id,
                     "method" => method,
                     "status" => "pending",
                     "timeoutMs" => timeout_ms,
                     "argKeyCount" => arg_key_count(args),
                     "cleanup" => %{
                       "includesArgs" => false,
                       "includesResult" => false,
                       "includesError" => false,
                       "includesCredentials" => false,
                       "includesSecretValues" => false
                     }
                   }
                 }}

              {:error, reason} ->
                LemonCore.NodeRegistry.cancel(invoke_id, {:invocation_store_failed, reason})
                {:error, Errors.internal_error("Failed to persist node invocation", reason)}
            end

          {:error, {:node_offline, _node}} ->
            {:error, Errors.unavailable("Node is not online")}

          {:error, :invalid_timeout} ->
            {:error, Errors.invalid_request("timeoutMs must be a positive integer")}

          {:error, {:invalid_payload, reason}} ->
            {:error,
             Errors.error(
               :invalid_request,
               "args violate JSON payload policy",
               payload_error_kind(reason)
             )}

          {:error, reason} ->
            {:error, Errors.internal_error("Failed to invoke node", reason)}
        end
    end
  end

  defp payload_error_kind({kind, _detail})
       when kind in [:max_bytes, :max_depth, :max_items, :not_json_safe],
       do: kind

  defp payload_error_kind(_reason), do: :invalid

  defp arg_key_count(args) when is_map(args), do: map_size(args)
  defp arg_key_count(_), do: 0

  defp payload_summary(stats) do
    %{
      present: true,
      kind: :object,
      bytes: stats.bytes,
      depth: stats.depth,
      item_count: stats.item_count
    }
  end
end
