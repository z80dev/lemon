defmodule LemonControlPlane.NodeIO do
  @moduledoc "Destination-targeted, connection-owned machine I/O invocation boundary."
  require Logger
  alias LemonControlPlane.Protocol.Errors

  def invoke(node_id, method, args, ctx, opts \\ [])

  def invoke(node_id, method, args, ctx, opts) when is_binary(node_id) and is_map(args) do
    owner = ctx[:conn_pid] || self()
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    ref = Process.monitor(owner)

    result =
      try do
        case LemonControlPlane.NodeStore.get_node(node_id) do
          nil ->
            {:error,
             Errors.error(:not_found, "Node not found", %{
               "preDispatch" => true,
               "retrySafe" => false
             })}

          node when is_map(node) ->
            case LemonCore.NodeRegistry.invoke_node(node_id, method, args,
                   recipient: self(),
                   timeout_ms: timeout_ms,
                   max_payload_bytes: LemonControlPlane.max_payload(),
                   expected_pid: opts[:expected_pid],
                   expected_generation: opts[:expected_generation],
                   required_native_privacy_context: opts[:required_native_privacy_context],
                   required_process_execution: opts[:required_process_execution]
                 ) do
              {:ok, invoke_id} ->
                await(invoke_id, ref, owner, timeout_ms + 1_000)

              {:error, {:node_connection_changed, _}} ->
                {:error,
                 Errors.error(:conflict, "Inspected node session changed before dispatch", %{
                   "reason" => "node_connection_changed",
                   "preDispatch" => true,
                   "retrySafe" => false
                 })}

              {:error, {:native_privacy_context_unsupported, _}} ->
                {:error,
                 Errors.error(
                   :unavailable,
                   "Node does not support private native proof provisioning",
                   %{
                     "reason" => "native_privacy_context_unsupported",
                     "preDispatch" => true,
                     "retrySafe" => false
                   }
                 )}

              {:error, {:process_execution_unsupported, _}} ->
                {:error,
                 Errors.error(:unavailable, "Node does not support native process execution", %{
                   "reason" => "process_execution_unsupported",
                   "preDispatch" => true,
                   "retrySafe" => false
                 })}

              {:error, _} ->
                {:error,
                 Errors.error(:unavailable, "Node is not available", %{
                   "preDispatch" => true,
                   "retrySafe" => false
                 })}
            end

          _ ->
            {:error,
             Errors.error(:unavailable, "Durable node store is not available", %{
               "preDispatch" => true,
               "retrySafe" => false
             })}
        end
      after
        Process.demonitor(ref, [:flush])
      end

    outcome = if match?({:ok, _}, result), do: "ok", else: "error"
    Logger.info("node_io operation=#{method} outcome=#{outcome} redacted=true")
    result
  end

  def invoke(_node_id, _method, _args, _ctx, _opts),
    do: {:error, Errors.invalid_request("nodeId must be a string")}

  defp await(invoke_id, ref, owner, wait_ms) do
    receive do
      {:lemon_node_result, ^invoke_id, {:ok, result}} ->
        {:ok, result}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, "target_mismatch"}}} ->
        {:error, Errors.error(:conflict, "Provider target does not match this machine")}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, "provider_binding_rejected"}}} ->
        {:error,
         Errors.error(:forbidden, "Provider login binding rejected by destination", %{
           "reason" => "provider_binding_rejected",
           "retrySafe" => false,
           "mutationMayHaveApplied" => false
         })}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in ["process_receipt_limit", "process_limit", "process_busy"] ->
        {:error,
         Errors.error(:unavailable, "Destination process admission capacity is unavailable", %{
           "reason" => reason,
           "retrySafe" => false,
           "mutationMayHaveApplied" => false
         })}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, "process_intent_conflict"}}} ->
        {:error,
         Errors.error(:conflict, "Fixed process ID has a different immutable intent", %{
           "reason" => "process_intent_conflict",
           "retrySafe" => false,
           "mutationMayHaveApplied" => false
         })}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in ["process_owner_mismatch", "stale_generation"] ->
        {:error,
         Errors.error(
           :forbidden,
           "Destination process belongs to another authenticated session",
           %{"reason" => reason, "retrySafe" => false, "mutationMayHaveApplied" => false}
         )}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in [
             "revision_conflict",
             "stale_preview",
             "already_exists",
             "mutation_conflict",
             "secret_operation_conflict"
           ] ->
        {:error,
         Errors.error(
           :conflict,
           "Destination revision, candidate set or operation binding changed",
           %{"reason" => reason, "retrySafe" => false}
         )}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in ["permission_denied", "forbidden"] ->
        {:error,
         Errors.error(:forbidden, "Destination denied access", %{
           "reason" => "permission_denied",
           "retrySafe" => false
         })}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in [
             "host_metrics_unavailable",
             "capability_inspection_unavailable",
             "secret_receipt_capacity",
             "filesystem_busy"
           ] ->
        {:error,
         Errors.error(
           :unavailable,
           "Destination inspection or operation admission is unavailable",
           %{"reason" => reason, "retrySafe" => true}
         )}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in [
             "atomic_move_unavailable",
             "filesystem_outcome_unknown",
             "secret_store_failed",
             "directory_not_empty"
           ] ->
        {:error,
         Errors.error(
           :unavailable,
           "Destination operation failed; reconcile before another mutation",
           %{"reason" => reason, "retrySafe" => false}
         )}

      {:lemon_node_result, ^invoke_id, {:error, {:remote, reason}}}
      when reason in [
             "invalid_request",
             "invalid_path",
             "path_not_allowed",
             "invalid_allowed_roots",
             "symlink_loop",
             "not_found",
             "not_directory",
             "not_regular_file",
             "content_too_large",
             "invalid_base64",
             "confirmation_required",
             "invalid_confirmation_token",
             "confirmation_expired",
             "preview_too_large",
             "invalid_secret_name",
             "invalid_secret_value",
             "invalid_operation_id",
             "invalid_node_id",
             "invalid_input",
             "invalid_dimensions",
             "shell_not_found",
             "shell_closed",
             "pty_busy"
           ] ->
        {:error,
         Errors.error(:invalid_request, "Destination rejected operation", %{
           "reason" => reason,
           "retrySafe" => true
         })}

      {:lemon_node_result, ^invoke_id, {:error, _}} ->
        {:error,
         Errors.error(
           :unavailable,
           "Destination operation failed; mutation outcome may be unknown",
           %{"preDispatch" => false, "retrySafe" => false, "mutationMayHaveApplied" => true}
         )}

      {:DOWN, ^ref, :process, ^owner, _} ->
        LemonCore.NodeRegistry.cancel(invoke_id, :connection_closed)

        {:error,
         Errors.error(
           :unavailable,
           "Opening connection closed; mutation outcome may be unknown",
           %{"preDispatch" => false, "retrySafe" => false, "mutationMayHaveApplied" => true}
         )}
    after
      wait_ms ->
        LemonCore.NodeRegistry.cancel(invoke_id, :timeout)

        {:error,
         Errors.error(
           :unavailable,
           "Destination operation timed out; mutation outcome may be unknown",
           %{"preDispatch" => false, "retrySafe" => false, "mutationMayHaveApplied" => true}
         )}
    end
  end
end
