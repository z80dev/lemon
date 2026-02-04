defmodule LemonControlPlane.Methods.ExecApprovalRequest do
  @moduledoc """
  Handler for the exec.approval.request control plane method.

  Creates an approval request for a tool execution.
  This is typically called by the agent runtime when a tool requires approval.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "exec.approval.request"

  @impl true
  def scopes, do: [:approvals]

  @impl true
  def handle(params, _ctx) do
    run_id = params["runId"] || params["run_id"]
    session_key = params["sessionKey"] || params["session_key"]
    tool = params["tool"]
    action = params["action"] || %{}
    rationale = params["rationale"]
    expires_in_ms = params["expiresInMs"] || params["expires_in_ms"] || 300_000

    cond do
      is_nil(tool) or tool == "" ->
        {:error, Errors.invalid_request("tool is required")}

      true ->
        if Code.ensure_loaded?(LemonRouter.ApprovalsBridge) do
          approval_id = LemonCore.Id.uuid()
          expires_at_ms = System.system_time(:millisecond) + expires_in_ms

          pending = %{
            id: approval_id,
            run_id: run_id,
            session_key: session_key,
            tool: tool,
            action: action,
            rationale: rationale,
            expires_at_ms: expires_at_ms,
            created_at_ms: System.system_time(:millisecond)
          }

          # Store the pending approval
          LemonCore.Store.put(:exec_approvals_pending, approval_id, pending)

          # Broadcast approval requested event
          event = LemonCore.Event.new(:approval_requested, %{pending: pending}, %{
            approval_id: approval_id,
            run_id: run_id,
            session_key: session_key
          })
          LemonCore.Bus.broadcast("exec_approvals", event)

          {:ok, %{
            "approvalId" => approval_id,
            "expiresAtMs" => expires_at_ms
          }}
        else
          {:error, Errors.not_implemented("ApprovalsBridge not available")}
        end
    end
  end
end
