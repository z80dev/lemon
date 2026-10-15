defmodule LemonControlPlane.Methods.ExecApprovalResolve do
  @moduledoc """
  Handler for the exec.approval.resolve method.

  Returns an owner-verified decision, optionally bound to an exact session/run.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "exec.approval.resolve"

  @impl true
  def scopes, do: [:approvals]

  @impl true
  def handle(params, _ctx) do
    approval_id = params["approvalId"]
    decision = parse_decision(params["decision"])

    cond do
      not valid_identity?(approval_id) ->
        {:error, {:invalid_request, "approvalId is required and must be a nonempty string", nil}}

      is_nil(params["decision"]) ->
        {:error, {:invalid_request, "decision is required", nil}}

      is_nil(decision) ->
        {:error,
         {:invalid_request,
          "Invalid decision. Must be one of: approve_once, approve_session, approve_agent, approve_global, deny",
          nil}}

      not valid_binding?(params, "expectedSessionKey") or
          not valid_binding?(params, "expectedRunId") ->
        {:error, {:invalid_request, "Expected identities must be nonempty strings", nil}}

      true ->
        opts =
          [{"expectedSessionKey", :expected_session_key}, {"expectedRunId", :expected_run_id}]
          |> Enum.flat_map(fn {field, option} ->
            if Map.has_key?(params, field), do: [{option, params[field]}], else: []
          end)

        case LemonCore.ExecApprovals.resolve(approval_id, decision, opts) do
          {:ok, receipt} -> {:ok, project_receipt(receipt)}
          {:error, reason} -> resolution_error(approval_id, reason)
        end
    end
  end

  defp valid_identity?(value), do: is_binary(value) and byte_size(value) in 1..1024

  defp valid_binding?(params, field),
    do: not Map.has_key?(params, field) or valid_identity?(params[field])

  defp project_receipt(receipt) do
    decision = Atom.to_string(receipt.decision)
    outcome = Atom.to_string(receipt.outcome)

    %{
      "resolved" => true,
      "approvalId" => receipt.approval_id,
      "sessionKey" => receipt.session_key,
      "runId" => receipt.run_id,
      "decision" => decision,
      "outcome" => outcome,
      "approved" => receipt.outcome == :approved,
      "replayed" => receipt.replayed,
      "resolvedAtMs" => receipt.resolved_at_ms,
      "summary" => %{
        "approvalId" => receipt.approval_id,
        "resolved" => true,
        "decision" => decision,
        "outcome" => outcome,
        "cleanup" => %{
          "includesAction" => false,
          "includesRationale" => false,
          "includesSecretValues" => false
        }
      }
    }
  end

  defp resolution_error(approval_id, reason) do
    {code, message} =
      case reason do
        :not_found -> {:not_found, "Approval not found"}
        :mismatch -> {:conflict, "Approval identity or preview changed"}
        :expired -> {:conflict, "Approval expired"}
        :cancelled -> {:conflict, "Approval cancelled"}
        :conflict -> {:conflict, "Approval already resolved with another decision"}
        :already_resolved -> {:conflict, "Approval already resolved; exact identities required"}
        :resolution_in_progress -> {:conflict, "Approval resolution is in progress"}
        :store_unavailable -> {:unavailable, "Approval resolution unavailable"}
        _ -> {:invalid_request, "Invalid approval resolution"}
      end

    {:error, {code, message, %{"approvalId" => approval_id, "reason" => Atom.to_string(reason)}}}
  end

  defp parse_decision("approve_once"), do: :approve_once
  defp parse_decision("approveOnce"), do: :approve_once
  defp parse_decision("approve_session"), do: :approve_session
  defp parse_decision("approveSession"), do: :approve_session
  defp parse_decision("approve_agent"), do: :approve_agent
  defp parse_decision("approveAgent"), do: :approve_agent
  defp parse_decision("approve_global"), do: :approve_global
  defp parse_decision("approveGlobal"), do: :approve_global
  defp parse_decision("deny"), do: :deny
  defp parse_decision(_), do: nil
end
