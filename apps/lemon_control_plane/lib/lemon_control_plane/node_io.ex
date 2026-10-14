defmodule LemonControlPlane.NodeIO do
  @moduledoc "Destination-targeted, connection-owned machine I/O invocation boundary."
  require Logger
  alias LemonControlPlane.Protocol.Errors

  def invoke(node_id, method, args, ctx) when is_binary(node_id) and is_map(args) do
    owner = ctx[:conn_pid] || self()
    ref = Process.monitor(owner)
    result = try do
      case LemonControlPlane.NodeStore.get_node(node_id) do
        nil -> {:error, Errors.not_found("Node not found")}
        _ ->
          case LemonCore.NodeRegistry.invoke(node_id, method, args,
                 recipient: self(), timeout_ms: 30_000,
                 max_payload_bytes: LemonControlPlane.max_payload()) do
            {:ok, invoke_id} -> await(invoke_id, ref, owner)
            {:error, _} -> {:error, Errors.unavailable("Node is not available")}
          end
      end
    after
      Process.demonitor(ref, [:flush])
    end
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"
    Logger.info("node_io operation=#{method} outcome=#{outcome} redacted=true")
    result
  end

  def invoke(_node_id, _method, _args, _ctx),
    do: {:error, Errors.invalid_request("nodeId must be a string")}

  defp await(invoke_id, ref, owner) do
    receive do
      {:lemon_node_result, ^invoke_id, {:ok, result}} -> {:ok, result}
      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
          when reason in ["invalid_request", "invalid_path", "path_not_allowed",
            "invalid_allowed_roots", "symlink_loop", "not_found", "permission_denied",
            "not_directory", "not_regular_file", "content_too_large", "invalid_base64",
            "directory_not_empty", "already_exists", "confirmation_required",
            "invalid_secret_name", "invalid_secret_value", "invalid_input", "invalid_dimensions",
            "shell_not_found", "shell_closed", "pty_busy"] ->
        {:error, Errors.error(:invalid_request, "Destination rejected operation", %{"reason" => reason, "retrySafe" => true})}
      {:lemon_node_result, ^invoke_id, {:error, _}} ->
        {:error, Errors.error(:unavailable, "Destination operation failed; mutation outcome may be unknown", %{"retrySafe" => false})}
      {:DOWN, ^ref, :process, ^owner, _} ->
        LemonCore.NodeRegistry.cancel(invoke_id, :connection_closed)
        {:error, Errors.unavailable("Opening connection closed")}
    after
      31_000 ->
        LemonCore.NodeRegistry.cancel(invoke_id, :timeout)
        {:error, Errors.error(:unavailable, "Destination operation timed out; mutation outcome may be unknown", %{"retrySafe" => false})}
    end
  end
end
