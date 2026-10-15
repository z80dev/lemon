defmodule LemonControlPlane.NodeSecretProofs do
  @moduledoc "Owner/session admission and post-provision acknowledgement for private native proof secrets."
  alias LemonControlPlane.Protocol.Errors

  # Match the vault's String.trim normalization before deciding namespace. A
  # whitespace-decorated name must not bypass the private proof admission path.
  def dispatch_opts(node_id, %{"name" => name} = args) when is_binary(name) do
    case String.trim(name) do
      "lemon_bot/invocations/" <> run_id ->
        if args["operationId"] == run_id do
          destination_opts(run_id, node_id)
        else
          {:error,
           Errors.invalid_request("Private invocation proof requires its exact operationId")}
        end

      _ ->
        {:ok, []}
    end
  end

  def dispatch_opts(_node_id, _args), do: {:ok, []}

  defp destination_opts(run_id, node_id) do
    case LemonRouter.NativeLineage.pending_destination(run_id, node_id) do
      {:ok, %{node_id: ^node_id, pid: pid, generation: generation}}
      when is_pid(pid) and is_integer(generation) and generation >= 0 ->
        {:ok, pinned_opts(pid, generation, :pending)}

      {:error, :not_found} ->
        # Only strict owning-Store absence permits a new pre-admission root.
        # Stale/finished/mismatched follow-ups never enter this path.
        fresh_destination_opts(node_id)

      {:error, :invalid_run_id} ->
        {:error, Errors.invalid_request("Invalid private invocation proof operationId")}

      {:error, :not_pending} ->
        {:error,
         Errors.error(:conflict, "Private invocation proof is not pending", %{
           "reason" => "private_proof_not_pending",
           "preDispatch" => true,
           "retrySafe" => false
         })}

      {:error, :destination_mismatch} ->
        {:error,
         Errors.error(:forbidden, "Private invocation proof destination changed", %{
           "reason" => "private_proof_destination_mismatch",
           "preDispatch" => true,
           "retrySafe" => false
         })}

      _ ->
        unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    :exit, _ -> unavailable()
  end

  defp fresh_destination_opts(node_id) do
    case LemonCore.NodeRegistry.resolve_id(node_id) do
      {:ok, %{id: ^node_id, pid: pid, generation: generation}}
      when is_pid(pid) and is_integer(generation) and generation >= 0 ->
        {:ok, pinned_opts(pid, generation, :root)}

      _ ->
        unavailable()
    end
  end

  defp pinned_opts(pid, generation, kind),
    do: [
      expected_pid: pid,
      expected_generation: generation,
      required_native_privacy_context: 1,
      private_proof_kind: kind
    ]

  def verify_after_dispatch(node_id, args, opts) do
    case opts[:private_proof_kind] do
      nil ->
        :ok

      kind when kind in [:root, :pending] ->
        run_id = args["operationId"]
        pid = opts[:expected_pid]
        generation = opts[:expected_generation]

        owner_valid =
          case {kind, LemonRouter.NativeLineage.pending_destination(run_id, node_id)} do
            {:pending, {:ok, %{node_id: ^node_id, pid: ^pid, generation: ^generation}}} -> true
            {:root, {:error, :not_found}} -> true
            _ -> false
          end

        if owner_valid and current_destination?(node_id, pid, generation),
          do: :ok,
          else: acknowledgement_changed()

      _ ->
        acknowledgement_changed()
    end
  rescue
    _ -> acknowledgement_changed()
  catch
    :exit, _ -> acknowledgement_changed()
  end

  defp current_destination?(node_id, pid, generation) do
    case LemonCore.NodeRegistry.resolve_id(node_id) do
      {:ok, %{id: ^node_id, pid: ^pid, generation: ^generation, metadata: metadata}} ->
        LemonCore.NodeRegistry.native_privacy_context_supported?(metadata)

      _ ->
        false
    end
  end

  defp acknowledgement_changed do
    {:error,
     Errors.error(
       :unavailable,
       "Private proof authority changed after provisioning; do not replay",
       %{
         "reason" => "private_proof_acknowledgement_changed",
         "preDispatch" => false,
         "retrySafe" => false,
         "mutationMayHaveApplied" => true
       }
     )}
  end

  defp unavailable do
    {:error,
     Errors.error(:unavailable, "Private invocation proof destination is unavailable", %{
       "reason" => "private_proof_destination_unavailable",
       "preDispatch" => true,
       "retrySafe" => false
     })}
  end
end
