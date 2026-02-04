defmodule LemonControlPlane.Methods.ExecApprovalResolve do
  @moduledoc """
  Handler for the exec.approval.resolve method.

  Resolves a pending approval request.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "exec.approval.resolve"

  @impl true
  def scopes, do: [:approvals]

  @impl true
  def handle(params, _ctx) do
    approval_id = params["approvalId"]
    decision = params["decision"]

    cond do
      is_nil(approval_id) ->
        {:error, {:invalid_request, "approvalId is required", nil}}

      is_nil(decision) ->
        {:error, {:invalid_request, "decision is required", nil}}

      true ->
        decision_atom = parse_decision(decision)

        if is_nil(decision_atom) do
          {:error, {:invalid_request, "Invalid decision. Must be one of: approve_once, approve_session, approve_agent, approve_global, deny", nil}}
        else
          LemonRouter.ApprovalsBridge.resolve(approval_id, decision_atom)

          {:ok, %{
            "resolved" => true,
            "approvalId" => approval_id,
            "decision" => decision
          }}
        end
    end
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
