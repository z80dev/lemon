defmodule LemonControlPlane.NodeSecretProofs do
  @moduledoc "Pre-dispatch owner/session admission for private native invocation proof secrets."
  alias LemonControlPlane.Protocol.Errors

  # Match the vault's String.trim normalization before deciding namespace. A
  # whitespace-decorated name must not bypass the private proof admission path.
  def dispatch_opts(node_id, %{"name" => name} = args) when is_binary(name) do
    case String.trim(name) do
      "lemon_bot/invocations/" <> run_id ->
        if args["operationId"] == run_id do
          destination_opts(run_id, node_id)
        else
          {:error, Errors.invalid_request("Private invocation proof requires its exact operationId")}
        end
      _ -> {:ok, []}
    end
  end

  def dispatch_opts(_node_id, _args), do: {:ok, []}

  defp destination_opts(run_id, node_id) do
    case LemonRouter.NativeLineage.pending_destination(run_id, node_id) do
      {:ok, %{node_id: ^node_id, pid: pid, generation: generation}}
          when is_pid(pid) and is_integer(generation) and generation >= 0 ->
        {:ok, pinned_opts(pid, generation)}
      {:error, :not_found} ->
        # Only strict owning-Store absence permits a new pre-admission root.
        # Stale/finished/mismatched follow-ups never enter this path.
        fresh_destination_opts(node_id)
      {:error, :invalid_run_id} ->
        {:error, Errors.invalid_request("Invalid private invocation proof operationId")}
      {:error, :not_pending} ->
        {:error, Errors.error(:conflict, "Private invocation proof is not pending",
          %{"reason" => "private_proof_not_pending", "preDispatch" => true, "retrySafe" => false})}
      {:error, :destination_mismatch} ->
        {:error, Errors.error(:forbidden, "Private invocation proof destination changed",
          %{"reason" => "private_proof_destination_mismatch", "preDispatch" => true, "retrySafe" => false})}
      _ -> unavailable()
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
        {:ok, pinned_opts(pid, generation)}
      _ -> unavailable()
    end
  end

  defp pinned_opts(pid, generation), do: [expected_pid: pid,
    expected_generation: generation, required_native_privacy_context: 1]

  defp unavailable do
    {:error, Errors.error(:unavailable, "Private invocation proof destination is unavailable",
      %{"reason" => "private_proof_destination_unavailable", "preDispatch" => true, "retrySafe" => false})}
  end
end
